#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../integration-tests/lifecycle-oracles.sh
source "${RN_ROOT}/integration-tests/lifecycle-oracles.sh"

fail() {
  echo "FAIL lifecycle oracle: $*" >&2
  exit 1
}

rn_expect_http_status 429 429 \
  || fail "exact status matcher rejected the expected fail-close response"
if rn_expect_http_status 200 429; then
  fail "exact status matcher accepted fail-open as fail-close"
fi
if rn_expect_http_status 000 429; then
  fail "exact status matcher accepted a transport failure"
fi

log_fixture="$(mktemp)"
trap 'rm -f "${log_fixture}"' EXIT
printf 'rn: result error status=-2\n' >"${log_fixture}"
rn_expect_log_count "${log_fixture}" 'rn: result error status=-2' 1 \
  || fail "completion-count oracle rejected exactly one callback"
if rn_expect_log_count "${log_fixture}" 'rn: result error status=-2' 0; then
  fail "completion-count oracle accepted a timeout callback after abort"
fi
printf 'rn: result error status=-2\n' >>"${log_fixture}"
if rn_expect_log_count "${log_fixture}" 'rn: result error status=-2' 1; then
  fail "completion-count oracle accepted a duplicate callback"
fi

bash -c 'trap "" TERM; while :; do read -r -t 1 _ || true; done' &
stubborn_pid=$!
sleep 0.05
set +e
rn_terminate_pid "${stubborn_pid}" "stubborn fixture" 2 0.01 >/dev/null 2>&1
termination_status=$?
set -e
if [[ "${termination_status}" != "1" ]]; then
  fail "forced termination returned ${termination_status}, expected 1"
fi
if kill -0 "${stubborn_pid}" 2>/dev/null; then
  fail "forced termination left the fixture alive"
fi

expected_groups=$'timeout\naborted-client\nsteering-rebind\nworker-resolver-scope\nadmission-contract\nenforcement-boundary\noutage-policy\ndns-policy\nguard-latency\nprotocol-policy\ncardinality'
actual_groups="$("${RN_ROOT}/integration-tests/lifecycle-regressions.sh" list-all)"
if [[ "${actual_groups}" != "${expected_groups}" ]]; then
  fail "all-mode manifest does not cover the complete public lifecycle matrix"
fi

echo "PASS lifecycle oracles reject wrong status/counts, forced shutdown, and incomplete all-mode coverage"
