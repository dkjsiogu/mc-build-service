# 证据 01：init 脚本里注册监听器 → 配置缓存作废 **且构建失败**

- **时间**：2026-10-13 02:45（本仓库 v0.1 首次端到端实测）
- **场景**：`Arsenal_Graft`（NeoForge 1.21.1，Gradle 9.2.0，JDK 21），全新 `GRADLE_USER_HOME`，
  安装 `mc-build-hub.init.gradle` v0.1，执行 `./gradlew help --configuration-cache`
- **结果**：`BUILD FAILED`（v0.1 的统计功能把消费方的构建全搞挂了）

## 原始报错（未删改）

```
* What went wrong:
Configuration cache problems found in this build.

3 problems were found storing the configuration cache.
- Initialization script '/home/dkjsiogu/文档/project/mc-build-service/.bench/home-cold/init.d/mc-build-hub.init.gradle': line 118: registration of listener on 'TaskExecutionGraph.beforeTask' is unsupported
  See https://docs.gradle.org/9.2.0/userguide/configuration_cache_requirements.html#config_cache:requirements:build_listeners
- Initialization script '.../mc-build-hub.init.gradle': line 121: registration of listener on 'TaskExecutionGraph.afterTask' is unsupported
- Initialization script '.../mc-build-hub.init.gradle': line 170: registration of listener on 'Gradle.buildFinished' is unsupported

> Listener registration 'Gradle.buildFinished' by build is unsupported.
> Listener registration 'TaskExecutionGraph.beforeTask' by org.gradle.execution.taskgraph.DefaultTaskExecutionGraph@74823e3a is unsupported.
> Listener registration 'TaskExecutionGraph.afterTask' by org.gradle.execution.taskgraph.DefaultTaskExecutionGraph@74823e3a is unsupported.

BUILD FAILED in 1m 29s
1 actionable task: 1 executed
Configuration cache entry discarded with 3 problems.
```

> 注意最后一行：**"Configuration cache entry discarded"**。
> 就算构建没失败，配置缓存也白存了 —— 也就是说，"为了观测缓存效果而挂监听器"这件事，
> 本身就把要观测的那个收益毁掉了。属于自己拆自己台。

## 派生的两条规则（已写进 F2）

1. **init 脚本里不许注册任何构建监听器**：`TaskExecutionGraph.beforeTask/afterTask`、
   `Gradle.buildFinished`、`Gradle.addListener(...)` 全部列入禁用清单。
2. **观测改走日志**：`> Task :x FROM-CACHE` 这类 plain 控制台输出 + `--profile` 的 HTML 报告，
   足以还原"命中率 + 五段时间分布 + 最慢任务"，且对构建零侵入（`tools/report.mjs`）。

## 顺带确认的两件事

- 该 init 脚本的 `try/catch` 兜底是有效的：v0.1 在抛错前先把"远程缓存接线失败"记成了 warning
  而不是中断构建（那次失败纯粹是监听器违规导致的，与缓存接线无关）。
- 同一份脚本在改掉监听器（v0.2）后，`help` 两次运行分别是 "Configuration cache entry stored."
  与 "Reusing configuration cache." —— 配置缓存**可以**在 init 脚本存在时正常工作。
