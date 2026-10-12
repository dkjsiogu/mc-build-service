#!/usr/bin/env bash
# lib/java.sh —— 挑一个能跑 Gradle 的 JDK（被 bench.sh / selftest.sh 共用）
# =====================================================================================
# 为什么要有这东西：本机 java 常常不在 PATH 里（只有 /usr/lib/jvm 下几个 JDK），
# 于是「忘了 export JAVA_HOME」会被误读成"黑盒子坏了"——自检脚本自己得先把这事办了。
#
# 优先级：HUB_JAVA_HOME / BENCH_JAVA_HOME / SELFTEST_JAVA_HOME > 已设的 JAVA_HOME
#        > PATH 里的 java > /usr/lib/jvm 下 21/17/25 优先的扫描结果
# Gradle 9.x 要求 JDK 17+，所以扫描时优先 21。
hub_pick_java_home() {
  local cand="${HUB_JAVA_HOME:-${BENCH_JAVA_HOME:-${SELFTEST_JAVA_HOME:-}}}"

  if [[ -z "$cand" && -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/java" ]]; then
    cand="$JAVA_HOME"
  fi

  if [[ -z "$cand" ]] && command -v java >/dev/null 2>&1; then
    cand="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
  fi

  if [[ -z "$cand" ]]; then
    local pat d
    for pat in '*21*' '*17*' '*25*' '*'; do
      for d in /usr/lib/jvm/$pat; do
        if [[ -x "$d/bin/java" ]]; then cand="$d"; break 2; fi
      done
    done
  fi

  if [[ -z "$cand" || ! -x "$cand/bin/java" ]]; then
    echo "[java] 找不到可用 JDK：请设置 HUB_JAVA_HOME=/path/to/jdk" >&2
    return 1
  fi

  export JAVA_HOME="$cand"
  # 让 PATH 里也有 java：有些构建脚本会直接调 java/javac，而不是走 JAVA_HOME
  case ":$PATH:" in
    *":$JAVA_HOME/bin:"*) ;;
    *) export PATH="$JAVA_HOME/bin:$PATH" ;;
  esac
  return 0
}
