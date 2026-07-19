#!/usr/bin/env bash
set -euo pipefail

RN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RCLIENT_DIR="$("${RN_ROOT}/tools/resolve-rl-c-client.sh")"
TEST_BIN="$(mktemp "${TMPDIR:-/tmp}/rn-addr-records.XXXXXX")"
trap 'rm -f "${TEST_BIN}"' EXIT

read -r -a extra_cflags <<<"${CFLAGS:-}"
read -r -a extra_ldflags <<<"${LDFLAGS:-}"
"${CC:-cc}" \
  -std=c11 -Wall -Wextra -Werror \
  "${extra_cflags[@]}" \
  -I"${RN_ROOT}/src" \
  -I"${RCLIENT_DIR}/include" \
  "${RN_ROOT}/src/rn_addr_records.c" \
  "${RN_ROOT}/tests/test-addr-records.c" \
  "${extra_ldflags[@]}" \
  -o "${TEST_BIN}"
"${TEST_BIN}"
