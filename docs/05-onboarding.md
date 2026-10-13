# 接入指南（一个 mod 仓库 = 2 个文件 + 5 个 secret）

> 原则：**项目本身一行都不改**。不改 `build.gradle`、不改 `settings.gradle`、不改 `gradle.properties`。
> 所有能力都从 workflow 侧注入（`-I` init 脚本 / 命令行开关 / 环境变量）。
> 理由很实际：一旦要求"每个项目改配置"，就会卡在"某个项目就是不兼容"上，然后整件事停在半路。

## 第 1 步：配 secret（仓库 Settings → Secrets and variables → Actions）

见 `docs/03-r2-setup.md` 第 4 节。最小可用集合是 `MC_HUB_CACHE_URL/USER/PASS`；
`MC_HUB_CC_KEY` 强烈建议配（配置缓存跨 Runner 复用的开关）。

## 第 2 步：加构建 workflow

把 `examples/consumer/.github/workflows/build.yml` 拷到你的 `.github/workflows/`。
要改的只有两处：

```yaml
      # ① 钉住黑盒子版本：用 tag（v1），不要用浮动的 main —— 缓存接线改动会失效一次配置缓存
      uses: dkjsiogu/mc-build-service/.github/workflows/reusable-build.yml@v1
      with:
        # ② 共享作用域标签：只是给人看的（指纹是自动算的），建议写清 MC + loader 版本
        cache-scope: 'mc1.21.1-neoforge21.1.233'
```

## 第 3 步（建议）：加定时预热

把 `examples/consumer/.github/workflows/warm-cache.yml` 也拷过去。
它每天凌晨把"贵且与代码无关"的部分先算好塞进 R2，白天改代码时只剩增量编译。

**首次接入的正确顺序**（很关键，顺序错了会以为没效果）：

```
1) 先手动跑一次 warm-cache（workflow_dispatch，save-warmpack=true）
      → 这一步会：下载依赖 → 跑 NeoForm 反混淆 → 把任务输出推进远程缓存
      → 打出 warmpack-<指纹>.tar.zst 上传到 R2
2) 再触发一次 build
      → 观察 Job Summary：应当是"远程缓存命中 + 配置缓存存储/复用"
3) 之后正常 push 即可
```

## 怎么判断"真的接上了"

看每次构建自动生成的 Job Summary（`tools/report.mjs` 产出）：

```
### 🧊 mc-build-hub 构建报告
| 结果 | ✅ SUCCESSFUL |
| 配置缓存 | ✅ 复用（配置开销≈0） |
| 任务 | 共 88（执行 12 / 缓存命中 70 / 最新 6 / 跳过 0） |
| 构建缓存命中率 | 85.4% |
| 远程缓存 | https://...workers.dev/cache/（push=false） |
**时间分布**：启动 2.1s ｜ Settings+buildSrc 0.0s ｜ 配置项目 0.3s ｜ 转换 0.0s ｜ 任务执行 37.4s ｜ 合计 40.2s
```

三条判据：
1. **配置缓存 = 复用**：如果一直是"新建并存储"，检查 `MC_HUB_CC_KEY` 是否配了（F4）。
2. **远程缓存有命中**：如果命中恒为 0，先看日志里有没有 `[mc-build-hub]` 的预检 warning（F6，多半是凭证）。
3. **时间分布里"启动"很小**：如果"启动"仍是 60~90s，说明 L1/L3 没生效（依赖/发行版还在重下，见 F8）。

## 常见问题

| 现象 | 原因 | 处置 |
|---|---|---|
| 命中率 0，构建却成功 | 缓存节点 401 / URL 结尾少了 `/` | 看 `run-gradle.sh` 的预检 warning |
| 配置缓存从不复用 | 没配 `MC_HUB_CC_KEY`；或黑盒子 ref 用了浮动 `main` 且刚改过 init 脚本 | 配上 key；把 ref 钉成 tag |
| 预热包一直 404 | 还没跑过 warm-cache；或指纹变了（换了 MC/loader/Gradle/JDK） | 跑一次 `reusable-warm-cache.yml` |
| `jar` 每次都不命中 | Gradle 默认禁止打包类任务进缓存（F5） | 正常现象；大 jar 项目可自行 `outputs.cacheIf { true }` |
| 拉预热包比重新下载还慢 | 包太大 / Runner 到 R2 的链路差 | `warmpack: off` 关掉，只吃 L1+L2 |
| 私有黑盒子仓库调用报 404 / 运行 0 秒失败 | 跨私有仓库调用 reusable workflow 的可见性限制 | 本仓库已公开 ⇒ 直连即可；若你的 hub 必须私有，走 `examples/consumer-private-hub/`（见 `docs/06` G1） |

## 多项目并行开发

- 各仓库的构建**天然并行**（GitHub 各自分配 Runner），互不排队。
- 共享的是**产物**：同 MC/loader 版本的项目共用同一份预热包与远程缓存条目，
  所以第 3、4 个项目的冷启动比第 1 个还快（它们直接吃到前一个项目喂热的 NeoForm 产物）。
- 想本地同时开多个项目：`GRADLE_USER_HOME` 指向同一个共享目录即可
  （本机已有先例：`/home/dkjsiogu/文档/mod/.gradle-shared`）。
