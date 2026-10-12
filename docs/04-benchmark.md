# 基准：冷启动能压到几十秒吗？

**结论：能，但兑现它的不是"远程构建缓存"，而是"跨仓库预热包"。**

在 `Arsenal_Graft`（NeoForge 1.21.1 / moddev 2.0.120 / Gradle 9.2.0 / JDK 21，`assemble`）上实测：

| 场景 | 墙钟 | 启动 | Settings | 配置 | 执行 | 配置缓存 | 任务 执行/命中 | 远程缓存 命中/写入 |
|---|---|---|---|---|---|---|---|---|
| **s4 黑盒子完整形态**（L1+L2+L3） | **42.4s** | 3.0s | 0.4s | 0.7s | 37.8s | stored | 7 / 0 | 0 / 0 |
| s0b 只缺远程构建缓存（L1+L3） | 42.4s | 2.3s | 0.4s | 0.7s | 38.5s | stored | 7 / 0 | 0 / — |
| s3 改一行代码（L1+L2） | 96.1s | 2.7s | 0.4s | 0.7s | 91.8s | stored | 7 / 0 | 0 / 0 |
| s2 同提交重建（L1+L2） | 91.0s | 2.1s | 0.4s | 0.7s | 87.3s | stored | 6 / 1 | 1 / 0 |
| s3b 再加项目 `.gradle`（L1+L2+CC 数据） | 96.5s | 2.5s | 0.4s | 0.7s | 92.3s | recalculated | 7 / 0 | 0 / 0 |
| s1 首次接入（依赖要下、反混淆已由预热包提供） | 296s | 58.6s | 9.8s | 9.4s | 39.3s | stored | 7 / 0 | 0 / 1 |
| s0 真·冷启动（无任何缓存） | **失败**（338s 处） | — | — | — | — | — | 见 `evidence/02-cold-start-failure.md` |

> 全部数据来自 `tools/bench.sh all`，原始 JSON 见 [`evidence/bench-results.json`](../evidence/bench-results.json)。

---

## 三条最重要的读数

### 1. 决定性的那 2.3 倍，来自 L3（预热包）

`s3`（96.1s）→ `s4`（42.4s）**唯一的差别**是：s4 先还原了 1.4G 预热包（含 `caches/neoformruntime`）。
时间去哪了，看最慢任务一目了然：

| 任务 | 没有预热包（s2/s3） | 有预热包（s4/s0b） |
|---|---|---|
| `:createMinecraftArtifacts` | **85.3s** | **30.3s** |
| `:compileJava` | 1.3s（命中） | 6.8s |
| `:jar` / `:processResources` | 0.3s / 0.1s | 0.2s / 0.2s |

预热包把 NeoForm 那一段砍掉 55s；剩下的 30.3s 是 NFRT **自己的缓存校验与产物整理**开销 ——
这就是本机在该 MC/loader 组合上的**地板**（想再低只能换更快的机器或自托管常驻环境）。

### 2. 远程构建缓存（L2）在这个项目上几乎没贡献 —— 而且原因是结构性的

`s4` 与 `s0b` 的墙钟**完全一样（42.4s）**：唯一的差别是 s0b 关掉了远程构建缓存。
整个矩阵里 L2 只命中过 1 次（s2 的 `:compileJava`，价值约 4.5s）。原因是两条硬事实：

- **F5**：`jar` / `processResources` / `Copy` 被 Gradle 标为"Not worth caching"，**永远不进缓存**；
- **F12**：`createMinecraftArtifacts` 自己写着 `@DisableCachingByDefault(because = "Implements its own caching")`
  —— 反混淆/重编译那部分**根本不在 Gradle 构建缓存的管辖范围内**。

所以"把 Loom/NFRT 的反混淆产物交给远程 Build Cache 复用"这个直觉方案**在 NeoForge 上不成立**，
必须靠 L3 把 `caches/neoformruntime` 整个搬过去。

