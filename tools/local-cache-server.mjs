#!/usr/bin/env node
/*
 * local-cache-server.mjs —— 自托管构建缓存节点（零依赖，只用 Node 内置模块）
 * =====================================================================
 *
 * 两个用途：
 *   ① CI/本地联调：在真 R2 之前，先用它在本地把"远程构建缓存"这条链路跑通、量出收益。
 *   ② 自托管缓存节点：把 --dir 指到一块大盘（或 NFS/对象存储挂载点）就是一台可用的缓存服务器。
 *      与 worker/src/index.js 实现同一套协议，行为可互相替换。
 *
 * 协议（Gradle 内置 HttpBuildCache 的约定）：
 *   GET  /cache/<key>   → 200 + body（命中）；404（未命中，必须精确 404，其他码 Gradle 会报错）
 *   PUT  /cache/<key>   → 2xx（成功）；413 表示过大（Gradle 会跳过该条目）
 *   HEAD /cache/<key>   → 200/404
 *   DELETE /cache/<key> → 204（清理用）
 *   GET/PUT/HEAD/DELETE /pack/<name> → 「预热包」大对象（跨仓库共享的 GRADLE_USER_HOME 快照）
 *   GET  /healthz       → 200 {"ok":true,...}
 *   GET  /stats         → 命中/未命中/写入计数与字节数
 *
 * 用法：
 *   node tools/local-cache-server.mjs --port 8787 --dir /var/cache/mc-build-hub [--token user:pass] [--max-mb 512]
 */

import http from 'node:http'
import fs from 'node:fs'
import fsp from 'node:fs/promises'
import path from 'node:path'
import crypto from 'node:crypto'

// ---------- CLI ----------
const argv = process.argv.slice(2)
const arg = (name, def) => {
  const i = argv.indexOf(`--${name}`)
  return i >= 0 && argv[i + 1] ? argv[i + 1] : def
}
const PORT = Number(arg('port', process.env.PORT || 8787))
const DIR = path.resolve(arg('dir', process.env.CACHE_DIR || '.cache-node'))
const TOKEN = arg('token', process.env.CACHE_TOKEN || '')
const MAX_BYTES = Number(arg('max-mb', process.env.CACHE_MAX_MB || 512)) * 1024 * 1024
const VERBOSE = argv.includes('--verbose') || process.env.VERBOSE === '1'

const CACHE_DIR = path.join(DIR, 'cache')
const PACK_DIR = path.join(DIR, 'pack')
fs.mkdirSync(CACHE_DIR, { recursive: true })
fs.mkdirSync(PACK_DIR, { recursive: true })

const stats = { hits: 0, misses: 0, puts: 0, deletes: 0, bytesIn: 0, bytesOut: 0, errors: 0, startedAt: new Date().toISOString() }

// 键名白名单：Gradle 的 key 是 hex；预热包名允许字母数字与 . _ -
const SAFE = /^[A-Za-z0-9._-]{1,200}$/
const log = (...a) => { if (VERBOSE) console.error('[cache-node]', ...a) }

const send = (res, code, body, headers = {}) => {
  if (body === undefined || body === null) {
    res.writeHead(code, headers)
    res.end()
    return
  }
  const buf = Buffer.isBuffer(body) ? body : Buffer.from(String(body))
  res.writeHead(code, { 'content-length': buf.length, ...headers })
  res.end(buf)
}

const authorized = (req) => {
  if (!TOKEN) return true
  const h = req.headers.authorization || ''
  if (!h.startsWith('Basic ')) return false
  const got = Buffer.from(h.slice(6), 'base64').toString('utf8')
  // 定时安全比较，避免网上的时序侧信道（便宜且不亏）
  const a = Buffer.from(got), b = Buffer.from(TOKEN)
  return a.length === b.length && crypto.timingSafeEqual(a, b)
}

