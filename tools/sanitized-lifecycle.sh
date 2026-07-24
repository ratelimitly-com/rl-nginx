#!/usr/bin/env bash
set -Eeuo pipefail

RN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${RN_ROOT}/tools/sanitizer-flags.env"
NGINX_SRC="${NGINX_SRC:-${RN_ROOT}/upstream-nginx}"
SANITIZER_RUNS="${SANITIZER_RUNS:-3}"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-${RN_ROOT}/integration-tests/artifacts/lifecycle-sanitized}"
PROBE_ARTIFACTS="${ARTIFACT_ROOT}/standalone-probes"
PROBE_LOG="${PROBE_ARTIFACTS}/sanitizer.log"
SANITIZER_CFLAGS="${RN_SANITIZER_COMPILE_FLAGS} ${RN_SANITIZER_PROBE_FLAGS}"
SANITIZER_LDFLAGS="${RN_SANITIZER_LINK_FLAGS}"
RCLIENT_REBUILT=0

usage() {
  cat <<EOF
Usage: tools/sanitized-lifecycle.sh

Builds the locked rl-c-client, public responder, nginx, and rl-nginx with
AddressSanitizer and UndefinedBehaviorSanitizer, then runs every lifecycle,
final-admission, enforcement-boundary, outage-policy, DNS-policy,
guard/latency, and malformed-protocol/response-cardinality case repeatedly.
The ordinary C-client build is restored before exit.

Environment overrides:
  RCLIENT_DIR          locked C-client checkout (default: ./_deps/rl-c-client)
  NGINX_SRC            nginx source tree (default: ./upstream-nginx)
  SANITIZER_RUNS       number of complete lifecycle runs (default: 3)
  ARTIFACT_ROOT        test artifact directory
  KEEP_SANITIZED_BUILD keep sanitized C-client artifacts when set to 1
  ASAN_OPTIONS         sanitizer runtime options
  UBSAN_OPTIONS        sanitizer runtime options
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if (( $# != 0 )); then
  usage >&2
  exit 2
fi
if ! [[ "${SANITIZER_RUNS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "SANITIZER_RUNS must be a positive integer" >&2
  exit 2
fi

RCLIENT_DIR="$("${RN_ROOT}/tools/resolve-rl-c-client.sh")"

restore_rclient() {
  local status=$?

  trap - EXIT
  if (( RCLIENT_REBUILT )) && [[ "${KEEP_SANITIZED_BUILD:-0}" != "1" ]]; then
    echo "[sanitizers] restoring the ordinary rl-c-client build"
    if ! make -C "${RCLIENT_DIR}" clean \
        || ! make -C "${RCLIENT_DIR}" \
        || ! make -C "${RCLIENT_DIR}" test-responder; then
      echo "[sanitizers] failed to restore rl-c-client build artifacts" >&2
      if (( status == 0 )); then
        status=1
      fi
    fi
  fi
  exit "${status}"
}
trap restore_rclient EXIT

run_sanitized_probe() {
  "$@" 2>&1 | tee -a "${PROBE_LOG}"
}

export ASAN_OPTIONS="${ASAN_OPTIONS:-abort_on_error=1:detect_leaks=1:strict_string_checks=1}"
# Keep UBSan recoverable so the exact report scanner, rather than process exit
# timing, decides which diagnostics are accepted. Every report outside the
# reviewed upstream-nginx signatures still fails the gate.
export UBSAN_OPTIONS="${UBSAN_OPTIONS:-halt_on_error=0:print_stacktrace=1}"
# nginx -t and nginx -s control commands exit without tearing down the
# configuration-cycle pools they initialized. Suppress leak detection only for
# those short-lived subprocesses; the runtime master, workers, and standalone
# probes retain detect_leaks=1.
export RN_NGINX_ONESHOT_ASAN_OPTIONS="${ASAN_OPTIONS}:detect_leaks=0"

echo "[sanitizers] building rl-c-client and responder"
make -C "${RCLIENT_DIR}" clean
RCLIENT_REBUILT=1
make -C "${RCLIENT_DIR}" \
  CFLAGS="${SANITIZER_CFLAGS}" \
  LDFLAGS="${SANITIZER_LDFLAGS}" \
  all test-responder
mkdir -p "${PROBE_ARTIFACTS}"
: >"${PROBE_LOG}"
run_sanitized_probe env \
  CFLAGS="${SANITIZER_CFLAGS}" \
  LDFLAGS="${SANITIZER_LDFLAGS}" \
  RCLIENT_DIR="${RCLIENT_DIR}" \
  "${RN_ROOT}/tests/test-c-client-contract.sh"
run_sanitized_probe env \
  CFLAGS="${SANITIZER_CFLAGS}" \
  LDFLAGS="${SANITIZER_LDFLAGS}" \
  "${RN_ROOT}/tests/test-numeric.sh"
run_sanitized_probe env \
  CFLAGS="${SANITIZER_CFLAGS}" \
  LDFLAGS="${SANITIZER_LDFLAGS}" \
  RCLIENT_DIR="${RCLIENT_DIR}" \
  "${RN_ROOT}/tests/test-srv-records.sh"
if ! "${RN_ROOT}/tools/check-sanitizer-reports.sh" "${PROBE_ARTIFACTS}"; then
  echo "[sanitizers] sanitizer report found in standalone probes" >&2
  exit 1
fi

echo "[sanitizers] building nginx and rl-nginx"
RN_TEST_FAULT_INJECTION=1 \
RCLIENT_DIR="${RCLIENT_DIR}" \
  "${RN_ROOT}/tools/build-nginx.sh" "${NGINX_SRC}" \
  --clean --debug --sanitize --skip-rclient-build

for (( run = 1; run <= SANITIZER_RUNS; run++ )); do
  run_artifacts="${ARTIFACT_ROOT}/run-${run}"
  echo "[sanitizers] lifecycle run ${run}/${SANITIZER_RUNS}"
  RCLIENT_DIR="${RCLIENT_DIR}" \
    ARTIFACT_ROOT="${run_artifacts}" \
    SKIP_BUILD=1 \
    "${RN_ROOT}/integration-tests/lifecycle-regressions.sh" all
  RCLIENT_DIR="${RCLIENT_DIR}" \
    ARTIFACT_ROOT="${run_artifacts}" \
    SKIP_BUILD=1 \
    "${RN_ROOT}/integration-tests/lifecycle-regressions.sh" fault-injection

  if ! "${RN_ROOT}/tools/check-sanitizer-reports.sh" "${run_artifacts}"; then
    echo "[sanitizers] sanitizer report found in run ${run}" >&2
    exit 1
  fi
done

echo "[sanitizers] ${SANITIZER_RUNS} complete public lifecycle and fault-injection run(s) passed"
echo "[sanitizers] artifacts: ${ARTIFACT_ROOT}"
