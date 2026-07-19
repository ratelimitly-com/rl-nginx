#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
NGINX_SRC="${NGINX_SRC:-${RN_ROOT}/upstream-nginx}"
SKIP_BUILD="${SKIP_BUILD:-0}"

usage() {
  cat <<EOF
Usage: integration-tests/public.sh

Runs the required public rl-nginx integration suite using only:
  - the locked public rl-c-client responder;
  - the local DNS fixture;
  - the pinned nginx source; and
  - this module.

The suite covers DNS fixture fidelity, final pre-content admission ordering,
request lifecycle safety, steering rebind, and response-cardinality handling
under fail-open and fail-close.

Environment overrides:
  RCLIENT_DIR  C-client checkout (default: locked ./_deps checkout)
  NGINX_SRC    nginx source tree (default: ./upstream-nginx)
  NGINX_BIN    nginx binary (default: $NGINX_SRC/objs/nginx)
  SKIP_BUILD   reuse NGINX_BIN instead of rebuilding (0 or 1; default: 0)

The lower-level lifecycle runner also accepts its documented port and artifact
overrides. No RateLimitly server, tenant, credential, or private repository is
used.
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
case "${SKIP_BUILD}" in
  0|1) ;;
  *)
    echo "SKIP_BUILD must be 0 or 1" >&2
    exit 2
    ;;
esac

RCLIENT_DIR="$("${RN_ROOT}/tools/resolve-rl-c-client.sh")"
if [[ ! -f "${NGINX_SRC}/auto/configure" ]]; then
  echo "nginx source not initialized: ${NGINX_SRC}" >&2
  echo "Run: git submodule update --init upstream-nginx" >&2
  exit 1
fi

echo "[public-suite] testing the strict DNS fixture"
python3 "${SCRIPT_DIR}/test_local_dns_server.py"

echo "[public-suite] running all public lifecycle regressions"
RCLIENT_DIR="${RCLIENT_DIR}" \
  NGINX_SRC="${NGINX_SRC}" \
  SKIP_BUILD="${SKIP_BUILD}" \
  "${SCRIPT_DIR}/lifecycle-regressions.sh" all

echo "PASS public integration suite"
