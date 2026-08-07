#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s inherit_errexit
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
  cat <<EOF
Usage:
  integration-tests/internal-full-stack.sh [SECRET]
  integration-tests/internal-full-stack.sh -h|--help

Runs the optional internal rl-nginx full-stack test from the repo root.
Local mode requires the private ../rl workspace and:
  1. builds rl-c-client, rlnet if needed, ratelimitly-server, and nginx;
  2. starts ratelimitly-server from ../rl/implementations/rust by default;
  3. registers a temporary tenant;
  4. starts a local DNS server for _ratelimitly._udp.\${DOMAIN};
  5. starts nginx with the generated test config;
  6. verifies an allow path and a rate-limited deny path.

External-server mode:
  EXTERNAL_SERVER=1 DOMAIN=<tenant-domain> TENANT_KEY=<rl-aes/rl-cookie key> integration-tests/internal-full-stack.sh

This skips local Rust server startup, tenant registration, and local DNS. It
uses the configured DNS resolver to resolve _ratelimitly._udp.\${DOMAIN}.

Common environment overrides:
  RL_ROOT=${RN_ROOT}/../rl
  RL_RUST_ROOT=\${RL_ROOT}/implementations/rust
  RCLIENT_DIR=${RN_ROOT}/_deps/rl-c-client (locked default; override explicitly)
  RL_HOST=127.0.0.1 (address used by the harness to reach the server)
  DNS_PORT=53535
  NGINX_RESOLVER_OPTIONS=ipv6=off
  RL_SERVER_PORT=39080
  NGINX_PORT=18088
  RATELIMITLY_POLICY_UNIT=100ms
  ALLOW_REQUESTS=50
  DENY_REQUESTS=200
  PARALLELISM=20
  CLIENT_TIMEOUT_SEC=30

External mode uses more conservative defaults:
  RATELIMITLY_POLICY_UNIT=1000ms
  ALLOW_REQUESTS=20
  DENY_REQUESTS=80
  PARALLELISM=5

