#!/usr/bin/env node
/*
 * report.mjs —— 从 Gradle 构建日志里榨出「时间去哪了」与「缓存命中率」
 * ==========================================================================
 * 为什么用解析日志、而不是在 init 脚本里挂监听器：
 *   Gradle 9 起配置缓存问题默认=构建失败，而 TaskExecutionGraph.beforeTask/afterTask、
 *   Gradle.buildFinished 的监听器注册都被配置缓存判为 unsupported ⇒ 一旦注册，
 *   配置缓存条目作废 **并且整个构建 FAILED**。为了看数据把构建搞挂，是笔亏本买卖。
 *   （实测现场：evidence/01-cc-listener-trap.md）
 *
 * 用法：
 *   node tools/report.mjs <build.log> [--json] [--out result.json] [--profile <profile.html>]
 * 输出：
 *   人类可读摘要（默认）或 JSON（--json / --out）
 */

import fs from 'node:fs'
import path from 'node:path'

const args = process.argv.slice(2)
const logPath = args.find((a) => !a.startsWith('--'))
const asJson = args.includes('--json')
const asMarkdown = args.includes('--markdown')
const outIdx = args.indexOf('--out')
const outPath = outIdx >= 0 ? args[outIdx + 1] : null
const profileIdx = args.indexOf('--profile')
const profilePath = profileIdx >= 0 ? args[profileIdx + 1] : null

if (!logPath) {
  console.error('用法: node tools/report.mjs <build.log> [--json] [--out result.json] [--profile profile.html]')
  process.exit(2)
}

const log = fs.readFileSync(logPath, 'utf8')
const lines = log.split(/\r?\n/)

// ---- 任务态：Gradle 的 plain 控制台逐行形如 "> Task :compileJava FROM-CACHE" ----
const states = { fromCache: [], upToDate: [], skipped: [], noSource: [], failed: [], executed: [] }
const suffixMap = {
  'FROM-CACHE': 'fromCache',
  'UP-TO-DATE': 'upToDate',
  SKIPPED: 'skipped',
  'NO-SOURCE': 'noSource',
  FAILED: 'failed',
}
for (const line of lines) {
  const m = line.match(/^>\s+Task\s+(\S+)(?:\s+([A-Z-]+))?\s*$/)
  if (!m) continue
  const [, task, suffix] = m
  const bucket = suffix && suffixMap[suffix] ? suffixMap[suffix] : 'executed'
  states[bucket].push(task)
}
// 同一个任务可能被打印多次（重试/多项目），按唯一路径去重后再统计
for (const k of Object.keys(states)) states[k] = [...new Set(states[k])]

// ---- 配置缓存状态 ----
let cc = { status: 'unknown', reason: '' }
if (/Reusing configuration cache\./.test(log)) cc = { status: 'reused', reason: '' }
else if (/Configuration cache entry stored\./.test(log)) cc = { status: 'stored', reason: '' }
const calc = log.match(/Calculating task graph as configuration cache cannot be reused because ([^\n.]+)/)
if (calc) cc = { status: 'recalculated', reason: calc[1].trim() }

// ---- 构建结果与耗时 ----
const res = log.match(/^BUILD (SUCCESSFUL|FAILED) in (.+)$/m)
const result = res ? res[1] : 'UNKNOWN'
const buildTimeText = res ? res[2].trim() : ''
const toSeconds = (t) => {
  if (!t) return null
  let s = 0
  const h = t.match(/(\d+)\s*h/)
  const m = t.match(/(\d+)\s*m(?!s)/)
  const sec = t.match(/([\d.]+)\s*s/)
  if (h) s += Number(h[1]) * 3600
  if (m) s += Number(m[1]) * 60
  if (sec) s += Number(sec[1])
  return s || null
}

// ---- 枢纽横幅（init 脚本打的配置摘要）----
const bannerLine = lines.find((l) => l.includes('[mc-build-hub] 配置 ')) || ''
const banner = {}
for (const kv of bannerLine.replace(/^.*配置\s*/, '').split(/\s+/)) {
  const i = kv.indexOf('=')
  if (i > 0) banner[kv.slice(0, i)] = kv.slice(i + 1)
}

// ---- 可选：解析 --profile 生成的 HTML ----
// 这份报告才是"时间去哪了"的权威口径：启动 / Settings+buildSrc / 配置 / 转换 / 执行 五段，
// --scan 那种细粒度剖析要联网+接受条款，不适合塞进每一条 CI。
let profile = null
if (profilePath && fs.existsSync(profilePath)) profile = parseProfile(profilePath)
const slowest = profile ? profile.slowestTasks : []

