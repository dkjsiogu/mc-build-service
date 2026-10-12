#!/usr/bin/env bash
# bench.sh —— 冷/温启动基准：把「GitHub 托管 Runner」在本地如实模拟出来
# =====================================================================================
# 为什么能当真：托管 Runner 的本质是「干净的 GRADLE_USER_HOME + 干净的源码树 + 网络」。
#   本地把这三样复现出来，量到的数字与线上同量级（差异只在磁盘/网络带宽，
#   而"冷启动贵在哪、缓存能救多少"这个结论不会变）。
#
# 场景矩阵（每个场景都在全新的 GRADLE_USER_HOME 里跑，互不污染）：
#   s0  裸冷启动（不用黑盒子，远程缓存关闭）        ← 真·对照组（本机因内存不足挂在反编译，见 docs/04）
#   s1  冷启动 + 填充远程缓存                       ← 第一次接入；NFRT 产物按"预热包已就位"播种
#   s2  温启动：同一次提交在新 Runner 上重建        ← 远程缓存全命中
#   s3  温启动：改了 1 行代码                       ← 日常最常见的场景
#   s3b 温启动 + 项目 .gradle 也被恢复               ← 验证"配置缓存跨 Runner 复用"能不能成
#   s4  温启动 + 预热包（跨仓库共享的 NeoForm/依赖） ← "黑盒子"完整形态
#   s0b 预热包已就位但没有远程缓存                   ← 只缺 L2 会怎样（隔离出远程构建缓存的贡献）
#
# 关于 NFRT 播种（BENCH_NFRT_SEED）：NeoForm 反编译在本机需要 4G 堆 × 16 线程，
#   本机（15G 总内存、GUI 常驻 3G）两次都把它撑死 ⇒ 用"已算好的 NeoForm 产物"代表
#   「预热包已拉取」这个状态。这正是黑盒子在真实流水线里的常态：
#   第一个项目付一次反编译成本，之后所有项目/所有 Runner 都吃这份产物。
#
# 用法：
#   tools/bench.sh check                 # 只做环境自检
#   tools/bench.sh run s0 s1 s2          # 跑指定场景（按给定顺序）
#   tools/bench.sh all                   # 跑全矩阵
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BENCH="${BENCH_DIR:-$ROOT/.bench}"
LOGS="$BENCH/logs"
WORK="$BENCH/work"
EVIDENCE="$BENCH/evidence"
RESULTS="$EVIDENCE/bench-results.json"

PROJECT_NAME="${BENCH_PROJECT_NAME:-Arsenal_Graft}"
PROJECT_SRC="${BENCH_PROJECT_SRC:-/home/dkjsiogu/文档/mod/$PROJECT_NAME}"
GRADLE_TASKS="${BENCH_TASKS:-assemble}"
JAVA_HOME="${BENCH_JAVA_HOME:-${JAVA_HOME:-}}"
CACHE_URL="${MC_HUB_CACHE_URL:-http://127.0.0.1:8787/cache/}"
CACHE_NODE_DIR="${CACHE_NODE_DIR:-$BENCH/cache-node}"
PROFILE="${BENCH_PROFILE:-1}"          # 1 = 传 --profile 拿逐任务耗时
# shellcheck source=lib/java.sh
source "$ROOT/tools/lib/java.sh"
hub_pick_java_home || { echo "[bench] 找不到可用 JDK：设 HUB_JAVA_HOME 指一个" >&2; exit 1; }

