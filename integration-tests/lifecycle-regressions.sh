#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SELF="${SCRIPT_DIR}/lifecycle-regressions.sh"
# shellcheck source=lifecycle-oracles.sh
source "${SCRIPT_DIR}/lifecycle-oracles.sh"

usage() {
  cat <<EOF
Usage: integration-tests/lifecycle-regressions.sh [all|list-all|admission-contract|cardinality|rendered-values|protocol-policy|outage-policy|dns-policy|guard-latency|fault-injection|enforcement-boundary|worker-resolver-scope|timeout|aborted-client|udp-ingress-fairness|steering-rebind|outage|dns-missing-srv|dns-bad-target|dns-timeout|guard-pass|guard-deny|guard-multiple|guard-start-fail-open|guard-timeout-fail-open|guard-aborted-client|malformed-auth|malformed-truncated|malformed-request-id|count-empty|count-short|count-extra]

Runs the complete required public lifecycle matrix against the locked
rl-c-client test responder. Every case pins the original nginx worker PID,
triggers its target path, and requires both worker survival and a successful
follow-up request. Use list-all to print the all-mode group manifest.

Environment overrides:
  RCLIENT_DIR       C-client checkout (default: locked ./_deps checkout)
  NGINX_SRC         nginx source tree (default: ./upstream-nginx)
  NGINX_LOAD_MODULE absolute dynamic-module path to load (default: none)
  DNS_PORT          local DNS port (default: 15353)
  RESPONDER_PORT    UDP responder port (default: 19080)
  NGINX_PORT        nginx HTTP port (default: 18098)
  REQUEST_POLICY_UNIT  C-client scheduling unit (default: 100ms; 300ms standard-policy horizon)
  DNS_REFRESH_SEC   wait after DNS mode changes (default: 1.2)
  DNS_TIMEOUT_RECOVERY_SEC
                    wait after restoring DNS from timeout mode (default: 6)
  ABORT_REQUESTS    aborted clients in the stress case (default: 20)
  FAIL_POLICY       generated nginx policy: close or open (default: close)
  FAULT_POINT       test-only fault selected by the fault-injection group
  SKIP_BUILD=1      reuse existing responder and nginx binaries

Artifacts are written under integration-tests/artifacts/lifecycle/.
EOF
}

MODE="${1:-all}"
if [[ "${MODE}" == "-h" || "${MODE}" == "--help" ]]; then
  usage
  exit 0
fi
if (( $# > 1 )); then
  usage >&2
  exit 2
fi
case "${MODE}" in
  all|list-all|admission-contract|admission-contract-close|admission-contract-open|cardinality|rendered-values|rendered-values-close|rendered-values-open|protocol-policy|outage-policy|dns-policy|guard-latency|fault-injection|fault|enforcement-boundary|worker-resolver-scope|timeout|aborted-client|udp-ingress-fairness|steering-rebind|outage|dns-missing-srv|dns-bad-target|dns-timeout|guard-pass|guard-deny|guard-multiple|guard-start-fail-open|guard-timeout-fail-open|guard-aborted-client|malformed-auth|malformed-truncated|malformed-request-id|count-empty|count-short|count-extra) ;;
  *)
    echo "Unknown lifecycle case: ${MODE}" >&2
    usage >&2
    exit 2
    ;;
esac

ALL_PUBLIC_GROUPS=(
  timeout
  aborted-client
  udp-ingress-fairness
  steering-rebind
  worker-resolver-scope
  admission-contract
  enforcement-boundary
  rendered-values
  outage-policy
  dns-policy
  guard-latency
  protocol-policy
  cardinality
)
if [[ "${MODE}" == "list-all" ]]; then
  printf '%s\n' "${ALL_PUBLIC_GROUPS[@]}"
  exit 0
fi

RCLIENT_DIR="$("${RN_ROOT}/tools/resolve-rl-c-client.sh")"
export RCLIENT_DIR
NGINX_SRC="${NGINX_SRC:-${RN_ROOT}/upstream-nginx}"
NGINX_BIN="${NGINX_BIN:-${NGINX_SRC}/objs/nginx}"
NGINX_LOAD_MODULE="${NGINX_LOAD_MODULE:-}"
RESPONDER_BIN="${RESPONDER_BIN:-${RCLIENT_DIR}/bin/r_test_responder}"
DNS_SERVER="${DNS_SERVER:-127.0.0.1}"
DNS_PORT="${DNS_PORT:-15353}"
DNS_BAD_PORT="${DNS_BAD_PORT:-$((DNS_PORT + 1))}"
RESPONDER_HOST="${RESPONDER_HOST:-127.0.0.1}"
RESPONDER_PORT="${RESPONDER_PORT:-19080}"
NGINX_HOST="${NGINX_HOST:-127.0.0.1}"
NGINX_PORT="${NGINX_PORT:-18098}"
DOMAIN="${DOMAIN:-rn-test.local}"
SERVER_ID="${SERVER_ID:-1}"
REQUEST_POLICY_UNIT="${REQUEST_POLICY_UNIT:-100ms}"
DNS_REFRESH_SEC="${DNS_REFRESH_SEC:-1.2}"
DNS_TIMEOUT_RECOVERY_SEC="${DNS_TIMEOUT_RECOVERY_SEC:-6}"
ABORT_REQUESTS="${ABORT_REQUESTS:-20}"
FAIL_POLICY="${FAIL_POLICY:-close}"
FAULT_POINT="${FAULT_POINT:-}"
CLIENT_TIMEOUT_SEC="${CLIENT_TIMEOUT_SEC:-3}"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-${SCRIPT_DIR}/artifacts/lifecycle}"
ABORT_CLIENT_HELPER="${SCRIPT_DIR}/abort_http_clients.py"
UDP_PORT_HELPER="${SCRIPT_DIR}/worker_udp_port.py"
UDP_FLOOD_HELPER="${SCRIPT_DIR}/udp_flood.py"
ENFORCEMENT_ALLOW_COUNT=3
ENFORCEMENT_TOTAL_REQUESTS=5

RESPONDER_PID=""
DNS_PID=""
NGINX_PID=""
FLOOD_PID=""
HTTP_PROBE_PID=""
ORIGINAL_WORKER_PID=""
CASE_FAILED=0
RESPONDER_RUN=0

case "${FAIL_POLICY}" in
  close|open) ;;
  *) fail_policy_error="FAIL_POLICY must be close or open, got: ${FAIL_POLICY}" ;;
esac
if [[ -n "${fail_policy_error:-}" ]]; then
  echo "${fail_policy_error}" >&2
  exit 2
fi

log() {
  printf '[lifecycle:%s] %s\n' "${MODE}" "$*"
}

fail() {
  echo "FAIL [${MODE}] $*" >&2
  exit 1
}

record_failure() {
  echo "FAIL [${MODE}] $*" >&2
  CASE_FAILED=1
}

