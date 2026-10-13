# 接上 Cloudflare R2（步骤 + 为什么这么设计）

> 状态：**已接通，并用真实 R2 桶端到端验证**（协议一致性 13/13；干净 home 写入 → 另一个干净 home 100% 命中）。
> 两种接法见第 1 节：**方案 A 作业内直连代理**（只需 R2 密钥，推荐）／**方案 B Cloudflare Worker**（需要 Workers 权限）。
> 没配 R2 时整套流程**照常工作**，只是丢掉 L2/L3（跨仓库复用）的收益，L1 依旧生效。

## 0. 为什么是 R2 + Worker，而不是直接用 S3 协议

| 方案 | 代价 |
|---|---|
| 第三方 S3 构建缓存插件（如 `com.github.burrunan.s3-build-cache`） | 多一个插件依赖；插件解析失败会**连构建一起挂** —— 缓存是锦上添花的东西，不该有让构建失败的权力 |
| Gradle 商业版 Develocity 的 S3 缓存 | 要商业授权 |
| **R2 + 一层薄适配（本仓库方案）**：作业内直连代理 / Cloudflare Worker | 客户端只用 Gradle **内置**的 `HttpBuildCache`；服务端 80 行 JS；R2 出网流量**免费**（冷 Runner 拉缓存不产生流量费，这条对"每天几十次构建"的场景是决定性的） |

参考：S3 插件路径依然保留在文档里（见文末"备选：直接走 S3 插件"），但它不是默认。

## 1. 把 R2 接上：两条路，选一条

|  | 方案 A：**作业内直连代理**（推荐） | 方案 B：部署 Cloudflare Worker |
|---|---|---|
| 需要的权限 | 只有 R2（S3 密钥） | 还要 **Workers Scripts: Edit**（实测缺它会 403，见下表） |
| 每次构建开销 | 作业内起一个 Node 进程（< 1 秒） | 无 |
| 端点 | 每个作业各起一个（**缓存内容**仍然全仓库共享） | 一个端点所有仓库共用 |
| 第三方 Gradle 依赖 | **零**（用 Gradle 内置 `HttpBuildCache`） | 零 |
| 适合 | 拿不到 Workers 权限、或想立刻用起来 | 已有 Workers 权限、想要统一入口 |

两条路的**对象键布局完全一致**（`cache/…` 与 `pack/…`），所以 A ↔ B 可以随时切换，
**已经攒下的缓存不用搬家**（本仓库两种模式都已用真实桶跑通）。

---

### 方案 A：作业内直连 R2（推荐；已用真实桶端到端验证）

原理：工作流里起一个本地节点（`tools/local-cache-server.mjs --s3-*`），
它用 SigV4 把请求转发给 R2；**Gradle 那边只跟 `http://127.0.0.1:8787` 说 HTTP**，
于是既不需要 Worker，也不需要任何第三方 Gradle 插件。
工作流里已经接好（`tools/ci/cache-node.sh start`），消费方只要配 secret：

| Secret | 值 |
|---|---|
| `MC_HUB_S3_ENDPOINT` | `https://<account>.r2.cloudflarestorage.com` |
| `MC_HUB_S3_BUCKET` | 桶名（本仓库实测：`buildcach`） |
| `MC_HUB_S3_KEY_ID` | R2 的 Access Key ID |
| `MC_HUB_S3_SECRET` | R2 的 Secret Access Key |
| `MC_HUB_CACHE_USER` / `MC_HUB_CACHE_PASS` | 作业内节点的 Basic 校验，随便设一对（两侧要一致） |

**注意**：方案 A 下**不要**再配 `MC_HUB_CACHE_URL` —— 工作流检测到它为空且有 S3 配置时才会起代理；
一旦提供了现成地址（Worker / 自托管节点），就会优先用那个。

本仓库的实测闭环（真实 R2 桶）：

```
第一次：干净 GRADLE_USER_HOME → 构建成功 → 向 R2 写入 4 个条目
第二次：另一个干净 GRADLE_USER_HOME → 4 个任务全部 FROM-CACHE（命中率 100%）
        > Task :compileJava FROM-CACHE
        > Task :hubStamp FROM-CACHE
        > Task :processResources FROM-CACHE
        > Task :jar FROM-CACHE
```

> **R2 的两个坑**（实测，已固化进代码，不必自己再踩）：
> ① **不能 chunked 上传**：不带 `content-length` 时 R2 会写 0 字节或直接拒绝大对象
>    ⇒ 代理必须显式转发长度（否则预热包这种几百 MB 的对象必挂）；
> ② **必须带 `x-amz-content-sha256`**：缺了报 `400 InvalidRequest`（**不是**权限问题，别去查 token）。
>
> 另外一条容易误判的：**R2 的 Access Key ID 就是该 API Token 的 ID**，Secret Access Key 是它的 SHA256。
> 所以 `GET /user/tokens/verify` 返回的 `id` 与你手里的 Access Key ID 一模一样 —— 不是复制错了。

