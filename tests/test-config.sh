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

VALID_AUTH_KEY='rl-aes1qypsqqqqqqqqqqqrqvpsxqcrqvpsxqcrqvpsxqcrqvpsxqcrqvpsxqcrqvpsxqcrqdgrrulcvcn0x5'
LEGACY_AUTH_KEY='rl-aes1qyqqqqqqqqqqq6uxkfel7d8uuxwkhqzwladr74684kjw4g30r4yuq8jjmkmcwk6tqqqqzqqqqsqqqqqsqqqyqqqqqqkqzqqq0n6jux'
UNKNOWN_VERSION_AUTH_KEY='rl-aes1qgpqqqqqqqqqqqqzqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqghjmuhcchgqf0'
INVALID_QUOTA_AUTH_KEY='rl-aes1qyysqqqqqqqqqqqfpyysjzgfpyysjzgfpyysjzgfpyysjzgfpyysjzgfpyysjzgfpyqqqqqqurys6m'
VALID_AUTH="  ratelimitly_auth_key ${VALID_AUTH_KEY};"
VALID_DNS_SRV='  ratelimitly_dns_srv tenant.example.invalid;'
VALID_ZONE='  ratelimitly_zone primary "bucket=primary" rate=100r/s;'
VALID_TRACKER='  ratelimitly_tracker latency "service=service:latency";'
VALID_GUARD='  ratelimitly_guard latency_guard tracker=latency threshold=100ms;'
VALID_RESOLVER='  resolver 127.0.0.1;'
ENABLED_SERVER=$'  server {\n    listen unix:__SOCKET__;\n    location / {\n      ratelimitly zone=primary;\n      return 204;\n    }\n  }'
printf -v MAX_IDENTIFIER '%*s' 1024 ''
MAX_IDENTIFIER="${MAX_IDENTIFIER// /i}"
OVERSIZED_IDENTIFIER="${MAX_IDENTIFIER}i"
printf -v MAX_LABEL '%*s' 256 ''
MAX_LABEL="${MAX_LABEL// /l}"
OVERSIZED_LABEL="${MAX_LABEL}l"

# The public DSL deliberately separates tracker identity, admission guards,
# and post-response reporting.  Keep these cases near the top so a build of an
# older module fails before the broader compatibility fixture is migrated.
run_case explicit_tracker_guard_and_report accept \
  "${VALID_RESOLVER}"$'\n'"${VALID_DNS_SRV}"$'\n'"${VALID_AUTH}"$'\n'\
$'  ratelimitly_zone primary "bucket=primary" rate=100r/s;\n  ratelimitly_tracker latency "service=service:$host" ttl=30s max_samples=128 buffer_size=32 min_sample_threshold=0;\n  ratelimitly_guard fast tracker=latency threshold=100ms;\n  server {\n    listen unix:__SOCKET__;\n    location / {\n      ratelimitly zone=primary guard=fast;\n      ratelimitly_report latency;\n      return 204;\n    }\n  }'

run_case report_without_guard_or_rate_request accept \
  "${VALID_RESOLVER}"$'\n'"${VALID_DNS_SRV}"$'\n'"${VALID_AUTH}"$'\n'\
$'  ratelimitly_tracker latency "service=service:latency";\n  server {\n    listen unix:__SOCKET__;\n    location / { ratelimitly_report latency; return 204; }\n  }'

run_case report_inheritance_can_be_disabled accept \
  "${VALID_RESOLVER}"$'\n'"${VALID_DNS_SRV}"$'\n'"${VALID_AUTH}"$'\n'\
$'  ratelimitly_tracker latency "service=service:latency";\n  server {\n    listen unix:__SOCKET__;\n    ratelimitly_report latency;\n    location /health { ratelimitly_report off; return 204; }\n    location /api { return 204; }\n  }'

run_case legacy_guard_owns_tracker_fields reject \
  $'  ratelimitly_guard legacy "service=service:legacy" threshold=100ms;' \
  'ratelimitly_guard expects tracker= and threshold='