run_nginx_oneshot() {
  local -a oneshot_env=()

  if [[ -n "${RN_NGINX_ONESHOT_ASAN_OPTIONS:-}" ]]; then
    oneshot_env+=("ASAN_OPTIONS=${RN_NGINX_ONESHOT_ASAN_OPTIONS}")
  fi
  env "${oneshot_env[@]}" "${NGINX_BIN}" "$@"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

stop_responder() {
  rn_terminate_pid "${RESPONDER_PID}" "test responder" || true
  RESPONDER_PID=""
}

stop_nginx() {
  local attempt

  if [[ -n "${NGINX_PID}" ]] && kill -0 "${NGINX_PID}" 2>/dev/null; then
    run_nginx_oneshot -p "${PREFIX}/" -c "${NGINX_CONF}" -s quit \
      >/dev/null 2>&1 || true
    for (( attempt = 0; attempt < 30; attempt++ )); do
      if ! kill -0 "${NGINX_PID}" 2>/dev/null; then
        wait "${NGINX_PID}" 2>/dev/null || true
        NGINX_PID=""
        return 0
      fi
      sleep 0.1
    done
  fi
  if ! rn_terminate_pid "${NGINX_PID}" "nginx master"; then
    record_failure "nginx required SIGKILL during clean shutdown"
  fi
  NGINX_PID=""
}

check_clean_nginx_shutdown() {
  stop_nginx
  if grep -Eq '\[alert\].*(open socket .* left|aborting)' "${NGINX_ERROR_LOG}"; then
    record_failure "nginx reported a leaked connection during worker shutdown"
  else
    log "worker shutdown completed without leaked-connection alerts"
  fi
}

cleanup() {
  rn_terminate_pid "${FLOOD_PID}" "UDP flood fixture" || true
  FLOOD_PID=""
  rn_terminate_pid "${HTTP_PROBE_PID}" "HTTP probe" || true
  HTTP_PROBE_PID=""
  stop_nginx
  stop_responder
  rn_terminate_pid "${DNS_PID}" "local DNS server" || true
}

prepare_binaries() {
  need_cmd bash
  need_cmd curl
  need_cmd dd
  need_cmd dig
  need_cmd make
  need_cmd ps
  need_cmd python3

  if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    log "building the public test responder"
    make -C "${RCLIENT_DIR}" test-responder
    log "building nginx with the module"
    RCLIENT_DIR="${RCLIENT_DIR}" \
      "${RN_ROOT}/tools/build-nginx.sh" "${NGINX_SRC}" --clean --debug
  fi

  [[ -x "${RESPONDER_BIN}" ]] || fail "responder binary not found: ${RESPONDER_BIN}"
  [[ -x "${NGINX_BIN}" ]] || fail "nginx binary not found: ${NGINX_BIN}"
  if [[ -n "${NGINX_LOAD_MODULE}" ]]; then
    [[ -f "${NGINX_LOAD_MODULE}" ]] \
      || fail "nginx dynamic module not found: ${NGINX_LOAD_MODULE}"
  fi
}

run_all() {
  local failures=0
  local lifecycle_case

  prepare_binaries
  for lifecycle_case in "${ALL_PUBLIC_GROUPS[@]}"; do
    if FAIL_POLICY=close SKIP_BUILD=1 "${SELF}" "${lifecycle_case}"; then
      printf 'PASS %s\n' "${lifecycle_case}"
    else
      printf 'FAIL %s (see %s/%s)\n' \
        "${lifecycle_case}" "${ARTIFACT_ROOT}" "${lifecycle_case}" >&2
      failures=$((failures + 1))
    fi
  done
  if (( failures > 0 )); then
    echo "${failures} lifecycle regression(s) failed" >&2
    return 1
  fi
  log "all public lifecycle regressions passed"
}

run_cardinality() {
  local failures=0
  local policy
  local scenario

  prepare_binaries
  for policy in close open; do
    for scenario in count-empty count-short count-extra; do
      if ARTIFACT_ROOT="${ARTIFACT_ROOT}/cardinality/${policy}" \
          FAIL_POLICY="${policy}" \
          SKIP_BUILD=1 \
          "${SELF}" "${scenario}"; then
        printf 'PASS %s/%s\n' "${policy}" "${scenario}"
      else
        printf 'FAIL %s/%s (see %s/cardinality/%s/%s)\n' \
          "${policy}" "${scenario}" "${ARTIFACT_ROOT}" "${policy}" "${scenario}" >&2
        failures=$((failures + 1))
      fi
    done
  done
  if (( failures > 0 )); then
    echo "${failures} response-cardinality regression(s) failed" >&2
    return 1
  fi
  log "all response-cardinality regressions passed"
}

run_rendered_values() {
  local failures=0
  local policy

  prepare_binaries
  for policy in close open; do
    if ARTIFACT_ROOT="${ARTIFACT_ROOT}/rendered-values/${policy}" \
        FAIL_POLICY="${policy}" \
        SKIP_BUILD=1 \
        "${SELF}" "rendered-values-${policy}"; then
      printf 'PASS %s/rendered-values\n' "${policy}"
    else
      printf 'FAIL %s/rendered-values (see %s/rendered-values/%s)\n' \
        "${policy}" "${ARTIFACT_ROOT}" "${policy}" >&2
      failures=$((failures + 1))
    fi
  done
  if (( failures > 0 )); then
    echo "${failures} rendered-value policy regression(s) failed" >&2
    return 1
  fi
  log "all rendered-value policy regressions passed"
}

run_admission_contract() {
  local failures=0
  local policy

  prepare_binaries
  for policy in close open; do
    if ARTIFACT_ROOT="${ARTIFACT_ROOT}/admission-contract/${policy}" \
        FAIL_POLICY="${policy}" \
        SKIP_BUILD=1 \
        "${SELF}" "admission-contract-${policy}"; then
      printf 'PASS %s/admission-contract\n' "${policy}"
    else
      printf 'FAIL %s/admission-contract (see %s/admission-contract/%s)\n' \
        "${policy}" "${ARTIFACT_ROOT}" "${policy}" >&2
      failures=$((failures + 1))
    fi
  done
  if (( failures > 0 )); then
    echo "${failures} admission-contract regression(s) failed" >&2
    return 1
  fi
  log "all admission-contract regressions passed"
}

run_protocol_policy() {
  local failures=0
  local policy
  local scenario

  prepare_binaries
  for policy in close open; do
    for scenario in malformed-auth malformed-truncated malformed-request-id; do
      if ARTIFACT_ROOT="${ARTIFACT_ROOT}/protocol/${policy}" \
          FAIL_POLICY="${policy}" \
          SKIP_BUILD=1 \
          "${SELF}" "${scenario}"; then
        printf 'PASS %s/%s\n' "${policy}" "${scenario}"
      else
        printf 'FAIL %s/%s (see %s/protocol/%s/%s)\n' \
          "${policy}" "${scenario}" "${ARTIFACT_ROOT}" "${policy}" "${scenario}" >&2
        failures=$((failures + 1))
      fi
    done
  done
  if (( failures > 0 )); then
    echo "${failures} protocol-policy regression(s) failed" >&2
    return 1
  fi
  log "all protocol-policy regressions passed"
}

run_outage_policy() {
  local failures=0
  local policy

  prepare_binaries
  for policy in close open; do
    if ARTIFACT_ROOT="${ARTIFACT_ROOT}/outage/${policy}" \
        FAIL_POLICY="${policy}" \
        SKIP_BUILD=1 \
        "${SELF}" outage; then
      printf 'PASS %s/outage\n' "${policy}"
    else
      printf 'FAIL %s/outage (see %s/outage/%s/outage)\n' \
        "${policy}" "${ARTIFACT_ROOT}" "${policy}" >&2
      failures=$((failures + 1))
    fi
  done
  if (( failures > 0 )); then
    echo "${failures} outage-policy regression(s) failed" >&2
    return 1
  fi
  log "all outage-policy regressions passed"
}

run_dns_policy() {
  local failures=0
  local policy
  local scenario

  prepare_binaries
  for policy in close open; do
    for scenario in dns-missing-srv dns-bad-target dns-timeout; do
      if ARTIFACT_ROOT="${ARTIFACT_ROOT}/dns/${policy}" \
          FAIL_POLICY="${policy}" \
          SKIP_BUILD=1 \
          "${SELF}" "${scenario}"; then
        printf 'PASS %s/%s\n' "${policy}" "${scenario}"
      else
        printf 'FAIL %s/%s (see %s/dns/%s/%s)\n' \
          "${policy}" "${scenario}" "${ARTIFACT_ROOT}" "${policy}" "${scenario}" >&2
        failures=$((failures + 1))
      fi
    done
  done
  if (( failures > 0 )); then
    echo "${failures} dns-policy regression(s) failed" >&2
    return 1
  fi
  log "all dns-policy regressions passed"
}

run_guard_latency() {
  local failures=0
  local fail_policy
  local scenario

  prepare_binaries
  for scenario in guard-pass guard-deny guard-multiple \
      guard-start-fail-open guard-timeout-fail-open guard-aborted-client; do
    fail_policy=close
    case "${scenario}" in
      guard-start-fail-open|guard-timeout-fail-open|guard-aborted-client)
        fail_policy=open
        ;;
    esac
    if ARTIFACT_ROOT="${ARTIFACT_ROOT}/guard" \
        FAIL_POLICY="${fail_policy}" \
        SKIP_BUILD=1 \
        "${SELF}" "${scenario}"; then
      printf 'PASS %s\n' "${scenario}"
    else
      printf 'FAIL %s (see %s/guard/%s)\n' \
        "${scenario}" "${ARTIFACT_ROOT}" "${scenario}" >&2
      failures=$((failures + 1))
    fi
  done
  if (( failures > 0 )); then
    echo "${failures} guard-latency regression(s) failed" >&2
    return 1
  fi
  log "all guard-latency regressions passed"
}

run_fault_injection() {
  local failures=0
  local fault
  local fault_points=(
    worker-tenant
    worker-secret
    client-create
    post-client-create
    resolver-srv-request
    resolver-srv-name
    resolver-srv-service
    resolver-srv-domain
    resolver-srv-start
    resolver-addr-request
    resolver-addr-name
    resolver-addr-start
    posted-request-drain
    rebind-open
  )

  prepare_binaries
  for fault in "${fault_points[@]}"; do
    if ARTIFACT_ROOT="${ARTIFACT_ROOT}/fault-injection/${fault}" \
        FAULT_POINT="${fault}" \
        FAIL_POLICY=close \
        SKIP_BUILD=1 \
        "${SELF}" fault; then
      printf 'PASS fault/%s\n' "${fault}"
    else
      printf 'FAIL fault/%s (see %s/fault-injection/%s)\n' \
        "${fault}" "${ARTIFACT_ROOT}" "${fault}" >&2
      failures=$((failures + 1))
    fi
  done
  if (( failures > 0 )); then
    echo "${failures} fault-injection regression(s) failed" >&2
    return 1
  fi
  log "all resolver, worker-init, posted-request, and rebind fault injections passed"
}

wait_for_log() {
  local pattern="$1"
  local file="$2"
  local attempts="${3:-100}"
  local attempt

  for (( attempt = 0; attempt < attempts; attempt++ )); do
    if grep -q -- "${pattern}" "${file}" 2>/dev/null; then
      return 0
    fi
    sleep 0.05
  done
  return 1
}

start_dns() {
  log "starting DNS ${DNS_SERVER}:${DNS_PORT} -> ${SERVER_ID}:${RESPONDER_PORT}"
  printf 'normal\n' >"${DNS_STATE_FILE}"
  python3 "${SCRIPT_DIR}/local_dns_server.py" \
    --listen-host "${DNS_SERVER}" \
    --port "${DNS_PORT}" \
    --domain "${DOMAIN}" \
    --state-file "${DNS_STATE_FILE}" \
    --record "${SERVER_ID}:${RESPONDER_PORT}" \
    >"${DNS_LOG}" 2>&1 &
  DNS_PID=$!

  wait_for_log 'local DNS server listening' "${DNS_LOG}" 100 \
    || fail "DNS fixture did not become ready; see ${DNS_LOG}"
  dig @"${DNS_SERVER}" -p "${DNS_PORT}" +short SRV \
    "_ratelimitly._udp.${DOMAIN}" >"${DNS_CHECK_LOG}"
  grep -q "${RESPONDER_PORT}" "${DNS_CHECK_LOG}" \
    || fail "DNS fixture did not return responder port ${RESPONDER_PORT}"
}

set_dns_mode() {
  local mode="$1"

  printf '%s\n' "${mode}" >"${DNS_STATE_FILE}"
  log "DNS mode set to ${mode}"
}

dns_failure_mode() {
  case "${MODE}" in
    dns-missing-srv|guard-start-fail-open) printf 'missing-srv\n' ;;
    dns-bad-target) printf 'bad-target\n' ;;
    dns-timeout) printf 'timeout\n' ;;
    *) return 1 ;;
  esac
}