---

### 方案 B：部署 Cloudflare Worker

#### 权限矩阵（最容易卡住的一步）

Cloudflare 的 API Token 权限是按资源勾选的，**只勾 R2 是部署不了 Worker 的**。实测：

| 权限 | 用途 | 只勾 R2 时的表现 |
|---|---|---|
| Account → **Workers R2 Storage → Edit** | 建桶/读写对象 | ✅ 正常（`wrangler r2 bucket list` 通得过） |
| Account → **Workers Scripts → Edit** | **部署 Worker 本体** | ❌ `PUT /workers/scripts/...` 返回 403 `No access to the specified resource` |
| Account → Workers Scripts → Read | 列脚本（排查用） | ✅ 能列，但**不能部署**（最容易误判成"权限够了"） |

所以：如果 `wrangler r2 bucket list` 成功、`wrangler deploy` 却报
`A request to the Cloudflare API (/accounts/.../workers/scripts/.../secrets) failed. No access to the specified resource.`
—— 那就是缺 **Workers Scripts: Edit**（最快是用 "Edit Cloudflare Workers" 模板新建一个 token）。

#### 命令（非交互，适合脚本化）

```bash
export CLOUDFLARE_ACCOUNT_ID=<你的 account id>        # 就是 R2 endpoint 里那段 <account>.r2.cloudflarestorage.com
export CLOUDFLARE_API_TOKEN=<有 Workers Scripts:Edit 的 API Token>

npx wrangler r2 bucket create buildcach               # 桶名要与 worker/wrangler.toml 的 bucket_name 一致
cd worker && npm install
printf '%s' 'hub:<32位随机串>' | npx wrangler secret put CACHE_TOKEN
npx wrangler deploy
```

部署完会打印 `https://mc-build-hub-cache.<你的子域>.workers.dev`，把它填进
`MC_HUB_CACHE_URL`（末尾要带 `/cache/`）即可，其余 secret 与方案 A 相同。

> 若提示 workers.dev 子域未启用：Cloudflare Dashboard → Workers 里注册一个 `<名字>.workers.dev` 子域
> （账号级一次性操作；也可以改用自定义域名 + `wrangler.toml` 的 `routes`）。

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

### 5a. 先验 Worker 本身（**这是最值得先做的一步**）

Worker 的代码路径（R2 读写、Basic 鉴权、流式 PUT/GET）可以在本地用 miniflare 完整跑一遍，
不需要 Cloudflare 账号、不需要建桶：

```bash
cd worker
npm install
echo 'CACHE_TOKEN=hub:workertest' > .dev.vars     # 本地密钥，已在 .gitignore 里
npx wrangler dev --port 8788 &                    # 本地模式，R2 由 miniflare 模拟
node test/conformance.mjs http://127.0.0.1:8788 hub:workertest
```

本仓库实测输出：**13 项断言全部通过**（含"未命中必须精确 404""PUT/GET 字节一致""无凭证 fail closed"）。
也就是说 `wrangler deploy` 之后会踩到的协议问题，在这一步就已经暴露完了。

### 5b. 再验 Gradle ↔ 缓存节点这条链路

`tools/local-cache-server.mjs` 与 Worker 实现**同一套协议**，可以本地先验：

```bash
node tools/local-cache-server.mjs --port 8787 --dir .cache-node --token hub:local

# 另开一个终端
export MC_HUB_CACHE_URL=http://127.0.0.1:8787/cache/
export MC_HUB_CACHE_USER=hub MC_HUB_CACHE_PASS=local
export MC_HUB_CACHE_PUSH=true
tools/bench.sh run s1 s2 s3        # 冷启动填充 → 干净 home 命中
```

想看"全绿"的确定性证据，直接跑 `tools/selftest.sh`（22 项断言，含端到端缓存闭环）。

## 6. 想换掉 Cloudflare？（都走同一套 HTTP 协议）

`HttpBuildCache` 只认 HTTP，所以后端可以随便换：

- **自建**：`node tools/local-cache-server.mjs --port 8787 --dir /srv/mc-cache`，前面挂 nginx + TLS + Basic Auth
- **其它对象存储**：把 `worker/src/index.js` 的 `env.BUCKET` 换成对应绑定（S3 兼容的都能包）
- **公司内网 Nexus/Artifactory**：如果已有制品库，也可以直接指过去（只要是 Gradle HTTP 缓存协议）

## 附：备选 —— 直接走 S3 插件（不推荐，但保留）

如果坚持不引入 Worker：用 `com.github.burrunan.s3-build-cache`（实测最新 1.9.10，2026-10-01 仍在维护），
在 `settings.gradle` 里指向 R2 的 S3 端点（`https://<account>.r2.cloudflarestorage.com`）。
**代价**：多一个插件依赖 + 每个项目都要改 `settings.gradle`（违背本方案"项目零改动"的原则）。
