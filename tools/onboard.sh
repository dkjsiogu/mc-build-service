#!/usr/bin/env bash
# onboard.sh —— 把一个 mod 仓库接到「黑盒子」上（一条命令）
# =====================================================================================
# 它做的四件事：
#   ① 识别项目工具链（MC / loader / Gradle / JDK）→ 算出**预热包指纹**
#   ② 生成两个 workflow 文件（构建 + 定时预热），项目配置一行都不用改
#   ③ 把需要的 secret 写进目标仓库（值从本机凭证文件读，不回显）
#   ④ 打印"下一步该跑什么"，以及**你这个项目能不能直接吃现成的预热包**
#
# 用法：
#   tools/onboard.sh --dir /path/to/mod-repo          # 推荐：本地已克隆，能顺便算指纹
#   tools/onboard.sh --repo owner/name                # 只给远端名（会在临时目录浅克隆）
#   tools/onboard.sh                                  # 当前目录就是 mod 仓库
#
# 常用选项：
#   --tasks <Gradle 任务>    默认 assemble（想跑测试就写 build）
#   --java <大版本>          默认 21
#   --scope <标签>           默认自动生成 mc<MC>-<loader><版本>
#   --project-path <子路径>  多模块仓库里指定子项目，默认 .
#   --secrets-from <文件>    默认 <hub>/.env.local
#   --no-secrets             只生成 workflow，不碰 secret
#   --commit                 顺手提交并推送（默认只写文件，留给你 review）
#   --dry-run                只打印计划，什么都不改
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HUB_ROOT="$(cd "$HERE/.." && pwd)"

TARGET_DIR=""; TARGET_REPO=""; TASKS="assemble"; JAVA_VER="21"; SCOPE=""; PROJECT_PATH="."
SECRETS_FROM="$HUB_ROOT/.env.local"; DO_SECRETS=1; DO_COMMIT=0; DRY=0
BRANCH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) TARGET_DIR="${2:-}"; shift 2 ;;
    --repo) TARGET_REPO="${2:-}"; shift 2 ;;
    --tasks) TASKS="${2:-}"; shift 2 ;;
    --java) JAVA_VER="${2:-}"; shift 2 ;;
    --scope) SCOPE="${2:-}"; shift 2 ;;
    --project-path) PROJECT_PATH="${2:-}"; shift 2 ;;
    --secrets-from) SECRETS_FROM="${2:-}"; shift 2 ;;
    --no-secrets) DO_SECRETS=0; shift ;;
    --commit) DO_COMMIT=1; shift ;;
    --branch) BRANCH="${2:-}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "未知参数：$1（--help 看用法）" >&2; exit 2 ;;
  esac
done