is_guard_case() {
  case "${MODE}" in
    steering-rebind|guard-pass|guard-deny|guard-multiple|guard-start-fail-open|guard-timeout-fail-open|guard-aborted-client) return 0 ;;
    *) return 1 ;;
  esac
}

start_responder() {
  local scenario="$1"
  local steering="${2:-keep}"
  local delay_ms="${3:-0}"
  local allow_count="${4:-1}"

  stop_responder
  RESPONDER_RUN=$((RESPONDER_RUN + 1))
  RESPONDER_LOG="${ARTIFACT_DIR}/responder-${RESPONDER_RUN}-${scenario}-${steering}.jsonl"
  RESPONDER_ERROR_LOG="${ARTIFACT_DIR}/responder-${RESPONDER_RUN}-${scenario}-${steering}.err"
  : >"${RESPONDER_LOG}"
  : >"${RESPONDER_ERROR_LOG}"
  log "starting responder scenario=${scenario} steering=${steering} delay_ms=${delay_ms}"
  "${RESPONDER_BIN}" \
    "--listen=${RESPONDER_HOST}:${RESPONDER_PORT}" \
    "--scenario=${scenario}" \
    "--server-id=${SERVER_ID}" \
    "--steering=${steering}" \
    "--delay-ms=${delay_ms}" \
    "--allow-count=${allow_count}" \
    >"${RESPONDER_LOG}" 2>"${RESPONDER_ERROR_LOG}" &
  RESPONDER_PID=$!

  wait_for_log '"event":"ready"' "${RESPONDER_LOG}" 100 \
    || fail "responder did not become ready; see ${RESPONDER_ERROR_LOG}"
}

synthetic_auth_key() {
  "${RESPONDER_BIN}" \
    "--listen=${RESPONDER_HOST}:${RESPONDER_PORT}" \
    --print-nginx-config \
    | awk '$1 == "ratelimitly_auth_key" { sub(/;$/, "", $2); print $2; exit }'
}

write_nginx_config() {
  local auth_key
  local debug_mode="on"
  local fault_directive=""
  local guard_defs=""
  local load_module_directive=""
  local ratelimitly_rule="ratelimitly zone=lifecycle_zone;"
  local zone_rate="10000r/s"
  auth_key="$(synthetic_auth_key)"
  [[ -n "${auth_key}" ]] || fail "could not obtain the responder's synthetic nginx key"
  if [[ "${MODE}" == "enforcement-boundary" ]]; then
    zone_rate="${ENFORCEMENT_ALLOW_COUNT}r/h"
  fi
  if [[ "${MODE}" == "udp-ingress-fairness" ]]; then
    debug_mode="off"
  fi
  if is_guard_case; then
    guard_defs='  ratelimitly_guard lifecycle_guard "service=svc:lifecycle:$uri" threshold=100ms ttl=30s max_samples=128 buffer_size=32 min_sample_threshold=0;'
    ratelimitly_rule="ratelimitly zone=lifecycle_zone guard=lifecycle_guard;"
    if [[ "${MODE}" == "guard-multiple" ]]; then
      guard_defs="${guard_defs}"$'\n''  ratelimitly_guard lifecycle_guard_secondary "service=svc:lifecycle:secondary:$uri" threshold=100ms ttl=30s max_samples=128 buffer_size=32 min_sample_threshold=0;'
      ratelimitly_rule="ratelimitly zone=lifecycle_zone guard=lifecycle_guard guard=lifecycle_guard_secondary;"
    fi
  fi
  if [[ -n "${NGINX_LOAD_MODULE}" ]]; then
    load_module_directive="load_module \"${NGINX_LOAD_MODULE}\";"
  fi
  if [[ -n "${FAULT_POINT}" ]]; then
    fault_directive="  ratelimitly_test_fault ${FAULT_POINT};"
  fi
  mkdir -p "${PREFIX}/logs" "${PREFIX}/html/admission-redirect"
  printf 'admission:{PLAIN}secret\n' >"${AUTH_FILE}"
  printf 'admitted through internal redirect\n' \
    >"${PREFIX}/html/admission-redirect/index.html"
  printf 'before <!--# include virtual="/admission-include" --> after\n' \
    >"${PREFIX}/html/admission-posted"
  dd if=/dev/zero of="${PREFIX}/html/steering-latency.bin" \
    bs=8192 count=1 status=none

  cat >"${NGINX_CONF}" <<EOF
${load_module_directive}
daemon off;
master_process on;
worker_processes 1;
pid logs/nginx.pid;
error_log ${NGINX_ERROR_LOG} debug;

events {
  worker_connections 128;
}

http {
  log_format ratelimitly_test '\$status \$ratelimitly_verdict';
  access_log ${NGINX_ACCESS_LOG} ratelimitly_test;
  resolver ${DNS_SERVER}:${DNS_PORT} valid=1s ipv6=off;
  resolver_timeout 1s;

  ratelimitly_dns_srv ${DOMAIN};
  ratelimitly_auth_key ${auth_key};
  ratelimitly_policy standard unit=${REQUEST_POLICY_UNIT};
  ratelimitly_fail ${FAIL_POLICY};
  ratelimitly_debug ${debug_mode};
${fault_directive}

  ratelimitly_zone lifecycle_zone "bucket=lifecycle:\$uri" rate=${zone_rate};
  ratelimitly_zone redirect_zone "bucket=redirect:one-request" rate=10000r/s;
  ratelimitly_zone rendered_bucket_zone "bucket=\$arg_value" rate=10000r/s;
  ratelimitly_zone boundary_zone "bucket=boundary:\$arg_value" rate=10000r/s;
  ratelimitly_guard rendered_service_guard "service=\$arg_value" threshold=100ms ttl=30s max_samples=128 buffer_size=32 min_sample_threshold=0;
  ratelimitly_guard rendered_threshold_guard service=rendered-threshold threshold=\$arg_value ttl=30s max_samples=128 buffer_size=32 min_sample_threshold=0;
${guard_defs}

  server {
    listen ${NGINX_HOST}:${NGINX_PORT};

    location = /health {
      return 204;
    }

    location = /limited {
      ratelimitly_label "LIFECYCLE:\$uri";
      ${ratelimitly_rule}
      root ${RN_ROOT}/tests;
      try_files /ok.txt =404;
    }

    location = /steering-latency {
      ratelimitly_label "STEERING-LATENCY:\$uri";
      ${ratelimitly_rule}
      limit_rate_after 1k;
      limit_rate 4k;
      root ${PREFIX}/html;
      try_files /steering-latency.bin =404;
    }

    location = /rendered-bucket {
      ratelimitly_label "RENDERED-BUCKET";
      ratelimitly zone=rendered_bucket_zone;
      root ${RN_ROOT}/tests;
      try_files /ok.txt =404;
    }

    location = /rendered-service {
      ratelimitly_label "RENDERED-SERVICE";
      ratelimitly zone=redirect_zone guard=rendered_service_guard;
      root ${RN_ROOT}/tests;
      try_files /ok.txt =404;
    }

    location = /rendered-threshold {
      ratelimitly_label "RENDERED-THRESHOLD";
      ratelimitly zone=redirect_zone guard=rendered_threshold_guard;
      root ${RN_ROOT}/tests;
      try_files /ok.txt =404;
    }

    location = /rendered-label {
      ratelimitly_label "\$arg_value";
      ratelimitly zone=redirect_zone;
      root ${RN_ROOT}/tests;
      try_files /ok.txt =404;
    }

    location = /bucket-boundary {
      ratelimitly_label "BUCKET-BOUNDARY";
      ratelimitly zone=boundary_zone;
      root ${RN_ROOT}/tests;
      try_files /ok.txt =404;
    }

    location = /admission-auth {
      satisfy any;
      deny all;
      auth_basic "admission contract";
      auth_basic_user_file ${AUTH_FILE};

      ratelimitly_label "AUTH:\$uri";
      ratelimitly zone=lifecycle_zone;
      root ${RN_ROOT}/tests;
      try_files /ok.txt =404;
    }

    location = /admission-route {
      ratelimitly_label "ROUTE:\$uri";
      ratelimitly zone=lifecycle_zone;
      root ${RN_ROOT}/tests;
      try_files /ok.txt =418;
    }

    location /admission-redirect/ {
      ratelimitly_label "REDIRECT:\$uri";
      ratelimitly zone=redirect_zone;
      root ${PREFIX}/html;
      index index.html;
    }

    location = /admission-subrequest {
      mirror /admission-mirror;
      ratelimitly_label "SUBREQUEST-MAIN:\$uri";
      ratelimitly zone=redirect_zone;
      root ${RN_ROOT}/tests;
      try_files /ok.txt =404;
    }

    location = /admission-posted {
      ratelimitly_label "POSTED:\$uri";
      ratelimitly zone=redirect_zone;
      root ${PREFIX}/html;
      default_type text/html;
      ssi on;
    }

    location = /admission-include {
      internal;
      return 200 "included";
    }

    location = /resolver-override {
      resolver ${DNS_SERVER}:${DNS_BAD_PORT} valid=1s ipv6=off;
      resolver_timeout 5s;
      ratelimitly_label "RESOLVER-SCOPE:\$uri";
      ratelimitly zone=lifecycle_zone;
      root ${RN_ROOT}/tests;
      try_files /ok.txt =404;
    }

    location = /admission-mirror {
      internal;
      ratelimitly_label "SUBREQUEST-MIRROR:\$uri";
      ratelimitly zone=redirect_zone;
      root ${RN_ROOT}/tests;
      try_files /ok.txt =404;
    }
  }
}
EOF
}

worker_pid() {
  ps -o pid=,args= --ppid "${NGINX_PID}" 2>/dev/null \
    | awk '/nginx: worker process/ { print $1; exit }'
}

replacement_worker_pid() {
  ps -o pid=,args= --ppid "${NGINX_PID}" 2>/dev/null \
    | awk -v old="${ORIGINAL_WORKER_PID}" \
        '$1 != old && /nginx: worker process/ { print $1; exit }'
}

