#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
NGINX_SRC="${NGINX_SRC:-${RN_ROOT}/upstream-nginx}"
NGINX_BIN="${NGINX_BIN:-${NGINX_SRC}/objs/nginx}"
NGINX_MODULE="${NGINX_MODULE:-${NGINX_SRC}/objs/ngx_http_rn_module.so}"
KEEP_RELOCATION_RUNTIME="${KEEP_RELOCATION_RUNTIME:-0}"

usage() {
  cat <<'EOF'
Usage: integration-tests/dynamic-module-relocation.sh

Validates a previously configured and built dynamic rl-nginx module by:
  - building the matching nginx binary from the same configured source tree;
  - copying the binary and module into an isolated runtime tree;
  - rejecting RPATH/RUNPATH and a shared librclient dependency;
  - running nginx -t, final-admission ordering, deterministic resolver scope,
    and deterministic enforcement through the relocated module without
    LD_LIBRARY_PATH.

Environment overrides:
  RCLIENT_DIR             C-client checkout (default: locked ./_deps checkout)
  NGINX_SRC               configured nginx source tree (default: ./upstream-nginx)
  NGINX_BIN               matching nginx binary path (default: $NGINX_SRC/objs/nginx)
  NGINX_MODULE            built module path (default: $NGINX_SRC/objs/ngx_http_rn_module.so)
  KEEP_RELOCATION_RUNTIME retain the isolated runtime after success (0 or 1)
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
case "${KEEP_RELOCATION_RUNTIME}" in
  0|1) ;;
  *)
    echo "KEEP_RELOCATION_RUNTIME must be 0 or 1" >&2
    exit 2
    ;;
esac

RCLIENT_DIR="$("${RN_ROOT}/tools/resolve-rl-c-client.sh")"

fail() {
  echo "FAIL dynamic module relocation: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

for command in env grep install ldd make mktemp readelf; do
  need_cmd "${command}"
done

[[ -f "${NGINX_SRC}/objs/Makefile" ]] \
  || fail "nginx is not configured: ${NGINX_SRC}/objs/Makefile"
[[ -f "${NGINX_MODULE}" ]] || fail "dynamic module not found: ${NGINX_MODULE}"

echo "[dynamic-relocation] building matching nginx binary and test responder"
make -C "${NGINX_SRC}" -j
make -C "${RCLIENT_DIR}" test-responder
[[ -x "${NGINX_BIN}" ]] || fail "nginx binary not found: ${NGINX_BIN}"

RUNTIME_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rl-nginx-relocation.XXXXXX")"
cleanup() {
  local status=$?

  trap - EXIT
  if (( status != 0 )) || [[ "${KEEP_RELOCATION_RUNTIME}" == "1" ]]; then
    echo "[dynamic-relocation] retained runtime: ${RUNTIME_ROOT}" >&2
  else
    rm -rf -- "${RUNTIME_ROOT}"
  fi
  exit "${status}"
}
trap cleanup EXIT

mkdir -p "${RUNTIME_ROOT}/sbin" "${RUNTIME_ROOT}/modules"
install -m 0755 "${NGINX_BIN}" "${RUNTIME_ROOT}/sbin/nginx"
install -m 0755 "${NGINX_MODULE}" \
  "${RUNTIME_ROOT}/modules/ngx_http_rn_module.so"

RUNTIME_NGINX="${RUNTIME_ROOT}/sbin/nginx"
RUNTIME_MODULE="${RUNTIME_ROOT}/modules/ngx_http_rn_module.so"

echo "[dynamic-relocation] inspecting relocated module"
READELF_OUTPUT="$(readelf -d "${RUNTIME_MODULE}")" \
  || fail "readelf could not inspect ${RUNTIME_MODULE}"
printf '%s\n' "${READELF_OUTPUT}"
if grep -Eq '\((RPATH|RUNPATH)\)' <<<"${READELF_OUTPUT}"; then
  fail "relocated module contains RPATH or RUNPATH"
fi
if grep -Fq 'librclient.so' <<<"${READELF_OUTPUT}"; then
  fail "relocated module requires librclient.so"
fi

LDD_OUTPUT="$(ldd "${RUNTIME_MODULE}")" \
  || fail "ldd could not inspect ${RUNTIME_MODULE}"
printf '%s\n' "${LDD_OUTPUT}"
if grep -Fq 'librclient.so' <<<"${LDD_OUTPUT}"; then
  fail "ldd reports a librclient.so dependency"
fi
if grep -Fq 'not found' <<<"${LDD_OUTPUT}"; then
  fail "ldd reports an unresolved shared library"
fi

echo "[dynamic-relocation] running final-admission ordering"
env -u LD_LIBRARY_PATH \
  RCLIENT_DIR="${RCLIENT_DIR}" \
  NGINX_SRC="${NGINX_SRC}" \
  NGINX_BIN="${RUNTIME_NGINX}" \
  NGINX_LOAD_MODULE="${RUNTIME_MODULE}" \
  ARTIFACT_ROOT="${RUNTIME_ROOT}/artifacts" \
  SKIP_BUILD=1 \
  "${SCRIPT_DIR}/lifecycle-regressions.sh" admission-contract

echo "[dynamic-relocation] running deterministic resolver selection"
env -u LD_LIBRARY_PATH \
  RCLIENT_DIR="${RCLIENT_DIR}" \
  NGINX_SRC="${NGINX_SRC}" \
  NGINX_BIN="${RUNTIME_NGINX}" \
  NGINX_LOAD_MODULE="${RUNTIME_MODULE}" \
  ARTIFACT_ROOT="${RUNTIME_ROOT}/artifacts" \
  SKIP_BUILD=1 \
  "${SCRIPT_DIR}/lifecycle-regressions.sh" worker-resolver-scope

echo "[dynamic-relocation] running deterministic enforcement"
env -u LD_LIBRARY_PATH \
  RCLIENT_DIR="${RCLIENT_DIR}" \
  NGINX_SRC="${NGINX_SRC}" \
  NGINX_BIN="${RUNTIME_NGINX}" \
  NGINX_LOAD_MODULE="${RUNTIME_MODULE}" \
  ARTIFACT_ROOT="${RUNTIME_ROOT}/artifacts" \
  SKIP_BUILD=1 \
  "${SCRIPT_DIR}/lifecycle-regressions.sh" enforcement-boundary

echo "PASS dynamic module relocation"
