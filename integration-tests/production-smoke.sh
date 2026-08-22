#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lifecycle-oracles.sh
source "${SCRIPT_DIR}/lifecycle-oracles.sh"

usage() {
  cat <<EOF
Usage: integration-tests/production-smoke.sh

Runs a bounded live protocol smoke of this module against the RateLimitly
production fleet. It is a protocol proof, not a load test: it builds nginx with
this module, starts nginx against production, and drives real HTTP requests
that must produce two authenticated server-side facts.

  1. Latency read-back. One slow request reports its measured latency to a
     per-run tracker. Polling then alternates between an identically configured
     control tracker that received no report and the reported one, so both stay
     on the same number of guard evaluations. The reported guard must deny at an
     evaluation where the control guard still admits. The reported sample is the
     only difference between the two, so that denial can only come from
     production storing the sample and returning it.

  2. Rate denial. A one-token bucket must admit once and reject the next
     request.

Every decision is checked as an HTTP status *and* a \$ratelimitly_verdict.
Fail-open and fail-close leave no verdict, so a transport failure can never be
mistaken for an authenticated allow or deny.

Discovery is derived from the credential alone: the generated configuration
declares no ratelimitly_dns_srv and no ratelimitly_dns_resolver, so nginx
resolves c-<api-key-id>.p0.ratelimitly.com through the system resolver.

Required environment:
  RATELIMITLY_AUTH_KEY           production API key; never printed or uploaded
  RATELIMITLY_P0_TEST_NAMESPACE  1..48 [A-Za-z0-9_-] characters, unique per run

Environment overrides:
  RCLIENT_DIR       C-client checkout (default: locked ./_deps checkout)
  NGINX_SRC         nginx source tree (default: ./upstream-nginx)
  NGINX_BIN         nginx binary (default: \$NGINX_SRC/objs/nginx)
  NGINX_HOST        nginx listen address (default: 127.0.0.1)
  NGINX_PORT        nginx HTTP port (default: 18099)
  SKIP_BUILD        reuse existing binaries (0 or 1; default: 0)
  REQUEST_POLICY_UNIT  C-client scheduling unit (default: 100ms)
  LIVE_BUDGET_SEC   wall-clock budget for the live phase (default: 180)
  KEEP_ARTIFACTS    keep the private run directory (0 or 1; default: 0)

The generated configuration embeds the credential, so the run directory is a
private mkdtemp with mode 0700 and is removed on exit. Never publish it as a
CI artifact.
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

NGINX_SRC="${NGINX_SRC:-${RN_ROOT}/upstream-nginx}"
NGINX_BIN="${NGINX_BIN:-${NGINX_SRC}/objs/nginx}"
NGINX_HOST="${NGINX_HOST:-127.0.0.1}"
NGINX_PORT="${NGINX_PORT:-18099}"
SKIP_BUILD="${SKIP_BUILD:-0}"
# The standard policy horizon is three units and must fit the API key's
# dedup_ttl_ms_max quota, so keep the default small enough for any key.
REQUEST_POLICY_UNIT="${REQUEST_POLICY_UNIT:-100ms}"
LIVE_BUDGET_SEC="${LIVE_BUDGET_SEC:-180}"
KEEP_ARTIFACTS="${KEEP_ARTIFACTS:-0}"

# The reported sample must be unmistakably slower than an ordinary admitted
# request and unmistakably slower than the guard threshold. 15 KiB after a
# 1 KiB burst at 4 KiB/s takes about 3.75s, while an admitted probe completes
# in tens of milliseconds.
GUARD_THRESHOLD_MS=1000
SLOW_BODY_BYTES=16384
SLOW_MAX_TIME=30
CLIENT_TIMEOUT_SEC=15
READBACK_ATTEMPTS=25
READBACK_DELAY_SEC=0.2
WARMUP_ATTEMPTS=100
WARMUP_DELAY_SEC=0.2

NGINX_CONF=""
NGINX_PID=""
PREFIX=""
OBSERVED_CODE=""
OBSERVED_VERDICT=""
DEADLINE=0

log() {
  printf '[production-smoke] %s\n' "$*"
}

fail() {
  echo "FAIL production-smoke: $*" >&2
  exit 1
}

case "${SKIP_BUILD}" in
  0|1) ;;
  *) fail "SKIP_BUILD must be 0 or 1" ;;
