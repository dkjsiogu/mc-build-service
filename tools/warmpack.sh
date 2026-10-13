#!/usr/bin/env bash
# warmpack.sh —— 跨仓库共享的「预热包」（GRADLE_USER_HOME 里可共享的那部分快照）
# =====================================================================================
# 存在的理由（一句话）：GitHub Actions 的缓存是**按仓库隔离**的，
#   repo A 的 ~/.gradle 缓存 repo B 一点都拿不到；而 NeoForm 反混淆/重编译产物
#   （caches/neoformruntime，实测 1.2G）只跟 MC/loader 版本有关、跟仓库无关。
#   把它打包丢进 R2，任何仓库的冷 Runner 都能秒变"温"——这才是"黑盒子"的实质。
#
# 用法：
#   tools/warmpack.sh fingerprint [project-dir]              # 打印共享指纹（跨仓库同版本=同指纹）
#   tools/warmpack.sh list-dirs                              # 打印纳入快照的目录清单
#   tools/warmpack.sh pack <gradle-home> <out.tar.zst> [project-dir]
#   tools/warmpack.sh restore <in.tar.zst> <gradle-home>
#
# 设计取舍：
#   - 不收 caches/build-cache-1（本地构建缓存）：那是"每台机器一份"的易变目录，
#     跨机共享请走远程构建缓存（R2），别混进预热包把体积撑爆。
#   - 不收 jdks/native/daemon/workers：跟机器架构绑定，搬过去反而可能出错。
#   - 收 wrapper/dists：Gradle 发行版本身 291M，冷 Runner 每次重下就是白白几十秒。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEMA_VERSION="1"          # 改目录清单/口径就 +1，让旧预热包自然作废
ZSTD_LEVEL="${WARMPACK_ZSTD_LEVEL:-6}"

# 共享目录清单（相对 GRADLE_USER_HOME）
SHARED_DIRS=(
  "wrapper/dists"          # Gradle 发行版
  "caches/modules-2"       # 依赖 jar（内容寻址，跨仓库/跨 JDK 通用）
  "caches/neoformruntime"  # NeoForm 反混淆/重编译产物（NeoForge 家族的大头）
  "caches/forge_gradle"    # ForgeGradle/NeoGradle 家族的大头
  "caches/jars-9"          # 构建脚本编译产物
)
# caches/<gradle版本> 例如 caches/9.2.0：Gradle 生成的 API jar，按版本目录动态纳入
EXCLUDE_ARGS=(
  --exclude='*.lock'
  --exclude='*/tmp/*'
  --exclude='*/tmp'
  --exclude='*/journal-1/*'
  --exclude='*/fileHashes/*'
  --exclude='*/executionHistory/*'
  --exclude='*/configuration-cache/*'
  --exclude='*/.tmp/*'
  --exclude='*/gc.properties'
)

die() { echo "warmpack: $*" >&2; exit 1; }

