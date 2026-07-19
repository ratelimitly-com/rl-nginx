#!/usr/bin/env bash
set -euo pipefail

RN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NGINX_BIN="${NGINX_BIN:-${RN_ROOT}/upstream-nginx/objs/nginx}"
RCLIENT_DIR="$("${RN_ROOT}/tools/resolve-rl-c-client.sh")"
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

run_case() {
  local label="$1"
  local expectation="$2"
  local body="$3"
  local expected_log="${4:-}"
  local prefix="${TEST_ROOT}/${label}"
  local config="${prefix}/nginx.conf"
  local output="${prefix}/nginx-test.log"
  local status

  mkdir -p "${prefix}/logs"
  body="${body//__SOCKET__/${prefix}/nginx.sock}"
  cat >"${config}" <<EOF
events {}

http {
${body}
}
EOF

  if "${NGINX_BIN}" -t -p "${prefix}/" -c "${config}" >"${output}" 2>&1;
  then
    status=0
  else
    status=$?
  fi

  case "${expectation}" in
  accept)
    if (( status != 0 )); then
      cat "${output}" >&2
      echo "FAIL [${label}] rejected valid configuration" >&2
      return 1
    fi
    ;;
  reject)
    if (( status == 0 )); then
      echo "FAIL [${label}] accepted invalid configuration" >&2
      return 1
    fi
    if [[ -n "${expected_log}" ]] && ! grep -Fq "${expected_log}" "${output}"; then
      cat "${output}" >&2
      echo "FAIL [${label}] rejection did not contain: ${expected_log}" >&2
      return 1
    fi
    ;;
  *)
    echo "FAIL [${label}] unknown expectation: ${expectation}" >&2
    return 1
    ;;
  esac
}

run_example_case() {
  local source="$1"
  local label="example-$(basename "${source}" .conf)"
  local prefix="${TEST_ROOT}/${label}"
  local config="${prefix}/nginx.conf"
  local output="${prefix}/nginx-test.log"

  mkdir -p "${prefix}/logs"
  sed \
    -e "s|rl-aes1REPLACE_WITH_YOUR_KEY|${VALID_AUTH_KEY}|g" \
    -e "s|listen 8080;|listen unix:${prefix}/nginx.sock;|g" \
    "${source}" >"${config}"

  if ! "${NGINX_BIN}" -t -p "${prefix}/" -c "${config}" >"${output}" 2>&1; then
    cat "${output}" >&2
    echo "FAIL [${label}] copyable example rejected after placeholder substitution" >&2
    return 1
  fi
}

VALID_AUTH_KEY='rl-aes1qyqqqqqqqqqqq6uxkfel7d8uuxwkhqzwladr74684kjw4g30r4yuq8jjmkmcwk6tqqqqzqqqqsqqqqqsqqqyqqqqqqkqzqqq0n6jux'
VALID_AUTH="  ratelimitly_auth_key ${VALID_AUTH_KEY};"
VALID_TENANT='  ratelimitly_tenant tenant.example.invalid;'
VALID_ZONE='  ratelimitly_zone primary bucket="primary" rate=100r/s;'
VALID_RESOLVER='  resolver 127.0.0.1;'
ENABLED_SERVER=$'  server {\n    listen unix:__SOCKET__;\n    location / {\n      ratelimitly zone=primary;\n      return 204;\n    }\n  }'

run_case representative accept \
  "${VALID_RESOLVER}"$'\n'"${VALID_TENANT}"$'\n'"${VALID_AUTH}"$'\n'\
$'  ratelimitly_timeout 50ms;\n  ratelimitly_fail close;\n  ratelimitly_debug off;\n  ratelimitly_zone primary bucket="primary:$uri" rate=4294967295r/4294967s;\n  ratelimitly_zone secondary bucket="secondary:$uri" rate=1r/h;\n  ratelimitly_group combined zone=primary zone=secondary;\n  ratelimitly_guard latency service="service:$host" threshold=4294967295ms ttl=4294967295ms max_samples=4294967295 buffer_size=4294967295 min_sample_threshold=0;\n  server {\n    listen unix:__SOCKET__;\n    location / {\n      ratelimitly_label "CONFIG:$uri";\n      ratelimitly group=combined guard=latency;\n      return 204;\n    }\n  }'

run_case min_sample_zero accept \
  $'  ratelimitly_guard zero service="service:zero" threshold=100ms ttl=30s max_samples=128 buffer_size=32 min_sample_threshold=0;'
run_case min_sample_positive accept \
  $'  ratelimitly_guard positive service="service:positive" threshold=100ms ttl=30s max_samples=128 buffer_size=32 min_sample_threshold=1;'
run_case dynamic_values_deferred accept \
  $'  map $arg_rate $dynamic_rate { default invalid-at-runtime; }\n  map $arg_threshold $dynamic_threshold { default invalid-at-runtime; }\n  ratelimitly_zone dynamic bucket="dynamic" rate=$dynamic_rate;\n  ratelimitly_guard dynamic_guard service="dynamic" threshold=$dynamic_threshold;'