run_case representative accept \
  "${VALID_RESOLVER}"$'\n'"${VALID_DNS_SRV}"$'\n'"${VALID_AUTH}"$'\n'\
$'  log_format ratelimitly_test "$status $ratelimitly_verdict";\n  access_log off;\n  ratelimitly_policy standard unit=50ms;\n  ratelimitly_fail close;\n  ratelimitly_debug off;\n  ratelimitly_zone primary "bucket=primary:$uri" rate=4294967295r/4294967s;\n  ratelimitly_zone secondary "bucket=secondary:$uri" rate=1r/h;\n  ratelimitly_group combined zone=primary zone=secondary;\n  ratelimitly_tracker latency "service=service:$host" ttl=4294967295ms max_samples=4294967295 buffer_size=4294967295 min_sample_threshold=0;\n  ratelimitly_guard latency_guard tracker=latency threshold=4294967295ms;\n  server {\n    listen unix:__SOCKET__;\n    location / {\n      ratelimitly_label "CONFIG:$uri";\n      ratelimitly group=combined guard=latency_guard;\n      ratelimitly_report latency;\n      return 204;\n    }\n  }'

run_case guard_only_rule accept \
  "${VALID_RESOLVER}"$'\n'"${VALID_DNS_SRV}"$'\n'"${VALID_AUTH}"$'\n'"${VALID_TRACKER}"$'\n'"${VALID_GUARD}"$'\n  server {\n    listen unix:__SOCKET__;\n    location / { ratelimitly guard=latency_guard; return 204; }\n  }'

run_case min_sample_zero accept \
  $'  ratelimitly_tracker zero "service=service:zero" ttl=30s max_samples=128 buffer_size=32 min_sample_threshold=0;'
run_case min_sample_positive accept \
  $'  ratelimitly_tracker positive "service=service:positive" ttl=30s max_samples=128 buffer_size=32 min_sample_threshold=1;'
run_case dynamic_values_deferred accept \
  $'  map $arg_rate $dynamic_rate { default invalid-at-runtime; }\n  map $arg_threshold $dynamic_threshold { default invalid-at-runtime; }\n  ratelimitly_zone dynamic "bucket=dynamic" rate=$dynamic_rate;\n  ratelimitly_tracker dynamic_tracker "service=dynamic";\n  ratelimitly_guard dynamic_guard tracker=dynamic_tracker threshold=$dynamic_threshold;'
run_case unitless_durations_are_seconds accept \
  $'  ratelimitly_policy standard unit=1;\n  ratelimitly_tracker seconds_tracker "service=seconds" ttl=1;\n  ratelimitly_guard seconds tracker=seconds_tracker threshold=1;'
run_case standard_default_unit accept \
  $'  ratelimitly_policy standard;'
run_case single_round accept \
  $'  ratelimitly_policy single_round unit=25ms;'
run_case single_round_wire_horizon_boundary accept \
  $'  ratelimitly_policy single_round unit=4294967295ms;'
run_case standard_wire_horizon_boundary accept \
  $'  ratelimitly_policy standard unit=1431655765ms;'
run_case custom_fixed accept \
  $'  ratelimitly_policy custom unit=20ms replays=1 replay_gap=fixed:1 final_wait_units=1 completion_delivery=on;'
run_case custom_schedules accept \
  $'  ratelimitly_policy custom unit=10ms replays=2 replay_gap=linear:1:1:3 final_wait_units=2 completion_delivery=off;'
run_case max_static_bucket accept \
  "  ratelimitly_zone max_bucket \"bucket=${MAX_IDENTIFIER}\" rate=1r/s;"
run_case max_static_service accept \
  "  ratelimitly_tracker max_service \"service=${MAX_IDENTIFIER}\";"
run_case max_static_label accept \
  "  server { listen unix:__SOCKET__; location / { ratelimitly_label \"${MAX_LABEL}\"; return 204; } }"