const cacheRelevant = states.fromCache.length + states.executed.length
const cacheHitRate = cacheRelevant ? Math.round((states.fromCache.length / cacheRelevant) * 1000) / 10 : 0

const report = {
  log: path.resolve(logPath),
  result,
  buildTimeText,
  buildSeconds: toSeconds(buildTimeText),
  configurationCache: cc,
  hub: banner,
  tasks: {
    total: Object.values(states).reduce((n, a) => n + a.length, 0),
    executed: states.executed.length,
    fromCache: states.fromCache.length,
    upToDate: states.upToDate.length,
    skipped: states.skipped.length,
    noSource: states.noSource.length,
    failed: states.failed.length,
  },
  cacheHitRatePct: cacheHitRate,
  fromCacheTasks: states.fromCache,
  executedTasks: states.executed,
  failedTasks: states.failed,
  profile,
  slowestTasks: slowest,
}

if (outPath) {
  fs.mkdirSync(path.dirname(path.resolve(outPath)), { recursive: true })
  fs.writeFileSync(outPath, JSON.stringify(report, null, 2))
}

if (asMarkdown) {
  console.log(toMarkdown(report))
} else if (asJson) {
  console.log(JSON.stringify(report, null, 2))
} else {
  const ccText = { reused: '复用（0 配置开销）', stored: '新建并存储', recalculated: `重算：${cc.reason}`, unknown: '未知' }[cc.status]
  console.log(`构建结果        : ${result}${buildTimeText ? ` （Gradle 计时 ${buildTimeText}）` : ''}`)
  console.log(`配置缓存        : ${ccText}`)
  if (banner.gradle) console.log(`环境            : gradle=${banner.gradle} java=${banner.java} remote=${banner.remote} push=${banner.push}`)
  console.log(`任务            : 共 ${report.tasks.total}（执行 ${report.tasks.executed} / 缓存命中 ${report.tasks.fromCache} / 最新 ${report.tasks.upToDate} / 跳过 ${report.tasks.skipped}）`)
  console.log(`构建缓存命中率  : ${cacheHitRate}%（from-cache ÷ (from-cache + 执行)）`)
  if (profile) {
    const f = (v) => (v == null ? '-' : `${(v / 1000).toFixed(1)}s`)
    console.log(`时间分布        : 启动 ${f(profile.startupMs)} ｜ Settings+buildSrc ${f(profile.settingsMs)} ｜ 配置项目 ${f(profile.configuringMs)} ｜ 转换 ${f(profile.transformsMs)} ｜ 任务执行 ${f(profile.executionMs)} ｜ 合计 ${f(profile.totalMs)}`)
    if (profile.startupMs > 30000) console.log('                  ↳ 启动段偏大：冷 GRADLE_USER_HOME 时这里含 Gradle 发行版下载/解包')
  }
  if (states.fromCache.length) {
    console.log(`命中任务示例    : ${states.fromCache.slice(0, 8).join(', ')}${states.fromCache.length > 8 ? ` …共 ${states.fromCache.length} 个` : ''}`)
  }
  if (slowest.length) {
    console.log('最慢任务        :')
    for (const t of slowest.slice(0, 12)) console.log(`  ${String(t.ms).padStart(8)} ms  ${t.task}`)
  }
}

/**
 * GitHub Step Summary 用的 Markdown。
 * 目的：把"这次构建省了多少"直接摆在 PR 页面上，而不用点进日志里翻。
 */