fingerprint() {
  local project="${1:-.}"
  local parts=()
  parts+=("schema=$SCHEMA_VERSION")

  # Gradle 版本：以 wrapper 为准（CI 用的就是这个）
  local wrapper="$project/gradle/wrapper/gradle-wrapper.properties"
  if [[ -f "$wrapper" ]]; then
    parts+=("gradle=$(grep -E '^distributionUrl=' "$wrapper" | sed -E 's/.*gradle-([0-9][^-]*)-.*/\1/')")
  fi

  # MC / loader / 映射版本：凡是 gradle.properties 里带 version 且跟 MC 生态相关的键
  local props="$project/gradle.properties"
  if [[ -f "$props" ]]; then
    local vers
    # ⚠️ 必须排除 *_version_range：那是 neoforge.mods.toml 里的**兼容性声明**（例如 [1.21.1,1.21.2)），
    #    跟 NeoForm/Gradle 产物毫无关系。带上它会把"本可共用同一个预热包"的项目硬拆成两个包
    #    —— 实测：Arsenal_Graft 与 女仆变大 只差一个 loader_version_range，竟算出不同指纹。
    #    取舍：指纹宁窄勿宽（喂错产物会引发莫名编译错误），但"声明性元数据"不该参与鉴别。
    vers="$(grep -E '^[A-Za-z0-9_.]*(minecraft|neo|forge|loader|fabric|parchment|mappings|mc)[A-Za-z0-9_.]*=' "$props" 2>/dev/null \
      | grep -vE '_version_range=' | grep -vE '^[A-Za-z0-9_.]*(mod|pack)_version=' | sort || true)"
    [[ -n "$vers" ]] && parts+=("$vers")
  fi

  # JDK 大版本（NeoForm 产物与 JVM 版本相关）
  local java_bin="${JAVA_HOME:-}/bin/java"
  [[ -x "$java_bin" ]] || java_bin="$(command -v java || true)"
  if [[ -n "$java_bin" && -x "$java_bin" ]]; then
    parts+=("jdk=$("$java_bin" -version 2>&1 | head -1 | sed -E 's/.*version "([0-9]+).*/\1/')")
  fi

  printf '%s\n' "${parts[@]}" | sha256sum | cut -c1-12
}

list_dirs() {
  local home="${1:-}"
  for d in "${SHARED_DIRS[@]}"; do echo "$d"; done
  if [[ -n "$home" && -d "$home/caches" ]]; then
    for d in "$home"/caches/[0-9]*; do
      [[ -d "$d" ]] && echo "caches/$(basename "$d")"
    done
  fi
}

pack() {
  local home="$1" out="$2" project="${3:-.}"
  [[ -d "$home" ]] || die "GRADLE_USER_HOME 不存在：$home"
  command -v zstd >/dev/null || die "需要 zstd（apt install zstd）"

  local present=()
  while IFS= read -r d; do
    [[ -n "$d" && -e "$home/$d" ]] && present+=("$d")
  done < <(list_dirs "$home")
  [[ ${#present[@]} -gt 0 ]] || die "没有可打包的目录（$home 是空的？）"

  mkdir -p "$(dirname "$out")"
  local t0 t1 raw
  t0=$(date +%s)
  raw=$(du -sc "${present[@]/#/$home/}" 2>/dev/null | tail -1 | cut -f1)
  echo "warmpack: 打包 ${#present[@]} 个目录（原始 $(numfmt --to=iec "${raw}K" 2>/dev/null || echo "${raw}K")）→ $out" >&2
  printf '%s\n' "${present[@]}" > "${out}.manifest"
  echo "fingerprint=$(fingerprint "$project")" >> "${out}.manifest"
  echo "created=$(date -Iseconds)" >> "${out}.manifest"

  tar -C "$home" -cf - "${EXCLUDE_ARGS[@]}" "${present[@]}" \
    | zstd -T0 -"$ZSTD_LEVEL" -q -o "$out" -f
  t1=$(date +%s)
  echo "warmpack: 完成，$(du -h "$out" | cut -f1)，耗时 $((t1 - t0))s" >&2
}

restore() {
  local archive="$1" home="$2"
  [[ -f "$archive" ]] || die "预热包不存在：$archive"
  command -v zstd >/dev/null || die "需要 zstd"
  mkdir -p "$home"
  local t0 t1
  t0=$(date +%s)
  zstd -dc "$archive" | tar -C "$home" -xf -
  t1=$(date +%s)
  echo "warmpack: 还原完成 → $home（$((t1 - t0))s，$(du -sh "$home" 2>/dev/null | cut -f1)）" >&2
}

case "${1:-}" in
  fingerprint) fingerprint "${2:-.}" ;;
  list-dirs)   list_dirs "${2:-}" ;;
  pack)        [[ $# -ge 3 ]] || die "用法: warmpack.sh pack <gradle-home> <out.tar.zst> [project-dir]"; pack "$2" "$3" "${4:-.}" ;;
  restore)     [[ $# -ge 3 ]] || die "用法: warmpack.sh restore <in.tar.zst> <gradle-home>"; restore "$2" "$3" ;;
  *)           sed -n '2,30p' "$0"; exit 2 ;;
esac
