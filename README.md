# mc-build-service —— MC mod 的「黑盒子」构建缓存枢纽

> **一句话**：把托管 Runner 上"每次从零开始"的昂贵部分（依赖、Gradle 发行版、NeoForm 反混淆、任务输出）
> 变成**所有项目共享的一份产物**，让冷启动尽可能接近温启动 —— 而且**接入的 mod 项目一行代码都不用改**。

```
              其它 mod 仓库 ──uses: dkjsiogu/mc-build-service/.github/workflows/reusable-build.yml@v1──┐
                                                                                                    │
   ┌────────────────────────────────────────────────────────────────────────────────────────────────┘
   ▼
┌───────────────────────┐   L1 依赖层（GH Actions 缓存，同仓库）
│  reusable-build.yml   │   L2 任务输出层（R2 远程构建缓存，**跨仓库**）
│  黑盒子 = 本仓库       │   L3 分析产物层（NeoForm 预热包，**跨仓库**）
└───────────────────────┘
```

---

## 为什么需要它（问题不是"缓存没开"，而是"缓存跨不了仓库"）

托管 Runner 的硬约束是：**没有常驻 daemon，缓存也不会自己变热**。更关键的是三个常被忽略的事实：

1. **GitHub Actions 的缓存是按仓库隔离的** —— 仓库 A 的 `~/.gradle`，仓库 B 一个字节也拿不到。
   所以"集中缓存枢纽"必须有一个**仓库之外的中立存储**（本方案用 Cloudflare R2）。
2. **Gradle 9 起，配置缓存问题 = 构建失败**；而且配置缓存条目住在**项目目录**里，
   默认**不会**被 `setup-gradle` 带上 Runner —— 除非你给它一个 `cache-encryption-key`。
3. **`jar` / `processResources` 默认根本不进构建缓存**（Gradle 用 `@DisableCachingByDefault`
   标了"Not worth caching"），所以"命中率 80%"这类说法在打包阶段是不成立的。

这三条（以及另外 8 条）连同实测证据都写在 **[docs/02-hard-facts.md](docs/02-hard-facts.md)**。
本仓库的形态完全由它们决定：**能用内置能力就不用插件，能在 workflow 侧解决就不动项目配置。**

---

## 30 秒接入

**推荐：一条命令**（自动识别工具链 → 生成 workflow → 配 secret → 告诉你能否直接吃现成的预热包）：

```bash
tools/onboard.sh --dir /path/to/your-mod-repo     # --dry-run 先看计划，--commit 一步到位
```

本仓库是**公开**仓库，所以消费方可以**零凭证**直接调它的 reusable workflow
（公开仓库的 reusable workflow 可被任何仓库调用，含私有仓库 ✓）。
**mod 项目本身零改动**：不改 `build.gradle` / `settings.gradle` / `gradle.properties`。
手工等价流程（想自己控节奏时）见 [docs/05-onboarding.md](docs/05-onboarding.md)。

```bash
# 1) 配 secret（仓库 Settings → Secrets and variables → Actions）
#    方案 A（推荐，不需要 Workers 权限）：给 R2 密钥，工作流在作业内起代理直连
MC_HUB_S3_ENDPOINT  = https://<account>.r2.cloudflarestorage.com
MC_HUB_S3_BUCKET    = buildcach
MC_HUB_S3_KEY_ID    = <R2 Access Key ID>
MC_HUB_S3_SECRET    = <R2 Secret Access Key>
MC_HUB_CACHE_USER   = hub
MC_HUB_CACHE_PASS   = <与 hub 侧一致>
MC_HUB_CC_KEY       = $(openssl rand -base64 16)     # 配置缓存跨 Runner 复用的开关
#    方案 B：只给一个现成的缓存端点（Cloudflare Worker / 自托管节点）也行
# MC_HUB_CACHE_URL  = https://<worker>.workers.dev/cache/

# 2) 拷两个 workflow（或用 tools/onboard.sh 自动生成）
cp examples/consumer/.github/workflows/{build,warm-cache}.yml <你的仓库>/.github/workflows/

# 3) 先跑一次预热（把 NeoForm 产物喂进 R2），再正常 push
gh workflow run warm-cache.yml && gh workflow run build.yml
```

