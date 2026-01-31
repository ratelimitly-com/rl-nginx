#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 /path/to/nginx-bin [nginx.conf]"
  exit 1
fi

NGINX_BIN="$1"
CONF="${2:-/home/wojtek/glar/rn/tests/nginx.conf}"

if [[ ! -x "$NGINX_BIN" ]]; then
  echo "nginx binary not executable: $NGINX_BIN"
  exit 1
fi

if [[ ! -f "$CONF" ]]; then
  echo "config not found: $CONF"
  exit 1
fi

"$NGINX_BIN" -c "$CONF"