function toMarkdown(r) {
  const ccText = { reused: '✅ 复用（配置开销≈0）', stored: '📦 新建并存储', recalculated: `♻️ 重算：${r.configurationCache.reason || '原因未记录'}`, unknown: '❔ 未知' }[r.configurationCache.status]
  const sec = (ms) => (ms == null ? '-' : `${(ms / 1000).toFixed(1)}s`)
  const lines = []
  lines.push('### 🧊 mc-build-hub 构建报告')
  lines.push('')
  lines.push('| 指标 | 值 |')
  lines.push('|---|---|')
  lines.push(`| 结果 | ${r.result === 'SUCCESSFUL' ? '✅ SUCCESSFUL' : `❌ ${r.result}`} |`)
  if (r.buildTimeText) lines.push(`| Gradle 计时 | ${r.buildTimeText} |`)
  lines.push(`| 配置缓存 | ${ccText} |`)
  lines.push(`| 任务 | 共 ${r.tasks.total}（执行 ${r.tasks.executed} / 缓存命中 ${r.tasks.fromCache} / 最新 ${r.tasks.upToDate} / 跳过 ${r.tasks.skipped}） |`)
  lines.push(`| 构建缓存命中率 | ${r.cacheHitRatePct}% |`)
  if (r.hub && r.hub.remote) lines.push(`| 远程缓存 | \`${r.hub.remote}\`（push=${r.hub.push ?? '-'}） |`)
  if (r.hub && r.hub.gradle) lines.push(`| 环境 | gradle=${r.hub.gradle} java=${r.hub.java} workers=${r.hub.workers} |`)
  lines.push('')
  if (r.profile) {
    lines.push(`**时间分布**：启动 ${sec(r.profile.startupMs)} ｜ Settings+buildSrc ${sec(r.profile.settingsMs)} ｜ 配置项目 ${sec(r.profile.configuringMs)} ｜ 转换 ${sec(r.profile.transformsMs)} ｜ 任务执行 ${sec(r.profile.executionMs)} ｜ 合计 ${sec(r.profile.totalMs)}`)
    lines.push('')
  }
  if (r.slowestTasks && r.slowestTasks.length) {
    lines.push('<details><summary>最慢的任务</summary>')
    lines.push('')
    lines.push('| 任务 | 耗时 | 状态 |')
    lines.push('|---|---|---|')
    for (const t of r.slowestTasks.slice(0, 10)) lines.push(`| \`${t.task}\` | ${(t.ms / 1000).toFixed(2)}s | ${t.result || ''} |`)
    lines.push('')
    lines.push('</details>')
    lines.push('')
  }
  if (r.fromCacheTasks && r.fromCacheTasks.length) {
    lines.push(`<details><summary>远程/本地构建缓存命中的任务（${r.fromCacheTasks.length}）</summary>`)
    lines.push('')
    for (const t of r.fromCacheTasks.slice(0, 40)) lines.push(`- \`${t}\``)
    if (r.fromCacheTasks.length > 40) lines.push(`- …另有 ${r.fromCacheTasks.length - 40} 个`)
    lines.push('')
    lines.push('</details>')
  }
  return lines.join('\n')
}

/**
 * 解析 Gradle --profile 的 HTML 报告。
 * 结构（Gradle 9.2 实测）：
 *   Summary 段 : <tr><td>Startup</td><td class="numeric">1m15.13s</td></tr>
 *   任务段     : <tr><td class="indentPath">:help</td><td class="numeric">0.011s</td><td></td></tr>
 */
function parseProfile(file) {
  const html = fs.readFileSync(file, 'utf8')
  const rows = html.split(/<tr[^>]*>/i)
  const summary = {}
  const labelMap = {
    'Total Build Time': 'totalMs',
    Startup: 'startupMs',
    'Settings and buildSrc': 'settingsMs',
    'Loading Projects': 'loadingMs',
    'Configuring Projects': 'configuringMs',
    'Artifact Transforms': 'transformsMs',
    'Task Execution': 'executionMs',
  }
  const tasks = []
  for (const row of rows) {
    const cells = [...row.matchAll(/<td[^>]*>(.*?)<\/td>/gis)].map((m) => m[1].replace(/<[^>]*>/g, '').trim())
    if (cells.length < 2) continue
    const dur = parseDurationMs(cells[1])
    if (dur == null) continue
    if (labelMap[cells[0]]) summary[labelMap[cells[0]]] = dur
    else if (cells[0].startsWith(':') && cells[0] !== ':') tasks.push({ task: cells[0], ms: dur, result: cells[2] || '' })
  }
  return { ...summary, slowestTasks: tasks.sort((a, b) => b.ms - a.ms).slice(0, 30) }
}

/** "1m39.28s" / "13.418s" / "234ms" / "0s" → 毫秒 */
function parseDurationMs(text) {
  const t = String(text || '').trim()
  if (!t) return null
  let ms = 0
  let matched = false
  const min = t.match(/([\d.]+)\s*m(?!s)/)
  const sec = t.match(/([\d.]+)\s*s/)
  const milli = t.match(/([\d.]+)\s*ms/)
  if (min) { ms += Number(min[1]) * 60000; matched = true }
  if (sec) { ms += Number(sec[1]) * 1000; matched = true }
  if (milli) { ms += Number(milli[1]); matched = true }
  return matched ? Math.round(ms) : null
}
