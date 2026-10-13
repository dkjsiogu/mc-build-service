#!/usr/bin/env node
/*
 * local-cache-server.mjs —— 构建缓存节点（零依赖，只用 Node 内置模块）
 * =====================================================================
 * 三种用法，一套协议、一套代码：
 *   ① 本地联调：磁盘后端，在真 R2 之前先把链路跑通、量出收益。
 *   ② 自托管节点：把 --dir 指到一块大盘（或 NFS 挂载点）就是一台可用的缓存服务器。
 *   ③ **CI 内直连对象存储**：用 --s3-* 起一个进程内节点，由它用 SigV4 把请求转发到
 *      Cloudflare R2 / 任何 S3 兼容存储。Gradle 那边依旧只跟 http://127.0.0.1 说 HTTP
 *      ⇒ 不需要部署 Worker（也就不需要 Cloudflare 的 "Workers Scripts: Edit" 权限），
 *      并且**零第三方 Gradle 依赖**这条设计纪律得以保持。
 *      对象键布局与 worker/src/index.js 完全一致（cache/… 与 pack/…），两种模式可共用同一个桶，
 *      将来拿到 Worker 权限后只需把 MC_HUB_CACHE_URL 换成 Worker 地址，缓存内容不用搬家。
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
 *   # 磁盘后端（本地/自托管）
 *   node tools/local-cache-server.mjs --port 8787 --dir /var/cache/mc-build-hub [--token user:pass]
 *   # S3/R2 后端（CI 内直连；键名即对象键）
 *   node tools/local-cache-server.mjs --port 8787 \
 *     --s3-endpoint https://<account>.r2.cloudflarestorage.com --s3-bucket buildcach \
 *     --s3-key-id <access key id> --s3-secret <secret>
 */

import http from 'node:http'
import fs from 'node:fs'
import fsp from 'node:fs/promises'
import path from 'node:path'
import crypto from 'node:crypto'
import { Readable } from 'node:stream'
import { createS3 } from './lib/s3.mjs'

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

// S3 / R2 后端
const S3 = {
  endpoint: arg('s3-endpoint', process.env.S3_ENDPOINT || ''),
  bucket: arg('s3-bucket', process.env.S3_BUCKET || ''),
  accessKeyId: arg('s3-key-id', process.env.S3_ACCESS_KEY_ID || ''),
  secretAccessKey: arg('s3-secret', process.env.S3_SECRET_ACCESS_KEY || ''),
  region: arg('s3-region', process.env.S3_REGION || 'auto'),
}
const USE_S3 = Boolean(S3.endpoint && S3.bucket && S3.accessKeyId && S3.secretAccessKey)

const CACHE_DIR = path.join(DIR, 'cache')
const PACK_DIR = path.join(DIR, 'pack')
if (!USE_S3) {
  fs.mkdirSync(CACHE_DIR, { recursive: true })
  fs.mkdirSync(PACK_DIR, { recursive: true })
}

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
  const a = Buffer.from(got)
  const b = Buffer.from(TOKEN)
  return a.length === b.length && crypto.timingSafeEqual(a, b)
}

// ---------------------------------------------------------------- 后端：磁盘
const diskBackend = {
  kind: 'disk',
  fileOf: (kind, key) => path.join(kind === 'cache' ? CACHE_DIR : PACK_DIR, key),
  async get(kind, key) {
    const file = this.fileOf(kind, key)
    try {
      const st = await fsp.stat(file)
      return { status: 200, stream: fs.createReadStream(file), size: st.size }
    } catch {
      return { status: 404 }
    }
  },
  async put(kind, key, req, limit) {
    const file = this.fileOf(kind, key)
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
      await fsp.rename(tmp, file)   // 先写临时文件再 rename：避免半截文件被当"命中"读走
      stats.bytesIn += written
      stats.puts += 1
      return { status: 200, written }
    } catch (err) {
      await fsp.rm(tmp, { force: true }).catch(() => {})
      if (tooLarge) return { status: 413 }
      throw err
    }
  },
  async remove(kind, key) {
    await fsp.rm(this.fileOf(kind, key), { force: true })
    stats.deletes += 1
    return { status: 204 }
  },
  async info() {
    return { backend: 'disk', dir: DIR }
  },
}