esac
case "${KEEP_ARTIFACTS}" in
  0|1) ;;
  *) fail "KEEP_ARTIFACTS must be 0 or 1" ;;
esac

# --- credential and namespace gates -----------------------------------------
# A live test that quietly no-ops is worse than no test, so a missing or
# malformed credential is loud rather than skipped.

[[ -n "${RATELIMITLY_AUTH_KEY:-}" ]] \
  || fail "RATELIMITLY_AUTH_KEY is required"
# Shape only. The value is never printed and nginx -t performs the real bech32
# validation. Rejecting anything else also keeps the generated configuration
# free of whitespace, quotes, and directive terminators.
[[ "${RATELIMITLY_AUTH_KEY}" =~ ^rl-(aes|cookie)1[0-9a-z]{40,}$ ]] \
  || fail "RATELIMITLY_AUTH_KEY is not a bech32 RateLimitly API key"

NAMESPACE="${RATELIMITLY_P0_TEST_NAMESPACE:-}"
[[ -n "${NAMESPACE}" ]] \
  || fail "RATELIMITLY_P0_TEST_NAMESPACE is required"
[[ ${#NAMESPACE} -le 48 && "${NAMESPACE}" =~ ^[A-Za-z0-9_-]+$ ]] \
  || fail "RATELIMITLY_P0_TEST_NAMESPACE must be 1..48 safe ASCII characters"

# Production discovery must be derived exclusively from the credential. Refuse
# accidental overrides, then remove even empty values from child processes.
for variable in \
  RATELIMITLY_TENANT \
  RATELIMITLY_EXAMPLE_SERVER_HOST \
  RATELIMITLY_EXAMPLE_SERVER_PORT; do
  [[ -z "${!variable:-}" ]] \
    || fail "${variable} must not override key-derived production discovery"
done
unset RATELIMITLY_TENANT
unset RATELIMITLY_EXAMPLE_SERVER_HOST
unset RATELIMITLY_EXAMPLE_SERVER_PORT

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

# --- process and artifact lifetime ------------------------------------------

stop_nginx() {
  local attempt

  if [[ -n "${NGINX_PID}" ]] && kill -0 "${NGINX_PID}" 2>/dev/null; then
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
  rn_terminate_pid "${NGINX_PID}" "nginx master" || true
  NGINX_PID=""
}

report_diagnostics() {
  # The module logs an API key id and request ids, never the credential, so
  # these lines are safe to echo. The generated configuration is not.
  [[ -n "${NGINX_ERROR_LOG:-}" && -f "${NGINX_ERROR_LOG:-}" ]] || return 0
  echo "--- last module and nginx diagnostics ---" >&2
  grep -E 'rn: |\[(error|warn|crit|alert|emerg)\]' "${NGINX_ERROR_LOG}" \
    | tail -n 60 >&2 || true
  if [[ -n "${NGINX_ACCESS_LOG:-}" && -f "${NGINX_ACCESS_LOG:-}" ]]; then
    echo "--- access log (status verdict uri) ---" >&2
    tail -n 40 "${NGINX_ACCESS_LOG}" >&2 || true
  fi
}

cleanup() {
  local status=$?

  if (( status != 0 )); then
    report_diagnostics
  fi
  stop_nginx
  if [[ -n "${PREFIX}" && "${KEEP_ARTIFACTS}" == "0" ]]; then
    rm -rf "${PREFIX}"
  elif [[ -n "${PREFIX}" ]]; then
    echo "kept private run directory: ${PREFIX}" >&2
  fi
}
trap cleanup EXIT

# --- build ------------------------------------------------------------------

need_cmd awk
need_cmd bash
need_cmd curl
need_cmd dd
need_cmd grep
need_cmd make

RCLIENT_DIR="$("${RN_ROOT}/tools/resolve-rl-c-client.sh")"
if [[ "${SKIP_BUILD}" != "1" ]]; then
  log "building nginx with the module"
  RCLIENT_DIR="${RCLIENT_DIR}" \
    "${RN_ROOT}/tools/build-nginx.sh" "${NGINX_SRC}" --clean --debug
fi
[[ -x "${NGINX_BIN}" ]] || fail "nginx binary not found: ${NGINX_BIN}"

# --- private run directory --------------------------------------------------

umask 077
PREFIX="$(mktemp -d "${TMPDIR:-/tmp}/rl-nginx-production-smoke.XXXXXX")"
chmod 700 "${PREFIX}"
mkdir -p "${PREFIX}/logs" "${PREFIX}/html"
NGINX_CONF="${PREFIX}/nginx.conf"
NGINX_ERROR_LOG="${PREFIX}/logs/error.log"
NGINX_ACCESS_LOG="${PREFIX}/logs/access.log"
NGINX_STDOUT_LOG="${PREFIX}/logs/nginx-stdout.log"
NGINX_CONFIG_LOG="${PREFIX}/logs/nginx-config.log"
BASE_URL="http://${NGINX_HOST}:${NGINX_PORT}"
: >"${NGINX_ERROR_LOG}"
: >"${NGINX_ACCESS_LOG}"
dd if=/dev/zero of="${PREFIX}/html/slow.bin" \
  bs="${SLOW_BODY_BYTES}" count=1 status=none

cat >"${NGINX_CONF}" <<EOF
daemon off;
master_process on;
worker_processes 1;
pid logs/nginx.pid;
error_log ${NGINX_ERROR_LOG} debug;

events {
  worker_connections 64;
}

http {
  log_format ratelimitly_p0 '\$status \$ratelimitly_verdict \$request_uri';
  access_log ${NGINX_ACCESS_LOG} ratelimitly_p0;

  # No ratelimitly_dns_srv and no ratelimitly_dns_resolver. Production
  # discovery is derived from the credential alone, through the system
  # resolver, exactly as a deployment holding only a key would do it.
  ratelimitly_auth_key ${RATELIMITLY_AUTH_KEY};
  ratelimitly_policy standard unit=${REQUEST_POLICY_UNIT};
  ratelimitly_fail close;
  ratelimitly_debug on;

  # Identities are fixed literals scoped by the per-run namespace, so
  # concurrent runs can never share a bucket or a tracker.
  ratelimitly_zone p0_open
    "bucket=p0|ns=${NAMESPACE}|zone=open"
    rate=10000r/s;
  ratelimitly_zone p0_single
    "bucket=p0|ns=${NAMESPACE}|zone=single"
    rate=1r/m;

  ratelimitly_tracker p0_reported_tracker
    "service=p0|ns=${NAMESPACE}|svc=reported"
    ttl=60s max_samples=1 buffer_size=1 min_sample_threshold=1;
  ratelimitly_tracker p0_control_tracker
    "service=p0|ns=${NAMESPACE}|svc=control"
    ttl=60s max_samples=1 buffer_size=1 min_sample_threshold=1;

  ratelimitly_guard p0_reported_guard
    tracker=p0_reported_tracker
    threshold=${GUARD_THRESHOLD_MS}ms;
  ratelimitly_guard p0_control_guard
    tracker=p0_control_tracker
    threshold=${GUARD_THRESHOLD_MS}ms;

  server {
    listen ${NGINX_HOST}:${NGINX_PORT};

    location = /health {
      return 204;
    }

    location = /p0/warm {
      ratelimitly_label "p0=warm";
      ratelimitly zone=p0_open;
      root ${RN_ROOT}/tests;
      try_files /ok.txt =404;
    }

    location = /p0/latency/reported-slow {
      ratelimitly_label "p0=latency-reported-slow";
      ratelimitly zone=p0_open guard=p0_reported_guard;
      ratelimitly_report p0_reported_tracker;
      limit_rate_after 1k;
      limit_rate 4k;
      root ${PREFIX}/html;
      try_files /slow.bin =404;
    }

    location = /p0/latency/control-slow {
      ratelimitly_label "p0=latency-control-slow";
      ratelimitly zone=p0_open guard=p0_control_guard;
      limit_rate_after 1k;
      limit_rate 4k;
      root ${PREFIX}/html;
      try_files /slow.bin =404;
    }

    location = /p0/latency/reported {
      ratelimitly_label "p0=latency-reported";
      ratelimitly zone=p0_open guard=p0_reported_guard;
      root ${RN_ROOT}/tests;
      try_files /ok.txt =404;
    }

    location = /p0/latency/control {
      ratelimitly_label "p0=latency-control";
      ratelimitly zone=p0_open guard=p0_control_guard;
      root ${RN_ROOT}/tests;
      try_files /ok.txt =404;
    }

    location = /p0/rate {
      ratelimitly_label "p0=rate";
      ratelimitly zone=p0_single;
      root ${RN_ROOT}/tests;
      try_files /ok.txt =404;
    }
  }
}
EOF

if grep -Eq '^[[:space:]]*ratelimitly_dns_(srv|resolver)\b' "${NGINX_CONF}"; then
  fail "the generated configuration must not override key-derived discovery"
fi

# --- nginx lifecycle --------------------------------------------------------

start_nginx() {
  local attempt
  local code

  if ! "${NGINX_BIN}" -p "${PREFIX}/" -c "${NGINX_CONF}" -t \
      >"${NGINX_CONFIG_LOG}" 2>&1; then
    cat "${NGINX_CONFIG_LOG}" >&2
    fail "nginx rejected the generated production configuration"
  fi

  log "starting nginx on ${NGINX_HOST}:${NGINX_PORT}"
  "${NGINX_BIN}" -p "${PREFIX}/" -c "${NGINX_CONF}" \
    >"${NGINX_STDOUT_LOG}" 2>&1 &
  NGINX_PID=$!

  for (( attempt = 0; attempt < 100; attempt++ )); do
    if ! kill -0 "${NGINX_PID}" 2>/dev/null; then
      fail "nginx exited during startup"
    fi
    code="$(curl --max-time 1 -s -o /dev/null -w '%{http_code}' \
      "${BASE_URL}/health" || true)"
    if rn_expect_http_status "${code}" "204"; then
      return 0
    fi
    sleep 0.05
  done
  fail "nginx did not become reachable"
}

# --- decision observation ---------------------------------------------------

check_budget() {
  (( $(date +%s) < DEADLINE )) \
    || fail "the live phase exceeded its ${LIVE_BUDGET_SEC}s budget during $1"
}

# Records OBSERVED_CODE from curl and OBSERVED_VERDICT from the access log.
# The verdict carries authenticated provenance: it is 'allow' or 'deny' only
# for a valid RateLimitly decision and '-' on every fail-open or fail-close
# path, including the 429 that fail-close returns.
observe() {
  local path="$1"
  local max_time="${2:-${CLIENT_TIMEOUT_SEC}}"
  local attempt
  local line
  local start

  start="$(wc -l <"${NGINX_ACCESS_LOG}")"
  OBSERVED_CODE="$(curl --max-time "${max_time}" -s -o /dev/null \
    -w '%{http_code}' "${BASE_URL}${path}" || true)"
  OBSERVED_VERDICT=""
  for (( attempt = 0; attempt < 100; attempt++ )); do
    line="$(tail -n "+$((start + 1))" "${NGINX_ACCESS_LOG}" \
      | awk -v path="${path}" '$3 == path { record = $0 } END { print record }')"
    if [[ -n "${line}" ]]; then
      OBSERVED_VERDICT="$(awk '{ print $2 }' <<<"${line}")"
      return 0
    fi
    sleep 0.05
  done
  fail "nginx logged no access record for ${path}"
}

expect_decision() {
  local label="$1"
  local path="$2"
  local code="$3"
  local verdict="$4"
  local max_time="${5:-${CLIENT_TIMEOUT_SEC}}"

  observe "${path}" "${max_time}"
  if ! rn_expect_http_status "${OBSERVED_CODE}" "${code}" \
      || [[ "${OBSERVED_VERDICT}" != "${verdict}" ]]; then
    fail "${label}: expected ${code}/${verdict}," \
      "observed ${OBSERVED_CODE}/${OBSERVED_VERDICT}"
  fi
  log "${label}: ${OBSERVED_CODE} ${OBSERVED_VERDICT}"
}

# --- proofs -----------------------------------------------------------------

warm_client() {
  local attempt

  for (( attempt = 0; attempt < WARMUP_ATTEMPTS; attempt++ )); do
    check_budget "discovery warm-up"
    observe /p0/warm
    if rn_expect_http_status "${OBSERVED_CODE}" "200" \
        && [[ "${OBSERVED_VERDICT}" == "allow" ]]; then
      log "production discovery and admission are live" \
        "(attempt $((attempt + 1)))"
      return 0
    fi
    sleep "${WARMUP_DELAY_SEC}"
  done
  fail "no authenticated production allow within ${WARMUP_ATTEMPTS} attempts;" \
    "the last result was ${OBSERVED_CODE}/${OBSERVED_VERDICT}"
}

prove_latency_tracker() {
  local attempt
  local denied=0

  # Both trackers start empty and take exactly one slow admitted request. Only
  # the second one reports its measured latency, so the read-back below starts
  # as early as possible within the tracker TTL.
  expect_decision "control tracker withholds its sample" \
    /p0/latency/control-slow 200 allow "${SLOW_MAX_TIME}"
  expect_decision "reported tracker takes a slow sample" \
    /p0/latency/reported-slow 200 allow "${SLOW_MAX_TIME}"

  # Interleaved polling keeps both trackers on the same number of guard
  # evaluations, so the reported sample stays the only difference between them.
  #
  # The comparison is only valid at equal evaluation counts. A tracker this
  # narrow warms up from admissions alone, so an extra control evaluation after
  # the reported guard has already denied will deny too, for reasons that have
  # nothing to do with the report. Do not add a trailing control check.
  for (( attempt = 0; attempt < READBACK_ATTEMPTS; attempt++ )); do
    check_budget "latency read-back"
    expect_decision "control guard stays open" \
      /p0/latency/control 200 allow
    observe /p0/latency/reported
    if rn_expect_http_status "${OBSERVED_CODE}" "429" \
        && [[ "${OBSERVED_VERDICT}" == "deny" ]]; then
      denied=1
      log "reported guard denied after read-back" \
        "(attempt $((attempt + 1)))"
      break
    fi
    if ! rn_expect_http_status "${OBSERVED_CODE}" "200" \
        || [[ "${OBSERVED_VERDICT}" != "allow" ]]; then
      fail "latency read-back observed ${OBSERVED_CODE}/${OBSERVED_VERDICT};" \
        "expected an authenticated allow or deny"
    fi
    sleep "${READBACK_DELAY_SEC}"
  done
  (( denied == 1 )) \
    || fail "the reported slow sample never denied the" \
      "${GUARD_THRESHOLD_MS}ms guard within ${READBACK_ATTEMPTS} attempts"
}

prove_rate_limiter() {
  check_budget "rate denial"
  expect_decision "one-token bucket admits once" /p0/rate 200 allow
  expect_decision "one-token bucket then rejects" /p0/rate 429 deny
}

# --- run --------------------------------------------------------------------

DEADLINE=$(( $(date +%s) + LIVE_BUDGET_SEC ))
start_nginx
warm_client
prove_latency_tracker
prove_rate_limiter
stop_nginx

echo "PASS production protocol smoke (latency read-back, rate denial)"
