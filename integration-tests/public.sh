#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOCKED_RCLIENT_DIR="${RN_ROOT}/_deps/rl-c-client"
RCLIENT_DIR="${RCLIENT_DIR:-${LOCKED_RCLIENT_DIR}}"
NGINX_SRC="${NGINX_SRC:-${RN_ROOT}/upstream-nginx}"

usage() {
  cat <<EOF
Usage: integration-tests/public.sh

Runs the required public rl-nginx integration suite using only:
  - the locked public rl-c-client responder;
  - the local DNS fixture;
  - the pinned nginx source; and
  - this module.

The suite covers DNS fixture fidelity, request lifecycle safety, steering
rebind, and response-cardinality handling under fail-open and fail-close.

Environment overrides:
  RCLIENT_DIR  C-client checkout (default: locked ./_deps checkout)
  NGINX_SRC    nginx source tree (default: ./upstream-nginx)

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

if [[ ! -d "${RCLIENT_DIR}" ]]; then
  if [[ "${RCLIENT_DIR}" != "${LOCKED_RCLIENT_DIR}" ]]; then
    echo "C-client checkout not found: ${RCLIENT_DIR}" >&2
    exit 1
  fi
  "${RN_ROOT}/tools/fetch-rl-c-client.sh"
fi
if [[ ! -f "${NGINX_SRC}/auto/configure" ]]; then
  echo "nginx source not initialized: ${NGINX_SRC}" >&2
  echo "Run: git submodule update --init upstream-nginx" >&2
  exit 1
fi

echo "[public-suite] testing the strict DNS fixture"
python3 "${SCRIPT_DIR}/test_local_dns_server.py"

echo "[public-suite] running lifecycle regressions"
RCLIENT_DIR="${RCLIENT_DIR}" \
  NGINX_SRC="${NGINX_SRC}" \
  SKIP_BUILD=0 \
  "${SCRIPT_DIR}/lifecycle-regressions.sh" all

echo "[public-suite] running the exact enforcement boundary"
RCLIENT_DIR="${RCLIENT_DIR}" \
  NGINX_SRC="${NGINX_SRC}" \
  SKIP_BUILD=1 \
  "${SCRIPT_DIR}/lifecycle-regressions.sh" enforcement-boundary

echo "[public-suite] running outage-policy regressions"
RCLIENT_DIR="${RCLIENT_DIR}" \
  NGINX_SRC="${NGINX_SRC}" \
  SKIP_BUILD=1 \
  "${SCRIPT_DIR}/lifecycle-regressions.sh" outage-policy

echo "[public-suite] running response-cardinality regressions"
RCLIENT_DIR="${RCLIENT_DIR}" \
  NGINX_SRC="${NGINX_SRC}" \
  SKIP_BUILD=1 \
  "${SCRIPT_DIR}/lifecycle-regressions.sh" cardinality

echo "PASS public integration suite"