worker_udp_port() {
  python3 "${UDP_PORT_HELPER}" "${ORIGINAL_WORKER_PID}"
}

worker_udp_socket_count() {
  python3 "${UDP_PORT_HELPER}" --count "${ORIGINAL_WORKER_PID}"
}

start_nginx() {
  local attempt
  local code

  run_nginx_oneshot -p "${PREFIX}/" -c "${NGINX_CONF}" -t \
    >"${NGINX_CONFIG_LOG}" 2>&1 \
    || fail "nginx configuration failed; see ${NGINX_CONFIG_LOG}"

  log "starting nginx on ${NGINX_HOST}:${NGINX_PORT}"
  "${NGINX_BIN}" -p "${PREFIX}/" -c "${NGINX_CONF}" \
    >"${NGINX_STDOUT_LOG}" 2>&1 &
  NGINX_PID=$!

  for (( attempt = 0; attempt < 100; attempt++ )); do
    if ! kill -0 "${NGINX_PID}" 2>/dev/null; then
      fail "nginx exited during startup; see ${NGINX_ERROR_LOG}"
    fi
    code="$(curl --max-time 1 -s -o /dev/null -w '%{http_code}' \
      "http://${NGINX_HOST}:${NGINX_PORT}/health" || true)"
    if [[ "${code}" == "204" ]]; then
      ORIGINAL_WORKER_PID="$(worker_pid)"
      [[ -n "${ORIGINAL_WORKER_PID}" ]] \
        || fail "could not identify the nginx worker process"
      log "nginx master=${NGINX_PID} worker=${ORIGINAL_WORKER_PID}"
      return 0
    fi
    sleep 0.05
  done
  fail "nginx did not become reachable; see ${NGINX_ERROR_LOG}"
}

request_code() {
  local max_time="${1:-${CLIENT_TIMEOUT_SEC}}"
  request_path_code /limited "${max_time}"
}

request_path_code() {
  local path="$1"
  local max_time="${2:-${CLIENT_TIMEOUT_SEC}}"
  shift 2 || true
  curl --max-time "${max_time}" -s -o /dev/null -w '%{http_code}' \
    "$@" "http://${NGINX_HOST}:${NGINX_PORT}${path}" || true
}

responder_rate_request_count() {
  grep -c '"event":"rate_request"' "${RESPONDER_LOG}" || true
}

warm_client() {
  local attempt
  local code

  for (( attempt = 0; attempt < 100; attempt++ )); do
    code="$(request_code)"
    if [[ "${code}" == "200" ]] \
        && wait_for_log '"event":"rate_request"' "${RESPONDER_LOG}" 20; then
      log "baseline allow succeeded"
      return 0
    fi
    sleep 0.05
  done
  fail "could not warm the RateLimitly client; see ${NGINX_ERROR_LOG}"
}

check_worker_survival() {
  local phase="$1"
  local current=""

  if ! kill -0 "${NGINX_PID}" 2>/dev/null; then
    record_failure "nginx master died after ${phase}"
    return 0
  fi
  current="$(worker_pid)"
  if [[ -z "${current}" ]]; then
    record_failure "nginx has no worker after ${phase}"
  elif [[ "${current}" != "${ORIGINAL_WORKER_PID}" ]]; then
    record_failure "worker restarted after ${phase}: expected ${ORIGINAL_WORKER_PID}, got ${current}"
  else
    log "worker ${current} survived ${phase}"
  fi
}

check_follow_up() {
  local phase="$1"
  local attempt
  local code="000"
  local observed=0

  start_responder allow keep 0
  for (( attempt = 0; attempt < 40; attempt++ )); do
    code="$(request_code)"
    if [[ "${code}" == "200" ]] \
        && wait_for_log '"event":"rate_request"' "${RESPONDER_LOG}" 20; then
      observed=1
      break
    fi
    sleep 0.05
  done
  if [[ "${code}" != "200" || "${observed}" != "1" ]]; then
    record_failure "follow-up request after ${phase} did not complete through the responder (last HTTP ${code})"
  else
    log "follow-up request after ${phase} succeeded"
  fi
  check_worker_survival "${phase} follow-up"
}

check_rebind_follow_up() {
  local phase="$1"
  local assert_deferred="${2:-0}"
  local code
  local error_log_start
  local port_before
  local port_after

  port_before="$(worker_udp_port)" \
    || fail "could not determine the worker UDP port before ${phase}"
  error_log_start="$(wc -l <"${NGINX_ERROR_LOG}")"
  start_responder allow rebind 0
  code="$(request_code)"
  if [[ "${code}" != "200" ]]; then
    record_failure "rebind follow-up after ${phase} returned ${code}, expected 200"
  else
    log "rebind follow-up after ${phase} succeeded"
  fi
  tail -n "+$((error_log_start + 1))" "${NGINX_ERROR_LOG}" \
    >"${ARTIFACT_DIR}/${MODE}-rebind.log"
  if ! grep -q 'steering_feedback=0 (rebind pending)' \
      "${ARTIFACT_DIR}/${MODE}-rebind.log"; then
    record_failure "rebind follow-up after ${phase} did not process steering feedback"
  fi
  if [[ "${assert_deferred}" == "1" ]] \
      && grep -q 'rn: rebind_socket udp_read_active=1' \
        "${ARTIFACT_DIR}/${MODE}-rebind.log"; then
    record_failure "steering closed the UDP connection inside its active read callback"
  fi
  sleep 0.1
  port_after="$(worker_udp_port)" \
    || fail "could not determine the worker UDP port after ${phase}"
  if [[ "${port_after}" == "${port_before}" ]]; then
    record_failure "worker UDP source port did not change after ${phase}: ${port_before}"
  else
    log "worker UDP source port changed after ${phase}: ${port_before} -> ${port_after}"
  fi
  check_worker_survival "${phase} rebind follow-up"
}

check_reload() {
  local attempt
  local code="000"
  local old_worker="${ORIGINAL_WORKER_PID}"
  local new_worker=""

  run_nginx_oneshot -p "${PREFIX}/" -c "${NGINX_CONF}" -s reload \
    >/dev/null 2>&1 \
    || {
      record_failure "nginx reload command failed"
      return 0
    }

  for (( attempt = 0; attempt < 100; attempt++ )); do
    new_worker="$(replacement_worker_pid)"
    if [[ -n "${new_worker}" ]]; then
      break
    fi
    sleep 0.05
  done
  if [[ -z "${new_worker}" ]]; then
    record_failure "nginx did not start a replacement worker during reload"
    return 0
  fi

  for (( attempt = 0; attempt < 100; attempt++ )); do
    if ! kill -0 "${old_worker}" 2>/dev/null; then
      break
    fi
    sleep 0.05
  done
  if kill -0 "${old_worker}" 2>/dev/null; then
    record_failure "old worker ${old_worker} did not exit after reload"
  fi

  ORIGINAL_WORKER_PID="${new_worker}"
  for (( attempt = 0; attempt < 40; attempt++ )); do
    code="$(request_code)"
    if [[ "${code}" == "200" ]]; then
      break
    fi
    sleep 0.05
  done
  if [[ "${code}" != "200" ]]; then
    record_failure "request after nginx reload returned ${code}, expected 200"
  elif ! worker_udp_port >/dev/null; then
    record_failure "replacement worker did not initialize its UDP client"
  else
    log "reload replaced worker ${old_worker} with ${new_worker}; follow-up succeeded"
  fi
}

run_timeout_case() {
  local code
  local error_log_start

  error_log_start="$(wc -l <"${NGINX_ERROR_LOG}")"

  start_responder drop keep 0
  code="$(request_code)"
  if [[ "${code}" != "429" ]]; then
    record_failure "timeout trigger returned ${code}, expected fail-close 429"
  fi
  wait_for_log '"disposition":"dropped"' "${RESPONDER_LOG}" 20 \
    || record_failure "drop responder did not observe the timeout request"
  if ! rn_expect_log_count "${RESPONDER_LOG}" \
      '"event":"rate_request"' 2; then
    record_failure "timeout policy did not send exactly one initial request and one replay"
  fi
  sleep 0.2
  tail -n "+$((error_log_start + 1))" "${NGINX_ERROR_LOG}" \
    >"${ARTIFACT_DIR}/timeout-trigger.log"
  if ! rn_expect_log_count "${ARTIFACT_DIR}/timeout-trigger.log" \
      'rn: result error status=-2' 1; then
    record_failure "timeout trigger did not produce exactly one C-client timeout completion"
  fi
  check_worker_survival "timeout callback"
  check_follow_up "timeout callback"
}

run_aborted_client_case() {
  local abort_log_start

  start_responder allow keep 2000
  abort_log_start="$(wc -l <"${NGINX_ERROR_LOG}")"
  log "resetting ${ABORT_REQUESTS} clients before the delayed response"
  python3 "${ABORT_CLIENT_HELPER}" \
    --host "${NGINX_HOST}" \
    --port "${NGINX_PORT}" \
    --requests "${ABORT_REQUESTS}"
  wait_for_log '"event":"rate_request"' "${RESPONDER_LOG}" 40 \
    || record_failure "delayed responder did not observe an aborted request"
  sleep 0.5
  tail -n "+$((abort_log_start + 1))" "${NGINX_ERROR_LOG}" \
    >"${ARTIFACT_DIR}/aborted-client-trigger.log"
  if ! rn_expect_log_count "${ARTIFACT_DIR}/aborted-client-trigger.log" \
      'rn: result error status=-2' 0; then
    record_failure "an aborted request reached the C-client timeout callback after cleanup"
  fi
  if [[ "${MODE}" == "guard-aborted-client" ]] \
      && grep -q '"event":"latency_report"' "${RESPONDER_LOG}"; then
    record_failure "client abort without an admission verdict sent a latency report"
  fi
  if [[ "${MODE}" == "guard-aborted-client" ]] \
      && grep -q 'rn: latency_report' "${ARTIFACT_DIR}/aborted-client-trigger.log"; then
    record_failure "client abort without an admission verdict attempted a latency report"
  fi
  check_worker_survival "aborted-client cleanup and timer expiry"
  check_rebind_follow_up "aborted-client cleanup"
  check_follow_up "aborted-client cleanup"
}

