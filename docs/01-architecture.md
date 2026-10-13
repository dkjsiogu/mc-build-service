# 架构：三层缓存 + 一个中立存储

```
                        ┌──────────────────────────────────────────────┐
                        │   mc-build-service（黑盒子 = 本仓库）          │
                        │                                              │
   其它 mod 仓库 ────────▶│  · reusable-build.yml      构建入口          │
   （workflow_call）      │  · reusable-warm-cache.yml 预热入口          │
                        │  · mc-build-hub.init.gradle 统一接线         │
                        │  · warmpack.sh / bench.sh / selftest.sh      │
                        └───────────────┬──────────────────────────────┘
                                        │
              ┌─────────────────────────┼─────────────────────────────┐
              ▼                         ▼                             ▼
   ┌────────────────────┐   ┌─────────────────────┐   ┌──────────────────────────┐
   │ L1 依赖层           │   │ L2 任务输出层        │   │ L3 分析产物层（预热包）    │
   │ GH Actions 缓存     │   │ 远程构建缓存 (R2)    │   │ R2 大对象                 │
   │ ~/.gradle/caches    │   │ Gradle HttpBuildCache│   │ warmpack-<指纹>.tar.zst  │
   │ 作用域：**同仓库**   │   │ 作用域：**所有仓库**  │   │ 作用域：**所有仓库**       │
   │ 免运维、免费         │   │ 任务级增量           │   │ 反混淆/依赖/发行版一次性    │
   └────────────────────┘   └─────────────────────┘   └──────────────────────────┘
```

## 为什么必须是三层

三层不是"多堆几个缓存"，而是**三个互相不可替代的失效点**。缺哪层，就在哪层重新付钱：

| 层 | 解决的问题 | 不做的后果 | 谁负责 |
|---|---|---|---|
| L1 依赖层 | 依赖 jar、Gradle 发行版、transforms、build-logic | 冷 Runner 每次重下 ~90s（实测 F8） | `setup-gradle`（同仓库） |
| L2 任务输出层 | `compileJava`、NeoForm 各阶段… 的产物复用 | 每次都全量重编译 | `mc-build-hub.init.gradle` + R2（Worker 或作业内代理） |
| L3 分析产物层 | NeoForm 反混淆/重编译的**中间产物与结果**（1.2G 级） | 换仓库/换 Runner 就重跑几分钟反混淆 | `warmpack.sh` + R2 |

**L1 与 L2/L3 的分工原则**：凡是 **GitHub 自己就能免费托管**的（同仓库、按 run 递进），交 L1；凡是**必须跨仓库**或**体积大但复用价值高**的，交 L2/L3（R2）。

## 数据流（一次 push 到底发生了什么）

```
push ──▶ reusable-build.yml
            │
            ├─ ① checkout 被测仓库 → project/
            ├─ ② setup-java + setup-gradle(basic)
            │     └─ 恢复 L1：~/.gradle/caches、wrapper/dists（+ 有加密键时含项目状态/配置缓存）
            ├─ ③ checkout 黑盒子 → .mc-build-hub/
            ├─ ④ 安装 00-mc-build-hub.init.gradle → $GRADLE_USER_HOME/init.d/
            ├─ ⑤ warmpack-ci.sh restore
            │     └─ GET $BASE/pack/warmpack-<指纹>.tar.zst → 解到 GRADLE_USER_HOME（L3）
            ├─ ⑥ run-gradle.sh
            │     ├─ 预检远程缓存（401 会静默清零收益 → 这里提前吼）
            │     ├─ ./gradlew <tasks> --configuration-cache --build-cache --profile
            │     │     └─ init 脚本：强制并行/缓存 + 接上 HttpBuildCache（L2）
            │     │           未命中 → 执行 → 同时写本地缓存与远程缓存
            │     └─ report.mjs 解析日志 → 命中率/五段时间分布 → Job Summary + outputs
            └─ ⑦ upload-artifact（jar + 构建日志）
```

## 两个仓库角色

- **枢纽仓库（本仓库）**：只有脚本、workflow、Worker；不装任何 mod 代码，不存任何密钥。密钥全部由调用方通过 `secrets: inherit` 传入。
- **消费仓库（各 mod）**：新增 1~2 个 YAML 文件即可，`build.gradle` / `gradle.properties` **一行都不用改**（这是刻意的：改造项目配置的方案，注定会在"某个项目就是不兼容"上翻车）。

## 刻意的设计取舍

| 决定 | 理由 |
|---|---|
| 用 **Worker + R2** 包成 HTTP 缓存，而不是第三方 S3 插件 | Gradle 内置 `HttpBuildCache` 零依赖；插件解析失败会连构建一起挂，而缓存是"锦上添花"的东西，不该有这个权力 |
| 统计靠**解析日志**，不在 init 脚本挂监听器 | Gradle 9 里挂监听器 = 配置缓存作废 + 构建失败（F2） |
| `cache-provider: basic`（MIT）而非默认的 `enhanced` | 关键路径不该押在"私有仓库免费预览"的商业服务上（F10） |
| 预热包**不含** `caches/build-cache-1` | 本地构建缓存是"每台机器一份"的易变目录；跨机共享走 L2，别混在一起把包撑爆 |
| 预热包**含** `wrapper/dists` | 291M 的 Gradle 发行版，冷 Runner 每次重下就是白等（F8） |
| 指纹 = MC/loader + Gradle + JDK + schema 版本 | 与**仓库无关**的才是可共享的；把仓库名掺进去就等于没共享 |
| 预热包默认 `off` 也能用 | 只想要 L2 收益的仓库不该被强制拉 200M+ 的包；`warmpack: off` 一行关掉 |

## 明确不承诺的事

- **不提供常驻 daemon**：托管 Runner 上不可能有；本方案的收益全部来自缓存，不来自"热 JVM"。
- **不保证 `jar` 任务命中**：Gradle 默认不让打包类任务进缓存（F5）。大 jar 项目可自行 `outputs.cacheIf { true }`，但那是项目侧的决定。
- **不替代自托管 Runner**：真要"秒级"迭代，本地/自托管 + 常驻 daemon 才是终局。本方案的目标是把**托管 Runner 的冷启动压到可接受**，并且让**多个项目共享同一份昂贵产物**。
