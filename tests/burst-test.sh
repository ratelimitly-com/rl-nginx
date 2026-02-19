#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_ERR_LOG="$RN_DIR/logs/error.log"
if [[ ! -f "$DEFAULT_ERR_LOG" ]]; then
  DEFAULT_ERR_LOG="/usr/local/nginx/logs/error.log"
fi

usage() {
  cat <<'EOF'
Usage:
  burst-test.sh [BASE_URL] [BURST_SIZE] [PARALLELISM] [NGINX_ERR_LOG]
  burst-test.sh -h|--help

What it does:
  Sends burst traffic to the configured ratelimitly nginx test endpoints and
  summarizes HTTP codes and, when nginx error log is available, rn decision lines.

Arguments:
  BASE_URL     Target nginx base URL (default: http://127.0.0.1:8088)
  BURST_SIZE   Requests per scenario burst (default: 1000)
  PARALLELISM  Concurrent curl workers via xargs -P (default: 50)
  NGINX_ERR_LOG  Nginx error log path (default: ../logs/error.log or /usr/local/nginx/logs/error.log)

Scenarios:
  1) /api/static/test
  2) /api/dynamic/test?user=alice
  3) /api/dynamic/test?user=wojtek
  4) /api/dynamic/test?user=wojtek with cookie session=s1
  5) /api/dynamic/test?user=wojtek with cookie session=s2
  6) /api/group/test?user=wojtek with cookie session=s1
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "${1:-}" == -* ]]; then
  echo "Unknown option: $1" >&2
  usage
  exit 1
fi

BASE_URL="${1:-http://127.0.0.1:8088}"
BURST_SIZE="${2:-1000}"
PARALLELISM="${3:-50}"
NGINX_ERR_LOG="${4:-$DEFAULT_ERR_LOG}"

run_burst() {
  local name="$1"
  local url="$2"
  local cookie="${3:-}"
  local tmp
  local err_tmp
  local ok
  local non_ok
  local code_429=0
  local code_000=0
  local err_before=0
  local err_after=0
  local timeout_status=0
  local any_error_status=0
  local rn_allow=0
  local rn_deny=0

  tmp="$(mktemp)"
  err_tmp="$(mktemp)"

  if [[ -f "$NGINX_ERR_LOG" ]]; then
    err_before="$(wc -l < "$NGINX_ERR_LOG")"
  fi

  seq "$BURST_SIZE" | xargs -P "$PARALLELISM" -I{} bash -c '
    url="$1"
    cookie="$2"
    if [[ -n "$cookie" ]]; then
      curl -s -o /dev/null -w "%{http_code}\n" --cookie "$cookie" "$url" || echo "000"
    else
      curl -s -o /dev/null -w "%{http_code}\n" "$url" || echo "000"
    fi
  ' _ "$url" "$cookie" > "$tmp"

  ok="$(grep -c "^200$" "$tmp" || true)"
  non_ok="$((BURST_SIZE - ok))"
  code_429="$(grep -c "^429$" "$tmp" || true)"
  code_000="$(grep -c "^000$" "$tmp" || true)"

  if [[ -f "$NGINX_ERR_LOG" ]]; then
    err_after="$(wc -l < "$NGINX_ERR_LOG")"
    if (( err_after > err_before )); then
      sed -n "$((err_before + 1)),$((err_after))p" "$NGINX_ERR_LOG" > "$err_tmp"
      timeout_status="$(grep -c "rn: result error status=-2" "$err_tmp" || true)"
      any_error_status="$(grep -c "rn: result error status=" "$err_tmp" || true)"
      rn_allow="$(grep -c "rn: result success=1" "$err_tmp" || true)"
      rn_deny="$(grep -c "rn: result success=0" "$err_tmp" || true)"
    fi

    printf "%-26s 200=%4d  non-200=%4d  429=%4d  000=%4d  rn_allow=%4d  rn_deny=%4d  timeout_status=%4d  error_status=%4d\n" \
      "$name" "$ok" "$non_ok" "$code_429" "$code_000" "$rn_allow" "$rn_deny" "$timeout_status" "$any_error_status"
  else
    printf "%-26s 200=%4d  non-200=%4d  429=%4d  000=%4d\n" \
      "$name" "$ok" "$non_ok" "$code_429" "$code_000"
  fi

  rm -f "$tmp"
  rm -f "$err_tmp"
}

echo "BASE_URL=$BASE_URL BURST_SIZE=$BURST_SIZE PARALLELISM=$PARALLELISM"
echo "HTTP summary includes explicit 429 and 000 counts."
if [[ -f "$NGINX_ERR_LOG" ]]; then
  echo "Using NGINX_ERR_LOG=$NGINX_ERR_LOG"
  echo "timeout_status counts 'rn: result error status=-2' in each burst window."
  echo "With ratelimitly_fail open + ratelimitly_debug on, timeout_status approximates fail-open timeouts."
else
  echo "NGINX_ERR_LOG not found at $NGINX_ERR_LOG (timeout/fail-open counters disabled)."
fi
echo

run_burst "static" "$BASE_URL/api/static/test"
run_burst "dynamic user=alice" "$BASE_URL/api/dynamic/test?user=alice"
run_burst "dynamic user=wojtek" "$BASE_URL/api/dynamic/test?user=wojtek"
run_burst "dynamic wojtek sess=s1" "$BASE_URL/api/dynamic/test?user=wojtek" "session=s1"
run_burst "dynamic wojtek sess=s2" "$BASE_URL/api/dynamic/test?user=wojtek" "session=s2"
run_burst "group wojtek sess=s1" "$BASE_URL/api/group/test?user=wojtek" "session=s1"