# 复制源码树时排除的东西：这些要么是运行期产物（几个 G），要么是"Runner 上本来就没有"的
EXCLUDES=(
  --exclude="$PROJECT_NAME/run" --exclude="$PROJECT_NAME/build" --exclude="$PROJECT_NAME/.gradle"
  --exclude="$PROJECT_NAME/tmp" --exclude="$PROJECT_NAME/logs" --exclude="$PROJECT_NAME/output"
  --exclude="$PROJECT_NAME/.git" --exclude="$PROJECT_NAME/.eclipse" --exclude="$PROJECT_NAME/helloagents"
  --exclude="$PROJECT_NAME/.duel-platform" --exclude="$PROJECT_NAME/.web-catalog" --exclude="$PROJECT_NAME/.claude"
  --exclude="$PROJECT_NAME/.ssh_keys" --exclude="$PROJECT_NAME/docs" --exclude="$PROJECT_NAME/skills"
)

log() { printf '\033[36m[bench]\033[0m %s\n' "$*" >&2; }
ok()  { printf '\033[32m[bench]\033[0m %s\n' "$*" >&2; }
bad() { printf '\033[31m[bench]\033[0m %s\n' "$*" >&2; }

# ---------------------------------------------------------------- 基础设施
ensure_cache_node() {
  if curl -sf "${CACHE_URL%/cache/}/healthz" >/dev/null 2>&1; then
    ok "缓存节点在线：$CACHE_URL"
    return 0
  fi
  log "缓存节点未启动，正在拉起（dir=$CACHE_NODE_DIR）"
  mkdir -p "$CACHE_NODE_DIR" "$LOGS"
  nohup node "$ROOT/tools/local-cache-server.mjs" --port 8787 --dir "$CACHE_NODE_DIR" \
    >"$LOGS/cache-node.log" 2>&1 &
  echo $! > "$BENCH/cache-node.pid"
  for _ in $(seq 1 40); do
    curl -sf "http://127.0.0.1:8787/healthz" >/dev/null 2>&1 && { ok "缓存节点已就绪 (pid $(cat "$BENCH/cache-node.pid"))"; return 0; }
    sleep 0.25
  done
  bad "缓存节点起不来，见 $LOGS/cache-node.log"; return 1
}

cache_stats() { curl -s "${CACHE_URL%/cache/}/stats" 2>/dev/null || echo '{}'; }

# 全新源码树：模拟 actions/checkout 之后的干净工作区
fresh_project() {
  local dest="$1"
  rm -rf "$dest"; mkdir -p "$dest"
  tar -C "$(dirname "$PROJECT_SRC")" -cf - "${EXCLUDES[@]}" "$PROJECT_NAME" | tar -C "$dest" -xf -
  echo "$dest/$PROJECT_NAME"
}

# 全新 GRADLE_USER_HOME：模拟托管 Runner 上空的 ~/.gradle
fresh_home() {
  local home="$1"
  rm -rf "$home"; mkdir -p "$home/init.d"
  cp "$ROOT/gradle/mc-build-hub.init.gradle" "$home/init.d/"
  echo "$home"
}

# L1（依赖层）：托管 Runner 上由 setup-gradle 从 GH Actions 缓存恢复的那部分。
# 刻意**不含** caches/build-cache-1 —— 我们的工作流把它排除掉了（见 reusable-build.yml 的
# cache-excludes），好让"任务输出复用"由远程缓存（L2）负责，于是 L2 的贡献可以被单独量出来。
L1_DIRS=(wrapper/dists caches/modules-2 caches/jars-9)
seed_l1() {
  local home="$1" from="$2"
  [[ -d "$from" ]] || { bad "L1 种子源不存在：$from"; return 1; }
  local copied=()
  for d in "${L1_DIRS[@]}"; do
    [[ -e "$from/$d" ]] || continue
    mkdir -p "$home/$(dirname "$d")"
    cp -a "$from/$d" "$home/$d" 2>/dev/null && copied+=("$d")
  done
  for d in "$from"/caches/[0-9]*; do   # caches/<gradle版本>：生成的 API jar
    [[ -d "$d" ]] || continue
    cp -a "$d" "$home/caches/" 2>/dev/null && copied+=("caches/$(basename "$d")")
  done
  log "  已播种 L1 依赖层（模拟 setup-gradle 恢复 GH 缓存）：${copied[*]}"
}

