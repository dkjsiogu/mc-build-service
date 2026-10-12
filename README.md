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

在你的 mod 仓库加 **2 个文件**（拷 `examples/consumer/` 里的），配 **3~4 个 secret**，项目配置零改动：

```bash
# 1) 配 secret（仓库 Settings → Secrets and variables → Actions）
MC_HUB_CACHE_URL    = https://<你的worker>.workers.dev/cache/
MC_HUB_CACHE_USER   = hub
MC_HUB_CACHE_PASS   = <你的令牌>
MC_HUB_CC_KEY       = $(openssl rand -base64 16)     # 配置缓存跨 Runner 复用的开关，强烈建议

# 2) 拷两个 workflow
cp examples/consumer/.github/workflows/build.yml      <你的仓库>/.github/workflows/
cp examples/consumer/.github/workflows/warm-cache.yml <你的仓库>/.github/workflows/

# 3) 先跑一次预热（workflow_dispatch），再正常 push
gh workflow run warm-cache.yml && gh workflow run build.yml
```

细化的接入顺序与排错清单见 **[docs/05-onboarding.md](docs/05-onboarding.md)**。

---

## 它到底做了什么

| 层 | 内容 | 谁负责 | 跨仓库？ |
|---|---|---|---|
| **L1 依赖层** | 依赖 jar、Gradle 发行版、transforms、build-logic | `gradle/actions/setup-gradle`（`cache-provider: basic`，MIT） | ❌ 同仓库 |
| **L2 任务输出层** | `compileJava`、NeoForm 各阶段… 的产物 | `gradle/mc-build-hub.init.gradle` + Cloudflare Worker(R2) | ✅ |
| **L3 分析产物层** | NeoForm 反混淆/重编译产物、依赖、发行版（实测 1.2G+） | `tools/warmpack.sh`（`warmpack-<指纹>.tar.zst`） | ✅ |

外加两件"让收益可见、可核对"的事：

- **每次构建自动生成 Job Summary**：五段时间分布（启动 / Settings / 配置 / 转换 / 执行）+ 命中率 + 最慢任务；
- **远程缓存预检**：凭证错了会**静默**把命中率清零（Gradle 只记一条 warning），所以构建前先探一次并吼出来。

---

## 实测数据

<!--BENCH_TABLE-->

方法与口径见 **[docs/04-benchmark.md](docs/04-benchmark.md)**；原始 JSON 与日志见 `evidence/`。

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
evidence/                             实测证据（原始报错、失败现场）
tests/fixture/                        自检用最小 Gradle 工程
```

---

## 当前状态

| 部分 | 状态 |
|---|---|
| init 脚本（并行/构建缓存强制、远程缓存接线、告警） | ✅ 已在真实 NeoForge 工程上验证 |
| 可复用构建/预热工作流 | ✅ 语法与结构校验通过，已在 GitHub 上跑通自检 |
| Worker + R2 缓存节点 | ✅ 协议一致性测试通过（19 项）；**R2 桶与密钥待配置**（`docs/03`） |
| 自托管缓存节点（无 Cloudflare 也能用） | ✅ 本地端到端验证（冷写入 → 干净 home 命中） |
| 预热包机制 | ✅ 打包/还原/排除规则验证通过 |
| 冷/温基准 | ✅ 数据见上（真·冷启动的失败现场见 `evidence/02`） |
| R2 凭证 | ⏳ 待你在 Cloudflare 侧建桶后填 secret（"到时候再配置"） |

## 许可

MIT
