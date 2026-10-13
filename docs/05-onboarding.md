# 别的 mod 项目怎么用这个黑盒子

## 一句话

在目标仓库跑**一条命令**（或手工拷 2 个文件 + 配 7 个 secret），
然后**先预热一次、再正常 push**。**mod 项目本身一行都不用改** ——
不改 `build.gradle`、不改 `settings.gradle`、不改 `gradle.properties`。

```bash
# 在 mc-build-service 目录下，指向你要接入的 mod 仓库
tools/onboard.sh --dir /path/to/your-mod-repo
```

它会做完四件事，并把"你这个项目能不能直接吃现成的预热包"告诉你：

```
[onboard] 目标项目：女仆变大
  MC             1.21.1
  loader         neoforge 21.1.233
  Gradle         9.2.0
  JDK            21
  预热包指纹 604055c0ffd4
  cache-scope    mc1.21.1-neoforge21.1.233
  ✓ R2 里**已有**这个指纹的预热包 ⇒ 接入后第一次构建就是温启动（省掉几分钟反混淆）
[onboard] 生成 workflow（项目本身零改动）
  ✓ 已写入 .github/workflows/hub-build.yml
  ✓ 已写入 .github/workflows/hub-warm.yml
[onboard] 写入 secrets → dkjsiogu/xxx
  ✓ MC_HUB_S3_ENDPOINT / MC_HUB_S3_BUCKET / MC_HUB_S3_KEY_ID / MC_HUB_S3_SECRET
  ✓ MC_HUB_CACHE_USER / MC_HUB_CACHE_PASS / MC_HUB_CC_KEY
```

默认**只写文件、不提交**（留给你 review）；想一步到位加 `--commit`。
不确定会改什么就先 `--dry-run`。

---

## 手工三步（不想用脚本时）

### 第 1 步：拷两个 workflow

```bash
cp examples/consumer/.github/workflows/build.yml     <你的仓库>/.github/workflows/
cp examples/consumer/.github/workflows/warm-cache.yml <你的仓库>/.github/workflows/
```

把里面的 `cache-scope` 改成你的工具链标签（只是给人看的注释），`gradle-tasks` 按需改
（`assemble` 只出 jar；`build` 会连测试一起跑）。

### 第 2 步：配 7 个 secret

仓库 Settings → Secrets and variables → Actions：

| Secret | 值 | 用途 |
|---|---|---|
| `MC_HUB_S3_ENDPOINT` | `https://<account>.r2.cloudflarestorage.com` | 作业内直连 R2 |
| `MC_HUB_S3_BUCKET` | `buildcach` | 同上 |
| `MC_HUB_S3_KEY_ID` | R2 Access Key ID | 同上 |
| `MC_HUB_S3_SECRET` | R2 Secret Access Key | 同上 |
| `MC_HUB_CACHE_USER` | `hub` | 作业内节点的 Basic 校验 |
| `MC_HUB_CACHE_PASS` | 与 hub 侧一致 | 同上 |
| `MC_HUB_CC_KEY` | `openssl rand -base64 16` | **配置缓存跨 Runner 复用的开关** |

> 也可以只配 `MC_HUB_CACHE_URL`（指向一个现成的 Worker / 自托管节点）来替代前四个 —— 二选一。
> 细节与两条路的取舍见 `docs/03`。
> 想省事：这些值都在 hub 仓库本地的 `.env.local` 里，`tools/onboard.sh` 就是自动读它。

### 第 3 步：先预热，再构建（顺序别反）

```bash
gh workflow run 'warm-cache (mc-build-hub)'   # 第一次要把 NeoForm 反混淆算完（5~8 分钟）
gh workflow run 'build (mc-build-hub)'        # 这次就该看到"远程缓存命中 + 执行段骤降"
```

---

## 你的项目属于哪一种？（决定第一次是"等 5 分钟"还是"直接温启动"）