run_case omitted_tenant_default accept \
  "${VALID_RESOLVER}"$'\n'"${VALID_AUTH}"$'\n'"${VALID_ZONE}"$'\n'"${ENABLED_SERVER}"
run_case ratelimitly_dns_resolver accept \
  $'  ratelimitly_dns_resolver 127.0.0.1;' $'\n'"${VALID_AUTH}"$'\n'"${VALID_ZONE}"$'\n'"${ENABLED_SERVER}"
run_case ratelimitly_resolver_alias accept \
  $'  ratelimitly_resolver 127.0.0.1;' $'\n'"${VALID_AUTH}"$'\n'"${VALID_ZONE}"$'\n'"${ENABLED_SERVER}"
run_case omitted_resolver_system_dns_default accept \
  "${VALID_AUTH}"$'\n'"${VALID_ZONE}"$'\n'"${ENABLED_SERVER}"
run_case missing_auth reject \
  "${VALID_DNS_SRV}"$'\n'"${VALID_ZONE}"$'\n'"${ENABLED_SERVER}" \
  'ratelimitly_auth_key is required'
run_case invalid_auth reject \
  $'  ratelimitly_auth_key not-a-key;' \
  'invalid ratelimitly_auth_key bech32 value'
run_case legacy_unversioned_auth reject \
  "  ratelimitly_auth_key ${LEGACY_AUTH_KEY};" \
  'invalid ratelimitly_auth_key bech32 value'
run_case unknown_auth_format_version reject \
  "  ratelimitly_auth_key ${UNKNOWN_VERSION_AUTH_KEY};" \
  'invalid ratelimitly_auth_key bech32 value'
run_case invalid_auth_quota_word reject \
  "  ratelimitly_auth_key ${INVALID_QUOTA_AUTH_KEY};" \
  'invalid ratelimitly_auth_key bech32 value'

run_case malformed_static_rate reject \
  $'  ratelimitly_zone malformed "bucket=malformed" rate=not-a-rate;' \
  'invalid ratelimitly_zone rate'
run_case overflow_static_rate reject \
  $'  ratelimitly_zone overflow "bucket=overflow" rate=4294967296r/s;' \
  'invalid ratelimitly_zone rate'
run_case overflow_static_window reject \
  $'  ratelimitly_zone overflow_window "bucket=overflow" rate=1r/4294968s;' \
  'invalid ratelimitly_zone rate'
run_case oversized_static_bucket reject \
  "  ratelimitly_zone oversized_bucket \"bucket=${OVERSIZED_IDENTIFIER}\" rate=1r/s;" \
  'ratelimitly_zone bucket is 1025 bytes; maximum is 1024'
run_case value_only_quoted_bucket reject \
  $'  ratelimitly_zone quoted bucket="quoted" rate=1r/s;' \
  'quote the complete bucket= argument, not only its value'

run_case duplicate_zone reject \
  $'  ratelimitly_zone duplicate "bucket=one" rate=1r/s;\n  ratelimitly_zone duplicate "bucket=two" rate=2r/s;' \
  'duplicate ratelimitly_zone name'
run_case duplicate_tracker reject \
  $'  ratelimitly_tracker duplicate "service=one";\n  ratelimitly_tracker duplicate "service=two";' \
  'duplicate ratelimitly_tracker name'
run_case duplicate_guard reject \
  $'  ratelimitly_tracker tracker "service=one";\n  ratelimitly_guard duplicate tracker=tracker threshold=1ms;\n  ratelimitly_guard duplicate tracker=tracker threshold=2ms;' \
  'duplicate ratelimitly_guard name'
run_case duplicate_group reject \
  "${VALID_ZONE}"$'\n  ratelimitly_group duplicate zone=primary;\n  ratelimitly_group duplicate zone=primary;' \
  'duplicate ratelimitly_group name'
run_case empty_zone_name reject \
  $'  ratelimitly_zone "" "bucket=empty" rate=1r/s;' \
  'ratelimitly_zone requires positional <name> as first argument'
run_case empty_tracker_name reject \
  $'  ratelimitly_tracker "" "service=empty";' \
  'ratelimitly_tracker requires positional <name> as first argument'
