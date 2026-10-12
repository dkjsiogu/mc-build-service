#!/usr/bin/env bash
# warmpack-ci.sh —— 预热包在 CI 里的取/存（跨仓库共享 NeoForm + 依赖快照）
# =====================================================================================
# 用法：warmpack-ci.sh restore | save | name | url
#
# 环境变量：
#   MC_HUB_CACHE_URL   形如 https://xxx.workers.dev/cache/（会自动推出 /pack/ 前缀）
#   MC_HUB_CACHE_USER / MC_HUB_CACHE_PASS   与 Gradle 远程缓存同一套凭证
#   PROJECT_DIR        被测项目目录（默认 project）——指纹取自它，同版本项目共用一个包
#   GRADLE_USER_HOME   Gradle 用户目录（restore 的目标 / save 的来源）
#   WARMPACK           缺省 auto：按指纹命名；off：不做；其它值：显式指定包名
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HUB_ROOT="$(cd "$HERE/../.." && pwd)"

PROJECT_DIR="${PROJECT_DIR:-project}"
GRADLE_USER_HOME="${GRADLE_USER_HOME:-$HOME/.gradle}"
WARMPACK="${WARMPACK:-auto}"
CACHE_URL="${MC_HUB_CACHE_URL:-}"

# https://host/cache/  →  https://host/pack/
BASE="${CACHE_URL%/}"
case "$BASE" in
  */cache) BASE="${BASE%/cache}" ;;
esac
PACK_BASE="$BASE/pack"

AUTH=()
[[ -n "${MC_HUB_CACHE_USER:-}" ]] && AUTH=(-u "$MC_HUB_CACHE_USER:${MC_HUB_CACHE_PASS:-}")

fingerprint() { bash "$HUB_ROOT/tools/warmpack.sh" fingerprint "$PROJECT_DIR"; }

pack_name() {
  if [[ "$WARMPACK" != "auto" && "$WARMPACK" != "off" ]]; then
    echo "$WARMPACK"
  else
    echo "warmpack-$(fingerprint).tar.zst"
  fi
}

cmd="${1:-}"
case "$cmd" in
  name)
    pack_name
    ;;

  url)
    echo "$PACK_BASE/$(pack_name)"
    ;;

  restore)
    if [[ "$WARMPACK" == "off" ]]; then echo "预热包：按配置跳过"; exit 0; fi
    if [[ -z "$CACHE_URL" ]]; then echo "预热包：未配置 MC_HUB_CACHE_URL，跳过"; exit 0; fi
    name="$(pack_name)"
    tmp="$(mktemp -t warmpack.XXXXXX.tar.zst)"
    echo "预热包：尝试拉取 $PACK_BASE/$name"
    code="$(curl -sS -o "$tmp" -w '%{http_code}' "${AUTH[@]}" "$PACK_BASE/$name" || echo 000)"
    if [[ "$code" != "200" ]]; then
      echo "预热包：未命中（HTTP $code）⇒ 本次按冷依赖处理，稍后由预热工作流补上"
      rm -f "$tmp"
      [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "warmpack-hit=false" >>"$GITHUB_OUTPUT"
      exit 0
    fi
    bytes=$(stat -c%s "$tmp" 2>/dev/null || echo 0)
    echo "预热包：命中，$(numfmt --to=iec "$bytes" 2>/dev/null || echo "${bytes}B")，开始还原"
    t0=$(date +%s)
    bash "$HUB_ROOT/tools/warmpack.sh" restore "$tmp" "$GRADLE_USER_HOME"
    t1=$(date +%s)
    rm -f "$tmp"
    echo "预热包：还原耗时 $((t1 - t0))s → $GRADLE_USER_HOME"
    [[ -n "${GITHUB_OUTPUT:-}" ]] && {
      echo "warmpack-hit=true" >>"$GITHUB_OUTPUT"
      echo "warmpack-seconds=$((t1 - t0))" >>"$GITHUB_OUTPUT"
    }
    ;;

  save)
    if [[ -z "$CACHE_URL" ]]; then echo "预热包：未配置 MC_HUB_CACHE_URL，跳过保存"; exit 0; fi
    name="$(pack_name)"
    tmp="$(mktemp -t warmpack.XXXXXX.tar.zst)"
    echo "预热包：打包 $GRADLE_USER_HOME（指纹 $(fingerprint)）"
    bash "$HUB_ROOT/tools/warmpack.sh" pack "$GRADLE_USER_HOME" "$tmp" "$PROJECT_DIR"
    bytes=$(stat -c%s "$tmp" 2>/dev/null || echo 0)
    echo "预热包：上传 $PACK_BASE/$name（$(numfmt --to=iec "$bytes" 2>/dev/null || echo "${bytes}B")）"
    t0=$(date +%s)
    code="$(curl -sS -o /dev/null -w '%{http_code}' "${AUTH[@]}" -T "$tmp" "$PACK_BASE/$name" || echo 000)"
    t1=$(date +%s)
    rm -f "$tmp"
    if [[ "$code" =~ ^2 ]]; then
      echo "预热包：上传成功（HTTP $code，耗时 $((t1 - t0))s）"
    else
      echo "::warning::预热包上传失败 HTTP $code（缓存服务没配好？不影响本次构建产物）"
    fi
    ;;

  *)
    sed -n '2,14p' "$0"
    exit 2
    ;;
esac
