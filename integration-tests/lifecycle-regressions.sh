#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SELF="${SCRIPT_DIR}/lifecycle-regressions.sh"

usage() {
  cat <<EOF
Usage: integration-tests/lifecycle-regressions.sh [all|timeout|aborted-client|steering-rebind]

Runs the public A13 lifecycle regressions against the locked rl-c-client test
responder. Every case pins the original nginx worker PID, triggers the lifecycle
path, and requires both worker survival and a successful follow-up request.

Environment overrides:
  RCLIENT_DIR       C-client checkout (default: locked ./_deps checkout)
  NGINX_SRC         nginx source tree (default: ./upstream-nginx)
  DNS_PORT          local DNS port (default: 15353)
  RESPONDER_PORT    UDP responder port (default: 19080)
  NGINX_PORT        nginx HTTP port (default: 18098)
  REQUEST_TIMEOUT   module timeout (default: 300ms)
  ABORT_REQUESTS    aborted clients in the stress case (default: 20)
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
  all|timeout|aborted-client|steering-rebind) ;;
  *)
    echo "Unknown lifecycle case: ${MODE}" >&2
    usage >&2
    exit 2
    ;;
esac

RCLIENT_DIR="${RCLIENT_DIR:-${RN_ROOT}/_deps/rl-c-client}"
NGINX_SRC="${NGINX_SRC:-${RN_ROOT}/upstream-nginx}"
NGINX_BIN="${NGINX_BIN:-${NGINX_SRC}/objs/nginx}"
RESPONDER_BIN="${RESPONDER_BIN:-${RCLIENT_DIR}/bin/r_test_responder}"
DNS_SERVER="${DNS_SERVER:-127.0.0.1}"
DNS_PORT="${DNS_PORT:-15353}"
RESPONDER_HOST="${RESPONDER_HOST:-127.0.0.1}"
RESPONDER_PORT="${RESPONDER_PORT:-19080}"
NGINX_HOST="${NGINX_HOST:-127.0.0.1}"
NGINX_PORT="${NGINX_PORT:-18098}"
DOMAIN="${DOMAIN:-rn-test.local}"
SERVER_ID="${SERVER_ID:-1}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-300ms}"
ABORT_REQUESTS="${ABORT_REQUESTS:-20}"
CLIENT_TIMEOUT_SEC="${CLIENT_TIMEOUT_SEC:-3}"
ARTIFACT_ROOT="${ARTIFACT_ROOT:-${SCRIPT_DIR}/artifacts/lifecycle}"
ABORT_CLIENT_HELPER="${SCRIPT_DIR}/abort_http_clients.py"
UDP_PORT_HELPER="${SCRIPT_DIR}/worker_udp_port.py"

RESPONDER_PID=""
DNS_PID=""
NGINX_PID=""
ORIGINAL_WORKER_PID=""
CASE_FAILED=0
RESPONDER_RUN=0

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

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

terminate_pid() {
  local pid="$1"
  local label="$2"
  local attempt

  if [[ -z "${pid}" ]] || ! kill -0 "${pid}" 2>/dev/null; then
    return 0
  fi
  kill -TERM "${pid}" 2>/dev/null || true
  for (( attempt = 0; attempt < 30; attempt++ )); do
    if ! kill -0 "${pid}" 2>/dev/null; then
      wait "${pid}" 2>/dev/null || true
      return 0
    fi
    sleep 0.1
  done
  log "force-killing ${label}: pid=${pid}"
  kill -KILL "${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true
}

stop_responder() {
  terminate_pid "${RESPONDER_PID}" "test responder"
  RESPONDER_PID=""
}

stop_nginx() {
  local attempt

  if [[ -n "${NGINX_PID}" ]] && kill -0 "${NGINX_PID}" 2>/dev/null; then
    LD_LIBRARY_PATH="${RCLIENT_DIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
      "${NGINX_BIN}" -p "${PREFIX}/" -c "${NGINX_CONF}" -s quit \
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
  terminate_pid "${NGINX_PID}" "nginx master"
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
  stop_nginx
  stop_responder
  terminate_pid "${DNS_PID}" "local DNS server"
}

prepare_binaries() {
  need_cmd bash
  need_cmd curl
  need_cmd dig
  need_cmd make
  need_cmd ps
  need_cmd python3

  if [[ ! -d "${RCLIENT_DIR}" ]]; then
    if [[ "${RCLIENT_DIR}" != "${RN_ROOT}/_deps/rl-c-client" ]]; then
      fail "C-client checkout not found: ${RCLIENT_DIR}"
    fi
    "${RN_ROOT}/tools/fetch-rl-c-client.sh"
  fi

  if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    log "building the public test responder"
    make -C "${RCLIENT_DIR}" test-responder
    log "building nginx with the module"
    RCLIENT_DIR="${RCLIENT_DIR}" \
      "${RN_ROOT}/tools/build-nginx.sh" "${NGINX_SRC}" --clean --debug
  fi

  [[ -x "${RESPONDER_BIN}" ]] || fail "responder binary not found: ${RESPONDER_BIN}"
  [[ -x "${NGINX_BIN}" ]] || fail "nginx binary not found: ${NGINX_BIN}"
}