run_udp_ingress_fairness_case() {
  local code
  local flood_log="${ARTIFACT_DIR}/udp-flood.jsonl"
  local port

  port="$(worker_udp_port)" \
    || fail "could not determine the UDP port before the ingress flood"
  python3 "${UDP_FLOOD_HELPER}" \
    --host "${NGINX_HOST}" \
    --port "${port}" \
    --duration 2 \
    --workers 32 \
    >"${flood_log}" 2>&1 &
  FLOOD_PID=$!

  wait_for_log '"event": "ready"' "${flood_log}" 40 \
    || fail "UDP flood fixture did not become ready; see ${flood_log}"
  kill -0 "${FLOOD_PID}" 2>/dev/null \
    || fail "UDP flood fixture exited before the fairness probe"

  code="$(request_path_code /health 0.5)"
  if [[ "${code}" != "204" ]]; then
    record_failure "health request under sustained invalid UDP ingress returned ${code}, expected 204"
  elif ! kill -0 "${FLOOD_PID}" 2>/dev/null; then
    record_failure "health request completed only after the UDP flood ended"
  else
    log "HTTP processing remained live during sustained invalid UDP ingress"
  fi
  if ! wait "${FLOOD_PID}"; then
    record_failure "UDP flood fixture failed; see ${flood_log}"
  fi
  FLOOD_PID=""
  wait_for_log '"event": "complete"' "${flood_log}" 20 \
    || record_failure "UDP flood fixture did not record its send count"
  check_worker_survival "bounded UDP receive processing"
  check_follow_up "bounded UDP receive processing"
}

check_rebind_latency_report() {
  local attempt
  local code="000"
  local code_file="${ARTIFACT_DIR}/steering-latency-code.txt"
  local error_log_start
  local port_after=""
  local port_before
  local current_port
  local rebind_log="${ARTIFACT_DIR}/steering-latency-rebind.log"

  port_before="$(worker_udp_port)" \
    || fail "could not determine the UDP port before the guarded steering request"
  error_log_start="$(wc -l <"${NGINX_ERROR_LOG}")"
  start_responder guard-pass rebind 0

  curl --max-time 5 -s -o /dev/null -w '%{http_code}' \
    "http://${NGINX_HOST}:${NGINX_PORT}/steering-latency" \
    >"${code_file}" &
  HTTP_PROBE_PID=$!

  wait_for_log '"event":"rate_request"' "${RESPONDER_LOG}" 40 \
    || record_failure "guarded steering responder did not observe the rate request"
  for (( attempt = 0; attempt < 100; attempt++ )); do
    current_port="$(worker_udp_port 2>/dev/null || true)"
    if [[ -n "${current_port}" && "${current_port}" != "${port_before}" ]]; then
      port_after="${current_port}"
      break
    fi
    sleep 0.02
  done
  if [[ -z "${port_after}" ]]; then
    record_failure "guarded steering request did not replace UDP source port ${port_before} before content completed"
  else
    log "guarded steering request changed UDP source port: ${port_before} -> ${port_after}"
  fi

  if ! wait "${HTTP_PROBE_PID}"; then
    record_failure "guarded steering HTTP request failed"
  fi
  HTTP_PROBE_PID=""
  if [[ -s "${code_file}" ]]; then
    code="$(<"${code_file}")"
  fi
  if [[ "${code}" != "200" ]]; then
    record_failure "guarded steering HTTP request returned ${code}, expected 200"
  fi

  wait_for_log '"event":"latency_report"' "${RESPONDER_LOG}" 40 \
    || record_failure "guarded steering request did not send its independent latency report"
  tail -n "+$((error_log_start + 1))" "${NGINX_ERROR_LOG}" >"${rebind_log}"
  if ! awk '
      /rn: UDP source socket rebound/ && rebound == 0 { rebound = NR }
      /rn: latency_report count=/ && report == 0 { report = NR }
      END { exit(rebound > 0 && report > rebound ? 0 : 1) }
    ' "${rebind_log}"; then
    record_failure "guarded steering did not complete source-port replacement before attempting its latency report"
  fi
  if ! awk '
      /"event":"rate_request"/ { rate_count++; rate_sequence = index($0, "\"sequence\":1") }
      /"event":"latency_report"/ { report_count++; report_sequence = index($0, "\"sequence\":2") }
      END {
        ok = rate_count == 1 && report_count == 1 && rate_sequence && report_sequence
        exit(ok ? 0 : 1)
      }
    ' "${RESPONDER_LOG}"; then
    record_failure "guarded steering did not produce exactly one rate request followed by one independent latency report"
  else
    log "latency report succeeded after the worker completed its steering rebind"
  fi
  check_worker_survival "steering before independent latency reporting"
}

run_steering_rebind_case() {
  check_rebind_latency_report
  check_rebind_follow_up "steering trigger" 1
  check_follow_up "steering rebind"
}

run_outage_case() {
  local access_log_start
  local code
  local error_log_start
  local expected_code

  if [[ "${FAIL_POLICY}" == "open" ]]; then
    expected_code="200"
  else
    expected_code="429"
  fi

  access_log_start="$(wc -l <"${NGINX_ACCESS_LOG}")"
  error_log_start="$(wc -l <"${NGINX_ERROR_LOG}")"
  start_responder drop keep 0
  code="$(request_code)"
  if [[ "${code}" == "000" ]]; then
    record_failure "outage with fail-${FAIL_POLICY} caused a transport error"
  elif [[ "${code}" != "${expected_code}" ]]; then
    record_failure "outage with fail-${FAIL_POLICY} returned ${code}, expected ${expected_code}"
  fi
  wait_for_log '"disposition":"dropped"' "${RESPONDER_LOG}" 20 \
    || record_failure "drop responder did not observe the outage request"
  sleep 0.2
  tail -n "+$((error_log_start + 1))" "${NGINX_ERROR_LOG}" \
    >"${ARTIFACT_DIR}/outage-trigger.log"
  if ! grep -q 'rn: result error status=-2' "${ARTIFACT_DIR}/outage-trigger.log"; then
    record_failure "outage did not complete through the C-client timeout callback"
  fi
  tail -n "+$((access_log_start + 1))" "${NGINX_ACCESS_LOG}" \
    >"${ARTIFACT_DIR}/outage-verdict.log"
  if ! grep -qx "${expected_code} -" "${ARTIFACT_DIR}/outage-verdict.log"; then
    record_failure "fail-${FAIL_POLICY} outage was not logged without a valid verdict"
  fi
  check_worker_survival "outage fail-${FAIL_POLICY} decision"
  check_follow_up "outage fail-${FAIL_POLICY} decision"
}

run_dns_failure_case() {
  local code
  local dns_mode
  local expected_code
  local phase

  dns_mode="$(dns_failure_mode)" || fail "unknown DNS failure mode: ${MODE}"
  case "${dns_mode}" in
    missing-srv) phase="missing SRV" ;;
    bad-target) phase="unresolvable SRV target" ;;
    timeout) phase="DNS timeout" ;;
  esac

  if [[ "${FAIL_POLICY}" == "open" ]]; then
    expected_code="200"
  else
    expected_code="429"
  fi

  code="$(request_code)"
  if [[ "${code}" == "000" ]]; then
    record_failure "${phase} with fail-${FAIL_POLICY} caused a transport error"
  elif [[ "${code}" != "${expected_code}" ]]; then
    record_failure "${phase} with fail-${FAIL_POLICY} returned ${code}, expected ${expected_code}"
  fi
  check_worker_survival "${phase} fail-${FAIL_POLICY} decision"

  set_dns_mode normal
  if [[ "${dns_mode}" == "timeout" ]]; then
    sleep "${DNS_TIMEOUT_RECOVERY_SEC}"
  else
    sleep "${DNS_REFRESH_SEC}"
  fi
  check_follow_up "${phase} fail-${FAIL_POLICY} recovery"
}