run_case reserved_tracker_name reject \
  $'  ratelimitly_tracker off "service=reserved";' \
  'ratelimitly_tracker name "off" is reserved'
run_case empty_guard_name reject \
  $'  ratelimitly_tracker tracker "service=empty";\n  ratelimitly_guard "" tracker=tracker threshold=1ms;' \
  'ratelimitly_guard requires positional <name> as first argument'
run_case empty_group_name reject \
  "${VALID_ZONE}"$'\n  ratelimitly_group "" zone=primary;' \
  'ratelimitly_group requires positional <name> as first argument'
run_case named_argument_as_group_name reject \
  "${VALID_ZONE}"$'\n  ratelimitly_zone secondary "bucket=secondary" rate=1r/s;\n  ratelimitly_group zone=primary zone=secondary;' \
  'ratelimitly_group requires positional <name> as first argument'
run_case empty_group_zone_reference reject \
  "${VALID_ZONE}"$'\n  ratelimitly_group invalid zone=;' \
  'ratelimitly_group requires nonempty zone= references'

run_case unknown_group_zone reject \
  $'  ratelimitly_group invalid zone=missing;' \
  'ratelimitly_group references unknown zone'
run_case unknown_rule_zone reject \
  "${VALID_DNS_SRV}"$'\n'"${VALID_AUTH}"$'\n  server {\n    listen unix:__SOCKET__;\n    location / { ratelimitly zone=missing; }\n  }' \
  'ratelimitly references unknown zone'
run_case unknown_rule_group reject \
  "${VALID_DNS_SRV}"$'\n'"${VALID_AUTH}"$'\n  server {\n    listen unix:__SOCKET__;\n    location / { ratelimitly group=missing; }\n  }' \
  'ratelimitly references unknown group'
run_case unknown_rule_guard reject \
  "${VALID_DNS_SRV}"$'\n'"${VALID_AUTH}"$'\n'"${VALID_ZONE}"$'\n  server {\n    listen unix:__SOCKET__;\n    location / { ratelimitly zone=primary guard=missing; }\n  }' \
  'ratelimitly references unknown guard'
run_case unknown_guard_only_rule reject \
  "${VALID_DNS_SRV}"$'\n'"${VALID_AUTH}"$'\n  server {\n    listen unix:__SOCKET__;\n    location / { ratelimitly guard=missing; }\n  }' \
  'ratelimitly references unknown guard'
run_case unknown_guard_tracker reject \
  $'  ratelimitly_guard invalid tracker=missing threshold=1ms;' \
  'ratelimitly_guard references unknown tracker'
run_case unknown_report_tracker reject \
  $'  server { listen unix:__SOCKET__; location / { ratelimitly_report missing; } }' \
  'ratelimitly_report references unknown tracker'
run_case duplicate_report reject \
  $'  ratelimitly_tracker tracker "service=service";\n  server { listen unix:__SOCKET__; location / { ratelimitly_report tracker; ratelimitly_report off; } }' \
  'is duplicate'
run_case empty_rule reject \
  $'  server { listen unix:__SOCKET__; location / { ratelimitly; } }' \
  'invalid number of arguments in "ratelimitly" directive'
run_case empty_rule_zone_reference reject \
  $'  server { listen unix:__SOCKET__; location / { ratelimitly zone=; } }' \
  'ratelimitly requires a nonempty zone= or group= reference'
run_case empty_rule_group_reference reject \
  $'  server { listen unix:__SOCKET__; location / { ratelimitly group=; } }' \
  'ratelimitly requires a nonempty zone= or group= reference'
run_case empty_rule_guard_reference reject \
  "${VALID_ZONE}"$'\n  server { listen unix:__SOCKET__; location / { ratelimitly zone=primary guard=; } }' \
  'ratelimitly requires nonempty guard= references'