run_all() {
  local failures=0
  local lifecycle_case

  prepare_binaries
  for lifecycle_case in timeout aborted-client steering-rebind; do
    if SKIP_BUILD=1 "${SELF}" "${lifecycle_case}"; then
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
  log "all lifecycle regressions passed"
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
  python3 "${SCRIPT_DIR}/local_dns_server.py" \
    --listen-host "${DNS_SERVER}" \
    --port "${DNS_PORT}" \
    --domain "${DOMAIN}" \
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

start_responder() {
  local scenario="$1"
  local steering="${2:-keep}"
  local delay_ms="${3:-0}"

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
  auth_key="$(synthetic_auth_key)"
  [[ -n "${auth_key}" ]] || fail "could not obtain the responder's synthetic nginx key"
  mkdir -p "${PREFIX}/logs"

  cat >"${NGINX_CONF}" <<EOF
daemon off;
master_process on;
worker_processes 1;
pid logs/nginx.pid;
error_log ${NGINX_ERROR_LOG} debug;

events {
  worker_connections 128;
}

http {
  access_log off;
  resolver ${DNS_SERVER}:${DNS_PORT} valid=1s ipv6=off;
  resolver_timeout 1s;

  ratelimitly_tenant ${DOMAIN};
  ratelimitly_auth_key ${auth_key};
  ratelimitly_timeout ${REQUEST_TIMEOUT};
  ratelimitly_fail close;
  ratelimitly_debug on;

  ratelimitly_zone lifecycle_zone bucket="lifecycle:\$uri" rate=10000r/s;

  server {
    listen ${NGINX_HOST}:${NGINX_PORT};

    location = /health {
      return 204;
    }

    location = /limited {
      ratelimitly_label "LIFECYCLE:\$uri";
      ratelimitly zone=lifecycle_zone;
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

worker_udp_port() {
  python3 "${UDP_PORT_HELPER}" "${ORIGINAL_WORKER_PID}"
}

start_nginx() {
  local attempt
  local code

  LD_LIBRARY_PATH="${RCLIENT_DIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
    "${NGINX_BIN}" -p "${PREFIX}/" -c "${NGINX_CONF}" -t \
    >"${NGINX_CONFIG_LOG}" 2>&1 \
    || fail "nginx configuration failed; see ${NGINX_CONFIG_LOG}"

  log "starting nginx on ${NGINX_HOST}:${NGINX_PORT}"
  LD_LIBRARY_PATH="${RCLIENT_DIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
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
  curl --max-time "${max_time}" -s -o /dev/null -w '%{http_code}' \
    "http://${NGINX_HOST}:${NGINX_PORT}/limited" || true
}

warm_client() {
  local attempt
  local code

  for (( attempt = 0; attempt < 100; attempt++ )); do
    code="$(request_code)"
    if [[ "${code}" == "200" ]]; then
      wait_for_log '"event":"rate_request"' "${RESPONDER_LOG}" 20 \
        || fail "warmup returned 200 without a responder request record"
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

  start_responder allow keep 0
  for (( attempt = 0; attempt < 40; attempt++ )); do
    code="$(request_code)"
    if [[ "${code}" == "200" ]]; then
      break
    fi
    sleep 0.05
  done
  if [[ "${code}" != "200" ]]; then
    record_failure "follow-up request after ${phase} returned ${code}, expected 200"
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
  sleep 0.2
  tail -n "+$((error_log_start + 1))" "${NGINX_ERROR_LOG}" \
    >"${ARTIFACT_DIR}/timeout-trigger.log"
  if ! grep -q 'rn: result error status=-2' "${ARTIFACT_DIR}/timeout-trigger.log"; then
    record_failure "timeout trigger did not complete through the C-client callback"
  elif awk '
      /rn: result error status=-2/ { completed = 1; next }
      completed && /rn: timeout tick/ { unsafe = 1 }
      END { exit unsafe ? 0 : 1 }
    ' "${ARTIFACT_DIR}/timeout-trigger.log"; then
    record_failure "timeout handler continued using request context after synchronous completion"
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
  if grep -q 'rn: timeout tick' "${ARTIFACT_DIR}/aborted-client-trigger.log"; then
    record_failure "request timer fired after the clients reset their connections"
  fi
  check_worker_survival "aborted-client cleanup and timer expiry"
  check_rebind_follow_up "aborted-client cleanup"
  check_follow_up "aborted-client cleanup"
}

run_steering_rebind_case() {
  check_rebind_follow_up "steering trigger" 1
  check_follow_up "steering rebind"
}

run_one() {
  ARTIFACT_DIR="${ARTIFACT_ROOT}/${MODE}"
  PREFIX="${ARTIFACT_DIR}/nginx-prefix"
  NGINX_CONF="${ARTIFACT_DIR}/nginx.conf"
  NGINX_ERROR_LOG="${ARTIFACT_DIR}/nginx-error.log"
  NGINX_STDOUT_LOG="${ARTIFACT_DIR}/nginx-stdout.log"
  NGINX_CONFIG_LOG="${ARTIFACT_DIR}/nginx-config.log"
  RESPONDER_LOG=""
  RESPONDER_ERROR_LOG=""
  DNS_LOG="${ARTIFACT_DIR}/dns.log"
  DNS_CHECK_LOG="${ARTIFACT_DIR}/dns-check.log"

  mkdir -p "${ARTIFACT_DIR}"
  find "${ARTIFACT_DIR}" -mindepth 1 -maxdepth 1 -type f -delete
  trap cleanup EXIT

  prepare_binaries
  start_dns
  start_responder allow keep 0
  write_nginx_config
  start_nginx
  warm_client

  case "${MODE}" in
    timeout) run_timeout_case ;;
    aborted-client) run_aborted_client_case ;;
    steering-rebind) run_steering_rebind_case ;;
  esac

  check_clean_nginx_shutdown

  if (( CASE_FAILED > 0 )); then
    log "regression failed; artifacts: ${ARTIFACT_DIR}"
    return 1
  fi
  log "regression passed; artifacts: ${ARTIFACT_DIR}"
}

if [[ "${MODE}" == "all" ]]; then
  run_all
else
  run_one
fi
