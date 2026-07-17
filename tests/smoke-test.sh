#!/usr/bin/env bash
set -euo pipefail

URL="${1:-http://127.0.0.1:8088/api/static/test}"
NGINX_ERR_LOG="${2:-/usr/local/nginx/logs/error.log}"

echo "Diagnostic helper: this script samples one request and recent rn: log lines."
echo "It is not a required pass/fail test; use integration-tests/public.sh for the"
echo "public readiness gate."
echo

if [[ ! -f "$NGINX_ERR_LOG" ]]; then
  echo "nginx error log not found: $NGINX_ERR_LOG"
  exit 1
fi

echo "Requesting: $URL"
code=$(curl -s -o /dev/null -w "%{http_code}" "$URL")

echo "HTTP status: $code"

echo "Recent rn: log lines:"
tail -n 200 "$NGINX_ERR_LOG" | rg "rn:" || true
