#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  burst-test.sh [BASE_URL] [BURST_SIZE] [PARALLELISM]
  burst-test.sh -h|--help

What it does:
  Sends burst traffic to the configured ratelimitly nginx test endpoints and
  summarizes responses by counting only HTTP 200 codes (grep '^200$').

Arguments:
  BASE_URL     Target nginx base URL (default: http://127.0.0.1:8088)
  BURST_SIZE   Requests per scenario burst (default: 1000)
  PARALLELISM  Concurrent curl workers via xargs -P (default: 50)

Scenarios:
  1) /api/static/test
  2) /api/dynamic/test?user=alice
  3) /api/dynamic/test?user=wojtek
  4) /api/dynamic/test?user=wojtek with cookie session=s1
  5) /api/dynamic/test?user=wojtek with cookie session=s2
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

run_burst() {
  local name="$1"
  local url="$2"
  local cookie="${3:-}"
  local tmp
  local ok
  local non_ok

  tmp="$(mktemp)"

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

  printf "%-26s 200=%4d  non-200=%4d\n" "$name" "$ok" "$non_ok"
  rm -f "$tmp"
}

echo "BASE_URL=$BASE_URL BURST_SIZE=$BURST_SIZE PARALLELISM=$PARALLELISM"
echo "Only counting HTTP 200 with: grep '^200$'"
echo

run_burst "static" "$BASE_URL/api/static/test"
run_burst "dynamic user=alice" "$BASE_URL/api/dynamic/test?user=alice"
run_burst "dynamic user=wojtek" "$BASE_URL/api/dynamic/test?user=wojtek"
run_burst "dynamic wojtek sess=s1" "$BASE_URL/api/dynamic/test?user=wojtek" "session=s1"
run_burst "dynamic wojtek sess=s2" "$BASE_URL/api/dynamic/test?user=wojtek" "session=s2"
