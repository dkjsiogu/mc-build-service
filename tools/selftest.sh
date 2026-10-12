#!/usr/bin/env bash
# selftest.sh —— 黑盒子自检：把整条链路在本地/CI 里验穿（不依赖 Minecraft）
# =====================================================================================
# 验什么（每一段都对应一个"线上会静默失效、事后极难排查"的点）：
#   ① 静态：所有脚本语法、workflow YAML 可解析、worker 代码可解析
#   ② 协议：缓存节点（自托管 Node 实现）通过一致性测试 —— 尤其"未命中必须精确 404"
#   ③ 指纹：预热包指纹可复现；换 MC 版本必然变（否则会把错的产物喂给别的项目）
#   ④ 闭环：干净 home 构建 → 远程缓存写入 → 再一个干净 home 构建 → **必须 FROM-CACHE**
#   ⑤ 预热包：打包 → 还原 → 内容对得上
#   ⑥ 报告：report.mjs 的 JSON/Markdown 两种口径都能出
#
# 用法：tools/selftest.sh [--keep]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="${SELFTEST_DIR:-$ROOT/.bench/selftest}"
PORT="${SELFTEST_PORT:-8789}"
TOKEN="hub:selftest"
KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1

PASS=0; FAIL=0
ok()  { printf '\033[32m  ✓\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '\033[31m  ✗\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
sec() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
# assert <描述> <命令...>
assert() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
# assert_log <描述> <文件> <正则>
assert_log() { local name="$1" f="$2" re="$3"; if grep -qE "$re" "$f" 2>/dev/null; then ok "$name"; else bad "$name（在 $f 里没匹配到 /$re/）"; fi; }
# json <文件> <js表达式>
json() { node -e "const r=require(process.argv[1]);process.exit(($2)?0:1)" "$1" 2>/dev/null; }

NODE_PID=""
cleanup() {
  [[ -n "$NODE_PID" ]] && kill "$NODE_PID" 2>/dev/null
  if [[ $KEEP -eq 0 ]]; then rm -rf "$TMP"; else echo "（保留现场：$TMP）"; fi
}
trap cleanup EXIT

rm -rf "$TMP"; mkdir -p "$TMP"

# shellcheck source=lib/java.sh
source "$ROOT/tools/lib/java.sh"
hub_pick_java_home || { bad "找不到可用 JDK（设 HUB_JAVA_HOME 指一个）"; exit 1; }
printf '\033[36m[selftest]\033[0m 使用 JDK：%s（%s）\n' "$JAVA_HOME" "$("$JAVA_HOME/bin/java" -version 2>&1 | head -1)"

# ---------------------------------------------------------------- ① 静态
sec "① 静态检查"
static_fail=0
while IFS= read -r f; do
  bash -n "$f" || { bad "bash -n $f"; static_fail=1; }
done < <(find "$ROOT" -name '*.sh' -not -path '*/.bench/*' | sort)
[[ $static_fail -eq 0 ]] && ok "所有 shell 脚本 bash -n 通过"

node_fail=0
while IFS= read -r f; do
  node --check "$f" || { bad "node --check $f"; node_fail=1; }
done < <(find "$ROOT" \( -name '*.mjs' -o -name '*.js' \) -not -path '*/.bench/*' -not -path '*/node_modules/*' | sort)
[[ $node_fail -eq 0 ]] && ok "所有 JS 文件 node --check 通过"

yaml_fail=0
for f in "$ROOT"/.github/workflows/*.yml; do
  python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1],encoding='utf-8'))" "$f" 2>/dev/null || { bad "YAML 解析失败：${f#$ROOT/}"; yaml_fail=1; }
done
[[ $yaml_fail -eq 0 ]] && ok "workflow YAML 全部可解析"

# ---------------------------------------------------------------- ② 缓存节点协议
sec "② 缓存节点一致性（含鉴权）"
node "$ROOT/tools/local-cache-server.mjs" --port "$PORT" --dir "$TMP/node" --token "$TOKEN" >"$TMP/node.log" 2>&1 &
NODE_PID=$!
for _ in $(seq 1 40); do curl -sf "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break; sleep 0.25; done
assert "缓存节点健康检查" curl -sf "http://127.0.0.1:$PORT/healthz"
assert "一致性测试（Gradle HTTP 构建缓存协议）" node "$ROOT/worker/test/conformance.mjs" "http://127.0.0.1:$PORT" "$TOKEN"
CACHE_URL="http://127.0.0.1:$PORT/cache/"

# ---------------------------------------------------------------- ③ 指纹
sec "③ 预热包指纹"
FP1="$(bash "$ROOT/tools/warmpack.sh" fingerprint "$ROOT/tests/fixture")"
FP2="$(bash "$ROOT/tools/warmpack.sh" fingerprint "$ROOT/tests/fixture")"
[[ "$FP1" == "$FP2" && -n "$FP1" ]] && ok "同工程指纹可复现（$FP1）" || bad "指纹不可复现：$FP1 vs $FP2"
mkdir -p "$TMP/other"
cp -a "$ROOT/tests/fixture/." "$TMP/other/"
cat >>"$TMP/other/gradle.properties" <<'EOF'
minecraft_version=1.20.1
neo_version=20.4.100
EOF
FP3="$(bash "$ROOT/tools/warmpack.sh" fingerprint "$TMP/other")"
[[ "$FP1" != "$FP3" ]] && ok "换 MC/loader 版本 → 指纹变化（$FP1 → $FP3）" || bad "换版本指纹却没变：$FP1 == $FP3"

# ---------------------------------------------------------------- ④ 端到端闭环
sec "④ 端到端闭环：冷 home 写入 → 干净 home 必须命中"
PROJECT="$TMP/fixture"; cp -a "$ROOT/tests/fixture" "$PROJECT"
mkhome() { # mkhome <目录> [--seed-dist-from <gradle-home>]
  local h="$1"; mkdir -p "$h/init.d"
  cp "$ROOT/gradle/mc-build-hub.init.gradle" "$h/init.d/00-mc-build-hub.init.gradle"
  if [[ "${2:-}" == "--seed-dist-from" && -d "$3/wrapper" ]]; then
    mkdir -p "$h/wrapper"; cp -a "$3/wrapper/." "$h/wrapper/" 2>/dev/null || true
  fi
  echo "$h"
}
# 首次：把发行版下载算进去太慢，这里允许从本机 ~/.gradle 借一份（自检只关心缓存闭环，不测下载耗时）
SEED="${SELFTEST_SEED_DIST:-$HOME/.gradle}"
HOME_A="$(mkhome "$TMP/home-a" --seed-dist-from "$SEED")"
HOME_B="$(mkhome "$TMP/home-b" --seed-dist-from "$SEED")"

mkdir -p "$TMP/run1" "$TMP/run2"
stats_before="$(curl -s "http://127.0.0.1:$PORT/stats")"

( cd "$TMP/run1" && PROJECT_DIR="$PROJECT" GRADLE_USER_HOME="$HOME_A" MC_HUB_CACHE_URL="$CACHE_URL" \
  MC_HUB_CACHE_PUSH=true GRADLE_TASKS=build bash "$ROOT/tools/ci/run-gradle.sh" ) >"$TMP/run1.out" 2>&1
rc1=$?
[[ $rc1 -eq 0 ]] && ok "第一次构建成功" || { bad "第一次构建失败（rc=$rc1，见 $TMP/run1/hub-build.log）"; tail -20 "$TMP/run1/hub-build.log"; }

stats_after1="$(curl -s "http://127.0.0.1:$PORT/stats")"
json "$TMP/run1/hub-stats.json" "r.tasks.executed>=3" && ok "第一次构建确实执行了任务（executed≥3）" || bad "第一次构建没有执行任务，缓存断言没意义"
puts1="$(node -e 'const a=JSON.parse(process.argv[1]),b=JSON.parse(process.argv[2]);console.log((b.puts||0)-(a.puts||0))' "$stats_before" "$stats_after1")"
[[ "${puts1:-0}" -gt 0 ]] && ok "远程缓存写入成功（$puts1 个条目）" || bad "远程缓存没有写入（puts=$puts1）"

# 第二次：模拟"另一台干净 Runner 上重建同一个提交"
rm -rf "$PROJECT/build" "$PROJECT/.gradle"
( cd "$TMP/run2" && PROJECT_DIR="$PROJECT" GRADLE_USER_HOME="$HOME_B" MC_HUB_CACHE_URL="$CACHE_URL" \
  MC_HUB_CACHE_PUSH=false GRADLE_TASKS=build bash "$ROOT/tools/ci/run-gradle.sh" ) >"$TMP/run2.out" 2>&1
rc2=$?
[[ $rc2 -eq 0 ]] && ok "第二次构建成功" || { bad "第二次构建失败（rc=$rc2）"; tail -20 "$TMP/run2/hub-build.log"; }

assert_log "日志里出现 FROM-CACHE" "$TMP/run2/hub-build.log" '^> Task .* FROM-CACHE'
json "$TMP/run2/hub-stats.json" "r.tasks.fromCache>=3" && ok "缓存命中任务 ≥3（命中 $(node -e 'console.log(require(process.argv[1]).tasks.fromCache)' "$TMP/run2/hub-stats.json") 个）" || bad "缓存命中任务不足"
json "$TMP/run2/hub-stats.json" "r.cacheHitRatePct>=50" && ok "命中率 ≥50%" || bad "命中率过低"
assert_log "配置缓存被复用/存储" "$TMP/run2/hub-build.log" 'Reusing configuration cache|Configuration cache entry (stored|reused)'

sec "④b 报告口径"
assert "report.mjs --json 可输出" node "$ROOT/tools/report.mjs" "$TMP/run2/hub-build.log" --json
assert_log "report.mjs --markdown 出表格" <(node "$ROOT/tools/report.mjs" "$TMP/run2/hub-build.log" --markdown) 'mc-build-hub 构建报告'

# ---------------------------------------------------------------- ⑤ 预热包往返
sec "⑤ 预热包打包/还原"
marker="$HOME_A/caches/modules-2/.hub-selftest-marker"
mkdir -p "$(dirname "$marker")" && echo "marker-$(date +%s)" >"$marker"
bash "$ROOT/tools/warmpack.sh" pack "$HOME_A" "$TMP/wp.tar.zst" "$ROOT/tests/fixture" >"$TMP/pack.log" 2>&1
[[ -s "$TMP/wp.tar.zst" ]] && ok "打包成功（$(du -h "$TMP/wp.tar.zst" | cut -f1)）" || bad "打包失败"
HOME_C="$TMP/home-c"; mkdir -p "$HOME_C"
bash "$ROOT/tools/warmpack.sh" restore "$TMP/wp.tar.zst" "$HOME_C" >"$TMP/restore.log" 2>&1
assert "还原后 marker 内容一致" grep -q "marker-" "$HOME_C/caches/modules-2/.hub-selftest-marker"
assert "还原后不含 lock 文件（排除规则生效）" bash -c "! find '$HOME_C' -name '*.lock' | grep -q ."
assert "还原后不含 build-cache-1（分离关注点）" bash -c "[[ ! -d '$HOME_C/caches/build-cache-1' ]]"

# ---------------------------------------------------------------- 汇总
printf '\n\033[1m自检结果：%d 通过 / %d 失败\033[0m\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
