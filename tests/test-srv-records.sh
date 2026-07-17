#!/usr/bin/env bash
set -euo pipefail

RN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RCLIENT_DIR="$("${RN_ROOT}/tools/resolve-rl-c-client.sh")"
TEST_BIN="$(mktemp "${TMPDIR:-/tmp}/rn-srv-records.XXXXXX")"
trap 'rm -f "${TEST_BIN}"' EXIT

if [[ ! -d "${RCLIENT_DIR}/include" ]]; then
  echo "rl-c-client headers not found: ${RCLIENT_DIR}/include" >&2
  exit 1
fi

read -r -a extra_cflags <<<"${CFLAGS:-}"
read -r -a extra_ldflags <<<"${LDFLAGS:-}"
"${CC:-cc}" \
  -std=c11 -Wall -Wextra -Werror \
  "${extra_cflags[@]}" \
  -I"${RN_ROOT}/src" \
  -I"${RCLIENT_DIR}/include" \
  "${RN_ROOT}/src/rn_srv_records.c" \
  "${RN_ROOT}/tests/test-srv-records.c" \
  "${extra_ldflags[@]}" \
  -o "${TEST_BIN}"
"${TEST_BIN}"