run_guard_case() {
  local code
  local error_log_start
  local expected_code
  local expected_guards
  local expected_rate_requests
  local expected_reports
  local expect_rate_request
  local scenario

  expected_code="200"
  expected_guards=1
  expected_rate_requests=1
  expected_reports=1
  expect_rate_request=1
  scenario="${MODE}"

  case "${MODE}" in
    guard-pass)
      scenario="guard-pass"
      ;;
    guard-deny)
      scenario="guard-deny"
      expected_code="429"
      expected_reports=0
      ;;
    guard-multiple)
      scenario="guard-pass"
      expected_guards=2
      expected_reports=2
      ;;
    guard-start-fail-open)
      scenario="allow"
      expected_reports=0
      expect_rate_request=0
      ;;
    guard-timeout-fail-open)
      scenario="drop"
      expected_rate_requests=2
      expected_reports=0
      ;;
  esac

  error_log_start="$(wc -l <"${NGINX_ERROR_LOG}")"
  start_responder "${scenario}" keep 0
  code="$(request_code)"
  if [[ "${code}" != "${expected_code}" ]]; then
    record_failure "${MODE} returned ${code}, expected ${expected_code}"
  fi
  if (( expect_rate_request > 0 )); then
    wait_for_log '"event":"rate_request"' "${RESPONDER_LOG}" 20 \
      || record_failure "${MODE} responder did not observe the rate request"
  elif grep -q '"event":"rate_request"' "${RESPONDER_LOG}"; then
    record_failure "${MODE} unexpectedly reached the responder"
  fi
  if (( expect_rate_request > 0 )) && ! awk \
      -v expected="${expected_rate_requests}" \
      -v guards="${expected_guards}" '
      /"event":"rate_request"/ {
        count++
        if (index($0, "\"guards\":" guards ",\"resources\":1,") == 0) bad = 1
      }
      END { exit count == expected && !bad ? 0 : 1 }
    ' "${RESPONDER_LOG}"; then
    record_failure "${MODE} did not send the expected guard/resource request shape"
  fi

  if (( expected_reports > 0 )); then
    wait_for_log '"event":"latency_report"' "${RESPONDER_LOG}" 40 \
      || record_failure "${MODE} did not send a post-response latency report"
    if ! awk -v reports="${expected_reports}" '
        /"event":"latency_report"/ {
          count++
          if (index($0, "\"reports\":" reports) == 0) bad = 1
        }
        END { exit count == 1 && !bad ? 0 : 1 }
      ' "${RESPONDER_LOG}"; then
      record_failure "${MODE} latency report did not contain the expected report count"
    fi
  else
    sleep 0.2
    tail -n "+$((error_log_start + 1))" "${NGINX_ERROR_LOG}" \
      >"${ARTIFACT_DIR}/guard-trigger.log"
    if grep -q '"event":"latency_report"' "${RESPONDER_LOG}"; then
      record_failure "${MODE} sent a latency report without a valid allow verdict"
    fi
    if grep -q 'rn: latency_report' "${ARTIFACT_DIR}/guard-trigger.log"; then
      record_failure "${MODE} attempted a latency report without a valid allow verdict"
    fi
  fi

  if [[ "${MODE}" == "guard-start-fail-open" ]]; then
    if ! grep -q 'rn: async_start_failed' "${NGINX_ERROR_LOG}"; then
      record_failure "${MODE} did not exercise asynchronous request startup failure"
    fi
    set_dns_mode normal
    sleep "${DNS_REFRESH_SEC}"
  elif [[ "${MODE}" == "guard-timeout-fail-open" ]] \
      && ! grep -q 'rn: result error status=-2' "${NGINX_ERROR_LOG}"; then
    record_failure "${MODE} did not complete through the timeout callback"
  fi

  check_worker_survival "${MODE} decision"
  check_follow_up "${MODE} decision"
}

run_malformed_protocol_case() {
  local code
  local error_log_start
  local expected_code

  if [[ "${FAIL_POLICY}" == "open" ]]; then
    expected_code="200"
  else
    expected_code="429"
  fi

  error_log_start="$(wc -l <"${NGINX_ERROR_LOG}")"
  start_responder "${MODE}" keep 0
  code="$(request_code)"
  if [[ "${code}" == "000" ]]; then
    record_failure "${MODE} with fail-${FAIL_POLICY} caused a transport error"
  elif [[ "${code}" != "${expected_code}" ]]; then
    record_failure "${MODE} with fail-${FAIL_POLICY} returned ${code}, expected ${expected_code}"
  fi
  wait_for_log "\"disposition\":\"${MODE}\"" "${RESPONDER_LOG}" 20 \
    || record_failure "${MODE} responder did not observe the malformed-response request"
  sleep 0.2
  tail -n "+$((error_log_start + 1))" "${NGINX_ERROR_LOG}" \
    >"${ARTIFACT_DIR}/${MODE}-trigger.log"
  if ! grep -q 'rn: result error status=' "${ARTIFACT_DIR}/${MODE}-trigger.log"; then
    record_failure "${MODE} did not complete through the C-client error callback"
  fi
  if grep -q 'rn: result success=' "${ARTIFACT_DIR}/${MODE}-trigger.log"; then
    record_failure "${MODE} logged the malformed response as a valid result"
  fi
  check_worker_survival "${MODE} fail-${FAIL_POLICY} decision"
  check_follow_up "${MODE} fail-${FAIL_POLICY} decision"
}

run_enforcement_boundary_case() {
  local access_log_start
  local code
  local event_count
  local request_number
  local expected_code

  access_log_start="$(wc -l <"${NGINX_ACCESS_LOG}")"
  start_responder quota keep 0 "${ENFORCEMENT_ALLOW_COUNT}"
  for (( request_number = 1; request_number <= ENFORCEMENT_TOTAL_REQUESTS;
      request_number++ )); do
    if (( request_number <= ENFORCEMENT_ALLOW_COUNT )); then
      expected_code="200"
    else
      expected_code="429"
    fi
    code="$(request_code)"
    if [[ "${code}" != "${expected_code}" ]]; then
      record_failure "request ${request_number}/${ENFORCEMENT_TOTAL_REQUESTS} returned ${code}, expected ${expected_code}"
    fi
  done

  event_count="$(grep -c '"event":"rate_request"' "${RESPONDER_LOG}" || true)"
  if [[ "${event_count}" != "${ENFORCEMENT_TOTAL_REQUESTS}" ]]; then
    record_failure "quota responder observed ${event_count} rate requests, expected ${ENFORCEMENT_TOTAL_REQUESTS}"
  fi
  if ! awk -v expected="${ENFORCEMENT_TOTAL_REQUESTS}" '
      /"event":"rate_request"/ {
        count++
        if (index($0, "\"sequence\":" count) == 0) bad = 1
        if (index($0, "\"guards\":0,\"resources\":1,") == 0) bad = 1
      }
      END { exit count == expected && !bad ? 0 : 1 }
    ' "${RESPONDER_LOG}"; then
    record_failure "quota responder events were not the exact ordered one-resource sequence"
  fi
  tail -n "+$((access_log_start + 1))" "${NGINX_ACCESS_LOG}" \
    >"${ARTIFACT_DIR}/enforcement-verdicts.log"
  if [[ "$(grep -c '^200 allow$' "${ARTIFACT_DIR}/enforcement-verdicts.log" || true)" \
      != "${ENFORCEMENT_ALLOW_COUNT}" ]]; then
    record_failure "access log did not expose one valid allow verdict per admitted request"
  fi
  if [[ "$(grep -c '^429 deny$' "${ARTIFACT_DIR}/enforcement-verdicts.log" || true)" \
      != "$((ENFORCEMENT_TOTAL_REQUESTS - ENFORCEMENT_ALLOW_COUNT))" ]]; then
    record_failure "access log did not expose one valid deny verdict per rejected request"
  fi

  log "exact boundary passed: ${ENFORCEMENT_ALLOW_COUNT} allow, $((ENFORCEMENT_TOTAL_REQUESTS - ENFORCEMENT_ALLOW_COUNT)) deny"
  check_worker_survival "exact enforcement boundary"
  check_follow_up "exact enforcement boundary"
}

run_rendered_values_case() {
  local after
  local before
  local code
  local expected_failure_code
  local log_start
  local max_identifier
  local max_label
  local oversized_identifier
  local oversized_label
  local -a failure_markers
  local -a failure_paths
  local -a failure_values
  local index

  if [[ "${FAIL_POLICY}" == "open" ]]; then
    expected_failure_code="200"
  else
    expected_failure_code="429"
  fi
  printf -v max_identifier '%*s' 1024 ''
  max_identifier="${max_identifier// /i}"
  oversized_identifier="${max_identifier}i"
  printf -v max_label '%*s' 256 ''
  max_label="${max_label// /l}"
  oversized_label="${max_label}l"

  failure_paths=(
    /rendered-bucket
    /rendered-service
    /rendered-bucket
    /rendered-service
    /rendered-label
    /rendered-threshold
  )
  failure_values=(
    ""
    ""
    "${oversized_identifier}"
    "${oversized_identifier}"
    "${oversized_label}"
    0
  )
  failure_markers=(
    'rn: zone_build_failed zone=rendered_bucket_zone'
    'rn: guard_build_failed guard=rendered_service_guard'
    'rn: zone_build_failed zone=rendered_bucket_zone'
    'rn: guard_build_failed guard=rendered_service_guard'
    'rn: label_build_failed uri=/ok.txt reason=too_long len=257 max=256'
    'rn: guard_build_failed guard=rendered_threshold_guard'
  )

  for index in "${!failure_paths[@]}"; do
    before="$(responder_rate_request_count)"
    log_start="$(wc -l <"${NGINX_ERROR_LOG}")"
    if [[ -n "${failure_values[index]}" ]]; then
      code="$(request_path_code \
        "${failure_paths[index]}?value=${failure_values[index]}" \
        "${CLIENT_TIMEOUT_SEC}")"
    else
      code="$(request_path_code "${failure_paths[index]}" \
        "${CLIENT_TIMEOUT_SEC}")"
    fi
    if [[ "${code}" != "${expected_failure_code}" ]]; then
      record_failure "${failure_paths[index]} invalid value returned ${code}, expected fail-${FAIL_POLICY} ${expected_failure_code}"
    fi
    after="$(responder_rate_request_count)"
    if [[ "${after}" != "${before}" ]]; then
      record_failure "${failure_paths[index]} invalid value reached the responder"
    fi
    tail -n "+$((log_start + 1))" "${NGINX_ERROR_LOG}" \
      >"${ARTIFACT_DIR}/rendered-value-${index}.log"
    if ! grep -Fq "${failure_markers[index]}" \
        "${ARTIFACT_DIR}/rendered-value-${index}.log"; then
      record_failure "${failure_paths[index]} invalid value did not record its build failure"
    fi
  done

  before="$(responder_rate_request_count)"
  code="$(request_path_code "/rendered-label" "${CLIENT_TIMEOUT_SEC}")"
  [[ "${code}" == "200" ]] \
    || record_failure "empty optional label returned ${code}, expected 200"
  wait_for_log '"label":""' "${RESPONDER_LOG}" 20 \
    || record_failure "empty optional label was not omitted at the responder"
  code="$(request_path_code "/rendered-bucket?value=${max_identifier}" \
    "${CLIENT_TIMEOUT_SEC}")"
  [[ "${code}" == "200" ]] \
    || record_failure "1024-byte bucket returned ${code}, expected 200"
  code="$(request_path_code "/rendered-service?value=${max_identifier}" \
    "${CLIENT_TIMEOUT_SEC}")"
  [[ "${code}" == "200" ]] \
    || record_failure "1024-byte service returned ${code}, expected 200"
  code="$(request_path_code "/rendered-label?value=${max_label}" \
    "${CLIENT_TIMEOUT_SEC}")"
  [[ "${code}" == "200" ]] \
    || record_failure "256-byte label returned ${code}, expected 200"
  code="$(request_path_code "/rendered-threshold?value=1" \
    "${CLIENT_TIMEOUT_SEC}")"
  [[ "${code}" == "200" ]] \
    || record_failure "unitless one-second threshold returned ${code}, expected 200"
  wait_for_log 'rn: guard=rendered_threshold_guard .* threshold_ms=1000' \
    "${NGINX_ERROR_LOG}" 20 \
    || record_failure "unitless threshold did not render as 1000ms"
  code="$(request_path_code "/bucket-boundary?value=known-bucket" \
    "${CLIENT_TIMEOUT_SEC}")"
  [[ "${code}" == "200" ]] \
    || record_failure "known bucket boundary request returned ${code}, expected 200"
  wait_for_log 'rn: bucket zone=boundary_zone id=98300f8a73dd010d75b92ce8d2298cc7' \
    "${NGINX_ERROR_LOG}" 20 \
    || record_failure "known bucket did not produce the locked wire identifier"
  after="$(responder_rate_request_count)"
  if [[ "${after}" != "$((before + 6))" ]]; then
    record_failure "valid boundary requests produced $((after - before)) responder events, expected 6"
  fi

  check_worker_survival "rendered-value fail-${FAIL_POLICY} policy"
  check_follow_up "rendered-value fail-${FAIL_POLICY} policy"
}