# 播种 NeoForm 产物 = 模拟"预热包已拉取"（跨仓库共享的那 1.2G 就在这儿）
NFRT_SEED_SOURCE="${BENCH_NFRT_SEED:-$HOME/.gradle/caches/neoformruntime}"
seed_nfrt() {
  local home="$1"
  if [[ ! -d "$NFRT_SEED_SOURCE" ]]; then
    bad "NeoForm 种子源不存在：$NFRT_SEED_SOURCE（本场景将退化为真冷启动，很可能挂在反编译）"
    return 1
  fi
  mkdir -p "$home/caches"
  cp -a "$NFRT_SEED_SOURCE" "$home/caches/neoformruntime"
  log "  已播种 NeoForm 产物：$(du -sh "$home/caches/neoformruntime" 2>/dev/null | cut -f1) ← $NFRT_SEED_SOURCE"
}

touch_source() {  # 改 1 行代码：日常提交的最小扰动
  local project="$1"
  local file
  file="$(find "$project/src/main/java" -name '*.java' -printf '%s %p\n' 2>/dev/null | sort -n | head -1 | cut -d' ' -f2-)"
  [[ -n "$file" ]] || { bad "找不到可改的 Java 源文件"; return 1; }
  printf '\n// bench: warm-cache touch %s\n' "$(date +%s)" >> "$file"
  echo "$file"
}