run_case empty_zone_cannot_hide_group_reference reject \
  "${VALID_ZONE}"$'\n  ratelimitly_group combined zone=primary;\n  server { listen unix:__SOCKET__; location / { ratelimitly zone= group=combined; } }' \
  'ratelimitly expects exactly one of zone= or group='
run_case empty_group_cannot_hide_zone_reference reject \
  "${VALID_ZONE}"$'\n  server { listen unix:__SOCKET__; location / { ratelimitly group= zone=primary; } }' \
  'ratelimitly expects exactly one of zone= or group='

run_case malformed_static_threshold reject \
  $'  ratelimitly_tracker tracker "service=invalid";\n  ratelimitly_guard invalid tracker=tracker threshold=not-a-duration;' \
  'invalid ratelimitly_guard threshold'
run_case overflow_static_threshold reject \
  $'  ratelimitly_tracker tracker "service=overflow";\n  ratelimitly_guard overflow tracker=tracker threshold=4294967296ms;' \
  'invalid ratelimitly_guard threshold'
run_case zero_static_threshold reject \
  $'  ratelimitly_tracker tracker "service=zero";\n  ratelimitly_guard zero tracker=tracker threshold=0;' \
  'invalid ratelimitly_guard threshold'
run_case overflow_ttl reject \
  $'  ratelimitly_tracker overflow "service=overflow" ttl=4294967296ms;' \
  'invalid ratelimitly_tracker ttl'
run_case zero_ttl reject \
  $'  ratelimitly_tracker zero "service=zero" ttl=0;' \
  'invalid ratelimitly_tracker ttl'
run_case oversized_static_service reject \
  "  ratelimitly_tracker oversized_service \"service=${OVERSIZED_IDENTIFIER}\";" \
  'ratelimitly_tracker service is 1025 bytes; maximum is 1024'
run_case value_only_quoted_service reject \
  $'  ratelimitly_tracker quoted service="quoted";' \
  'quote the complete service= argument, not only its value'
run_case zero_max_samples reject \
  $'  ratelimitly_tracker zero "service=zero" max_samples=0;' \
  'invalid ratelimitly_tracker max_samples'
run_case zero_buffer_size reject \
  $'  ratelimitly_tracker zero "service=zero" buffer_size=0;' \
  'invalid ratelimitly_tracker buffer_size'
run_case overflow_min_sample reject \
  $'  ratelimitly_tracker overflow "service=overflow" min_sample_threshold=4294967296;' \
  'invalid ratelimitly_tracker min_sample_threshold'

run_case removed_timeout_directive reject \
  $'  ratelimitly_timeout 20ms;' \
  'unknown directive "ratelimitly_timeout"'
run_case invalid_policy_name reject \
  $'  ratelimitly_policy fast;' \
  'invalid ratelimitly_policy name'
run_case named_policy_unknown_argument reject \
  $'  ratelimitly_policy standard replays=2;' \
  'standard accepts only unit='
run_case duplicate_policy reject \
  $'  ratelimitly_policy standard;\n  ratelimitly_policy single_round;' \
  'is duplicate'
run_case invalid_policy_unit reject \
  $'  ratelimitly_policy standard unit=forever;' \
  'invalid ratelimitly_policy unit'
run_case zero_policy_unit reject \
  $'  ratelimitly_policy standard unit=0;' \
  'invalid ratelimitly_policy unit'
run_case overflow_policy_unit reject \
  $'  ratelimitly_policy standard unit=4294967296ms;' \
  'invalid ratelimitly_policy unit'
run_case policy_horizon_overflow reject \
  $'  ratelimitly_policy standard unit=1431655766ms;' \
  'ratelimitly_policy horizon exceeds the wire limit'
run_case custom_missing_fields reject \
  $'  ratelimitly_policy custom unit=20ms;' \
  'custom requires unit=, replays=, replay_gap=, final_wait_units=, and completion_delivery='
run_case custom_duplicate_field reject \
  $'  ratelimitly_policy custom unit=20ms unit=25ms replays=1 replay_gap=fixed:1 final_wait_units=1 completion_delivery=on;' \
  'duplicate ratelimitly_policy unit='
