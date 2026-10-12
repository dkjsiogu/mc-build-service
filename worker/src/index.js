/*
 * mc-build-hub-cache —— Cloudflare Worker：R2 版 Gradle 远程构建缓存
 * =====================================================================
 *
 * 为什么是 Worker + R2，而不是直接 S3（先说清取舍）：
 *   - Gradle 内置的 `HttpBuildCache` 只认 HTTP 协议；S3 协议要么靠第三方插件
 *     （burrunan/gradle-s3-build-cache，多一个依赖，插件解析失败会连构建一起挂），
 *     要么靠商业版 Develocity。用 Worker 把 R2 包成 HTTP 缓存 ⇒ **零第三方 Gradle 依赖**，
 *     而且加一层鉴权/限流/统计也不用碰客户端。
 *   - R2 出网流量免费，冷启动 Runner 拉缓存不花钱；这也是选 R2 而不是 S3 的核心原因。
 *
 * 协议（Gradle HttpBuildCache 约定，必须严格遵守）：
 *   GET  /cache/<key> → 200 + body（命中）｜404（未命中；**必须**精确 404，其它码 Gradle 会当错误）
 *   PUT  /cache/<key> → 2xx 成功｜413 过大（Gradle 跳过该条目）
 *   HEAD /cache/<key> → 200/404
 *   另有 /pack/<name> 用于「跨仓库预热包」（tar.zst 大对象），同一套鉴权。
 *
 * 鉴权：Gradle 侧 `credentials { username; password }` 走 HTTP Basic，
 *       这里比对 secret `CACHE_TOKEN`（格式 "user:pass"）。未配置 ⇒ 拒绝一切写入（读也拒）。
 *
 * 部署：
 *   wrangler secret put CACHE_TOKEN      # 例如 hub:<随机串>
 *   wrangler deploy
 */

const CACHE_PREFIX = 'cache/'
const PACK_PREFIX = 'pack/'

// 键名白名单：Gradle key 是 hex；预热包名允许字母数字与 . _ -
const SAFE_KEY = /^[A-Za-z0-9._-]{1,200}$/

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url)
    const t0 = Date.now()
    const log = (code, extra = '') => {
      if (env.VERBOSE === 'true') console.log(`${request.method} ${url.pathname} → ${code} ${extra} ${Date.now() - t0}ms`)
    }

    if (url.pathname === '/healthz') {
      log(200)
      return json({ ok: true, service: 'mc-build-hub-cache', bucket: env.BUCKET ? 'bound' : 'MISSING' })
    }

    const authError = checkAuth(request, env)
    if (authError) {
      log(401)
      return new Response('unauthorized', { status: 401, headers: { 'www-authenticate': 'Basic realm="mc-build-hub"' } })
    }

    if (url.pathname === '/stats') {
      const listed = await env.BUCKET.list({ limit: 1000 })
      log(200)
      return json({
        objects: listed.objects.length,
        truncated: listed.truncated,
        bytes: listed.objects.reduce((n, o) => n + (o.size || 0), 0),
        observedAt: new Date().toISOString(),
      })
    }

    const isCache = url.pathname.startsWith('/' + CACHE_PREFIX)
    const isPack = url.pathname.startsWith('/' + PACK_PREFIX)
    if (!isCache && !isPack) {
      log(404)
      return new Response('not found', { status: 404 })
    }

    const key = decodeURIComponent(url.pathname.slice(isCache ? CACHE_PREFIX.length + 1 : PACK_PREFIX.length + 1))
    if (!SAFE_KEY.test(key)) {
      log(400)
      return new Response('bad key', { status: 400 })
    }
    const r2Key = (isCache ? CACHE_PREFIX : PACK_PREFIX) + key

    try {
      if (request.method === 'GET' || request.method === 'HEAD') {
        const obj = await env.BUCKET.get(r2Key)
        if (!obj) {
          log(404)
          return new Response('miss', { status: 404 })
        }
        const headers = new Headers()
        obj.writeHttpMetadata(headers)
        headers.set('etag', obj.httpEtag)
        headers.set('content-length', String(obj.size))
        headers.set('cache-control', 'public, max-age=31536000, immutable')
        if (request.method === 'HEAD') {
          log(200, `HEAD ${obj.size}`)
          return new Response(null, { status: 200, headers })
        }
        log(200, `${obj.size}B`)
        return new Response(obj.body, { status: 200, headers })
      }

      if (request.method === 'PUT') {
        const maxBytes = isCache ? Number(env.MAX_ENTRY_BYTES || 536870912) : Number(env.MAX_PACK_BYTES || 4294967296)
        const declared = Number(request.headers.get('content-length') || 0)
        if (declared && declared > maxBytes) {
          log(413, `declared ${declared}`)
          return new Response('too large', { status: 413 })
        }
        const obj = await env.BUCKET.put(r2Key, request.body, {
          httpMetadata: { contentType: 'application/octet-stream' },
        })
        log(200, `${obj?.size ?? declared}B`)
        return new Response('stored', { status: 200 })
      }

      if (request.method === 'DELETE') {
        await env.BUCKET.delete(r2Key)
        log(204)
        return new Response(null, { status: 204 })
      }

      log(405)
      return new Response('method not allowed', { status: 405, headers: { allow: 'GET, HEAD, PUT, DELETE' } })
    } catch (err) {
      console.error('cache error', request.method, url.pathname, err && err.stack)
      log(500, String(err))
      return new Response('internal error', { status: 500 })
    }
  },
}

/** Basic 鉴权；CACHE_TOKEN 未配置 ⇒ 一律拒绝（fail closed，绝不裸奔） */
function checkAuth(request, env) {
  const expected = env.CACHE_TOKEN
  if (!expected) return new Response('cache token not configured', { status: 503 })
  const header = request.headers.get('authorization') || ''
  if (!header.startsWith('Basic ')) return new Response('unauthorized', { status: 401 })
  let got = ''
  try {
    got = atob(header.slice(6))
  } catch {
    return new Response('bad credentials', { status: 401 })
  }
  return timingSafeEqual(got, expected) ? null : new Response('unauthorized', { status: 401 })
}

/** 定时安全比较（Workers 里没有 node:crypto，手写一个等长异或） */
function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return diff === 0
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })
}