run_admission_contract_case() {
  local after
  local before
  local code

  before="$(responder_rate_request_count)"
  code="$(request_path_code /admission-auth "${CLIENT_TIMEOUT_SEC}")"
  if [[ "${code}" != "401" ]]; then
    record_failure "unauthenticated satisfy-any request returned ${code}, expected 401"
  fi
  sleep 0.1
  after="$(responder_rate_request_count)"
  if [[ "${after}" != "${before}" ]]; then
    record_failure "unauthenticated request consumed RateLimitly admission: ${before} -> ${after}"
  else
    log "unauthenticated request was rejected before RateLimitly admission"
  fi

  before="${after}"
  code="$(request_path_code /admission-auth "${CLIENT_TIMEOUT_SEC}" \
    --user admission:secret)"
  if [[ "${code}" != "200" ]]; then
    record_failure "authenticated satisfy-any request returned ${code}, expected 200"
  fi
  wait_for_log '"label":"AUTH:/ok.txt"' "${RESPONDER_LOG}" 20 \
    || record_failure "authenticated request did not reach RateLimitly after try_files"
  after="$(responder_rate_request_count)"
  if [[ "${after}" != "$((before + 1))" ]]; then
    record_failure "authenticated request produced ${after} RateLimitly events, expected $((before + 1))"
  else
    log "authenticated request consumed exactly one admission and reached content"
  fi

  before="${after}"
  code="$(request_path_code /admission-route "${CLIENT_TIMEOUT_SEC}")"
  if [[ "${code}" != "200" ]]; then
    record_failure "pre-content routing request returned ${code}, expected 200"
  fi
  wait_for_log '"label":"ROUTE:/ok.txt"' "${RESPONDER_LOG}" 20 \
    || record_failure "RateLimitly ran before try_files selected /ok.txt"
  after="$(responder_rate_request_count)"
  if [[ "${after}" != "$((before + 1))" ]]; then
    record_failure "routed request produced ${after} RateLimitly events, expected $((before + 1))"
  else
    log "try_files completed before the final RateLimitly admission"
  fi

  before="${after}"
  code="$(request_path_code /admission-redirect/ "${CLIENT_TIMEOUT_SEC}")"
  if [[ "${code}" != "200" ]]; then
    record_failure "internal-redirect request returned ${code}, expected 200"
  fi
  wait_for_log '"label":"REDIRECT:/admission-redirect/' \
    "${RESPONDER_LOG}" 20 \
    || record_failure "internal-redirect request did not reach RateLimitly admission"
  sleep 0.1
  after="$(responder_rate_request_count)"
  if [[ "${after}" != "$((before + 1))" ]]; then
    record_failure "one internally redirected request produced $((after - before)) RateLimitly events, expected 1"
  else
    log "internal redirect preserved exactly one RateLimitly admission"
  fi

  before="${after}"
  code="$(request_path_code /admission-subrequest "${CLIENT_TIMEOUT_SEC}")"
  if [[ "${code}" != "200" ]]; then
    record_failure "request with mirrored subrequest returned ${code}, expected 200"
  fi
  wait_for_log '"label":"SUBREQUEST-MAIN:/ok.txt"' \
    "${RESPONDER_LOG}" 20 \
    || record_failure "main mirrored request did not reach RateLimitly admission"
  sleep 0.1
  after="$(responder_rate_request_count)"
  if [[ "${after}" != "$((before + 1))" ]]; then
    record_failure "one request with a mirrored subrequest produced $((after - before)) RateLimitly events, expected 1"
  elif grep -q '"label":"SUBREQUEST-MIRROR:' "${RESPONDER_LOG}"; then
    record_failure "mirrored subrequest consumed RateLimitly admission"
  else
    log "subrequest did not create an independent RateLimitly admission"
  fi

  start_responder deny keep 0
  before="$(responder_rate_request_count)"
  code="$(request_path_code /admission-redirect/ "${CLIENT_TIMEOUT_SEC}")"
  if [[ "${code}" != "429" ]]; then
    record_failure "denied internal-redirect request returned ${code}, expected 429"
  fi
  wait_for_log '"event":"rate_request"' "${RESPONDER_LOG}" 20 \
    || record_failure "deny responder did not observe the internal-redirect request"
  sleep 0.1
  after="$(responder_rate_request_count)"
  if [[ "${after}" != "$((before + 1))" ]]; then
    record_failure "denied internal-redirect request produced $((after - before)) RateLimitly events, expected 1"
  else
    log "RateLimitly denial stopped content before the internal redirect"
  fi

  code="$(request_path_code /admission-auth "${CLIENT_TIMEOUT_SEC}" \
    --user admission:secret)"
  if [[ "${code}" != "429" ]]; then
    record_failure "authenticated RateLimitly deny returned ${code}, expected 429"
  fi
  wait_for_log '"event":"rate_request"' "${RESPONDER_LOG}" 20 \
    || record_failure "deny responder did not observe the authorized request"
  log "RateLimitly deny remained the final admission decision"

  start_responder drop keep 0
  before="$(responder_rate_request_count)"
  code="$(request_path_code /admission-redirect/ "${CLIENT_TIMEOUT_SEC}")"
  if [[ "${FAIL_POLICY}" == "open" ]]; then
    if [[ "${code}" != "200" ]]; then
      record_failure "fail-open internal-redirect request returned ${code}, expected 200"
    fi
  elif [[ "${code}" != "429" ]]; then
    record_failure "fail-close internal-redirect request returned ${code}, expected 429"
  fi
  wait_for_log '"disposition":"dropped"' "${RESPONDER_LOG}" 20 \
    || record_failure "drop responder did not observe the internal-redirect request"
  sleep 0.1
  after="$(responder_rate_request_count)"
  if [[ "${after}" != "$((before + 2))" ]]; then
    record_failure "dependency-error internal-redirect request produced $((after - before)) RateLimitly transmissions, expected initial send plus one replay"
  else
    log "fail-${FAIL_POLICY} outcome preserved one logical admission with its configured replay"
  fi

  check_worker_survival "pre-content admission contract"
  check_follow_up "pre-content admission contract"
}

run_count_mismatch_case() {
  local code
  local error_log_start
  local expected_code

  if [[ "${FAIL_POLICY}" == "open" ]]; then
    expected_code="200"
  else
    expected_code="429"
  fi

  error_log_start="$(wc -l <"${NGINX_ERROR_LOG}")"
  start_responder "${MODE}" keep 0
  code="$(request_code)"
  if [[ "${code}" != "${expected_code}" ]]; then
    record_failure "${MODE} with fail-${FAIL_POLICY} returned ${code}, expected ${expected_code}"
  fi
  wait_for_log '"event":"rate_request"' "${RESPONDER_LOG}" 20 \
    || record_failure "${MODE} responder did not observe the request"
  tail -n "+$((error_log_start + 1))" "${NGINX_ERROR_LOG}" \
    >"${ARTIFACT_DIR}/${MODE}-trigger.log"
  if ! grep -q 'rn: response_cardinality_mismatch' \
      "${ARTIFACT_DIR}/${MODE}-trigger.log"; then
    record_failure "${MODE} did not record a response-cardinality mismatch"
  fi
  if grep -q 'rn: result success=' "${ARTIFACT_DIR}/${MODE}-trigger.log"; then
    record_failure "${MODE} logged the mismatched response as a valid result"
  fi
  check_worker_survival "${MODE} fail-${FAIL_POLICY} decision"
  check_follow_up "${MODE} fail-${FAIL_POLICY} decision"
}

run_worker_resolver_scope_case() {
  local attempt
  local before
  local after
  local code

  before="$(responder_rate_request_count)"
  code="$(request_path_code /resolver-override "${CLIENT_TIMEOUT_SEC}")"
  for (( attempt = 0; attempt < 40 && code != 200; attempt++ )); do
    sleep 0.05
    code="$(request_path_code /resolver-override "${CLIENT_TIMEOUT_SEC}")"
  done
  if [[ "${code}" != "200" ]]; then
    record_failure "worker stayed pinned to the location resolver: returned ${code}, expected same-worker recovery through the HTTP-scope resolver"
  fi
  wait_for_log '"label":"RESOLVER-SCOPE:/ok.txt"' \
    "${RESPONDER_LOG}" 40 \
    || record_failure "HTTP-scope resolver did not deliver the first rate request"
  wait_for_log 'rn: resolve_srv start .* timeout_ms=1000' \
    "${NGINX_ERROR_LOG}" 40 \
    || record_failure "resolver context did not receive the HTTP-scope resolver_timeout"
  sleep 0.1
  after="$(responder_rate_request_count)"
  if [[ "${after}" != "$((before + 1))" ]]; then
    record_failure "resolver-scope request produced $((after - before)) RateLimitly events, expected 1"
  else
    log "HTTP-scope resolver and timeout won independently of request location"
  fi
  check_worker_survival "deterministic worker resolver selection"
  check_follow_up "deterministic worker resolver selection"
}

