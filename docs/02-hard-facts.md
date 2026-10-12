# 硬事实（全部经实测/源码核实，附证据与出处）

> 这一页是"黑盒子"的设计依据。**凡是没有实测证据的，这里不写。**
> 每条都标了：结论 → 证据 → 对设计的后果。
> 这些事实里有几条和"想当然的方案"是相反的，正是它们决定了本仓库长什么样。

---

## F1. GitHub Actions 的缓存是**按仓库隔离**的 —— 「共享缓存」不可能靠 actions/cache 实现

**结论**：`actions/cache` / `gradle/actions/setup-gradle` 写的缓存条目，只有**同一个仓库**的 workflow 能命中。仓库 A 的 `~/.gradle` 缓存，仓库 B 一个字节也拿不到。

**后果**：所谓"集中的缓存枢纽"**必须有一个仓库之外的中立存储**。这就是 R2 不是"锦上添花"而是**唯一可行解**的原因：
- 依赖层 / 配置缓存数据（同仓库、跨 run）→ 走 GH Actions 缓存（免费、零运维）
- 任务输出 / 预热包（**跨仓库**）→ 走 R2（本仓库的 Worker + 预热包机制）

**顺带纠正一个常见误解**：Configuration Cache 条目**不能跨项目共享**。它是"某个项目 + 某组构建脚本 + 某次任务请求"的任务图快照，跨项目复用没有语义。能跨项目共享的是**任务输出**和**依赖/反混淆产物**。

---

## F2. Gradle 9 起，配置缓存问题 = **构建失败**（不是告警）

**证据**：`evidence/01-cc-listener-trap.md`（本仓库第一次实测的真实报错）

```
* What went wrong:
Configuration cache problems found in this build.
- Initialization script '.../mc-build-hub.init.gradle': line 118: registration of listener
  on 'TaskExecutionGraph.beforeTask' is unsupported
- ... 'TaskExecutionGraph.afterTask' is unsupported
- ... 'Gradle.buildFinished' is unsupported
> BUILD FAILED
```

**后果**：init 脚本里**绝对不能**注册构建监听器。本仓库 v0.1 就是这么把所有消费方构建搞挂的。因此"逐任务命中率统计"改由**解析构建日志**完成（`tools/report.mjs`）——看数据不该拿构建稳定性做交换。

---

## F3. `StartParameter` 能强制的只有"并行 + 构建缓存"，**配置缓存强制不了**

**证据**：对 Gradle 9.2.0 的 `org.gradle.StartParameter` 做 `javap`：

```
public void setParallelProjectExecutionEnabled(boolean);   ✅ 可强制
public void setBuildCacheEnabled(boolean);                 ✅ 可强制
public boolean isConfigurationCacheRequested();            ❌ 只有 getter，没有 setter
（不存在任何 daemon 相关成员）                                ❌ 连成员都没有
```

**后果**：
- 并行 / 构建缓存：init 脚本可以"项目写 false 也盖回来"（这是 init 脚本相对 `gradle.properties` 的唯一优势，因为项目级 properties 会盖掉全局 properties）。
- 配置缓存：只能靠项目 `gradle.properties` 或命令行 `--configuration-cache`。所以黑盒子的工作流**显式传 `--configuration-cache`**。
- daemon：只能告警。

---

## F4. Configuration Cache 条目住在**项目目录**，不在 Gradle User Home

**证据**：实测 `find` 结果 —— `caches/*/configuration-cache` 在 `~/.gradle` 下**不存在**；条目实际位于 `<project>/.gradle/configuration-cache`（本项目实测 84K）。

**后果**：这是"配置缓存能不能跨 Runner 复用"的关键。`setup-gradle` 默认只缓存 **Gradle User Home**，光靠它，配置缓存每次都得重算。

**但是**——`setup-gradle` 源码里有这么一条（v6.4.0 `dist/setup-gradle/main/index.js` 中的缓存原因说明）：

```
"no-encryption-key": "Project state (build-logic and configuration cache) was not cached
                      - a [cache-encryption-key] is required."
```

**结论（本仓库最重要的一条运维知识）**：
> **`cache-encryption-key` 就是"配置缓存能否跨 Runner 复用"的总开关。**
> 不设它 → 每次冷 Runner 都要重算任务图（大项目 30~60s 白花）；
> 设了它（`openssl rand -base64 16` 存成 secret）→ 项目状态（build-logic + 配置缓存）才会被存取。

---

## F5. **打包类任务是"默认不可缓存"的** —— 高命中率不适用于 `jar`

**证据**：Gradle 源码 `@DisableCachingByDefault(because = "Not worth caching")`，出现在
`Jar`、`Copy`、`ProcessResources`、`Tar` 等核心任务上（`gh api search/code` 定位 + 实测日志）：

```
Caching disabled for task ':jar' because:
  Not worth caching
Caching disabled for task ':processResources' because:
  Not worth caching
```

**后果（这条最反直觉，直接影响"几十秒"能不能兑现）**：
- 即使远程缓存 100% 命中，**`jar` 和 `processResources` 每次冷 Runner 都要重新执行**。
- 所以"改一行代码 → 命中率 80%"这类说法，落到 NeoForge 项目上要打折：命中的是 `compileJava`、NeoForm 各阶段等；**打包与资源处理必然重跑**。
- 想要打包也进缓存，需要项目侧显式开：`tasks.withType(Jar) { outputs.cacheIf { true } }`。**默认不开**（Gradle 的判断是对的：小 jar 重新打包比走缓存更快），大 jar 项目可自行权衡。
- 实测影响见 `docs/04-benchmark.md` 的 s2/s3 明细。

