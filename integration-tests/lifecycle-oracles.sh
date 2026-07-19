#!/usr/bin/env bash

# Shared lifecycle assertions. Callers decide whether a mismatch is fatal
# immediately or accumulated with record_failure.

rn_expect_http_status() {
  local actual="$1"
  local expected="$2"
  [[ "${actual}" == "${expected}" ]]
}

rn_expect_log_count() {
  local file="$1"
  local pattern="$2"
  local expected="$3"
  local observed
  observed="$(grep -c -- "${pattern}" "${file}" 2>/dev/null || true)"
  [[ "${observed}" == "${expected}" ]]
}

# Return 0 when TERM is sufficient (or the process is already absent), and 1
# after using KILL. A forced kill is cleanup success but validation failure.
rn_terminate_pid() {
  local pid="$1"
  local label="$2"
  local attempts="${3:-30}"
  local delay="${4:-0.1}"
  local attempt

  if [[ -z "${pid}" ]] || ! kill -0 "${pid}" 2>/dev/null; then
    return 0
  fi
  kill -TERM "${pid}" 2>/dev/null || true
  for (( attempt = 0; attempt < attempts; attempt++ )); do
    if ! kill -0 "${pid}" 2>/dev/null; then
      wait "${pid}" 2>/dev/null || true
      return 0
    fi
    sleep "${delay}"
  done
  printf 'force-killing %s: pid=%s\n' "${label}" "${pid}" >&2
  kill -KILL "${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true
  return 1
}