# ---------------------------------------------------------------- 单场景执行
# run_gradle <id> <home> <project> <mode>   mode: nohub | read | readpush | push
run_gradle() {
  local id="$1" home="$2" project="$3" mode="$4"
  local logf="$LOGS/$id.log"
  local extra=()
  [[ "$PROFILE" == "1" ]] && extra+=(--profile)
  extra+=(--configuration-cache --console=plain)

  local stats_before stats_after
  stats_before="$(cache_stats)"

  (
    cd "$project"
    export GRADLE_USER_HOME="$home"
    export MC_HUB_CONFIG_FILE="$EVIDENCE/$id-config.txt"
    case "$mode" in
      nohub)    unset MC_HUB_CACHE_URL MC_HUB_CACHE_USER MC_HUB_CACHE_PASS; export MC_HUB_CACHE_PUSH=false ;;
      read)     export MC_HUB_CACHE_URL="$CACHE_URL" MC_HUB_CACHE_PUSH=false ;;
      readpush) export MC_HUB_CACHE_URL="$CACHE_URL" MC_HUB_CACHE_PUSH=true ;;
      push)     export MC_HUB_CACHE_URL="$CACHE_URL" MC_HUB_CACHE_PUSH=true ;;
    esac
    start=$(date +%s.%N)
    ./gradlew $GRADLE_TASKS "${extra[@]}" >"$logf" 2>&1
    rc=$?
    end=$(date +%s.%N)
    echo "$rc" > "$LOGS/$id.rc"
    echo "$start $end" > "$LOGS/$id.times"
  )

  stats_after="$(cache_stats)"
  local rc wall
  rc="$(cat "$LOGS/$id.rc")"
  wall="$(awk '{printf "%.1f", $2 - $1}' "$LOGS/$id.times")"
  local profile_html
  profile_html="$(ls -t "$project"/build/reports/profile/profile-*.html 2>/dev/null | head -1 || true)"

  # 用 report.mjs 做统一解析（CI 里也用同一个解析器，口径一致）
  node "$ROOT/tools/report.mjs" "$logf" --out "$EVIDENCE/$id-report.json" ${profile_html:+--profile "$profile_html"} >/dev/null 2>&1 || true

  node -e '
    const fs=require("fs");
    const [id,home,project,mode,rc,wall,logf,statsBefore,statsAfter,rep,results]=process.argv.slice(1);
    let r={}; try{ r=JSON.parse(fs.readFileSync(rep,"utf8")); }catch(e){ r={parseError:String(e)}; }
    const sb=JSON.parse(statsBefore), sa=JSON.parse(statsAfter);
    const rec={
      id, mode, wallSeconds:Number(wall), gradleRc:Number(rc),
      result:r.result||"UNKNOWN", gradleSeconds:r.buildSeconds??null,
      configurationCache:r.configurationCache||null,
      profile:r.profile||null,
      tasks:r.tasks||null, cacheHitRatePct:r.cacheHitRatePct??null,
      fromCacheTasks:(r.fromCacheTasks||[]).slice(0,40),
      slowestTasks:(r.slowestTasks||[]).slice(0,15),
      hub:r.hub||{},
      remote:{ hits:(sa.hits??0)-(sb.hits??0), misses:(sa.misses??0)-(sb.misses??0),
               puts:(sa.puts??0)-(sb.puts??0), bytesInMB:+(((sa.bytesIn??0)-(sb.bytesIn??0))/1048576).toFixed(1),
               bytesOutMB:+(((sa.bytesOut??0)-(sb.bytesOut??0))/1048576).toFixed(1) },
      gradleUserHome:home, project, log:logf,
      notes: process.env.BENCH_NOTE || "",
    };
    let all=[]; try{ all=JSON.parse(fs.readFileSync(results,"utf8")); }catch(e){}
    all=all.filter(x=>x.id!==id); all.push(rec);
    fs.mkdirSync(require("path").dirname(results),{recursive:true});
    fs.writeFileSync(results, JSON.stringify(all,null,2));
    const t=rec.tasks||{}; const pf=rec.profile||{};
    const s=(v)=>v==null?"-":(v/1000).toFixed(1);
    console.log(`${rec.result==="SUCCESSFUL"?"✓":"✗"} ${id.padEnd(6)} 墙钟 ${String(rec.wallSeconds).padStart(6)}s │ 启动 ${String(s(pf.startupMs)).padStart(5)}s │ 配置 ${String(s(pf.configuringMs)).padStart(5)}s │ 执行 ${String(s(pf.executionMs)).padStart(6)}s │ CC ${String((rec.configurationCache||{}).status).padEnd(12)} │ 任务 执行${String(t.executed??"?").padStart(3)}/命中${String(t.fromCache??"?").padStart(3)}/最新${String(t.upToDate??"?").padStart(3)} │ 远程 ${rec.remote.hits}命中/${rec.remote.puts}写入`);
  ' "$id" "$home" "$project" "$mode" "$rc" "$wall" "$logf" "$stats_before" "$stats_after" "$EVIDENCE/$id-report.json" "$RESULTS"

  [[ "$rc" == "0" ]]
}

# ---------------------------------------------------------------- 场景定义
scenario_s0() {
  log "s0 裸冷启动（不用黑盒子）——这是对照组，最慢也最重要"
  local project home
  project="$(fresh_project "$WORK/s0")"
  home="$(fresh_home "$BENCH/home-s0")"
  run_gradle s0 "$home" "$project" nohub
}

scenario_s1() {
  log "s1 冷启动 + 填充远程缓存（第一次接入；NFRT 产物按'预热包已就位'播种）"
  local project home
  project="$(fresh_project "$WORK/s1")"
  home="$(fresh_home "$BENCH/home-s1")"
  seed_nfrt "$home" || true
  BENCH_NOTE="NFRT 产物已播种（=预热包已拉取）；远程缓存为空，本次负责把它填满" \
  run_gradle s1 "$home" "$project" readpush
}

scenario_s2() {
  log "s2 温启动：同一次提交、全新 Runner（远程缓存全命中）"
  local project home
  project="$(fresh_project "$WORK/s2")"
  home="$(fresh_home "$BENCH/home-s2")"
  seed_l1 "$home" "$BENCH/home-s1"
  BENCH_NOTE="L1 依赖层已恢复 + L2 远程构建缓存；未还原预热包(L3)；源码未改动" \
  run_gradle s2 "$home" "$project" read
}

