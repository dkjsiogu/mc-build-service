#!/usr/bin/env node
/*
 * conformance.mjs —— 缓存节点一致性测试（Node 自托管节点 与 Cloudflare Worker 共用）
 * =============================================================================
 * 目的：任何"黑盒子"缓存后端都必须通过同一套协议断言，否则 Gradle 那边会以
 *       诡异的方式失败（比如把 403 当成"永远未命中"，静默丢掉全部收益）。
 *
 * 用法：
 *   node worker/test/conformance.mjs <base-url> [basic-token] [--verbose]
 *   node worker/test/conformance.mjs http://127.0.0.1:8787            # 无鉴权的本地节点
 *   node worker/test/conformance.mjs http://127.0.0.1:8788 hub:secret # wrangler dev
 *   CACHE_TOKEN=hub:secret node worker/test/conformance.mjs https://xxx.workers.dev hub:secret
 */

const [, , baseArg, tokenArg] = process.argv
const VERBOSE = process.argv.includes('--verbose')
const BASE = (baseArg || process.env.CACHE_BASE_URL || 'http://127.0.0.1:8787').replace(/\/$/, '')
const TOKEN = tokenArg || process.env.CACHE_TOKEN || ''

let pass = 0
let fail = 0
const failures = []

const authHeaders = TOKEN ? { authorization: 'Basic ' + Buffer.from(TOKEN).toString('base64') } : {}

async function check(name, fn) {
  try {
    await fn()
    pass++
    console.log(`  ✓ ${name}`)
  } catch (err) {
    fail++
    failures.push(`${name}: ${err.message}`)
    console.log(`  ✗ ${name}\n      ${err.message}`)
  }
}

const assert = (cond, msg) => {
  if (!cond) throw new Error(msg)
}

const key = () => 'conformance-' + Math.random().toString(16).slice(2) + '-' + Date.now().toString(16)

async function req(method, path, { body, headers = {} } = {}) {
  const res = await fetch(`${BASE}${path}`, { method, body, headers: { ...authHeaders, ...headers } })
  if (VERBOSE) console.log(`    [${method} ${path} → ${res.status}]`)
  return res
}

console.log(`\n缓存节点一致性测试 → ${BASE}${TOKEN ? ' (basic auth)' : ' (无鉴权)'}\n`)

// ---- 基础 ----
await check('GET /healthz 返回 200 且 ok:true', async () => {
  const res = await req('GET', '/healthz')
  assert(res.status === 200, `期望 200，得到 ${res.status}`)
  const body = await res.json()
  assert(body.ok === true, `期望 ok:true，得到 ${JSON.stringify(body)}`)
})

// ---- Gradle 构建缓存协议 ----
const k1 = key()
const payload = Buffer.from('mc-build-hub conformance payload ' + Math.random())

await check('未命中必须是精确的 404（其它状态码会让 Gradle 判为错误）', async () => {
  const res = await req('GET', `/cache/${k1}`)
  assert(res.status === 404, `期望 404，得到 ${res.status}`)
})

await check('PUT 写入返回 2xx', async () => {
  const res = await req('PUT', `/cache/${k1}`, { body: payload, headers: { 'content-type': 'application/octet-stream' } })
  assert(res.status >= 200 && res.status < 300, `期望 2xx，得到 ${res.status}`)
})

await check('PUT 后 GET 命中且字节完全一致', async () => {
  const res = await req('GET', `/cache/${k1}`)
  assert(res.status === 200, `期望 200，得到 ${res.status}`)
  const got = Buffer.from(await res.arrayBuffer())
  assert(got.equals(payload), `字节不一致：写入 ${payload.length}B，读回 ${got.length}B`)
})

await check('HEAD 命中返回 200 且带 content-length', async () => {
  const res = await req('HEAD', `/cache/${k1}`)
  assert(res.status === 200, `期望 200，得到 ${res.status}`)
  const len = Number(res.headers.get('content-length'))
  assert(len === payload.length, `content-length 期望 ${payload.length}，得到 ${len}`)
})

await check('重复 PUT 幂等（同 key 覆盖不报错）', async () => {
  const res = await req('PUT', `/cache/${k1}`, { body: payload, headers: { 'content-type': 'application/octet-stream' } })
  assert(res.status >= 200 && res.status < 300, `期望 2xx，得到 ${res.status}`)
})

await check('DELETE 后 GET 回到 404（清理语义）', async () => {
  const del = await req('DELETE', `/cache/${k1}`)
  assert(del.status === 204 || del.status === 200, `DELETE 期望 204/200，得到 ${del.status}`)
  const res = await req('GET', `/cache/${k1}`)
  assert(res.status === 404, `删除后期望 404，得到 ${res.status}`)
})

await check('非法键名被拒绝（不写进存储）', async () => {
  const res = await req('PUT', '/cache/..%2F..%2Fetc%2Fpasswd', { body: 'x' })
  assert(res.status === 400 || res.status === 404, `期望 400/404，得到 ${res.status}`)
})

await check('未知路由返回 404', async () => {
  const res = await req('GET', '/nope')
  assert(res.status === 404, `期望 404，得到 ${res.status}`)
})

// ---- 预热包（跨仓库共享的 GRADLE_USER_HOME 快照）----
const packName = key() + '.tar.zst'
const blob = Buffer.concat([Buffer.from('warmpack'), Buffer.alloc(256 * 1024).fill(7)])

await check('预热包 PUT/GET 往返一致（MB 级大对象）', async () => {
  const put = await req('PUT', `/pack/${packName}`, { body: blob })
  assert(put.status >= 200 && put.status < 300, `PUT 期望 2xx，得到 ${put.status}`)
  const res = await req('GET', `/pack/${packName}`)
  assert(res.status === 200, `GET 期望 200，得到 ${res.status}`)
  const got = Buffer.from(await res.arrayBuffer())
  assert(got.equals(blob), `预热包字节不一致：${blob.length}B vs ${got.length}B`)
  await req('DELETE', `/pack/${packName}`)
})

// ---- 鉴权（仅当配置了 token）----
if (TOKEN) {
  await check('无凭证请求被拒绝（fail closed）', async () => {
    const res = await fetch(`${BASE}/cache/${key()}`)
    assert(res.status === 401 || res.status === 403 || res.status === 503, `期望 401/403/503，得到 ${res.status}`)
  })
  await check('错误凭证被拒绝', async () => {
    const res = await fetch(`${BASE}/cache/${key()}`, { headers: { authorization: 'Basic ' + Buffer.from('hub:wrong').toString('base64') } })
    assert(res.status === 401 || res.status === 403, `期望 401/403，得到 ${res.status}`)
  })
  await check('正确凭证可读写', async () => {
    const k = key()
    const put = await req('PUT', `/cache/${k}`, { body: 'authed' })
    assert(put.status >= 200 && put.status < 300, `PUT 期望 2xx，得到 ${put.status}`)
    await req('DELETE', `/cache/${k}`)
  })
} else {
  console.log('  · 跳过鉴权断言（未提供 token）')
}

console.log(`\n结果：${pass} 通过 / ${fail} 失败`)
if (fail) {
  console.log('失败明细：')
  failures.forEach((f) => console.log('  - ' + f))
}
process.exit(fail ? 1 : 0)
