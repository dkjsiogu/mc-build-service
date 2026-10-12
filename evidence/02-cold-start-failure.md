# 证据 02：真·冷启动挂在 NeoForm 反编译 —— 以及它暴露出的一个真实约束

- **时间**：2026-10-13 03:02 ~ 03:09
- **场景**：`Arsenal_Graft`（NeoForge 1.21.1 / moddev 2.0.120），全新 `GRADLE_USER_HOME`，
  任务 `assemble`，远程缓存分别关闭（s0）/开启并推送（s1）
- **结果**：两次都在 NeoForm 的 `decompile` 阶段失败，分别耗时 **338.3s / 367.6s**

## 失败点（原始日志）

```
> Task :createMinecraftArtifacts FAILED
* What went wrong:
Execution failed for task ':createMinecraftArtifacts'.
> Process 'command '/usr/lib/jvm/graalvm-jdk-21.0.10+8.1/bin/java'' finished with non-zero exit value 1
```

NFRT 自身的阶段计时（说明真正贵的是哪一步）：

```
✓ Completed downloadClient in 21.75s
✓ Completed downloadServer in 34.29s
✓ Completed mergeMappings in 1.05s
✓ Completed stripClient in 1.35s
✓ Completed extractServer in 0.21s
✓ Completed stripServer in 0.90s
✓ Completed merge in 1.86s
✓ Completed rename in 2.71s
*** Started working on decompile
 ↳ Running external tool org.vineflower:vineflower:1.10.1
（此处进程死亡，output.jar 为 0 字节）
```

## 根因：NFRT 强制给 Vineflower 的堆与线程数

NeoFormRuntime 源码（`src/main/java/net/neoforged/neoform/runtime/actions/ExternalJavaToolAction.java`）：

```java
// NeoForm hardcodes 4G for Vineflower, but Vineflower will use one thread per core
// and the RAM usage should scale with the number of cores.
if (isVineflower()) {
    int allowedMebibytes = Math.max(
            4096,                                  // At least 4G
            256 * Runtime.getRuntime().availableProcessors());   // Allocate 256M per core
    boolean hasXmx = this.jvmArgs.removeIf(s -> s.startsWith("-Xmx"));
    if (hasXmx) {
        this.jvmArgs.add("-Xmx" + allowedMebibytes + "m");
    }
}
```

三个直接后果：

1. **`-Xmx` 是 NFRT 说了算**：16 核机器上是 `max(4096, 4096) = 4096m`，
   而且它会**移除**你原本传的 `-Xmx` 再塞回自己算的值。
2. **线程数 = 核数**：16 核 → Vineflower 开 16 个反编译线程，
   峰值内存远超堆参数本身（每个线程持有的类结构 + 输出缓冲）。
3. **本机环境刚好卡在边界**：15G 总内存 − GUI/编辑器约 3G − Gradle daemon 2G ⇒ 剩给反编译的不足 4G。
   两次尝试都死在同一步，`output.jar` 0 字节。

> 这与"黑盒子"的设计无关，但**必须写进文档**：
> **托管 Runner（4 核 / 16G 独占）反而比这台开发机更适合跑反编译** ——
> 4 核时 NFRT 计算 `max(4096, 1024) = 4096m` 且只有 4 个反编译线程，16G 独占，稳。

## 对方案的三个结论

1. **反编译产物值得共享**：它贵（分钟级）、它与仓库无关（只取决于 MC/loader/JDK）、
   它又刚好是"第一个项目付一次、其余项目全免"的典型 ⇒ 预热包（L3）的存在理由被这次失败反向证实。
2. **预热包必须包含 `caches/neoformruntime`**：这不是"顺手带上"，而是整个 L3 的核心（本机实测 1.2G）。
3. **本机内存是瓶颈，不是缓存方案**：因此基准矩阵把"真冷"单独列为失败证据，
   其余场景用"预热包已就位"（=播种 NFRT 产物）作为起点 —— 这也正是真实流水线里 99% 的运行状态。
   矩阵口径与结论见 `docs/04-benchmark.md`。