run_case missing_tenant reject \
  "${VALID_AUTH}"$'\n'"${VALID_ZONE}"$'\n'"${ENABLED_SERVER}" \
  'ratelimitly_tenant is required'
run_case missing_auth reject \
  "${VALID_TENANT}"$'\n'"${VALID_ZONE}"$'\n'"${ENABLED_SERVER}" \
  'ratelimitly_auth_key is required'
run_case invalid_auth reject \
  $'  ratelimitly_auth_key not-a-key;' \
  'invalid ratelimitly_auth_key bech32 value'

run_case malformed_static_rate reject \
  $'  ratelimitly_zone malformed bucket="malformed" rate=not-a-rate;' \
  'invalid ratelimitly_zone rate'
run_case overflow_static_rate reject \
  $'  ratelimitly_zone overflow bucket="overflow" rate=4294967296r/s;' \
  'invalid ratelimitly_zone rate'
run_case overflow_static_window reject \
  $'  ratelimitly_zone overflow_window bucket="overflow" rate=1r/4294968s;' \
  'invalid ratelimitly_zone rate'

run_case duplicate_zone reject \
  $'  ratelimitly_zone duplicate bucket="one" rate=1r/s;\n  ratelimitly_zone duplicate bucket="two" rate=2r/s;' \
  'duplicate ratelimitly_zone name'
run_case duplicate_guard reject \
  $'  ratelimitly_guard duplicate service="one" threshold=1ms;\n  ratelimitly_guard duplicate service="two" threshold=2ms;' \
  'duplicate ratelimitly_guard name'
run_case duplicate_group reject \
  "${VALID_ZONE}"$'\n  ratelimitly_group duplicate zone=primary;\n  ratelimitly_group duplicate zone=primary;' \
  'duplicate ratelimitly_group name'

run_case unknown_group_zone reject \
  $'  ratelimitly_group invalid zone=missing;' \
  'ratelimitly_group references unknown zone'
run_case unknown_rule_zone reject \
  "${VALID_TENANT}"$'\n'"${VALID_AUTH}"$'\n  server {\n    listen unix:__SOCKET__;\n    location / { ratelimitly zone=missing; }\n  }' \
  'ratelimitly references unknown zone'
run_case unknown_rule_group reject \
  "${VALID_TENANT}"$'\n'"${VALID_AUTH}"$'\n  server {\n    listen unix:__SOCKET__;\n    location / { ratelimitly group=missing; }\n  }' \
  'ratelimitly references unknown group'
run_case unknown_rule_guard reject \
  "${VALID_TENANT}"$'\n'"${VALID_AUTH}"$'\n'"${VALID_ZONE}"$'\n  server {\n    listen unix:__SOCKET__;\n    location / { ratelimitly zone=primary guard=missing; }\n  }' \
  'ratelimitly references unknown guard'

run_case malformed_static_threshold reject \
  $'  ratelimitly_guard invalid service="invalid" threshold=not-a-duration;' \
  'invalid ratelimitly_guard threshold'
run_case overflow_static_threshold reject \
  $'  ratelimitly_guard overflow service="overflow" threshold=4294967296ms;' \
  'invalid ratelimitly_guard threshold'
run_case overflow_ttl reject \
  $'  ratelimitly_guard overflow service="overflow" threshold=1ms ttl=4294967296ms;' \
  'invalid ratelimitly_guard ttl'
run_case zero_max_samples reject \
  $'  ratelimitly_guard zero service="zero" threshold=1ms max_samples=0;' \
  'invalid ratelimitly_guard max_samples'
run_case zero_buffer_size reject \
  $'  ratelimitly_guard zero service="zero" threshold=1ms buffer_size=0;' \
  'invalid ratelimitly_guard buffer_size'
run_case overflow_min_sample reject \
  $'  ratelimitly_guard overflow service="overflow" threshold=1ms min_sample_threshold=4294967296;' \
  'invalid ratelimitly_guard min_sample_threshold'

run_case invalid_timeout reject \
  $'  ratelimitly_timeout forever;' \
  'invalid timeout'
run_case invalid_fail_policy reject \
  $'  ratelimitly_fail maybe;' \
  'invalid ratelimitly_fail value'
run_case invalid_debug_flag reject \
  $'  ratelimitly_debug maybe;' \
  'invalid ratelimitly_debug value'
run_case invalid_bind reject \
  $'  ratelimitly_bind not-an-ip;' \
  'invalid ratelimitly_bind address'
run_case location_only_resolver reject \
  "${VALID_TENANT}"$'\n'"${VALID_AUTH}"$'\n'"${VALID_ZONE}"$'\n  server {\n    listen unix:__SOCKET__;\n    location / {\n      resolver 127.0.0.1;\n      ratelimitly zone=primary;\n      return 204;\n    }\n  }' \
  'ratelimitly requires resolver in the http context'

run_example_case "${RN_ROOT}/examples/minimal.conf"
run_example_case "${RN_ROOT}/examples/security-conscious.conf"

echo "PASS configuration matrix"
