# 证据 03：真实托管 Runner 上、真实 mod 工程的冷启动实测

- **时间**：2026-10-13 08:27~08:33（北京）
- **运行**：[Arsenal_Graft run 38327330041](https://github.com/dkjsiogu/Arsenal_Graft/actions/runs/38327330041)（分支 `ci/hub-cache-test`）
- **环境**：`ubuntu-latest`（2 核可见 / JDK 21.0.12 temurin），Gradle 9.2.0，`assemble`
- **缓存状态**：**全空**（没有 R2、没有预热包、GH 缓存也是首次）—— `remote=none`，命中率 0%
- **结果**：✅ SUCCESSFUL，产出 `arsenalgraft-3.0.122.jar`（3.94 MB）

## 关键数字（来自 hub 自己产出的 `hub-stats.json`）

```
结果: SUCCESSFUL | Gradle 计时: 4m 41s | 配置缓存: stored
任务: 共 8（执行 7 / 缓存命中 0 / 最新 0 / 无源 1） 命中率 0%
横幅: hub=0.2.0 gradle=9.2.0 java=21.0.12.1 parallel=true caching=true cc=true
      workers=2 remote=none push=false
```

| 阶段 | 耗时 |
|---|---|
| 启动（含 Gradle 发行版下载） | **14.2s** |
| Settings and buildSrc | 3.0s |
| Configuring Projects | 4.6s |
| Artifact Transforms | 0.0s |
| **任务执行** | **237.5s** |
| 合计 | 281.4s（约 4m41s；整 job 约 5m） |

最慢任务：

| 任务 | 耗时 | 说明 |
|---|---|---|
| `:createMinecraftArtifacts` | **212.1s** | NeoForm 反混淆/重编译（冷） |
| `:compileJava` | 24.1s | 759 个源文件全量编译（冷，2 worker） |
| `:neoFormRuntimeDependenciesCompileClasspath` | 4.5s | |
| `:compileClasspath` | 2.8s | |
| 其余 | < 1.5s | `jar` 仅 0.7s、`processResources` 0.4s |

## 这张表补上了本地测不出来的那一格

| | 本机（16 核 15G，国际链路慢） | 托管 Runner（2 核，链路快） |
|---|---|---|
| Gradle 发行版下载 | 约 10 分钟（145MB） | **14.2s** |
| 冷 `createMinecraftArtifacts` | 内存不足，两次都失败（`evidence/02`） | **212.1s**（稳定成功） |
| 冷全量流程 | — | **281.4s** |

→ 印证 `docs/06` G3：**托管 Runner 的网络与独占内存，反而比这台开发机更适合跑反混淆**。
本机那些"启动 58.6s"的数字是环境造成的，不能代表线上。

## 由此得到的线上收益预估（**是推算，不是实测**）

本地已实测：NFRT 缓存预热后，`createMinecraftArtifacts` 从 85.3s → **30.3s**（本机 16 核）。
把同一个比例搬到托管 Runner：

```
冷启动 281s
  ├─ createMinecraftArtifacts 212s  →  预热包到位后约 30~40s   （L3，最大头）
  ├─ compileJava              24s   →  远程构建缓存命中后约 1~2s（L2，仅同提交重建）
  └─ 其余                      45s   →  基本不变
预估温启动：70~100s（同提交重建）；改一行代码约 90~120s
```

这与本地实测的 `s4 = 42.4s`（16 核、依赖与反混淆全预热）是同一量级的两个采样点：
**核多的机器更接近"几十秒"，2 核托管 Runner 落在"一分半以内"。**
把 R2 配上之后，用同一个 `ci/hub-cache-test` 分支再跑一次即可把上表换成实测值。

## 附带确认的三件事

1. **跨仓库调用成立**：私有仓库 `Arsenal_Graft` 成功调用公开 hub `mc-build-service` 的
   reusable workflow（对照 `docs/06` G1：私有→私有会 0 秒失败）。整条链路没有用到任何 PAT。
2. **降级路径成立**：没有 R2 凭据时，工作流自动退化为"只吃 L1 依赖层"，**构建照常成功**，
   只在横幅里标 `remote=none`、命中率 0% —— 不会因为缓存没配好而挡住构建。
3. **产物与可观测性都在线**：jar 正常产出并上传；构建日志与 `hub-stats.json` 一并作为 artifact 留档，
   这就是上表的来源（`docs/04` 里所有"命中率/五段时间分布"都出自同一个解析器）。
