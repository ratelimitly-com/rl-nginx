#!/usr/bin/env bash
set -euo pipefail

URL="${1:-http://127.0.0.1:8081/api/test}"
NGINX_ERR_LOG="${2:-/usr/local/nginx/logs/error.log}"

if [[ ! -f "$NGINX_ERR_LOG" ]]; then
  echo "nginx error log not found: $NGINX_ERR_LOG"
  exit 1
fi

echo "Requesting: $URL"
code=$(curl -s -o /dev/null -w "%{http_code}" "$URL")

echo "HTTP status: $code"

echo "Recent rn: log lines:"
tail -n 200 "$NGINX_ERR_LOG" | rg "rn:" || true
