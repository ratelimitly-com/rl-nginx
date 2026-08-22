#!/usr/bin/env bash
set -euo pipefail

RN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_BIN="$(mktemp "${TMPDIR:-/tmp}/rn-resolv-conf.XXXXXX")"
trap 'rm -f "${TEST_BIN}"' EXIT

read -r -a extra_cflags <<<"${CFLAGS:-}"
read -r -a extra_ldflags <<<"${LDFLAGS:-}"
"${CC:-cc}" \
  -std=c11 -Wall -Wextra -Werror \
  "${extra_cflags[@]}" \
  -I"${RN_ROOT}/src" \
  "${RN_ROOT}/src/rn_resolv_conf.c" \
  "${RN_ROOT}/tests/test-resolv-conf.c" \
  "${extra_ldflags[@]}" \
  -o "${TEST_BIN}"
"${TEST_BIN}"