> 想把黑盒子保持私有？那就走 [`examples/consumer-private-hub/`](examples/consumer-private-hub/)：
> 自己检出黑盒子（用 PAT）再跑它的脚本。**为什么必须多这一步**：
> GitHub 不允许一个私有仓库调用另一个私有仓库的 reusable workflow —— 实测运行 0 秒失败、jobs 数 0，
> 而同仓库调用 8 秒成功（对照实验见 [docs/06-github-notes.md](docs/06-github-notes.md) G1）。


细化的接入顺序与排错清单见 **[docs/05-onboarding.md](docs/05-onboarding.md)**。

---

## 它到底做了什么

| 层 | 内容 | 谁负责 | 跨仓库？ |
|---|---|---|---|
| **L1 依赖层** | 依赖 jar、Gradle 发行版、transforms、build-logic | `gradle/actions/setup-gradle`（`cache-provider: basic`，MIT） | ❌ 同仓库 |
| **L2 任务输出层** | `compileJava`、NeoForm 各阶段… 的产物 | `gradle/mc-build-hub.init.gradle` + R2（Worker 或作业内直连代理） | ✅ |
| **L3 分析产物层** | NeoForm 反混淆/重编译产物、依赖、发行版（实测 1.2G+） | `tools/warmpack.sh`（`warmpack-<指纹>.tar.zst`） | ✅ |

外加两件"让收益可见、可核对"的事：

- **每次构建自动生成 Job Summary**：五段时间分布（启动 / Settings / 配置 / 转换 / 执行）+ 命中率 + 最慢任务；
- **远程缓存预检**：凭证错了会**静默**把命中率清零（Gradle 只记一条 warning），所以构建前先探一次并吼出来。

---

## 实测数据

`Arsenal_Graft`（NeoForge 1.21.1 / moddev 2.0.120 / Gradle 9.2.0 / JDK 21，任务 `assemble`）：

**A. 本机 16 核 —— 冷/温对比（同一台机器，逐层剥离）**

| 场景 | 墙钟 | 执行段 | 配置缓存 | 远程缓存 |
|---|---|---|---|---|
| **黑盒子完整形态**（L1 依赖 + L2 远程缓存 + L3 预热包） | **42.4s** | 37.8s | stored | 0 命中 |
| 只缺远程构建缓存（L1+L3） | 42.4s | 38.5s | stored | — |
| 改一行代码、没有预热包（L1+L2） | 96.1s | 91.8s | stored | 0 命中 |
| 同一次提交重建（L1+L2） | 91.0s | 87.3s | stored | **1 命中** |
| 真·冷启动（什么都不缓存） | ✗ 失败于反编译（338s 处） | — | — | — |

**B. GitHub 托管 Runner（2 核）—— 真实 mod、真实 R2 桶，接 R2 前后对照**

| 场景 | Gradle 构建 | 执行段 | `:createMinecraftArtifacts` | `:compileJava` | 整个 job | 证据 |
|---|---|---|---|---|---|---|
| 冷启动（无远程缓存） | 281.4s | 237.5s | **212.1s** | 24.1s | ~5min | [evidence/03](evidence/03-hosted-runner-cold.md) |
| **接上 R2 之后** | **28s** | **13.3s** | **3.2s** | 7.7s（FROM-CACHE） | **~65s** | [evidence/04](evidence/04-r2-live.md) |

> 这就是最终答案：**托管 Runner 上 `assemble` 从 4 分 41 秒降到 28 秒**，整 job 65 秒。
> 其中 19 秒花在从 R2 拉 540MB 预热包上，真正"构建"只占 29 秒。
> 托管 Runner 的发行版下载只要 14.2s（本机约 10 分钟）——本机那些"启动 58.6s"不代表线上。


**三条读数**（细节与边界见 [docs/04-benchmark.md](docs/04-benchmark.md)）：

1. **决定性的 2.3 倍来自 L3 预热包**：最慢任务 `:createMinecraftArtifacts` 从 **85.3s → 30.3s**；
   剩下的 30.3s 是 NFRT 自身缓存校验的地板。
2. **远程构建缓存对这个 NeoForge 项目几乎无贡献**，而且是结构性的：
   `jar`/`processResources` 被 Gradle 标为 "Not worth caching"（`@DisableCachingByDefault`，F5），
   反混淆任务则写着 `Implements its own caching`（F12）—— 它压根不在 Gradle 构建缓存的管辖范围内。
