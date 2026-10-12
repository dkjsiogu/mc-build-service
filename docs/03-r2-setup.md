# 接上 Cloudflare R2（步骤 + 为什么这么设计）

> 状态：**代码已就绪并本地验证通过**（Worker 协议、预热包往返、远程缓存闭环都有自检）。
> 只差把 R2 桶和密钥填进去 —— 这一步"到时候再配置"。
> 在没配之前，整套流程**照常工作**，只是丢掉了 L2/L3（跨仓库复用）的收益，L1 依旧生效。

## 0. 为什么是 R2 + Worker，而不是直接用 S3 协议

| 方案 | 代价 |
|---|---|
| 第三方 S3 构建缓存插件（如 `com.github.burrunan.s3-build-cache`） | 多一个插件依赖；插件解析失败会**连构建一起挂** —— 缓存是锦上添花的东西，不该有让构建失败的权力 |
| Gradle 商业版 Develocity 的 S3 缓存 | 要商业授权 |
| **Worker + R2（本仓库方案）** | 客户端只用 Gradle **内置**的 `HttpBuildCache`；服务端 80 行 JS；R2 出网流量**免费**（冷 Runner 拉缓存不产生流量费，这条对"每天几十次构建"的场景是决定性的） |

参考：S3 插件路径依然保留在文档里（见文末"备选：直接走 S3 插件"），但它不是默认。

## 1. 建桶与部署 Worker

```bash
# 一次性准备
npm i -g wrangler            # 或 npx wrangler
wrangler login

# 建桶（名字与 worker/wrangler.toml 里一致）
wrangler r2 bucket create mc-build-cache

# 部署缓存服务
cd worker
npm install
wrangler secret put CACHE_TOKEN     # 输入形如：hub:<32位随机串>
wrangler deploy
```

部署完会得到一个地址，形如 `https://mc-build-hub-cache.<你的子域>.workers.dev`。

## 2. 配生命周期规则（**别跳过这步**）

构建缓存是**可再生资源**，过期就该丢，否则桶只会无限长胖：

- Cloudflare Dashboard → R2 → `mc-build-cache` → Settings → Object lifecycle rules
- 建议：`prefix = cache/` 删除 30 天未修改的对象；`prefix = pack/` 删除 14 天未修改的对象
  （预热包有指纹命名，旧指纹的包被新包取代后就没人再读了）

## 3. 验通（部署完先验，别等 CI 报错）

```bash
# 用一致性测试验协议 + 鉴权（19 项断言）
node worker/test/conformance.mjs https://mc-build-hub-cache.<子域>.workers.dev hub:<你的串>

# 手工验一次读写
curl -u hub:<你的串> -X PUT --data-binary @README.md \
     https://mc-build-hub-cache.<子域>.workers.dev/cache/smoke-test-key
curl -u hub:<你的串> -o /dev/null -w '%{http_code}\n' \
     https://mc-build-hub-cache.<子域>.workers.dev/cache/smoke-test-key   # 期望 200
curl -u hub:<你的串> -X DELETE \
     https://mc-build-hub-cache.<子域>.workers.dev/cache/smoke-test-key
```

> ⚠️ **这一步测不出来、但线上会要命的情况**：凭证错了。Gradle 拿到 401 只会记一条 warning，
> 构建照样 SUCCESSFUL，**命中率永远是 0**。所以 `run-gradle.sh` 里内置了预检（F6）。

## 4. 在 GitHub 上配 secret（每个消费仓库各配一次）

| Secret | 值 | 必需 |
|---|---|---|
| `MC_HUB_CACHE_URL` | `https://mc-build-hub-cache.<子域>.workers.dev/cache/`（**结尾斜杠别丢**） | 是 |
| `MC_HUB_CACHE_USER` | `hub` | 是 |
| `MC_HUB_CACHE_PASS` | `<32位随机串>` | 是 |
| `MC_HUB_CC_KEY` | `openssl rand -base64 16` 的输出 | **强烈建议**：它是配置缓存跨 Runner 复用的开关（F4） |
| `MC_HUB_TOKEN` | 读私有黑盒子仓库的 PAT | 仅当黑盒子是私有仓库 |

也可以配成 **organization/repository 级别的 Variables + Secrets**，新仓库继承，不用逐个配。

## 5. 本地先用假节点把链路跑通（不需要 Cloudflare 账号）

`tools/local-cache-server.mjs` 与 Worker 实现**同一套协议**，可以本地先验：

```bash
node tools/local-cache-server.mjs --port 8787 --dir .cache-node --token hub:local

# 另开一个终端
export MC_HUB_CACHE_URL=http://127.0.0.1:8787/cache/
export MC_HUB_CACHE_USER=hub MC_HUB_CACHE_PASS=local
export MC_HUB_CACHE_PUSH=true
tools/bench.sh run s1 s2 s3        # 冷启动填充 → 干净 home 命中
```

## 6. 想换掉 Cloudflare？（都走同一套 HTTP 协议）

`HttpBuildCache` 只认 HTTP，所以后端可以随便换：

- **自建**：`node tools/local-cache-server.mjs --port 8787 --dir /srv/mc-cache`，前面挂 nginx + TLS + Basic Auth
- **其它对象存储**：把 `worker/src/index.js` 的 `env.BUCKET` 换成对应绑定（S3 兼容的都能包）
- **公司内网 Nexus/Artifactory**：如果已有制品库，也可以直接指过去（只要是 Gradle HTTP 缓存协议）

## 附：备选 —— 直接走 S3 插件（不推荐，但保留）

如果坚持不引入 Worker：用 `com.github.burrunan.s3-build-cache`（实测最新 1.9.10，2026-10-01 仍在维护），
在 `settings.gradle` 里指向 R2 的 S3 端点（`https://<account>.r2.cloudflarestorage.com`）。
**代价**：多一个插件依赖 + 每个项目都要改 `settings.gradle`（违背本方案"项目零改动"的原则）。