> L2 仍然值得留着：它对**同提交重建**（s2 实测命中）、多模块项目、测试任务、以及非 NeoForge 家族
> （例如 Fabric/Loom 的若干任务）是实打实的收益，而且成本近乎为零（一个内置 `HttpBuildCache` 接线）。

### 3. "配置阶段 30~60 秒"其实是**下载**，不是配置

预热之后，配置阶段实测只有 **0.4~0.7s**（`Startup 2.1~3.0s`）。
s1 里那个 `Startup 58.6s + Settings 9.8s + 配置 9.4s` 才是"冷"的真相 ——
而它的绝大部分是**下载**（本机到 services.gradle.org 的单次发行版下载就花了约 10 分钟，见 `docs/06` G3）。

**推论**：Configuration Cache 是"好习惯"，但在托管 Runner 的冷启动里**不是最大杠杆**；
最大杠杆是**别让 Runner 重新下载、别让 Runner 重新反混淆**。

---

## 口径与边界（哪些数字不能直接搬）

1. **本机网络远慢于托管 Runner**：`s1` 的启动段被发行版下载严重放大（本机约 10 分钟下 145MB）。
   在 GitHub `ubuntu-latest` 上这一步是十几秒；因此**绝对冷启动数字本机偏悲观**。
   与网络无关的量（命中率、任务态、执行段、L3 的 55s 差值）不受影响。
2. **NFRT 播种说明**：真·冷启动（s0）在本机因内存不足挂在反编译（4G 堆 × 16 线程，见 `evidence/02`），
   所以 s1~s4 用"预热包已拉取"作为起点 —— 这恰好是真实流水线里 99% 的运行状态。
3. **配置缓存**：本机矩阵里 s3b 恢复项目 `.gradle` 后仍是 `recalculated`，
   原因是**配置缓存条目对工程绝对路径敏感**，而 s3b 换了目录。
   托管 Runner 上工作区路径稳定（`/home/runner/work/<repo>/<repo>`），
   配合 `MC_HUB_CC_KEY` 才有机会跨 Runner 复用（F4）。同路径下的复用已单独验证：
   本地同工程连跑两次分别是 `Configuration cache entry stored.` 与 `Reusing configuration cache.`
4. **1.4G 预热包**：主要是 `caches/neoformruntime` 的中间产物（jar 内容不可压，zstd 收效有限）。
   Cloudflare R2 出网免费，托管 Runner 上拉这份包通常十几秒；嫌大可裁剪（代价是部分 NFRT 阶段重算）。

---

## 复现

```bash
# 环境自检（JDK / zstd / 缓存节点 / 被测项目）
tools/bench.sh check

# 完整矩阵（约 15~40 分钟，取决于网络与是否已有预热包）
tools/bench.sh all

# 只跑关心的场景（顺序有意义：s1 负责把远程缓存填满）
tools/bench.sh run s1 s2 s3 s4

# 不碰 Minecraft 的快速回归（几秒到几十秒）
tools/selftest.sh
```

被测项目、任务列表、JDK 都可用环境变量覆盖：
`BENCH_PROJECT_SRC` / `BENCH_TASKS` / `BENCH_JAVA_HOME` / `BENCH_NFRT_SEED`。

## 托管 Runner 上的对照证据

同一套链路在 GitHub `ubuntu-latest` 上的自检结果（[run 38296806476](https://github.com/dkjsiogu/mc-build-service/actions/runs/38296806476)）：

```
✓ 远程缓存写入成功（4 个条目）
✓ 日志里出现 FROM-CACHE
✓ 有任务命中构建缓存（命中 4 个）
✓ 关键路径 :compileJava 命中缓存
✓ 配置缓存被复用/存储
✓ 打包成功（128M）      ✓ 还原后 marker 内容一致
自检结果：22 通过 / 0 失败
```

即：**"冷 home 写入 → 干净 home 全部 FROM-CACHE"这条闭环，在真实托管 Runner 上被证明成立**，
不是本地跑得通而已。
