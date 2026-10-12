#!/usr/bin/env bash
# run-gradle.sh —— CI 侧唯一入口：跑 Gradle、计时、解析、写 GitHub Step Summary
# =====================================================================================
# 为什么把逻辑放脚本里而不是堆在 YAML：本地基准（tools/bench.sh）走的是同一套解析器，
# 于是"线上数字"和"本地数字"口径一致，不会出现两套互相矛盾的说法。
#
# 环境变量（都有默认值）：
#   PROJECT_DIR     被测项目目录（默认 project）
#   GRADLE_TASKS    任务列表（默认 build）
#   GRADLE_JVMARGS  传给 daemon 的堆参数（默认不覆写项目自己的设置）
#   EXTRA_ARGS      追加给 Gradle 的额外参数
#   PROFILE         1=加 --profile（拿五段时间分布，默认 1）
#   LOG             日志落盘路径（默认 $PWD/hub-build.log）
#   STATS_OUT       解析结果 JSON 落盘路径（默认 $PWD/hub-stats.json）
#   MC_HUB_*        交给 init 脚本（远程缓存地址/凭证/推送）
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HUB_ROOT="$(cd "$HERE/../.." && pwd)"

PROJECT_DIR="${PROJECT_DIR:-project}"
GRADLE_TASKS="${GRADLE_TASKS:-build}"
PROFILE="${PROFILE:-1}"
LOG="${LOG:-$PWD/hub-build.log}"
STATS_OUT="${STATS_OUT:-$PWD/hub-stats.json}"
EXTRA_ARGS="${EXTRA_ARGS:-}"

[[ -d "$PROJECT_DIR" ]] || { echo "::error::项目目录不存在：$PROJECT_DIR"; exit 2; }
[[ -x "$PROJECT_DIR/gradlew" ]] || { echo "::error::$PROJECT_DIR 下没有可执行的 gradlew（CI 里别忘 chmod +x gradlew）"; exit 2; }

ARGS=(--configuration-cache --build-cache --console=plain)
[[ "$PROFILE" == "1" ]] && ARGS+=(--profile)
if [[ -n "${GRADLE_JVMARGS:-}" ]]; then
  ARGS+=("-Dorg.gradle.jvmargs=$GRADLE_JVMARGS")
fi
# shellcheck disable=SC2206
[[ -n "$EXTRA_ARGS" ]] && ARGS+=($EXTRA_ARGS)

echo "::group::mc-build-hub 构建配置"
echo "  项目      : $PROJECT_DIR"
echo "  任务      : $GRADLE_TASKS"
echo "  参数      : ${ARGS[*]}"
echo "  远程缓存  : ${MC_HUB_CACHE_URL:-（未配置，跨仓库复用收益为 0）}"
echo "  远程推送  : ${MC_HUB_CACHE_PUSH:-false}"
echo "  CC 密钥   : ${GRADLE_ENCRYPTION_KEY:+已设置}${GRADLE_ENCRYPTION_KEY:-未设置}"
echo "::endgroup::"

# ---- 远程缓存预检 ----------------------------------------------------------------
# 不是装饰：缓存节点返回 401/403 时，Gradle 只记一条 warning，构建照样 SUCCESSFUL，
# 但命中率**永远是 0**。这种"看起来一切正常却一点没省"的故障是缓存系统里最贵的故障，
# 所以构建前先探一次，并把话说清楚（实测踩坑现场：tools/selftest.sh 在 GitHub Runner 上翻车那次）。
if [[ -n "${MC_HUB_CACHE_URL:-}" ]]; then
  probe_key="mc-build-hub-preflight-$(date +%s)-$$"
  probe_auth=()
  [[ -n "${MC_HUB_CACHE_USER:-}" ]] && probe_auth=(-u "$MC_HUB_CACHE_USER:${MC_HUB_CACHE_PASS:-}")
  probe_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    ${probe_auth[@]+"${probe_auth[@]}"} "${MC_HUB_CACHE_URL%/}/$probe_key" 2>/dev/null || echo 000)"
  case "$probe_code" in
    404) echo "远程缓存预检：通过（HTTP 404 = 未命中，符合协议）" ;;
    200) echo "远程缓存预检：通过（HTTP 200，探针键意外命中，无碍）" ;;
    401|403) echo "::warning::远程缓存预检失败（HTTP $probe_code）⇒ 本次远程缓存**全部失效**，命中率会是 0。请检查 MC_HUB_CACHE_USER / MC_HUB_CACHE_PASS。" ;;
    000) echo "::warning::远程缓存预检无法连通（网络/DNS/地址写错？）：${MC_HUB_CACHE_URL}" ;;
    *)   echo "::warning::远程缓存预检返回意外状态码 HTTP $probe_code（协议要求未命中必须是 404）" ;;
  esac
else
  echo "远程缓存预检：跳过（未配置 MC_HUB_CACHE_URL，本次只有本地/依赖层收益）"
fi

start=$(date +%s)
(
  cd "$PROJECT_DIR"
  # shellcheck disable=SC2086
  ./gradlew $GRADLE_TASKS "${ARGS[@]}"
) >"$LOG" 2>&1
rc=$?
end=$(date +%s)
wall=$((end - start))

# 逐任务耗时：优先用 Gradle 自己的 --profile 报告（权威口径）
PROFILE_HTML="$(ls -t "$PROJECT_DIR"/build/reports/profile/profile-*.html 2>/dev/null | head -1 || true)"

PARSE_ARGS=("$LOG" --out "$STATS_OUT")
[[ -n "$PROFILE_HTML" ]] && PARSE_ARGS+=(--profile "$PROFILE_HTML")
node "$HUB_ROOT/tools/report.mjs" "${PARSE_ARGS[@]}" || true

echo "── 构建日志尾部（最后 40 行）──"
tail -40 "$LOG" || true

# 给 GitHub Actions 的 outputs（脚本被当 step 跑时才有意义）
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "wall-seconds=$wall"
    echo "gradle-rc=$rc"
    node -e '
      const fs=require("fs");
      let r={}; try{r=JSON.parse(fs.readFileSync(process.argv[1],"utf8"))}catch(e){}
      const one=(k,v)=>console.log(`${k}=${String(v).replace(/\n/g," ")}`);
      one("cache-hit-rate", r.cacheHitRatePct ?? 0);
      one("result", r.result ?? "UNKNOWN");
      one("stats-json", JSON.stringify({tasks:r.tasks, cc:r.configurationCache, profile:r.profile, hub:r.hub}));
    ' "$STATS_OUT" 2>/dev/null || true
  } >>"$GITHUB_OUTPUT"
fi

# GitHub Step Summary：让"这次到底省了多少"直接出现在 PR/构建页面
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  node "$HUB_ROOT/tools/report.mjs" "$LOG" --markdown >>"$GITHUB_STEP_SUMMARY" 2>/dev/null || true
fi

if [[ $rc -ne 0 ]]; then
  echo "::error::Gradle 构建失败（退出码 $rc），完整日志见上方与产物 hub-build.log"
fi
exit $rc
