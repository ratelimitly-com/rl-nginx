#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./start-nginx.sh [--dynamic] [--clean] [--no-debug] [--nginx-src=PATH] [--conf=PATH] [--prefix=PATH]

Builds rclient, builds nginx with the rn module, then runs nginx in the foreground
with error_log sent to both stderr and logs/error.log.

By default nginx is built with debug support (`--with-debug`).
Use `--no-debug` to disable it.

Notes:
- For dynamic module builds, ensure your config loads the module with an absolute path
  (e.g. /path/to/nginx/objs/ngx_http_rn_module.so).
EOF
}

RN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGX_SRC="${NGX_SRC:-$RN_DIR/upstream-nginx}"
CONF="${CONF:-$RN_DIR/tests/nginx.conf}"
PREFIX="${NGINX_PREFIX:-$RN_DIR}"

detect_rclient_dir() {
  if [[ -n "${RCLIENT_DIR:-}" ]]; then
    echo "$RCLIENT_DIR"
    return 0
  fi
  if [[ -d "$RN_DIR/rl-c-client" ]]; then
    echo "$RN_DIR/rl-c-client"
    return 0
  fi
  if [[ -d "$RN_DIR/upstream-rl/clients/c" ]]; then
    echo "$RN_DIR/upstream-rl/clients/c"
    return 0
  fi
  return 1
}

BUILD_ARGS=()
DEBUG_BUILD=1

for arg in "$@"; do
  case "$arg" in
  --dynamic|--clean)
      BUILD_ARGS+=("$arg")
      ;;
    --debug)
      DEBUG_BUILD=1
      ;;
    --no-debug)
      DEBUG_BUILD=0
      ;;
    --nginx-src=*)
      NGX_SRC="${arg#*=}"
      ;;
    --conf=*)
      CONF="${arg#*=}"
      ;;
    --prefix=*)
      PREFIX="${arg#*=}"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg"
      usage
      exit 1
      ;;
  esac
done

if (( DEBUG_BUILD )); then
  BUILD_ARGS+=("--debug")
fi

if [[ ! -d "$NGX_SRC" ]]; then
  echo "nginx source not found: $NGX_SRC"
  exit 1
fi

if [[ ! -f "$CONF" ]]; then
  echo "config not found: $CONF"
  exit 1
fi

RCLIENT_DIR="$(detect_rclient_dir || true)"
if [[ -z "$RCLIENT_DIR" ]]; then
  echo "C r-client not found."
  echo "Set RCLIENT_DIR or provide one of:"
  echo "  - $RN_DIR/rl-c-client"
  echo "  - $RN_DIR/upstream-rl/clients/c"
  exit 1
fi

make -C "$RCLIENT_DIR"
"$RN_DIR/tests/build-nginx.sh" "$NGX_SRC" "${BUILD_ARGS[@]}"

NGINX_BIN="$NGX_SRC/objs/nginx"
if [[ ! -x "$NGINX_BIN" ]]; then
  echo "nginx binary not executable: $NGINX_BIN"
  exit 1
fi

mkdir -p "$PREFIX/logs"

export LD_LIBRARY_PATH="$RCLIENT_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

exec "$NGINX_BIN" \
  -p "$PREFIX" \
  -c "$CONF" \
  -e /dev/stderr \
  -g "daemon off; error_log stderr debug; error_log logs/error.log debug;"
