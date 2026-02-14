#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./start-nginx.sh [--dynamic] [--clean] [--debug] [--nginx-src=PATH] [--conf=PATH] [--prefix=PATH]

Builds rclient, builds nginx with the rn module, then runs nginx in the foreground
with error_log set to stderr.

Notes:
- For dynamic module builds, ensure your config loads the module with an absolute path
  (e.g. /path/to/nginx/objs/ngx_http_rn_module.so).
EOF
}

RN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGX_SRC="${NGX_SRC:-$RN_DIR/upstream-nginx}"
CONF="${CONF:-$RN_DIR/tests/nginx.conf}"
PREFIX="${NGINX_PREFIX:-$RN_DIR/.nginx}"

BUILD_ARGS=()

for arg in "$@"; do
  case "$arg" in
  --dynamic|--clean|--debug)
      BUILD_ARGS+=("$arg")
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

if [[ ! -d "$NGX_SRC" ]]; then
  echo "nginx source not found: $NGX_SRC"
  exit 1
fi

if [[ ! -f "$CONF" ]]; then
  echo "config not found: $CONF"
  exit 1
fi

make -C "$RN_DIR/upstream-rl/clients/c"
"$RN_DIR/tests/build-nginx.sh" "$NGX_SRC" "${BUILD_ARGS[@]}"

NGINX_BIN="$NGX_SRC/objs/nginx"
if [[ ! -x "$NGINX_BIN" ]]; then
  echo "nginx binary not executable: $NGINX_BIN"
  exit 1
fi

mkdir -p "$PREFIX/logs"

export LD_LIBRARY_PATH="$RN_DIR/upstream-rl/clients/c${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

exec "$NGINX_BIN" \
  -p "$PREFIX" \
  -c "$CONF" \
  -g "daemon off; error_log /dev/stderr debug;"
