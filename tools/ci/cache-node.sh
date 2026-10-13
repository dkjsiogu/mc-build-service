#!/usr/bin/env bash
# cache-node.sh —— CI 里的「R2/S3 直连代理」开关（start | stop | status | url）
# =====================================================================================
# 为什么需要它：
#   把 R2 包成 HTTP 缓存最干净的做法是部署 Cloudflare Worker，但那需要在 Cloudflare 侧
#   有 "Workers Scripts: Edit" 权限。没有那个权限时，可以在**作业内**起一个本地节点，
#   由它用 SigV4 转发到 R2 —— Gradle 依旧只跟 http://127.0.0.1 说 HTTP，
#   于是"零第三方 Gradle 依赖"这条设计纪律得以保持。
#
# 与 Worker 的关系：对象键布局完全一致（cache/… 与 pack/…）。
#   将来拿到 Worker 权限，只需把 MC_HUB_CACHE_URL 换成 Worker 地址，**缓存内容不用搬家**。
#
# 环境变量：
#   MC_HUB_S3_ENDPOINT / MC_HUB_S3_BUCKET / MC_HUB_S3_KEY_ID / MC_HUB_S3_SECRET  ← 必需
#   MC_HUB_CACHE_URL      已设置（例如已有 Worker）⇒ 本脚本什么都不做，优先用 Worker
#   MC_HUB_CACHE_USER/PASS 本地节点的 Basic 校验（随便设，但它必须与 Gradle 侧一致）
#   MC_HUB_CACHE_PORT     默认 8787
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HUB_ROOT="$(cd "$HERE/../.." && pwd)"
PORT="${MC_HUB_CACHE_PORT:-8787}"
PIDFILE="$PWD/hub-cache-node.pid"
LOGFILE="$PWD/hub-cache-node.log"

healthy() { curl -sf "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; }

set_env() {  # 把变量写给后续 step（GitHub Actions 的 $GITHUB_ENV）
  if [[ -n "${GITHUB_ENV:-}" ]]; then echo "$1" >>"$GITHUB_ENV"; else echo "（本地运行，未写 GITHUB_ENV）$1"; fi
}

case "${1:-}" in
  start)
    if [[ -n "${MC_HUB_CACHE_URL:-}" ]]; then
      echo "已有缓存地址（${MC_HUB_CACHE_URL}）⇒ 不启动本地代理"
      exit 0
    fi
    if [[ -z "${MC_HUB_S3_BUCKET:-}" || -z "${MC_HUB_S3_ENDPOINT:-}" ]]; then
      echo "未配置 MC_HUB_S3_*（也没有 Worker 地址）⇒ 本次只吃依赖层（L1），跳过远程构建缓存"
      exit 0
    fi
    if healthy; then echo "缓存节点已在运行"; else
      node "$HUB_ROOT/tools/local-cache-server.mjs" --port "$PORT" \
        --s3-endpoint "$MC_HUB_S3_ENDPOINT" --s3-bucket "$MC_HUB_S3_BUCKET" \
        --s3-key-id "$MC_HUB_S3_KEY_ID" --s3-secret "$MC_HUB_S3_SECRET" \
        --token "${MC_HUB_CACHE_USER:-hub}:${MC_HUB_CACHE_PASS:-}" \
        >"$LOGFILE" 2>&1 &
      echo $! >"$PIDFILE"
      for _ in $(seq 1 40); do healthy && break; sleep 0.25; done
    fi
    if healthy; then
      echo "缓存节点就绪：$(curl -s "http://127.0.0.1:$PORT/healthz" | head -c 200)"
      set_env "MC_HUB_CACHE_URL=http://127.0.0.1:$PORT/cache/"
    else
      echo "::warning::缓存节点启动失败（本次退化为只用依赖层）；日志见 $LOGFILE"
      head -20 "$LOGFILE" 2>/dev/null || true
    fi
    ;;

  stop)
    if [[ -f "$PIDFILE" ]]; then
      kill "$(cat "$PIDFILE")" 2>/dev/null || true
      rm -f "$PIDFILE"
      echo "缓存节点已停止"
    fi
    ;;

  status)
    if healthy; then curl -s "http://127.0.0.1:$PORT/stats"; else echo '{"running":false}'; fi
    ;;

  url)
    echo "http://127.0.0.1:$PORT/cache/"
    ;;

  *)
    sed -n '2,20p' "$0"
    exit 2
    ;;
esac