Artifacts are written to:
  ${SCRIPT_DIR}/artifacts
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if (( $# > 1 )); then
  echo "Too many arguments" >&2
  usage >&2
  exit 1
fi

ARTIFACT_DIR="${SCRIPT_DIR}/artifacts"
mkdir -p "${ARTIFACT_DIR}"
chmod 700 "${ARTIFACT_DIR}"
find "${ARTIFACT_DIR}" -mindepth 1 -maxdepth 1 -type f -delete

MASTER_LOG="${ARTIFACT_DIR}/test.log"
exec > >(tee "${MASTER_LOG}") 2>&1

DEFAULT_SECRET="rl-secret16rkc9fkshnpdmdwp6dn0g8fpzamkx3ftlrlg2azvfnm3nkzdfc7qd2v85f"
SECRET="${1:-${SECRET:-${DEFAULT_SECRET}}}"

default_dns_server() {
  awk '/^nameserver[[:space:]]+/ { print $2; exit }' /etc/resolv.conf
}

RL_ROOT="${RL_ROOT:-${RN_ROOT}/../rl}"
RL_RUST_ROOT="${RL_RUST_ROOT:-${RL_ROOT}/implementations/rust}"
RL_SERVER_BIN="${RL_SERVER_BIN:-${RL_RUST_ROOT}/target/release/ratelimitly-server}"
TENANT_CLI_DIR="${RL_ROOT}/tenant_management/elixir"
LOCAL_DNS_SERVER="${SCRIPT_DIR}/local_dns_server.py"

RCLIENT_DIR="$("${RN_ROOT}/tools/resolve-rl-c-client.sh")"
NGINX_SRC="${NGINX_SRC:-${RN_ROOT}/upstream-nginx}"
NGINX_BIN="${NGINX_BIN:-${NGINX_SRC}/objs/nginx}"

EXTERNAL_SERVER="${EXTERNAL_SERVER:-0}"
if [[ "${EXTERNAL_SERVER}" == "1" ]]; then
  if [[ -z "${DOMAIN:-}" ]]; then
    echo "EXTERNAL_SERVER=1 requires DOMAIN=<tenant-domain>" >&2
    exit 1
  fi
  DNS_SERVER="${DNS_SERVER:-$(default_dns_server)}"
  DNS_PORT="${DNS_PORT:-53}"
else
  DOMAIN="${DOMAIN:-rn-itest.local}"
  DNS_SERVER="${DNS_SERVER:-127.0.0.1}"
  DNS_PORT="${DNS_PORT:-53535}"
fi
RL_HOST="${RL_HOST:-127.0.0.1}"
RL_SERVER_PORT="${RL_SERVER_PORT:-39080}"
RL_NODE_ID="${RL_NODE_ID:-11}"
NGINX_HOST="${NGINX_HOST:-127.0.0.1}"
NGINX_PORT="${NGINX_PORT:-18088}"
NGINX_RESOLVER_OPTIONS="${NGINX_RESOLVER_OPTIONS-ipv6=off}"
TENANT_AUTH="${TENANT_AUTH:-aes}"
TENANT_ID="${TENANT_ID:-$(( ( $(date +%s) % 1000000000 ) + 1000 ))}"
TENANT_SEED="${TENANT_SEED:-tenant-seed-${TENANT_ID}}"
TEST_DEDUP_N_BUCKETS_LOG2="${RL_DEDUP_N_BUCKETS_LOG2:-12}"
TEST_DEDUP_TTL_MS="${RL_DEDUP_TTL:-300}"
TENANT_DEDUP_TTL_MS_MAX="${TENANT_DEDUP_TTL_MS_MAX:-${TEST_DEDUP_TTL_MS}}"

if [[ "${EXTERNAL_SERVER}" == "1" ]]; then
  DEFAULT_RATELIMITLY_POLICY_UNIT=1000ms
  DEFAULT_ALLOW_REQUESTS=20
  DEFAULT_DENY_REQUESTS=80
  DEFAULT_PARALLELISM=5
else
  DEFAULT_RATELIMITLY_POLICY_UNIT=100ms
  DEFAULT_ALLOW_REQUESTS=50
  DEFAULT_DENY_REQUESTS=200
  DEFAULT_PARALLELISM=20
fi

RATELIMITLY_POLICY_UNIT="${RATELIMITLY_POLICY_UNIT:-${DEFAULT_RATELIMITLY_POLICY_UNIT}}"
ALLOW_REQUESTS="${ALLOW_REQUESTS:-${DEFAULT_ALLOW_REQUESTS}}"
DENY_REQUESTS="${DENY_REQUESTS:-${DEFAULT_DENY_REQUESTS}}"
PARALLELISM="${PARALLELISM:-${DEFAULT_PARALLELISM}}"
CLIENT_TIMEOUT_SEC="${CLIENT_TIMEOUT_SEC:-30}"

SERVER_PID=""
DNS_PID=""
NGINX_PID=""
SERVER_ID=""
TENANT_KEY="${TENANT_KEY:-}"

log() {
  printf '[itest] %s\n' "$*"
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

terminate_pid() {
  local pid="$1"
  local label="$2"
  local signal="${3:-TERM}"
  local attempt

  if [[ -z "${pid}" ]] || ! kill -0 "${pid}" 2>/dev/null; then
    return 0
  fi

  kill "-${signal}" "${pid}" 2>/dev/null || true
  for (( attempt = 0; attempt < 20; attempt++ )); do
    if ! kill -0 "${pid}" 2>/dev/null; then
      wait "${pid}" 2>/dev/null || true
      return 0
    fi
    sleep 0.2
  done

  if [[ "${signal}" != "KILL" ]] && kill -0 "${pid}" 2>/dev/null; then
    log "Force-killing ${label}: pid=${pid}"
    terminate_pid "${pid}" "${label}" KILL
  fi
}

cleanup() {
  terminate_pid "${NGINX_PID}" "nginx"
  if [[ -n "${NGINX_BIN}" && -x "${NGINX_BIN}" ]]; then
    "${NGINX_BIN}" -p "${ARTIFACT_DIR}/nginx-prefix" -c "${ARTIFACT_DIR}/nginx.conf" -s quit >/dev/null 2>&1 || true
  fi
  terminate_pid "${DNS_PID}" "local DNS server"
  terminate_pid "${SERVER_PID}" "ratelimitly-server"
}
trap cleanup EXIT

run_tenant_cli() {
  local logfile="$1"
  shift
  log "Running tenant CLI -> ${logfile}"
  elixir \
    -r "${TENANT_CLI_DIR}/lib/tenant_management_cli/bech32.ex" \
    -r "${TENANT_CLI_DIR}/lib/tenant_management_cli.ex" \
    -e 'TenantManagementCLI.main(System.argv())' \
    -- \
    "$@" >"${logfile}" 2>&1
  cat "${logfile}"
}

ensure_local_rlnet_build() {
  local xdp_dir="${RL_ROOT}/xdp"
  local build_dir="${xdp_dir}/build-static"
  local static_lib="${build_dir}/src/librlnet.a"

  if [[ -f "${static_lib}" ]]; then
    log "Using existing rlnet static library: ${static_lib}"
    return
  fi

  log "Building rlnet static library"
  cmake -S "${xdp_dir}" -B "${build_dir}" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DRLNET_BUILD_SHARED=OFF \
    -DCMAKE_C_FLAGS=-fPIC
  cmake --build "${build_dir}" -j
}

build_all() {
  log "Building rl-c-client"
  make -C "${RCLIENT_DIR}" clean
  make -C "${RCLIENT_DIR}"

  if [[ "${EXTERNAL_SERVER}" != "1" ]]; then
    ensure_local_rlnet_build

    log "Building ratelimitly-server"
    cargo build --release --features full --bin ratelimitly-server --manifest-path "${RL_RUST_ROOT}/Cargo.toml"
  fi

  log "Building nginx with rl-nginx module"
  RCLIENT_DIR="${RCLIENT_DIR}" "${RN_ROOT}/tests/build-nginx.sh" "${NGINX_SRC}" --clean --debug
}

wait_for_server_ready() {
  local logfile="$1"
  local max_attempts="${2:-60}"
  local attempt
  local server_id_line=""
  local ready_line=""
  local server_id=""
  local started_port=""

  for (( attempt = 0; attempt < max_attempts; attempt++ )); do
    if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
      echo "ratelimitly-server exited early; see ${logfile}" >&2
      return 1
    fi
    server_id_line="$(grep -m1 'RateLimitly server starting: server_id=' "${logfile}" || true)"
    ready_line="$(grep -m1 'XDP datapath started successfully - server ready for requests' "${logfile}" || true)"
    if [[ -n "${server_id_line}" ]] && [[ -n "${ready_line}" ]]; then
      server_id="$(sed -n 's/.*server_id=\([0-9][0-9]*\) port=.*/\1/p' <<< "${server_id_line}")"
      started_port="$(sed -n 's/.* port=\([0-9][0-9]*\).*/\1/p' <<< "${server_id_line}")"
      if [[ -z "${server_id}" ]]; then
        echo "could not parse ratelimitly-server id from readiness log" >&2
        return 1
      fi
      if [[ "${started_port}" != "${RL_SERVER_PORT}" ]]; then
        echo "ratelimitly-server reported port ${started_port}, expected ${RL_SERVER_PORT}" >&2
        return 1
      fi
      printf '%s\n' "${server_id}"
      return 0
    fi
    sleep 0.5
  done

  echo "Timed out waiting for ratelimitly-server readiness; see ${logfile}" >&2
  return 1
}

start_rl_server() {
  local logfile="${ARTIFACT_DIR}/rl-server.log"
  log "Starting ratelimitly-server on port ${RL_SERVER_PORT}"
  (
    cd "${RL_ROOT}"
    RLNET_DISABLE_XDP=1 \
    RL_DEDUP_N_BUCKETS_LOG2="${TEST_DEDUP_N_BUCKETS_LOG2}" \
    RL_DEDUP_TTL="${TEST_DEDUP_TTL_MS}" \
    RUST_LOG=debug \
    exec "${RL_SERVER_BIN}" \
      --port "${RL_SERVER_PORT}" \
      --key "${SECRET}" \
      --node-id "${RL_NODE_ID}" \
      --verbose
  ) >"${logfile}" 2>&1 &
  SERVER_PID=$!
  SERVER_ID="$(wait_for_server_ready "${logfile}")"
  log "ratelimitly-server ready: server_id=${SERVER_ID}"
}

register_tenant() {
  local logfile="${ARTIFACT_DIR}/tenant-register.log"
  run_tenant_cli "${logfile}" \
    --auth "${TENANT_AUTH}" \
    --tenant "${TENANT_ID}" \
    --secret "${TENANT_SEED}" \
    --tenant-name "tenant-${TENANT_ID}" \
    --dedup-ttl-ms-max "${TENANT_DEDUP_TTL_MS_MAX}" \
    --dedup-ttl-ms "${TEST_DEDUP_TTL_MS}" \
    "${RL_HOST}:${RL_SERVER_PORT}" \
    "${SECRET}"

  TENANT_KEY="$(sed -n 's/.*"bech32_api_key":"\([^"]*\)".*/\1/p' "${logfile}" | tail -n1)"
  local ack_server_id
  ack_server_id="$(sed -n 's/.*"server_id":"\([^"]*\)".*/\1/p' "${logfile}" | tail -n1)"

  if [[ -z "${TENANT_KEY}" ]]; then
    echo "Failed to extract tenant key from ${logfile}" >&2
    exit 1
  fi
  if [[ "${ack_server_id}" != "${SERVER_ID}" ]]; then
    echo "Tenant registration ACK server_id mismatch: expected ${SERVER_ID}, got ${ack_server_id}" >&2
    exit 1
  fi
  log "Registered tenant ${TENANT_ID}"
}

start_dns() {
  local logfile="${ARTIFACT_DIR}/dns.log"
  log "Starting local DNS on ${DNS_SERVER}:${DNS_PORT} for ${DOMAIN}"
  python3 "${LOCAL_DNS_SERVER}" \
    --listen-host "${DNS_SERVER}" \
    --port "${DNS_PORT}" \
    --domain "${DOMAIN}" \
    --record "${SERVER_ID}:${RL_SERVER_PORT}" >"${logfile}" 2>&1 &
  DNS_PID=$!

  sleep 1
  if ! kill -0 "${DNS_PID}" 2>/dev/null; then
    echo "Local DNS server failed to start; see ${logfile}" >&2
    exit 1
  fi

  dig @"${DNS_SERVER}" -p "${DNS_PORT}" +short SRV "_ratelimitly._udp.${DOMAIN}" | tee "${ARTIFACT_DIR}/dns-check.log"
  if ! grep -q "${RL_SERVER_PORT}" "${ARTIFACT_DIR}/dns-check.log"; then
    echo "DNS SRV check did not include expected port ${RL_SERVER_PORT}" >&2
    exit 1
  fi
}

check_external_dns() {
  log "Checking external DNS SRV _ratelimitly._udp.${DOMAIN} via ${DNS_SERVER}:${DNS_PORT}"
  dig @"${DNS_SERVER}" -p "${DNS_PORT}" +short SRV "_ratelimitly._udp.${DOMAIN}" | tee "${ARTIFACT_DIR}/dns-check.log"
  if ! grep -Eq '^[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+[^[:space:]]+\.$' "${ARTIFACT_DIR}/dns-check.log"; then
    echo "DNS SRV check did not return a usable record for _ratelimitly._udp.${DOMAIN}" >&2
    exit 1
  fi
}

write_nginx_config() {
  local conf="${ARTIFACT_DIR}/nginx.conf"
  local prefix="${ARTIFACT_DIR}/nginx-prefix"
  mkdir -p "${prefix}/logs"

  cat >"${conf}" <<EOF
events {
  debug_connection ${NGINX_HOST};
}

http {
  resolver ${DNS_SERVER}:${DNS_PORT} valid=1s ${NGINX_RESOLVER_OPTIONS};
  resolver_timeout 2s;

  ratelimitly_dns_srv  ${DOMAIN};
  ratelimitly_auth_key ${TENANT_KEY};
  ratelimitly_policy standard unit=${RATELIMITLY_POLICY_UNIT};
  ratelimitly_fail     close;
  ratelimitly_debug    on;

  ratelimitly_zone allow_zone "bucket=v1|fixture=allow" rate=10000r/s;
  ratelimitly_zone deny_zone  "bucket=v1|fixture=deny"  rate=1r/s;

  server {
    listen ${NGINX_HOST}:${NGINX_PORT};

    location = /health {
      return 204;
    }

    location = /allow {
      ratelimitly_label "fixture=allow";
      ratelimitly zone=allow_zone;
      root ${RN_ROOT}/tests;
      try_files /ok.txt =404;
    }

    location = /deny {
      ratelimitly_label "fixture=deny";
      ratelimitly zone=deny_zone;
      root ${RN_ROOT}/tests;
      try_files /ok.txt =404;
    }
  }
}
EOF
}

start_nginx() {
  local conf="${ARTIFACT_DIR}/nginx.conf"
  local prefix="${ARTIFACT_DIR}/nginx-prefix"
  local error_log="${ARTIFACT_DIR}/nginx-error.log"

  log "Checking generated nginx config"
  "${NGINX_BIN}" -p "${prefix}" -c "${conf}" -t

  log "Starting nginx on ${NGINX_HOST}:${NGINX_PORT}"
  "${NGINX_BIN}" \
      -p "${prefix}" \
      -c "${conf}" \
      -e "${error_log}" \
      -g "daemon off; error_log ${error_log} debug;" &
  NGINX_PID=$!

  for _ in $(seq 1 50); do
    if ! kill -0 "${NGINX_PID}" 2>/dev/null; then
      echo "nginx exited early; see ${error_log}" >&2
      exit 1
    fi
    if curl --max-time "${CLIENT_TIMEOUT_SEC}" -fsS -o /dev/null "http://${NGINX_HOST}:${NGINX_PORT}/health" 2>/dev/null; then
      log "nginx is reachable"
      return
    fi
    sleep 0.2
  done

  echo "Timed out waiting for nginx; see ${error_log}" >&2
  exit 1
}

wait_for_ratelimitly_ready() {
  local error_log="${ARTIFACT_DIR}/nginx-error.log"
  local url="http://${NGINX_HOST}:${NGINX_PORT}/allow"
  local code

  log "Warming Ratelimitly client via ${url}"
  for _ in $(seq 1 60); do
    code="$(curl --max-time "${CLIENT_TIMEOUT_SEC}" -s -o /dev/null -w "%{http_code}" "${url}" || true)"
    if grep -q 'rn: result success=1' "${error_log}"; then
      log "Ratelimitly client is ready"
      return
    fi
    if [[ "${code}" != "000" ]]; then
      sleep 0.2
    else
      sleep 0.5
    fi
  done

  echo "Timed out waiting for Ratelimitly client decision; see ${error_log}" >&2
  exit 1
}

run_burst() {
  local name="$1"
  local path="$2"
  local requests="$3"
  local output="${ARTIFACT_DIR}/${name}.codes"
  local url="http://${NGINX_HOST}:${NGINX_PORT}${path}"

  log "Running burst ${name}: requests=${requests} parallelism=${PARALLELISM} url=${url}"
  seq "${requests}" | xargs -P "${PARALLELISM}" -I{} bash -c '
    timeout="$2"
    code="$(curl --max-time "$timeout" -s -o /dev/null -w "%{http_code}" "$1" || true)"
    printf "%s\n" "${code:-000}"
  ' _ "${url}" "${CLIENT_TIMEOUT_SEC}" > "${output}"

  local ok deny fail transport other
  ok="$(grep -c '^200$' "${output}" || true)"
  deny="$(grep -c '^429$' "${output}" || true)"
  fail="$(grep -Ec '^5[0-9][0-9]$' "${output}" || true)"
  transport="$(grep -c '^000$' "${output}" || true)"
  other="$(grep -Ev '^(200|429|000|5[0-9][0-9])$' "${output}" | grep -c '.' || true)"

  printf '%s\trequests=%s\t200=%s\t429=%s\t5xx=%s\t000=%s\tother=%s\n' \
    "${name}" "${requests}" "${ok}" "${deny}" "${fail}" "${transport}" "${other}" \
    | tee -a "${ARTIFACT_DIR}/results.tsv"
}

extract_result_field() {
  local name="$1"
  local key="$2"
  awk -F'\t' -v name="${name}" -v key="${key}" '
    $1 == name {
      for (i = 2; i <= NF; i++) {
        split($i, pair, "=")
        if (pair[1] == key) {
          print pair[2]
        }
      }
    }
  ' "${ARTIFACT_DIR}/results.tsv" | tail -n1
}

assert_eq() {
  local label="$1"
  local actual="$2"
  local expected="$3"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "FAIL ${label}: expected ${expected}, got ${actual}" >&2
    exit 1
  fi
}

assert_gt() {
  local label="$1"
  local actual="$2"
  local min="$3"
  if (( actual <= min )); then
    echo "FAIL ${label}: expected > ${min}, got ${actual}" >&2
    exit 1
  fi
}

assert_results() {
  local allow_200 allow_429 allow_000 allow_5xx allow_other
  local deny_429 deny_000 deny_5xx deny_other
  allow_200="$(extract_result_field allow 200)"
  allow_429="$(extract_result_field allow 429)"
  allow_000="$(extract_result_field allow 000)"
  allow_5xx="$(extract_result_field allow 5xx)"
  allow_other="$(extract_result_field allow other)"
  deny_429="$(extract_result_field deny 429)"
  deny_000="$(extract_result_field deny 000)"
  deny_5xx="$(extract_result_field deny 5xx)"
  deny_other="$(extract_result_field deny other)"

  assert_gt "allow 200" "${allow_200}" 0
  assert_eq "allow 429" "${allow_429}" 0
  assert_eq "allow 000" "${allow_000}" 0
  assert_eq "allow 5xx" "${allow_5xx}" 0
  assert_eq "allow other" "${allow_other}" 0

  assert_gt "deny 429" "${deny_429}" 0
  assert_eq "deny 000" "${deny_000}" 0
  assert_eq "deny 5xx" "${deny_5xx}" 0
  assert_eq "deny other" "${deny_other}" 0

  grep -q 'rn: result success=1' "${ARTIFACT_DIR}/nginx-error.log" || {
    echo "FAIL missing rn allow decision logs" >&2
    exit 1
  }
  grep -q 'rn: result success=0' "${ARTIFACT_DIR}/nginx-error.log" || {
    echo "FAIL missing rn deny decision logs" >&2
    exit 1
  }
}

main() {
  need_cmd curl
  need_cmd dig
  need_cmd make
  if [[ "${EXTERNAL_SERVER}" != "1" ]]; then
    need_cmd cargo
    need_cmd cmake
    need_cmd elixir
    need_cmd python3
  fi

  : > "${ARTIFACT_DIR}/results.tsv"
  build_all
  if [[ "${EXTERNAL_SERVER}" == "1" ]]; then
    if [[ -z "${TENANT_KEY}" ]]; then
      echo "EXTERNAL_SERVER=1 requires TENANT_KEY=<rl-aes/rl-cookie key>" >&2
      exit 1
    fi
    log "Using external Ratelimitly server for tenant ${DOMAIN}"
    check_external_dns
  else
    start_rl_server
    register_tenant
    start_dns
  fi
  write_nginx_config
  start_nginx
  wait_for_ratelimitly_ready
  run_burst allow /allow "${ALLOW_REQUESTS}"
  run_burst deny /deny "${DENY_REQUESTS}"
  assert_results
  log "Completed successfully"
  log "Artifacts: ${ARTIFACT_DIR}"
}

main "$@"
