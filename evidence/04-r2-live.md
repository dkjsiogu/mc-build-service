# 证据 04：R2 接通后的真实托管 Runner 实测 —— 281.4s → 28s

- **时间**：2026-10-13 09:18~09:24（北京）
- **运行**：
  - 预热 [run 38331012156](https://github.com/dkjsiogu/Arsenal_Graft/actions/runs/38331012156)（`ci/hub-cache-test`，约 7min）
  - 测量 [run 38331830117](https://github.com/dkjsiogu/Arsenal_Graft/actions/runs/38331830117)（`ci/hub-measure`）
- **环境**：`ubuntu-latest`（2 核可见 / JDK 21.0.12），Gradle 9.2.0，`assemble`
- **缓存状态**：R2 桶 `buildcach`，作业内 SigV4 代理直连（`remote=http://127.0.0.1:8787/cache/`）
- **结果**：✅ SUCCESSFUL，产出 `arsenalgraft-3.0.122.jar`

## 前后对比（同一个工程、同一个任务、同一类 Runner）

| | 冷启动（`evidence/03`，无远程缓存） | **配好 R2 之后** |
|---|---|---|
| **Gradle 构建** | 281.4s（4m41s） | **28s** |
| 其中 `:createMinecraftArtifacts` | 212.1s | **3.2s** |
| 其中 `:compileJava` | 24.1s | 7.7s（`FROM-CACHE`） |
| 启动 | 14.2s | 8.3s |
| Settings + 配置 | 7.6s | 2.6s |
| **任务执行段** | **237.5s** | **13.3s** |
| 整个 job（含检出/上传） | 约 5min | **约 65s** |

逐步耗时（测量运行）：

```
检出被测项目                          8s
配置 Gradle（依赖层缓存）              2s
启动 R2 直连代理                       1s
恢复跨仓库预热包（540MB）              19s   ← L3
构建                                  29s   ← 实测就是这一步
上传日志 + 产物                        3s
```

## 两级缓存各自干了什么

| 层 | 证据 | 效果 |
|---|---|---|
| **L3 预热包** | `pack/warmpack-a1fb159705b7.tar.zst`（**540 MB**）从 R2 拉回并解开，19s | `:createMinecraftArtifacts` **212.1s → 3.2s**（就是它把 4 分钟砍成几秒） |
| **L2 远程构建缓存** | 日志里 `> Task :compileJava FROM-CACHE`；桶内 `cache/57ebd198…`（1.9 MB） | `:compileJava` 24.1s → 7.7s（含解包） |
| **L1 依赖层** | `setup-gradle` 的 GH 缓存 | 启动段 14.2s → 8.3s（发行版/依赖不再重下） |

> 注意 `:compileJava` 仍是"最慢任务"（7.7s）——**这就是地板**：
> 2 核 Runner 上解包 1.9MB 缓存条目 + 依赖解析的开销，已经超过了编译本身能省的量。
> 换言之，这个工程在托管 Runner 上已经没什么可再压的了。

## 顺带验证的三件事

1. **指纹跨机器一致**：预热包名 `warmpack-a1fb159705b7` 与本机 `warmpack.sh fingerprint` 算出的
   完全一致 ⇒ "同 MC/loader/Gradle/JDK 的项目共用一个预热包"这件事在真实链路里成立。
2. **作业内代理是可用形态**：没有部署 Cloudflare Worker、也没有任何第三方 Gradle 插件，
   仅凭 R2 的 S3 密钥就把两级缓存跑通了（代价只是作业里多一个进程）。
3. **降级与写入策略都正确**：预热运行 `push=true`（把任务输出推进 R2），
   测量运行 `push=false`（非默认分支只读），两条横幅分别在两个运行里可查。

## 复现方式

```bash
# 1) 配 4 个 secret（R2 密钥）+ MC_HUB_CACHE_USER/PASS + MC_HUB_CC_KEY
#    见 docs/03 的「方案 A」
# 2) 先跑一次预热（喂 L2 + 传预热包）
gh workflow run warm-cache.yml
# 3) 再跑构建：Job Summary 里应看到 命中率>0 与 执行段骤降
gh workflow run build.yml
```
