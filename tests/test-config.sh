#!/usr/bin/env bash
set -euo pipefail

RN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NGINX_BIN="${NGINX_BIN:-${RN_ROOT}/upstream-nginx/objs/nginx}"
RCLIENT_DIR="${RCLIENT_DIR:-${RN_ROOT}/_deps/rl-c-client}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rn-config.XXXXXX")"
trap 'rm -rf "${TEST_ROOT}"' EXIT

if [[ ! -x "${NGINX_BIN}" ]]; then
  echo "nginx binary not found: ${NGINX_BIN}" >&2
  exit 1
fi
if [[ ! -d "${RCLIENT_DIR}" ]]; then
  echo "rl-c-client checkout not found: ${RCLIENT_DIR}" >&2
  exit 1
fi

run_valid_min_sample_threshold() {
  local label="$1"
  local threshold="$2"
  local prefix="${TEST_ROOT}/${label}"
  local config="${prefix}/nginx.conf"
  local output="${prefix}/nginx-test.log"

  mkdir -p "${prefix}/logs"
  cat >"${config}" <<EOF
events {}

http {
  ratelimitly_guard guard_${label}
    service="service:${label}"
    threshold=100ms
    ttl=30s
    max_samples=128
    buffer_size=32
    min_sample_threshold=${threshold};
}
EOF

  if ! LD_LIBRARY_PATH="${RCLIENT_DIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
      "${NGINX_BIN}" -t -p "${prefix}/" -c "${config}" >"${output}" 2>&1;
  then
    cat "${output}" >&2
    echo "FAIL rejected min_sample_threshold=${threshold}" >&2
    return 1
  fi
}

run_valid_min_sample_threshold zero 0
run_valid_min_sample_threshold positive 1

echo "PASS min_sample_threshold=0 and positive values are valid"