3. **"配置阶段 30~60 秒"其实是下载**：预热之后配置段实测只要 **0.4~0.7s**。
   所以 Configuration Cache 是好习惯，但在冷 Runner 上不是最大杠杆。

**托管 Runner 上的对照证据**：同一套链路在 GitHub `ubuntu-latest` 上自检 **22 项全过**
（"冷 home 写入 4 个条目 → 另一个干净 home 4 个任务全部 FROM-CACHE，含 `:compileJava`"），
见 [run 38296806476](https://github.com/dkjsiogu/mc-build-service/actions/runs/38296806476)。

原始 JSON：[`evidence/bench-results.json`](evidence/bench-results.json) ｜ 失败现场：[`evidence/02`](evidence/02-cold-start-failure.md)


---

## 自检：怎么证明"链路真的通"（而不是看起来通）

```bash
tools/selftest.sh          # 19 项断言，含"干净 home 构建 → 远程缓存写入 → 另一个干净 home 必须 FROM-CACHE"
tools/bench.sh check       # 只做环境自检
tools/bench.sh all         # 跑完整冷/温基准矩阵，产出 Markdown 表格
```

`selftest.sh` 刻意用**一个不碰 Minecraft 的小夹具工程**（`tests/fixture/`）来验缓存闭环 ——
几秒就能知道"缓存通没通"，而不是每次都等 NeoForm 反混淆五分钟。

这条链路上绝大多数故障都是**静默**的（401 清零命中率、指纹算错喂错产物、init 脚本违规直接判构建失败），
所以自检不是可选项。

---

## 仓库地图

```
gradle/mc-build-hub.init.gradle     ★ 核心接线：强制并行/构建缓存 + 接远程缓存 + 结构性告警
.github/workflows/
  reusable-build.yml                ★ 构建入口（workflow_call）
  reusable-warm-cache.yml           ★ 预热入口（workflow_call，喂缓存 + 打包预热包）
  selftest.yml                        本仓库自检（每次 push 跑）
tools/
  bench.sh / report.mjs               冷/温基准 + 日志解析（命中率、五段时间分布）
  warmpack.sh / ci/warmpack-ci.sh     预热包打包/还原/上传
  local-cache-server.mjs              自托管缓存节点（与 Worker 同协议，零依赖）
  selftest.sh                         全链路自检
  ci/run-gradle.sh                    CI 侧唯一入口（计时/汇总/预检）
worker/                              ★ Cloudflare Worker：R2 版 Gradle HTTP 构建缓存
docs/01-architecture.md               三层模型与设计取舍
docs/02-hard-facts.md                 ★ 11 条硬事实（含证据与出处）
docs/03-r2-setup.md                   R2 + Worker 部署步骤
docs/04-benchmark.md                  基准方法与结果
docs/05-onboarding.md                 接入与排错
docs/06-github-notes.md               ★ GitHub 侧实测限制（私有↔私有调用、默认分支、网络口径）
evidence/                             实测证据（原始报错、失败现场、基准 JSON）
tests/fixture/                        自检用最小 Gradle 工程
```

---

## 当前状态

| 部分 | 状态 |
|---|---|
| init 脚本（并行/构建缓存强制、远程缓存接线、预检、告警） | ✅ 已在真实 NeoForge 工程上验证 |
| 可复用构建/预热工作流 | ✅ actionlint 通过；已在 GitHub `ubuntu-latest` 上跑通自检（22/0） |
| R2 缓存后端 | ✅ **已接通真实桶**：协议一致性 13/13；**托管 Runner 实测 281.4s → 28s**（[evidence/04](evidence/04-r2-live.md)） |
| 自托管缓存节点（无 Cloudflare 也能用） | ✅ 本地 + GitHub 端到端验证（冷写入 → 干净 home 全部命中） |
| 预热包机制 | ✅ 打包/还原/排除规则验证通过（实测 1.4G / 22s 打包） |
| 冷/温基准 | ✅ 6 场景矩阵完成，数据见上；真·冷启动失败现场见 `evidence/02` |
| **仓库可见性** | ✅ 已公开（2026-10-13）⇒ 消费方 `uses: dkjsiogu/mc-build-service/.github/workflows/reusable-build.yml@v1` 零凭证直连；私有场景用 `examples/consumer-private-hub/` |
| R2 凭证 | ⏳ 待你在 Cloudflare 侧建桶后填 secret（"到时候再配置"） |

## 许可

MIT