scenario_s3() {
  log "s3 温启动：改了 1 行代码（日常场景）"
  local project home touched
  project="$(fresh_project "$WORK/s3")"
  home="$(fresh_home "$BENCH/home-s3")"
  seed_l1 "$home" "$BENCH/home-s1"
  touched="$(touch_source "$project")"; log "  改动：$touched"
  BENCH_NOTE="L1 依赖层已恢复 + L2 远程构建缓存；未还原预热包(L3)；改一行代码" \
  run_gradle s3 "$home" "$project" read
}

scenario_s3b() {
  log "s3b 温启动 + 项目 .gradle 也被恢复（验证配置缓存能否跨 Runner 复用）"
  local project home touched
  project="$(fresh_project "$WORK/s3b")"
  home="$(fresh_home "$BENCH/home-s3b")"
  seed_l1 "$home" "$BENCH/home-s1"
  # 模拟 CI 把工程目录 .gradle 一起缓存/恢复（CC 条目就住在那里）
  if [[ -d "$WORK/s1/$PROJECT_NAME/.gradle" ]]; then
    mkdir -p "$project/.gradle"
    cp -a "$WORK/s1/$PROJECT_NAME/.gradle/." "$project/.gradle/" 2>/dev/null || true
    log "  已恢复 .gradle（$(du -sh "$project/.gradle" | cut -f1)）"
  else
    bad "  s1 工程里没有 .gradle，跳过恢复（s3b 将退化成 s3）"
  fi
  touched="$(touch_source "$project")"; log "  改动：$touched"
  BENCH_NOTE="L1+L2 基础上再恢复项目 .gradle（验证配置缓存跨 Runner 复用）" \
  run_gradle s3b "$home" "$project" read
}

# 预热包：s4 与 s0b 共用同一份（同一指纹 ⇒ 同一包，正是跨仓库共享的语义）
ensure_warmpack() {
  local pack
  pack="$EVIDENCE/warmpack-$(bash "$ROOT/tools/warmpack.sh" fingerprint "$WORK/s1/$PROJECT_NAME").tar.zst"
  if [[ ! -f "$pack" ]]; then
    log "  预热包不存在 → 用 s1 的 GRADLE_USER_HOME 现场打包（原始 $(du -sh "$BENCH/home-s1" 2>/dev/null | cut -f1)）"
    WARMPACK_ZSTD_LEVEL="${WARMPACK_ZSTD_LEVEL:-3}" \
      bash "$ROOT/tools/warmpack.sh" pack "$BENCH/home-s1" "$pack" "$WORK/s1/$PROJECT_NAME" 2>&1 | sed 's/^/  /' >&2
  fi
  echo "$pack"
}

scenario_s4() {
  log "s4 温启动 + 预热包（跨仓库共享 NeoForm/依赖，'黑盒子'完整形态）"
  local project home pack
  pack="$(ensure_warmpack)"
  project="$(fresh_project "$WORK/s4")"
  home="$(fresh_home "$BENCH/home-s4")"
  log "  还原预热包 $(du -h "$pack" | cut -f1) → $home"
  bash "$ROOT/tools/warmpack.sh" restore "$pack" "$home" 2>&1 | sed 's/^/  /' >&2
  local touched
  touched="$(touch_source "$project")"; log "  改动：$touched"
  BENCH_NOTE="L1+L3 预热包已还原 + L2 远程构建缓存；改一行代码（黑盒子完整形态）" \
  run_gradle s4 "$home" "$project" read
}