run_fault_case() {
  local attempt
  local code
  local count
  local expected_count=1
  local fault_count_before
  local fault_count_after
  local worker_init_fault=0
  local port_before
  local port_after

  [[ -n "${FAULT_POINT}" ]] || fail "fault mode requires FAULT_POINT"

  if [[ "${FAULT_POINT}" == "rebind-open" ]]; then
    port_before="$(worker_udp_port)" \
      || fail "could not determine the UDP port before failed rebind"
    start_responder allow rebind 0
    code="$(request_code)"
    if [[ "${code}" != "200" ]]; then
      record_failure "failed-rebind trigger returned ${code}, expected 200"
    fi
    wait_for_log 'UDP socket rebind failed; retaining current endpoint' \
      "${NGINX_ERROR_LOG}" 40 \
      || record_failure "failed rebind did not report endpoint retention"
    sleep 1.2
    if (( $(grep -c 'UDP socket rebind failed; retaining current endpoint' \
        "${NGINX_ERROR_LOG}" || true) < 2 )); then
      record_failure "failed rebind did not execute its bounded retry"
    fi
    port_after="$(worker_udp_port)" \
      || fail "could not determine the UDP port after failed rebind"
    if [[ "${port_after}" != "${port_before}" ]]; then
      record_failure "failed rebind replaced the live endpoint: ${port_before} -> ${port_after}"
    else
      log "failed rebind retained UDP source port ${port_before}"
    fi
    check_follow_up "failed transactional rebind"
  elif [[ "${FAULT_POINT}" == "posted-request-drain" ]]; then
    local before
    local after
    local response_body="${ARTIFACT_DIR}/posted-request-body.txt"

    before="$(responder_rate_request_count)"
    code="$(curl --max-time 1 -s -o "${response_body}" -w '%{http_code}' \
      "http://${NGINX_HOST}:${NGINX_PORT}/admission-posted" || true)"
    if [[ "${code}" != "200" ]]; then
      record_failure "SSI request with a posted subrequest returned ${code}, expected 200 without a later client event"
    elif ! grep -Fq 'before included after' "${response_body}"; then
      record_failure "SSI request completed without the posted subrequest body"
    fi
    wait_for_log '"event":"rate_request"' "${RESPONDER_LOG}" 20 \
      || record_failure "posted-request-drain responder did not observe the request"
    sleep 0.1
    after="$(responder_rate_request_count)"
    if [[ "${after}" != "$((before + 1))" ]]; then
      record_failure "SSI request with a posted subrequest produced $((after - before)) RateLimitly events, expected 1"
    elif [[ "${code}" == "200" ]]; then
      log "asynchronous verdict drained the posted subrequest in the same event cycle"
    fi
    check_worker_survival "posted-request drain"
    check_follow_up "posted-request drain"
  else
    case "${FAULT_POINT}" in
      worker-tenant|worker-secret|client-create|post-client-create)
        expected_count=0
        worker_init_fault=1
        ;;
    esac

    for (( attempt = 1; attempt <= 8; attempt++ )); do
      code="$(request_code)"
      if ! rn_expect_http_status "${code}" 429; then
        record_failure "${FAULT_POINT} attempt ${attempt} returned ${code}, expected fail-close 429"
      fi
      check_worker_survival "${FAULT_POINT} attempt ${attempt}"
      count="$(worker_udp_socket_count)" \
        || fail "could not count worker UDP sockets after ${FAULT_POINT}"
      if [[ "${count}" != "${expected_count}" ]]; then
        record_failure "${FAULT_POINT} attempt ${attempt} left ${count} module UDP sockets, expected ${expected_count}"
      fi
    done

    if (( worker_init_fault )); then
      fault_count_before="$(grep -c "test fault injected: ${FAULT_POINT}" \
        "${NGINX_ERROR_LOG}" || true)"
      if (( fault_count_before >= 8 )); then
        record_failure "${FAULT_POINT} retried initialization on every request instead of backing off"
      fi

      sleep 1.1
      code="$(request_code)"
      if ! rn_expect_http_status "${code}" 429; then
        record_failure "${FAULT_POINT} bounded retry returned ${code}, expected fail-close 429"
      fi
      fault_count_after="$(grep -c "test fault injected: ${FAULT_POINT}" \
        "${NGINX_ERROR_LOG}" || true)"
      if [[ "${fault_count_after}" != "$((fault_count_before + 1))" ]]; then
        record_failure "${FAULT_POINT} did not execute exactly one initialization retry after backoff"
      else
        log "${FAULT_POINT} suppressed request-driven retries and retried once after backoff"
      fi
      check_worker_survival "${FAULT_POINT} bounded retry"
      count="$(worker_udp_socket_count)" \
        || fail "could not count worker UDP sockets after ${FAULT_POINT} retry"
      if [[ "${count}" != "${expected_count}" ]]; then
        record_failure "${FAULT_POINT} retry left ${count} module UDP sockets, expected ${expected_count}"
      fi
    fi
  fi

  wait_for_log "test fault injected: ${FAULT_POINT}" "${NGINX_ERROR_LOG}" 40 \
    || record_failure "fault hook ${FAULT_POINT} was not exercised"
}

run_one() {
  ARTIFACT_DIR="${ARTIFACT_ROOT}/${MODE}"
  PREFIX="${ARTIFACT_DIR}/nginx-prefix"
  NGINX_CONF="${ARTIFACT_DIR}/nginx.conf"
  NGINX_ERROR_LOG="${ARTIFACT_DIR}/nginx-error.log"
  NGINX_ACCESS_LOG="${ARTIFACT_DIR}/nginx-access.log"
  NGINX_STDOUT_LOG="${ARTIFACT_DIR}/nginx-stdout.log"
  NGINX_CONFIG_LOG="${ARTIFACT_DIR}/nginx-config.log"
  AUTH_FILE="${ARTIFACT_DIR}/htpasswd"
  RESPONDER_LOG=""
  RESPONDER_ERROR_LOG=""
  DNS_LOG="${ARTIFACT_DIR}/dns.log"
  DNS_CHECK_LOG="${ARTIFACT_DIR}/dns-check.log"
  DNS_STATE_FILE="${ARTIFACT_DIR}/dns-state"

  mkdir -p "${ARTIFACT_DIR}"
  find "${ARTIFACT_DIR}" -mindepth 1 -maxdepth 1 -type f -delete
  trap cleanup EXIT

  prepare_binaries
  start_dns
  if dns_mode="$(dns_failure_mode 2>/dev/null)"; then
    set_dns_mode "${dns_mode}"
  fi
  start_responder allow keep 0
  write_nginx_config
  start_nginx
  if [[ "${MODE}" == "fault"
      && "${FAULT_POINT}" != "rebind-open"
      && "${FAULT_POINT}" != "posted-request-drain" ]]; then
    log "skipping healthy warm-up before fault injection ${FAULT_POINT}"
  elif [[ "${MODE}" == "worker-resolver-scope" ]]; then
    log "skipping healthy warm-up so the resolver-override location initializes the worker"
  elif [[ "${MODE}" == rendered-values-* ]]; then
    log "skipping healthy warm-up before rendered-value boundary checks"
  elif dns_failure_mode >/dev/null 2>&1; then
    log "skipping healthy warm-up before ${MODE}; DNS starts in failure mode"
  else
    warm_client
  fi

  case "${MODE}" in
    timeout) run_timeout_case ;;
    aborted-client|guard-aborted-client) run_aborted_client_case ;;
    udp-ingress-fairness) run_udp_ingress_fairness_case ;;
    steering-rebind) run_steering_rebind_case ;;
    outage) run_outage_case ;;
    dns-missing-srv|dns-bad-target|dns-timeout) run_dns_failure_case ;;
    guard-pass|guard-deny|guard-multiple|guard-start-fail-open|guard-timeout-fail-open) run_guard_case ;;
    malformed-auth|malformed-truncated|malformed-request-id) run_malformed_protocol_case ;;
    enforcement-boundary) run_enforcement_boundary_case ;;
    rendered-values-close|rendered-values-open) run_rendered_values_case ;;
    worker-resolver-scope) run_worker_resolver_scope_case ;;
    admission-contract-close|admission-contract-open) run_admission_contract_case ;;
    count-empty|count-short|count-extra) run_count_mismatch_case ;;
    fault) run_fault_case ;;
  esac

  if [[ "${MODE}" != "fault" ]]; then
    check_reload
  fi
  check_clean_nginx_shutdown

  if (( CASE_FAILED > 0 )); then
    log "regression failed; artifacts: ${ARTIFACT_DIR}"
    return 1
  fi
  log "regression passed; artifacts: ${ARTIFACT_DIR}"
}

if [[ "${MODE}" == "all" ]]; then
  run_all
elif [[ "${MODE}" == "admission-contract" ]]; then
  run_admission_contract
elif [[ "${MODE}" == "cardinality" ]]; then
  run_cardinality
elif [[ "${MODE}" == "rendered-values" ]]; then
  run_rendered_values
elif [[ "${MODE}" == "protocol-policy" ]]; then
  run_protocol_policy
elif [[ "${MODE}" == "outage-policy" ]]; then
  run_outage_policy
elif [[ "${MODE}" == "dns-policy" ]]; then
  run_dns_policy
elif [[ "${MODE}" == "guard-latency" ]]; then
  run_guard_latency
elif [[ "${MODE}" == "fault-injection" ]]; then
  run_fault_injection
else
  run_one
fi
