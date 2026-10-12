# GitHub 侧的行为与限制（实测记录，不是转述文档）

这一页专门记录**在真实 GitHub 上跑出来的**结论。有些限制官方文档写得含糊，
而它们直接决定架构长什么样，所以这里用探针仓库一条条验过。

---

## G1. 私有仓库的 reusable workflow **不能**被另一个私有仓库调用（个人账号实测）

**实验设计**（探针仓库 `dkjsiogu/mc-build-service-probe`，私有；黑盒子 `dkjsiogu/mc-build-service`，私有）：

| 探针 | 内容 | 结果 |
|---|---|---|
| `probe-cross.yml` | `uses: dkjsiogu/mc-build-service/.github/workflows/reusable-build.yml@main` | ❌ **0 秒失败，jobs 数 = 0** |
| `probe-local.yml` | `uses: ./.github/workflows/inner-reusable.yml`（同仓库） | ✅ **成功，8 秒** |

**结论**：
- 同仓库调用完全正常 ⇒ 不是语法/配置问题；
- 跨到**私有**仓库时，**GitHub 连解析都不做**（0 job），不是"跑到某一步才失败"。
  也就是说：想在私有 hub 上靠 reusable workflow 做共享，此路不通。
- 附带修正一个常见误用：`secrets: inherit` 按官方文档仅限"同组织/同企业"，
  跨仓库调用时不要指望它。

**对架构的两个后果**（本仓库两个消费者模板正好对应这两条路）：

1. **把黑盒子做成公开仓库** → `uses: .../reusable-build.yml@v1` 直接可用，
   消费方**零额外凭证**（凭证都来自消费方自己的 secrets）。← 推荐
   模板：`examples/consumer/.github/workflows/build.yml`
2. **黑盒子保持私有** → 消费方自己 `actions/checkout` 出黑盒子（用 PAT），
   然后跑它的脚本。多 30 行 YAML + 一个 `MC_HUB_TOKEN`。← 今天就能用
   模板：`examples/consumer-private-hub/.github/workflows/build.yml`

> 公共仓库的 reusable workflow 可以被任何人调用（包括私有仓库调用它），
> 这是 GitHub 设计的"共享自动化"路径。黑盒子里没有任何密钥 ——
> 缓存地址与令牌全部由调用方通过 secret 注入，所以公开它不会泄露任何东西。

---

## G2. `workflow_dispatch` 只能触发默认分支上存在的工作流

**实测**：推了 `master` 之后 `gh workflow run selftest.yml` 能派发；
把默认分支改成 `main` 之后，派发同样正常 —— 但**只认默认分支**上的那份定义。

**实践含义**：新增/改名的 workflow 想手动触发，得先合进默认分支；
想验证特性分支上的工作流，用 `push:` 触发而不是 `workflow_dispatch`。

---

## G3. 托管 Runner 上"分发层"的耗时与本地不可比

**实测对照**：

| 项目 | 本机（国际链路慢） | GitHub `ubuntu-latest` |
|---|---|---|
| Gradle 9.2.0 发行版（145MB） | **约 10 分钟**（约 240KB/s） | 十几秒 |
| 夹具工程两次完整构建 | 每轮 ~10s（结构相同） | 每轮 ~10s（自检日志实测） |

**实践含义**：本仓库的基准数据里，"启动"那一项在本机会被发行版下载严重放大；
评估托管 Runner 的收益时，要看**任务态/命中率/执行段**这些与网络无关的量，
而不是直接对比墙钟。这也是 L1 必须缓存 `wrapper/dists` 的原因（`setup-gradle` 默认就会带上）。

---

## G4. 自检必须能"自己证明自己" —— 第一次在真实 Runner 上就抓到一个静默故障

**实测**：`selftest` 第一次跑在 GitHub Runner 上时，
"远程缓存没有写入（puts=0）" —— 原因是自检的缓存节点开了鉴权，而 Gradle 没拿到凭证：
**401 被 Gradle 降级成一条 warning，构建照样 SUCCESSFUL，命中率永远是 0**。

这类故障正是"必须有端到端断言"的理由：静态检查、单元测试全部通过，
链路却一点没生效。修复后把这个场景固化成两条护栏：

1. 自检脚本把同一套凭证同时交给 Gradle（`MC_HUB_CACHE_USER/PASS`）；
2. `run-gradle.sh` 构建前**预检**缓存地址，401/403 直接 `::warning::` 点名。