# 对照场景：预热包到位，但**没有**远程构建缓存 ⇒ 单独量出 L2 的贡献
scenario_s0b() {
  log "s0b 预热包已就位、但没有远程构建缓存（用来隔离 L2 的贡献）"
  local project home pack
  pack="$(ensure_warmpack)"
  project="$(fresh_project "$WORK/s0b")"
  home="$(fresh_home "$BENCH/home-s0b")"
  log "  还原预热包 $(du -h "$pack" | cut -f1) → $home"
  bash "$ROOT/tools/warmpack.sh" restore "$pack" "$home" 2>&1 | sed 's/^/  /' >&2
  touch_source "$project" >/dev/null
  BENCH_NOTE="L1+L3 预热包已还原，但 L2 远程构建缓存关闭 ⇒ 与 s4 的差值就是 L2 的贡献" \
  run_gradle s0b "$home" "$project" nohub
}

check() {
  log "环境自检"
  local fail=0
  for c in node curl tar zstd sha256sum; do
    command -v "$c" >/dev/null && ok "  $c: $(command -v "$c")" || { bad "  缺少 $c"; fail=1; }
  done
  [[ -x "$JAVA_HOME/bin/java" ]] && ok "  JAVA_HOME: $JAVA_HOME ($("$JAVA_HOME/bin/java" -version 2>&1 | head -1))" || { bad "  JAVA_HOME 无效：$JAVA_HOME"; fail=1; }
  [[ -f "$PROJECT_SRC/gradlew" ]] && ok "  被测项目：$PROJECT_SRC" || { bad "  项目不存在：$PROJECT_SRC"; fail=1; }
  ok "  共享指纹：$(bash "$ROOT/tools/warmpack.sh" fingerprint "$PROJECT_SRC")"
  ok "  纳入预热包的目录："
  bash "$ROOT/tools/warmpack.sh" list-dirs "$BENCH/home-s1" 2>/dev/null | sed 's/^/    /' >&2
  ensure_cache_node || fail=1
  df -h "$BENCH" | tail -1 | sed 's/^/  /' >&2
  return $fail
}

summary() {
  [[ -f "$RESULTS" ]] || { bad "还没有结果"; return 1; }
  node -e '
    const fs=require("fs");
    const all=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
    const order=["s0","s1","s2","s3","s3b","s4"];
    all.sort((a,b)=>order.indexOf(a.id)-order.indexOf(b.id));
    const base=all.find(x=>x.id==="s0");
    const s=(v)=>v==null?"-":(v/1000).toFixed(1);
    console.log("\n| 场景 | 墙钟(s) | 启动(s) | Settings(s) | 配置(s) | 执行(s) | 配置缓存 | 执行/命中/最新 | 远程 命中/写入 | 相对 s0 |");
    console.log("|---|---|---|---|---|---|---|---|---|---|");
    for(const r of all){
      const t=r.tasks||{}; const cc=(r.configurationCache||{}).status||"-"; const pf=r.profile||{};
      const speed=base&&base.wallSeconds?`${(base.wallSeconds/r.wallSeconds).toFixed(1)}×`:"-";
      console.log(`| ${r.id} | ${r.wallSeconds} | ${s(pf.startupMs)} | ${s(pf.settingsMs)} | ${s(pf.configuringMs)} | ${s(pf.executionMs)} | ${cc} | ${t.executed??"-"}/${t.fromCache??"-"}/${t.upToDate??"-"} | ${r.remote.hits}/${r.remote.puts} | ${speed} |`);
    }
    console.log("");
  ' "$RESULTS"
}

# ---------------------------------------------------------------- 主流程
mkdir -p "$LOGS" "$WORK" "$EVIDENCE"
case "${1:-all}" in
  check) check ;;
  run)   shift; ensure_cache_node || exit 1
         for s in "$@"; do "scenario_$s" || bad "场景 $s 未成功（已记录，继续）"; done
         summary ;;
  all)   ensure_cache_node || exit 1
         for s in s1 s2 s3 s3b s4 s0b; do "scenario_$s" || bad "场景 $s 未成功（已记录，继续）"; done
         summary ;;
  *)     sed -n '2,25p' "$0"; exit 2 ;;
esac