// ---------------------------------------------------------------- 后端：S3 / R2
const s3Backend = {
  kind: 's3',
  client: USE_S3 ? createS3(S3) : null,
  async get(kind, key) {
    const r = await this.client.get(`${kind}/${key}`)
    if (r.status === 200) {
      stats.bytesOut += r.size || 0
      // fetch 返回的是 Web ReadableStream，没有 .pipe() ⇒ 必须转成 Node 流再交给 res
      return { status: 200, stream: Readable.fromWeb(r.body), size: r.size }
    }
    return { status: r.status === 404 ? 404 : 502 }
  },
  async put(kind, key, req, limit) {
    const declared = Number(req.headers['content-length'] || 0)
    if (declared && declared > limit) return { status: 413 }
    let body = req
    let contentLength = declared
    if (!declared) {
      // 长度未知只能缓冲；但缓存条目动辄几十 MB，所以设一个小上限，
      // 超了直接拒（Gradle 会当作"这条没缓存上"，不影响构建）
      const chunks = []
      let n = 0
      for await (const c of req) {
        n += c.length
        if (n > 32 * 1024 * 1024) return { status: 413 }
        chunks.push(c)
      }
      body = Buffer.concat(chunks)
      contentLength = n
    }
    const r = await this.client.put(`${kind}/${key}`, body, { contentLength })
    if (r.status === 200) {
      stats.bytesIn += contentLength
      stats.puts += 1
      return { status: 200, written: contentLength }
    }
    stats.errors += 1
    log('S3 PUT 失败', r.status, r.error || '')
    return { status: 502 }
  },
  async remove(kind, key) {
    const r = await this.client.delete(`${kind}/${key}`)
    stats.deletes += 1
    return { status: r.status === 204 || r.status === 200 ? 204 : 502 }
  },
  async info() {
    const l = await this.client.list('cache/', 1000).catch(() => ({ objects: [] }))
    return {
      backend: 's3',
      endpoint: S3.endpoint,
      bucket: S3.bucket,
      cacheObjects: l.objects.filter((o) => o.key.startsWith('cache/')).length,
      bucketBytes: l.objects.reduce((n, o) => n + (o.size || 0), 0),
    }
  },
}

const backend = USE_S3 ? s3Backend : diskBackend

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
    return send(res, 200, JSON.stringify({ ok: true, ...(await backend.info()), stats }), { 'content-type': 'application/json' })
  }
  if (url.pathname === '/stats') {
    done(200)
    return send(res, 200, JSON.stringify({ ...stats, ...(await backend.info()) }, null, 2), { 'content-type': 'application/json' })
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

  try {
    if (req.method === 'GET' || req.method === 'HEAD') {
      const r = await backend.get(kind, key)
      if (r.status !== 200) {
        stats.misses += 1
        done(404)
        return send(res, 404, 'miss')
      }
      stats.hits += 1
      const headers = { 'content-type': 'application/octet-stream', 'cache-control': 'public, max-age=31536000' }
      if (r.size) headers['content-length'] = String(r.size)
      if (req.method === 'HEAD') {
        done(200, `HEAD ${r.size}`)
        return send(res, 200, null, headers)
      }
      done(200, `${r.size}B`)
      res.writeHead(200, headers)
      r.stream.pipe(res)
      return
    }

    if (req.method === 'PUT') {
      const r = await backend.put(kind, key, req, kind === 'cache' ? MAX_BYTES : 8 * 1024 * 1024 * 1024)
      if (r.status === 413) {
        stats.errors += 1
        done(413)
        return send(res, 413, 'too large')
      }
      if (r.status !== 200) {
        done(r.status)
        return send(res, r.status, 'backend error')
      }
      done(200, `${r.written}B`)
      return send(res, 200, 'stored')
    }

    if (req.method === 'DELETE') {
      const r = await backend.remove(kind, key)
      done(r.status)
      return send(res, r.status, null)
    }

    done(405)
    return send(res, 405, 'method not allowed')
  } catch (err) {
    stats.errors += 1
    console.error('[cache-node] 处理失败', req.method, url.pathname, err && err.message)
    if (res.headersSent) {           // 已经开始回包了：只能掐断，不能再 writeHead（否则 ERR_HTTP_HEADERS_SENT）
      try { res.destroy() } catch { /* ignore */ }
      return
    }
    done(500, String(err && err.message))
    return send(res, 500, 'internal error')
  }
})

server.listen(PORT, () => {
  const mode = USE_S3 ? `S3 → ${S3.endpoint} / ${S3.bucket}` : `磁盘 → ${DIR}`
  console.log(`[cache-node] listening http://127.0.0.1:${PORT}  ${mode}  auth=${TOKEN ? 'basic' : 'none'}  maxEntry=${MAX_BYTES / 1048576}MB`)
})

for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => {
    console.log(`[cache-node] ${sig} → 关闭（hits=${stats.hits} misses=${stats.misses} puts=${stats.puts} in=${(stats.bytesIn / 1048576).toFixed(1)}MB out=${(stats.bytesOut / 1048576).toFixed(1)}MB）`)
    server.close(() => process.exit(0))
  })
}