say()  { printf '\033[36m[onboard]\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m  ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[onboard]\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [[ $DRY -eq 1 ]]; then echo "  [dry-run] $*"; else eval "$@"; fi; }

# ---------------------------------------------------------------- 定位目标仓库
if [[ -n "$TARGET_REPO" && -z "$TARGET_DIR" ]]; then
  TMPC="$(mktemp -d)"
  say "浅克隆 $TARGET_REPO → $TMPC（只为了读配置、写 workflow）"
  git clone --depth 1 "https://github.com/$TARGET_REPO.git" "$TMPC/repo" >/dev/null 2>&1 || die "克隆失败：$TARGET_REPO"
  TARGET_DIR="$TMPC/repo"
fi
TARGET_DIR="${TARGET_DIR:-$PWD}"
[[ -f "$TARGET_DIR/gradlew" ]] || die "$TARGET_DIR 里没有 gradlew —— 这不像一个 Gradle 项目"
[[ -f "$TARGET_DIR/build.gradle" || -f "$TARGET_DIR/build.gradle.kts" ]] || die "$TARGET_DIR 里没有 build.gradle(.kts)"

REPO_SLUG="$(git -C "$TARGET_DIR" remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||; s|\.git$||')"
PROJECT_NAME="$(basename "$TARGET_DIR")"

# ---------------------------------------------------------------- ① 识别工具链
mc="$(grep -hE '^(minecraft_version|mc_version)=' "$TARGET_DIR/gradle.properties" 2>/dev/null | head -1 | cut -d= -f2)"
gw="$(grep -h 'distributionUrl' "$TARGET_DIR/gradle/wrapper/gradle-wrapper.properties" 2>/dev/null | sed -E 's/.*gradle-([0-9.]+)-.*/\1/')"
if grep -q 'net.neoforged' "$TARGET_DIR/build.gradle" 2>/dev/null; then
  loader="neoforge"; lver="$(grep -hE '^(neo_version|neoforge_version)=' "$TARGET_DIR/gradle.properties" 2>/dev/null | head -1 | cut -d= -f2)"
elif grep -q 'fabric-loom' "$TARGET_DIR/build.gradle" 2>/dev/null; then
  loader="fabric"; lver="$(grep -hE '^(loader_version|fabric_loader_version)=' "$TARGET_DIR/gradle.properties" 2>/dev/null | head -1 | cut -d= -f2)"
elif grep -qE 'net\.minecraftforge|forgegradle' "$TARGET_DIR/build.gradle" 2>/dev/null; then
  loader="forge"; lver="$(grep -hE '^(forge_version|minecraftforge_version)=' "$TARGET_DIR/gradle.properties" 2>/dev/null | head -1 | cut -d= -f2)"
else
  loader="unknown"; lver=""
fi
toolchain_java="$(grep -hE 'languageVersion *= *JavaLanguageVersion\.of\(([0-9]+)\)' "$TARGET_DIR/build.gradle" 2>/dev/null | head -1 | grep -oE '[0-9]+' | head -1)"
JAVA_VER="${toolchain_java:-$JAVA_VER}"
SCOPE="${SCOPE:-mc${mc:-x}-${loader}${lver}}"

# 预热包指纹里含有 **JDK 大版本**，而 CI 用的 JDK 由 workflow 的 java-version 决定（setup-java 设 JAVA_HOME）。
# 所以本地算指纹必须挑一个同大版本的 JDK，否则会算出与 CI 不同的值 —— 表现为"明明有现成包却报 404"。
find_jdk() {  # $1 = 大版本
  local want="$1" d ver
  for d in /usr/lib/jvm/* "$HOME"/.gradle/jdks/* "$HOME"/java/*; do
    [[ -x "$d/bin/java" ]] || continue
    ver="$("$d/bin/java" -version 2>&1 | head -1 | sed -E 's/.*version "([0-9]+).*/\1/')"
    [[ "$ver" == "$want" ]] && { echo "$d"; return 0; }
  done
  return 1
}
FP_JDK="$(find_jdk "$JAVA_VER" || true)"
if [[ -n "$FP_JDK" ]]; then
  FP="$(JAVA_HOME="$FP_JDK" bash "$HUB_ROOT/tools/warmpack.sh" fingerprint "$TARGET_DIR" 2>/dev/null || echo '?')"
else
  warn "本机没有 JDK $JAVA_VER ⇒ 指纹可能算不准（CI 上会按 java-version: $JAVA_VER 计算）"
  FP="$(bash "$HUB_ROOT/tools/warmpack.sh" fingerprint "$TARGET_DIR" 2>/dev/null || echo '?')"
fi

echo
say "目标项目：$PROJECT_NAME${REPO_SLUG:+ （$REPO_SLUG）}"
printf '  %-14s %s\n' "MC" "${mc:-未识别}" "loader" "$loader ${lver}" "Gradle" "${gw:-?}" "JDK" "$JAVA_VER"
printf '  %-14s %s\n' "预热包指纹" "$FP"
printf '  %-14s %s\n' "cache-scope" "$SCOPE"

# 这个项目能不能直接吃 R2 里现成的预热包？
if [[ -f "$SECRETS_FROM" ]]; then
  # shellcheck disable=SC1090
  set -a; . "$SECRETS_FROM"; set +a
  if [[ -n "${R2_ENDPOINT:-}" && -n "${R2_BUCKET:-}" ]]; then
    EMPTY=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    pack="pack/warmpack-${FP}.tar.zst"
    # 必须用 HEAD：GET 会把这 540MB 的包整个下载下来（"探测存在性"变成"下载整包"）
    code="$(curl -s -I -o /dev/null -w '%{http_code}' --aws-sigv4 'aws:amz:auto:s3' \
      --user "$R2_ACCESS_KEY_ID:$R2_SECRET_ACCESS_KEY" -H "x-amz-content-sha256: $EMPTY" \
      "$R2_ENDPOINT/$R2_BUCKET/$pack" 2>/dev/null || echo 000)"
    if [[ "$code" == "200" ]]; then
      ok "R2 里**已有**这个指纹的预热包 ⇒ 接入后第一次构建就是温启动（省掉几分钟反混淆）"
    elif [[ "$code" == "404" ]]; then
      warn "R2 里还没有这个指纹的包 ⇒ 先跑一次预热工作流（约 5~8 分钟，之后所有同工具链项目共享）"
    else
      warn "无法确认预热包状态（HTTP $code；凭证或网络问题？）"
    fi
  fi
fi

# ---------------------------------------------------------------- ② 生成 workflow
say "生成 workflow（项目本身零改动）"
GEN_BUILD="$TARGET_DIR/.github/workflows/hub-build.yml"
GEN_WARM="$TARGET_DIR/.github/workflows/hub-warm.yml"
mkdir -p "$(dirname "$GEN_BUILD")" 2>/dev/null || true

read -r -d '' BUILD_YML <<YAML || true
# 由 mc-build-service 的 tools/onboard.sh 生成（$(date -I)）
# 项目本身不需要任何改动：能力全部从工作流侧注入（-I init 脚本 / 命令行开关 / 环境变量）。
name: build (mc-build-hub)

on:
  push:
  pull_request:
  workflow_dispatch:

concurrency:
  group: hub-build-\${{ github.ref }}
  cancel-in-progress: true

jobs:
  build:
    uses: dkjsiogu/mc-build-service/.github/workflows/reusable-build.yml@v1
    with:
      gradle-tasks: '$TASKS'
      java-version: '$JAVA_VER'
      cache-scope: '$SCOPE'
      project-path: '$PROJECT_PATH'
      artifact-name: '$PROJECT_NAME'
    secrets: inherit
YAML

read -r -d '' WARM_YML <<YAML || true
# 由 mc-build-service 的 tools/onboard.sh 生成（$(date -I)）
# 每天凌晨把"贵且与代码无关"的部分先算好塞进 R2：之后白天改代码只剩增量编译。
name: warm-cache (mc-build-hub)

on:
  schedule:
    - cron: '0 18 * * *'      # UTC 18:00 = 北京 02:00
  workflow_dispatch:

concurrency:
  group: hub-warm
  cancel-in-progress: false

jobs:
  warm:
    uses: dkjsiogu/mc-build-service/.github/workflows/reusable-warm-cache.yml@v1
    with:
      warm-tasks: 'classes'
      java-version: '$JAVA_VER'
      cache-scope: '$SCOPE'
      project-path: '$PROJECT_PATH'
      save-warmpack: true
    secrets: inherit
YAML

if [[ $DRY -eq 1 ]]; then
  echo "  [dry-run] 将写入 $GEN_BUILD"; echo "$BUILD_YML" | sed 's/^/    /'
  echo "  [dry-run] 将写入 $GEN_WARM"
else
  printf '%s\n' "$BUILD_YML" >"$GEN_BUILD"
  printf '%s\n' "$WARM_YML" >"$GEN_WARM"
  ok "已写入 .github/workflows/hub-build.yml"
  ok "已写入 .github/workflows/hub-warm.yml"
fi

# ---------------------------------------------------------------- ③ 配 secret
if [[ $DO_SECRETS -eq 1 ]]; then
  if [[ -z "$REPO_SLUG" ]]; then
    warn "该项目没有 GitHub 远端 ⇒ 跳过 secret（先 push 到 GitHub 再重跑本脚本）"
  elif [[ ! -f "$SECRETS_FROM" ]]; then
    warn "找不到凭证文件 $SECRETS_FROM ⇒ 跳过 secret（可用 --secrets-from 指定）"
  else
    say "写入 secrets → $REPO_SLUG"
    # shellcheck disable=SC1090
    set -a; . "$SECRETS_FROM"; set +a
    set_secret() {  # set_secret <名字> <值>
      local name="$1" val="${2:-}"
      if [[ -z "$val" ]]; then warn "跳过 $name（本机凭证文件里没有）"; return 0; fi
      if [[ $DRY -eq 1 ]]; then echo "  [dry-run] gh secret set $name --repo $REPO_SLUG（值 ${#val} 字节，不回显）"; return 0; fi
      printf '%s' "$val" | gh secret set "$name" --repo "$REPO_SLUG" >/dev/null 2>&1 \
        && ok "$name" || warn "$name 写入失败（权限？）"
    }
    set_secret MC_HUB_S3_ENDPOINT     "${R2_ENDPOINT:-}"
    set_secret MC_HUB_S3_BUCKET       "${R2_BUCKET:-}"
    set_secret MC_HUB_S3_KEY_ID       "${R2_ACCESS_KEY_ID:-}"
    set_secret MC_HUB_S3_SECRET       "${R2_SECRET_ACCESS_KEY:-}"
    set_secret MC_HUB_CACHE_USER      "${CACHE_TOKEN%%:*}"
    set_secret MC_HUB_CACHE_PASS      "${CACHE_TOKEN#*:}"
    set_secret MC_HUB_CC_KEY          "${MC_HUB_CC_KEY:-}"
  fi
else
  warn "--no-secrets：未写入任何 secret"
fi

# ---------------------------------------------------------------- ④ 提交（可选）
if [[ $DO_COMMIT -eq 1 ]]; then
  say "提交并推送"
  run "git -C '$TARGET_DIR' add .github/workflows/hub-build.yml .github/workflows/hub-warm.yml"
  run "git -C '$TARGET_DIR' -c user.name=dkjsiogu -c user.email=dkjsiogu@users.noreply.github.com commit -q -m 'ci: 接入 mc-build-hub（build + 定时预热）'"
  if [[ -n "$BRANCH" ]]; then run "git -C '$TARGET_DIR' push -u origin HEAD:$BRANCH"; else run "git -C '$TARGET_DIR' push"; fi
  ok "已推送"
else
  say "文件已就位但**未提交**（自己 review 后）：
  git -C '$TARGET_DIR' add .github/workflows/hub-build.yml .github/workflows/hub-warm.yml
  git -C '$TARGET_DIR' commit -m 'ci: 接入 mc-build-hub'
  git -C '$TARGET_DIR' push"
fi

# ---------------------------------------------------------------- 下一步
cat <<EOF

下一步（顺序别反，反了会以为"没效果"）：
  1) 先跑一次预热： gh workflow run 'warm-cache (mc-build-hub)' --repo $REPO_SLUG
     —— 第一次要把 NeoForm 反混淆算完（5~8 分钟），并打出 warmpack-${FP}.tar.zst
  2) 再跑构建：     gh workflow run 'build (mc-build-hub)' --repo $REPO_SLUG
     —— 看 Job Summary：应出现"远程缓存命中"与"执行段骤降"
  3) 之后正常 push 即可

同工具链的项目会共用同一个预热包（指纹 ${FP}）——
第 2、3 个项目接入时，第一次构建就是温启动，不用再等反混淆。
EOF
