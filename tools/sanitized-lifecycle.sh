#!/usr/bin/env bash
set -Eeuo pipefail

RN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NGINX_SRC="${NGINX_SRC:-${RN_ROOT}/upstream-nginx}"
RCLIENT_DIR="${RCLIENT_DIR:-${RN_ROOT}/_deps/rl-c-client}"
SANITIZER_RUNS="${SANITIZER_RUNS:-3}"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-${RN_ROOT}/integration-tests/artifacts/lifecycle-sanitized}"
SANITIZER_CFLAGS="-O1 -g -Wall -Wextra -std=c11 -fsanitize=address,undefined -fno-omit-frame-pointer"
SANITIZER_LDFLAGS="-fsanitize=address,undefined"
RCLIENT_REBUILT=0

usage() {
  cat <<EOF
Usage: tools/sanitized-lifecycle.sh

Builds the locked rl-c-client, public responder, nginx, and rl-nginx with
AddressSanitizer and UndefinedBehaviorSanitizer, then runs every lifecycle
case repeatedly. The ordinary C-client build is restored before exit.

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

if [[ ! -d "${RCLIENT_DIR}" ]]; then
  if [[ "${RCLIENT_DIR}" != "${RN_ROOT}/_deps/rl-c-client" ]]; then
    echo "C-client checkout not found: ${RCLIENT_DIR}" >&2
    exit 1
  fi
  "${RN_ROOT}/tools/fetch-rl-c-client.sh"
fi

echo "[sanitizers] building rl-c-client and responder"
make -C "${RCLIENT_DIR}" clean
RCLIENT_REBUILT=1
make -C "${RCLIENT_DIR}" \
  CFLAGS="${SANITIZER_CFLAGS}" \
  LDFLAGS="${SANITIZER_LDFLAGS}" \
  all test-responder

echo "[sanitizers] building nginx and rl-nginx"
RCLIENT_DIR="${RCLIENT_DIR}" \
  "${RN_ROOT}/tools/build-nginx.sh" "${NGINX_SRC}" \
  --clean --debug --sanitize --skip-rclient-build

export ASAN_OPTIONS="${ASAN_OPTIONS:-abort_on_error=1:detect_leaks=0:strict_string_checks=1}"
export UBSAN_OPTIONS="${UBSAN_OPTIONS:-halt_on_error=1:print_stacktrace=1}"

for (( run = 1; run <= SANITIZER_RUNS; run++ )); do
  run_artifacts="${ARTIFACT_ROOT}/run-${run}"
  echo "[sanitizers] lifecycle run ${run}/${SANITIZER_RUNS}"
  RCLIENT_DIR="${RCLIENT_DIR}" \
    ARTIFACT_ROOT="${run_artifacts}" \
    SKIP_BUILD=1 \
    "${RN_ROOT}/integration-tests/lifecycle-regressions.sh" all

  if grep -R -E \
      'ERROR: AddressSanitizer|SUMMARY: AddressSanitizer|runtime error:' \
      "${run_artifacts}"; then
    echo "[sanitizers] sanitizer report found in run ${run}" >&2
    exit 1
  fi
done

echo "[sanitizers] ${SANITIZER_RUNS} complete lifecycle run(s) passed"
echo "[sanitizers] artifacts: ${ARTIFACT_ROOT}"