预热包按 **MC / loader / Gradle / JDK** 四要素算指纹；**同指纹 = 共用同一个包**。
本机实测（可以自己用 `tools/warmpack.sh fingerprint <项目>` 复核）：

| 项目 | 工具链 | 指纹 | R2 里有没有现成的 |
|---|---|---|---|
| Arsenal_Graft | 1.21.1 / NeoForge 21.1.233 / Gradle 9.2.0 / JDK 21 | `604055c0ffd4` | ✅ 540 MB |
| 女仆变大 | 同上 | `604055c0ffd4` | ✅ 同一个包，**接入即温启动** |
| 万业有日涅磐无枝 | 同上 | `604055c0ffd4` | ✅ 同一个包，**接入即温启动** |
| deepseekmod | 1.21.1 / NeoForge 21.1.123 / Gradle 8.13 | `853b72698f99` | ❌ 先预热一次 |
| longinus-mod | 1.20.1 / Forge 47.4.0 / Gradle 8.8 | `64066c97201f` | ❌ 先预热一次 |

> 指纹**只认影响产物的东西**：`*_version_range`（mod 兼容性声明）、`mod_version` 之类都不参与
> —— 否则"本可共用"的项目会被硬拆成两个包（这是实测踩过的坑，见 `tools/warmpack.sh` 注释）。

## 多项目并行开发

- **构建天然并行**：每个仓库各自分配 Runner，互不排队；hub 侧没有任何集中式排队点。
- **共享的是产物**，不是机器：同工具链的项目共用
  - 一份**预热包**（540 MB，含 NeoForm 反混淆产物）
  - 一份**远程任务输出缓存**（`compileJava` 之类）
- **第 3、4 个项目接入时成本几乎为零**：预热包已经在 R2 里，第一次构建就是温启动。
- 换了 MC/loader 版本才会产生新指纹，那时也只是**再多一个包**，老项目的包不受影响。

## 怎么确认"真的接上了"

每次构建都会自动生成 Job Summary（`tools/report.mjs` 产出），三条判据：

1. **配置缓存 = 复用** —— 一直是"新建并存储"就检查 `MC_HUB_CC_KEY` 是否配了；
2. **远程缓存有命中** —— 命中恒为 0 时先看日志里 `[mc-build-hub]` 的**预检** warning（多半是凭证）；
3. **"启动"段很小（几秒）** —— 如果仍是 60~90 秒，说明 L1/L3 没生效（依赖/发行版还在重下）。

参考值（真实托管 Runner、真实 mod、`assemble`）：冷启动 281s → 接上 R2 后 **28s**（`evidence/04`）。

## FAQ

| 现象 | 原因 | 处置 |
|---|---|---|
| 命中率 0，构建却成功 | 缓存节点 401 / 地址结尾少了 `/` | 看 `run-gradle.sh` 的预检 warning |
| 配置缓存从不复用 | 没配 `MC_HUB_CC_KEY`；或黑盒子 ref 用了浮动 `main` 且刚改过 init 脚本 | 配上 key；把 ref 钉成 tag（`@v1`） |
| 预热包一直 404 | 还没跑过 warm；或指纹变了（换了 MC/loader/Gradle/JDK） | 跑一次 `reusable-warm-cache.yml` |
| `jar` 每次都不命中 | Gradle 默认禁止打包类任务进缓存 | 正常现象（大 jar 项目可自行 `outputs.cacheIf { true }`） |
| 拉预热包比重新下载还慢 | 包太大 / Runner 到 R2 的链路差 | 工作流里把 `warmpack` 设成 `off`，只吃 L1+L2 |
| 私有 hub 调用报 404 | 私有仓库之间不能调 reusable workflow | hub 已公开 ⇒ 直连即可；自建私有 hub 见 `docs/06` G1 |
| 想只让部分项目用 | —— | 不配 secret 的仓库就自然只吃 L1，互不影响 |
