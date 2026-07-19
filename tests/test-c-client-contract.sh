#!/usr/bin/env bash
set -euo pipefail

RN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RCLIENT_DIR="$("${RN_ROOT}/tools/resolve-rl-c-client.sh")"
TEST_BIN="$(mktemp "${TMPDIR:-/tmp}/rn-c-client-contract.XXXXXX")"
trap 'rm -f "${TEST_BIN}"' EXIT

make -C "${RCLIENT_DIR}" librclient.a tools/r_test_responder_protocol.o

read -r -a extra_cflags <<<"${CFLAGS:-}"
read -r -a extra_ldflags <<<"${LDFLAGS:-}"
"${CC:-cc}" \
  -std=c11 -Wall -Wextra -Werror \
  "${extra_cflags[@]}" \
  -I"${RCLIENT_DIR}/include" \
  -I"${RCLIENT_DIR}/tools" \
  "${RN_ROOT}/tests/test-c-client-contract.c" \
  "${RCLIENT_DIR}/tools/r_test_responder_protocol.o" \
  "${RCLIENT_DIR}/librclient.a" \
  "${extra_ldflags[@]}" \
  -lcrypto -lresolv -pthread \
  -o "${TEST_BIN}"
"${TEST_BIN}"
