/*
 * lib/s3.mjs —— 极简 S3 客户端（AWS SigV4，零依赖）
 * =====================================================================================
 * 为什么自己写而不是引 AWS SDK：
 *   ① SDK 装完几十 MB，而这个文件只需要 5 个操作（get/head/put/delete/list）；
 *   ② 构建缓存的键名是 hex、桶是专用的 —— 不需要 SDK 那一整套抽象；
 *   ③ 少一个依赖 = 少一个在 CI 上"装不上/装得慢"的失败点。
 *
 * 为什么需要它：Cloudflare Worker 是把 R2 包成 HTTP 缓存的最干净做法，
 *   但部署 Worker 需要在 Cloudflare 侧有 "Workers Scripts: Edit" 权限。
 *   没有那个权限时，可以在 CI 里起一个**本地缓存节点**（tools/local-cache-server.mjs），
 *   由它用 SigV4 把请求转发到 R2 —— Gradle 那边依旧只跟 127.0.0.1 说 HTTP，
 *   于是"零第三方 Gradle 依赖"这条设计纪律得以保持。
 *
 * R2 的两个坑（实测）：
 *   · 必须带 x-amz-content-sha256（缺了报 400 InvalidRequest，不是权限问题）；
 *   · 大对象用 UNSIGNED-PAYLOAD 流式上传，避免把几百 MB 读进内存。
 */

import crypto from 'node:crypto'

const EMPTY_SHA256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
const UNSIGNED = 'UNSIGNED-PAYLOAD'

const sha256Hex = (data) => crypto.createHash('sha256').update(data).digest('hex')
const hmac = (key, data) => crypto.createHmac('sha256', key).update(data).digest()

/** 按 SigV4 规范编码 URI 路径：保留 '/'，其余按 RFC3986 转义 */
const encodePath = (p) =>
  p
    .split('/')
    .map((s) => encodeURIComponent(s).replace(/[!'()*]/g, (c) => '%' + c.charCodeAt(0).toString(16).toUpperCase()))
    .join('/')

/** 查询参数按 key 排序后编码 */
function canonicalQuery(params) {
  return Object.keys(params)
    .sort()
    .map((k) => `${encodeURIComponent(k)}=${encodeURIComponent(params[k])}`)
    .join('&')
}

export function createS3({ endpoint, bucket, accessKeyId, secretAccessKey, region = 'auto' }) {
  if (!endpoint || !bucket || !accessKeyId || !secretAccessKey) {
    throw new Error('createS3: endpoint/bucket/accessKeyId/secretAccessKey 都必填')
  }
  const base = endpoint.replace(/\/$/, '')
  const host = new URL(base).host

  /**
   * 发一个签名请求。
   * @param {string} method
   * @param {string} key        对象键（空字符串表示对桶本身操作，如 list）
   * @param {object} opts       { body, query, payloadHash }
   */
  async function signed(method, key, opts = {}) {
    const canonicalUri = '/' + bucket + (key ? '/' + encodePath(key) : '')
    const query = opts.query || {}
    const qs = canonicalQuery(query)
    const url = `${base}${canonicalUri}${qs ? '?' + qs : ''}`

    const now = new Date()
    const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, '') // 20261013T090000Z
    const dateStamp = amzDate.slice(0, 8)
    const payloadHash = opts.payloadHash || EMPTY_SHA256

    // 参与签名的头：host 与所有 x-amz-*（必须包含 x-amz-content-sha256）
    const headers = {
      host,
      'x-amz-content-sha256': payloadHash,
      'x-amz-date': amzDate,
    }
    if (opts.contentType) headers['content-type'] = opts.contentType
    // content-length 可以「带但不签」（SigV4 只强制签 x-amz-* 与 host）。
    // 必须显式带上：否则 undici 会改用 chunked 传输，而 R2 在 UNKNOWN 长度下会写 0 字节 / 拒绝大对象。
    const unsignable = {}
    if (opts.contentLength) unsignable['content-length'] = String(opts.contentLength)

    const sortedKeys = Object.keys(headers).sort()
    const canonicalHeaders = sortedKeys.map((k) => `${k}:${String(headers[k]).trim()}\n`).join('')
    const signedHeaders = sortedKeys.join(';')

    const canonicalRequest = [
      method,
      canonicalUri,
      qs,
      canonicalHeaders,
      signedHeaders,
      payloadHash,
    ].join('\n')

    const scope = `${dateStamp}/${region}/s3/aws4_request`
    const stringToSign = ['AWS4-HMAC-SHA256', amzDate, scope, sha256Hex(canonicalRequest)].join('\n')

    let k = hmac(`AWS4${secretAccessKey}`, dateStamp)
    k = hmac(k, region)
    k = hmac(k, 's3')
    k = hmac(k, 'aws4_request')
    const signature = crypto.createHmac('sha256', k).update(stringToSign).digest('hex')

    const authorization =
      `AWS4-HMAC-SHA256 Credential=${accessKeyId}/${scope}, ` +
      `SignedHeaders=${signedHeaders}, Signature=${signature}`

    const res = await fetch(url, {
      method,
      headers: { ...headers, ...unsignable, authorization },
      body: opts.body,
      duplex: opts.body ? 'half' : undefined,
      redirect: 'manual',
    })
    return res
  }

  return {
    bucket,
    /** 取对象；未命中返回 { status: 404 }，命中返回 { status:200, body, size } */
    async get(key) {
      const res = await signed('GET', key)
      if (res.status === 404) return { status: 404 }
      if (!res.ok) return { status: res.status, error: await res.text() }
      return { status: 200, body: res.body, size: Number(res.headers.get('content-length') || 0) }
    },

    async head(key) {
      const res = await signed('HEAD', key)
      if (res.status === 404) return { status: 404 }
      if (!res.ok) return { status: res.status }
      return { status: 200, size: Number(res.headers.get('content-length') || 0) }
    },

    /** 上传（流式 + UNSIGNED-PAYLOAD：不把 body 读进内存；必须给定 contentLength） */
    async put(key, bodyStream, { contentLength } = {}) {
      const res = await signed('PUT', key, {
        body: bodyStream,
        payloadHash: UNSIGNED,
        contentType: 'application/octet-stream',
        contentLength,
      })
      if (!res.ok) return { status: res.status, error: (await res.text()).slice(0, 300) }
      return { status: 200, contentLength }
    },

    async delete(key) {
      const res = await signed('DELETE', key)
      return { status: res.status }
    },

    /** 列出对象（用于 /stats 与清理） */
    async list(prefix = '', max = 1000) {
      const res = await signed('GET', '', { query: { 'list-type': '2', prefix, 'max-keys': String(max) } })
      if (!res.ok) return { status: res.status, objects: [] }
      const xml = await res.text()
      const objects = [...xml.matchAll(/<Contents>([\s\S]*?)<\/Contents>/g)].map((m) => ({
        key: (m[1].match(/<Key>([\s\S]*?)<\/Key>/) || [, ''])[1],
        size: Number((m[1].match(/<Size>(\d+)<\/Size>/) || [, 0])[1]),
      }))
      return { status: 200, objects, truncated: /<IsTruncated>true<\/IsTruncated>/.test(xml) }
    },
  }
}

export { EMPTY_SHA256, UNSIGNED }