/** 流式落盘：先写临时文件再 rename，避免半截文件被当成"命中"读走 */
const store = async (req, file, limit) => {
  const tmp = `${file}.${process.pid}.${Date.now()}.tmp`
  await fsp.mkdir(path.dirname(file), { recursive: true })
  let written = 0
  let tooLarge = false
  const ws = fs.createWriteStream(tmp)
  try {
    await new Promise((resolve, reject) => {
      req.on('data', (chunk) => {
        written += chunk.length
        if (written > limit) {
          tooLarge = true
          req.destroy()
          ws.destroy()
          reject(new Error('payload too large'))
        }
      })
      req.on('error', reject)
      ws.on('error', reject)
      ws.on('finish', resolve)
      req.pipe(ws)
    })
    await fsp.rename(tmp, file)
    stats.bytesIn += written
    stats.puts += 1
    return { tooLarge: false, written }
  } catch (err) {
    await fsp.rm(tmp, { force: true }).catch(() => {})
    if (tooLarge) return { tooLarge: true, written }
    throw err
  }
}

const server = http.createServer(async (req, res) => {
  const t0 = Date.now()
  let url
  try {
    url = new URL(req.url, 'http://localhost')
  } catch {
    return send(res, 400, 'bad url')
  }
  const done = (code, extra = '') => log(`${req.method} ${url.pathname} → ${code} ${extra} ${Date.now() - t0}ms`)

  if (url.pathname === '/healthz') {
    done(200)
    return send(res, 200, JSON.stringify({ ok: true, dir: DIR, stats }), { 'content-type': 'application/json' })
  }
  if (url.pathname === '/stats') {
    done(200)
    return send(res, 200, JSON.stringify(stats, null, 2), { 'content-type': 'application/json' })
  }
  if (!authorized(req)) {
    stats.errors += 1
    done(401)
    return send(res, 401, 'unauthorized', { 'www-authenticate': 'Basic realm="mc-build-hub"' })
  }

  const m = url.pathname.match(/^\/(cache|pack)\/(.+)$/)
  if (!m) {
    done(404)
    return send(res, 404, 'not found')
  }
  const [, kind, rawKey] = m
  const key = decodeURIComponent(rawKey)
  if (!SAFE.test(key)) {
    done(400)
    return send(res, 400, 'bad key')
  }
  const file = path.join(kind === 'cache' ? CACHE_DIR : PACK_DIR, key)

  try {
    if (req.method === 'GET' || req.method === 'HEAD') {
      let st
      try {
        st = await fsp.stat(file)
      } catch {
        stats.misses += 1
        done(404)
        return send(res, 404, 'miss')
      }
      stats.hits += 1
      stats.bytesOut += st.size
      const headers = { 'content-type': 'application/octet-stream', 'content-length': st.size, 'cache-control': 'public, max-age=31536000' }
      if (req.method === 'HEAD') {
        done(200, `HEAD ${st.size}`)
        return send(res, 200, null, headers)
      }
      done(200, `${st.size}B`)
      res.writeHead(200, headers)
      fs.createReadStream(file).pipe(res)
      return
    }

    if (req.method === 'PUT') {
      const r = await store(req, file, kind === 'cache' ? MAX_BYTES : 8 * 1024 * 1024 * 1024)
      if (r.tooLarge) {
        stats.errors += 1
        done(413)
        return send(res, 413, 'too large')
      }
      done(200, `${r.written}B`)
      return send(res, 200, 'stored')
    }

    if (req.method === 'DELETE') {
      await fsp.rm(file, { force: true })
      stats.deletes += 1
      done(204)
      return send(res, 204, null)
    }

    done(405)
    return send(res, 405, 'method not allowed')
  } catch (err) {
    stats.errors += 1
    console.error('[cache-node] 处理失败', req.method, url.pathname, err)
    done(500, String(err.message))
    return send(res, 500, 'internal error')
  }
})

// PUT 若带 Expect: 100-continue，直接放行（Node 默认行为），无需特殊处理
server.listen(PORT, () => {
  console.log(`[cache-node] listening http://127.0.0.1:${PORT}  dir=${DIR}  auth=${TOKEN ? 'basic' : 'none'}  maxEntry=${MAX_BYTES / 1048576}MB`)
})

for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => {
    console.log(`[cache-node] ${sig} → 关闭（hits=${stats.hits} misses=${stats.misses} puts=${stats.puts} in=${(stats.bytesIn / 1048576).toFixed(1)}MB out=${(stats.bytesOut / 1048576).toFixed(1)}MB）`)
    server.close(() => process.exit(0))
  })
}