run_case custom_replays_overflow reject \
  $'  ratelimitly_policy custom unit=20ms replays=65536 replay_gap=fixed:1 final_wait_units=1 completion_delivery=on;' \
  'invalid ratelimitly_policy replays'
run_case custom_invalid_schedule_kind reject \
  $'  ratelimitly_policy custom unit=20ms replays=1 replay_gap=random:1 final_wait_units=1 completion_delivery=on;' \
  'invalid ratelimitly_policy replay_gap'
run_case custom_malformed_linear_schedule reject \
  $'  ratelimitly_policy custom unit=20ms replays=1 replay_gap=linear:1:1 final_wait_units=1 completion_delivery=on;' \
  'invalid ratelimitly_policy replay_gap'
run_case custom_zero_replay_gap reject \
  $'  ratelimitly_policy custom unit=20ms replays=1 replay_gap=fixed:0 final_wait_units=1 completion_delivery=on;' \
  'invalid ratelimitly_policy replay_gap'
run_case custom_zero_linear_step reject \
  $'  ratelimitly_policy custom unit=20ms replays=1 replay_gap=linear:1:0:2 final_wait_units=1 completion_delivery=on;' \
  'invalid ratelimitly_policy replay_gap'
run_case custom_small_exponential_factor reject \
  $'  ratelimitly_policy custom unit=20ms replays=1 replay_gap=exponential:1:1:2 final_wait_units=1 completion_delivery=on;' \
  'invalid ratelimitly_policy replay_gap'
run_case custom_schedule_initial_above_maximum reject \
  $'  ratelimitly_policy custom unit=20ms replays=1 replay_gap=linear:2:1:1 final_wait_units=1 completion_delivery=on;' \
  'invalid ratelimitly_policy replay_gap'
run_case custom_invalid_completion_delivery reject \
  $'  ratelimitly_policy custom unit=20ms replays=1 replay_gap=fixed:1 final_wait_units=1 completion_delivery=maybe;' \
  'invalid ratelimitly_policy completion_delivery'
run_case policy_exceeds_credential_ttl reject \
  "${VALID_RESOLVER}"$'\n'"${VALID_DNS_SRV}"$'\n'"${VALID_AUTH}"$'\n'"${VALID_ZONE}"$'\n  ratelimitly_policy standard unit=101ms;\n'"${ENABLED_SERVER}" \
  'ratelimitly_policy horizon is invalid or exceeds the API-key dedup_ttl_ms_max of 300ms'
run_case invalid_fail_policy reject \
  $'  ratelimitly_fail maybe;' \
  'invalid ratelimitly_fail value'
run_case invalid_debug_flag reject \
  $'  ratelimitly_debug maybe;' \
  'invalid ratelimitly_debug value'
run_case duplicate_debug_off_then_on reject \
  $'  ratelimitly_debug off;\n  ratelimitly_debug on;' \
  'is duplicate'
run_case duplicate_debug_on_then_off reject \
  $'  ratelimitly_debug on;\n  ratelimitly_debug off;' \
  'is duplicate'
run_case oversized_static_label reject \
  "  server { listen unix:__SOCKET__; location / { ratelimitly_label \"${OVERSIZED_LABEL}\"; return 204; } }" \
  'ratelimitly_label is 257 bytes; maximum is 256'
run_case invalid_bind reject \
  $'  ratelimitly_bind not-an-ip;' \
  'invalid ratelimitly_bind address'
run_case location_only_resolver accept \
  "${VALID_DNS_SRV}"$'\n'"${VALID_AUTH}"$'\n'"${VALID_ZONE}"$'\n  server {\n    listen unix:__SOCKET__;\n    location / {\n      resolver 127.0.0.1;\n      ratelimitly zone=primary;\n      return 204;\n    }\n  }'

run_example_case "${RN_ROOT}/examples/minimal.conf"
run_example_case "${RN_ROOT}/examples/security-conscious.conf"

echo "PASS configuration matrix"