---

## F6. 缓存节点的 401/403 会**静默清零**全部收益

**证据**：本仓库 selftest 早期版本忘了把凭证传给 Gradle（节点开了 token），结果：构建 **SUCCESSFUL**、日志里只有一条 warning、远程缓存命中/写入 **全为 0**。

**后果**：`tools/ci/run-gradle.sh` 在构建前做**预检**：用同一套凭证探一次缓存地址，401/403 直接 `::warning::` 吼出来。这类"看起来一切正常但一点没省"的故障，是缓存系统里最贵的故障。

---

## F7. `init.d` 里的脚本按**文件名字典序**执行，`setup-gradle` 自己也会注入一个

**证据**：`setup-gradle` 文档明说它会写
`USER_HOME/.gradle/init.d/gradle-actions.build-result-capture.init.gradle`，并建议自定义脚本排在它**之前**。

**后果**：本仓库的脚本在 CI 里安装为 **`00-mc-build-hub.init.gradle`**（`00-` 前缀保证最先应用）。本地全局安装也建议沿用同一命名。

---

## F8. 托管 Runner 的"冷"主要冷在三处，且都可分别优化

**证据**：本仓库实测（Arsenal_Graft，NeoForge 1.21.1，Gradle 9.2.0，JDK 21）。冷 `GRADLE_USER_HOME` 下跑 `help`（不做任何实际构建）：

| 阶段（Gradle `--profile` 口径） | 耗时 | 说明 |
|---|---|---|
| Startup | 75.1s | 冷 home 时这里含 **Gradle 发行版下载/解包** |
| Settings and buildSrc | 13.4s | 插件解析（moddev 等）下载 |
| Configuring Projects | 10.4s | 项目配置本身只要十几秒，但**配置之前已经花掉 90 秒** |

**后果**：所谓"配置阶段 30~60s 不可见"其实绝大部分是**下载**，不是配置计算。所以：
- 依赖/发行版层（GH 缓存 + 预热包）→ 干掉这 90 秒
- 配置缓存（加密键 + 项目状态缓存）→ 干掉"任务图重算"
- 任务输出层（远程构建缓存）→ 干掉真正的编译/反混淆

三者是**串联**关系，缺一层就卡在那一层——这也是"只上远程构建缓存，冷启动还是慢"的原因。

---

## F9. NeoForm 反混淆产物又大又贵，且**与仓库无关**

**证据**：本机 `~/.gradle/caches/neoformruntime` = **1.2G**，另 `forge_gradle` = **1.4G**；`modules-2` = 335M；Gradle 发行版 291M。而 NeoForm 的输入只取决于 **(MC 版本, loader 版本, JDK)**。

**后果**：这正是"跨仓库预热包"的立足点——把与仓库无关的 1~2G 产物打成 `warmpack-<指纹>.tar.zst`（实测打包 259M 那次的样本含发行版；真实 NeoForge 工程的包体见 `docs/04`），任何仓库的冷 Runner 拉一次就跳过反混淆。指纹要素：**MC/loader 版本 + Gradle 版本 + JDK 大版本 + schema 版本**。

---

## F10. `setup-gradle` 的 `enhanced` 缓存是**商业实现**，`basic` 才是 MIT

**证据**：`setup-gradle` v6.4.0 文档原文 —— `enhanced`（默认）"powered by proprietary technology"，公开仓库免费、私有仓库目前是 **Free Preview**；`basic` 是 "fully open-source (MIT) ... built on the standard GitHub Actions cache"。

**后果**：黑盒子把**关键路径**明确钉在 `cache-provider: basic`。理由不是省钱，而是**可预期**：基础设施不该依赖一个可能改条款的免费预览。

---

## F11. NeoForm 反编译的堆与线程数**由 NFRT 强制决定**，`org.gradle.jvmargs` 管不着

**证据**：NeoFormRuntime 源码 `ExternalJavaToolAction.setJvmArgs`：

```java
if (isVineflower()) {
    int allowedMebibytes = Math.max(4096, 256 * Runtime.getRuntime().availableProcessors());
    boolean hasXmx = this.jvmArgs.removeIf(s -> s.startsWith("-Xmx"));
    if (hasXmx) { this.jvmArgs.add("-Xmx" + allowedMebibytes + "m"); }
}
```

**后果**：
- 16 核机器 → `-Xmx4096m` **且开 16 个反编译线程**；你传的 `-Xmx` 会被移除并覆盖。
- 本机（15G 总内存，GUI 常驻约 3G）实测**两次都死在 decompile**（`output.jar` 0 字节，exit 1），
  详见 `evidence/02-cold-start-failure.md`。
- **托管 Runner（4 核 / 16G 独占）反而更稳**：`max(4096, 1024) = 4096m`，只有 4 个反编译线程。
- 想让反编译少占内存，可控的杠杆是**让它看见更少的核**：
  `JAVA_TOOL_OPTIONS=-XX:ActiveProcessorCount=4`（对所有 JVM 生效，包括 NFRT 拉起的子进程）。
  代价是 Gradle 自身的 worker 数也跟着降。这条适合"内存紧张的自托管机器"，不适合托管 Runner。

