#!/usr/bin/env bash
set -euo pipefail

RN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rn-dependency-bootstrap.XXXXXX")"
trap 'rm -rf "${TEST_ROOT}"' EXIT

fail() {
  echo "FAIL dependency bootstrap: $*" >&2
  exit 1
}

for command in cp env git grep mkdir mktemp rm; do
  command -v "${command}" >/dev/null 2>&1 || fail "missing command: ${command}"
done

SUPPORTED_ENTRYPOINTS=(
  Makefile
  config
  start-nginx.sh
  tools/build-nginx.sh
  tools/sanitized-lifecycle.sh
  tests/build-nginx.sh
  tests/test-c-client-contract.sh
  tests/test-config.sh
  tests/test-srv-records.sh
  integration-tests/public.sh
  integration-tests/lifecycle-regressions.sh
  integration-tests/dynamic-module-relocation.sh
  integration-tests/internal-full-stack.sh
)

for entrypoint in "${SUPPORTED_ENTRYPOINTS[@]}"; do
  grep -Fq 'resolve-rl-c-client.sh' "${RN_ROOT}/${entrypoint}" \
    || fail "supported entrypoint bypasses the dependency resolver: ${entrypoint}"
  if grep -Eq 'git[[:space:]]+(clone|fetch|checkout)' "${RN_ROOT}/${entrypoint}"; then
    fail "supported entrypoint contains an independent Git bootstrap: ${entrypoint}"
  fi
  if grep -Fq '../rl-c-client' "${RN_ROOT}/${entrypoint}"; then
    fail "supported entrypoint contains an implicit sibling fallback: ${entrypoint}"
  fi
done

for contract_gate in Makefile tools/sanitized-lifecycle.sh; do
  grep -Fq 'tests/test-c-client-contract.sh' "${RN_ROOT}/${contract_gate}" \
    || fail "required gate omits the C-client contract probe: ${contract_gate}"
done

SOURCE_REPOSITORY="${TEST_ROOT}/source"
FIXTURE_ROOT="${TEST_ROOT}/rl-nginx"
FIXTURE_REPOSITORY="https://fixture.invalid/rl-c-client.git"

git init -q -b main "${SOURCE_REPOSITORY}"
git -C "${SOURCE_REPOSITORY}" config user.name "rl-nginx bootstrap test"
git -C "${SOURCE_REPOSITORY}" config user.email "bootstrap-test@example.invalid"
printf 'locked release\n' >"${SOURCE_REPOSITORY}/version.txt"
git -C "${SOURCE_REPOSITORY}" add version.txt
git -C "${SOURCE_REPOSITORY}" commit -q -m "Locked release"
LOCKED_COMMIT="$(git -C "${SOURCE_REPOSITORY}" rev-parse HEAD)"
git -C "${SOURCE_REPOSITORY}" tag v1.2.3

printf 'floating branch moved\n' >"${SOURCE_REPOSITORY}/version.txt"
git -C "${SOURCE_REPOSITORY}" commit -q -am "Advance main"
FLOATING_COMMIT="$(git -C "${SOURCE_REPOSITORY}" rev-parse HEAD)"
[[ "${LOCKED_COMMIT}" != "${FLOATING_COMMIT}" ]] \
  || fail "fixture release and floating branch unexpectedly match"

mkdir -p "${FIXTURE_ROOT}/tools" "${FIXTURE_ROOT}/dependencies"
cp "${RN_ROOT}/tools/fetch-rl-c-client.sh" "${FIXTURE_ROOT}/tools/"
cp "${RN_ROOT}/tools/resolve-rl-c-client.sh" "${FIXTURE_ROOT}/tools/"

write_lock() {
  local tag="$1"
  local commit="$2"

  cat >"${FIXTURE_ROOT}/dependencies/rl-c-client.env" <<EOF
RL_C_CLIENT_REPOSITORY="${FIXTURE_REPOSITORY}"
RL_C_CLIENT_TAG="${tag}"
RL_C_CLIENT_COMMIT="${commit}"
EOF
}

# Keep the fixture entirely local while exercising the production HTTPS-only
# bootstrap. Git rewrites only this deliberately invalid fixture URL.
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0="url.file://${SOURCE_REPOSITORY}.insteadOf"
export GIT_CONFIG_VALUE_0="${FIXTURE_REPOSITORY}"
export GIT_CONFIG_KEY_1="advice.detachedHead"
export GIT_CONFIG_VALUE_1="false"

write_lock v1.2.3 "${LOCKED_COMMIT}"
FETCHED_CHECKOUT="${TEST_ROOT}/fetched"
"${FIXTURE_ROOT}/tools/fetch-rl-c-client.sh" "${FETCHED_CHECKOUT}" >/dev/null
[[ "$(git -C "${FETCHED_CHECKOUT}" rev-parse HEAD)" == "${LOCKED_COMMIT}" ]] \
  || fail "fetch did not select the locked release commit"
[[ "$(git -C "${FETCHED_CHECKOUT}" rev-parse HEAD)" != "${FLOATING_COMMIT}" ]] \
  || fail "fetch selected the floating branch head"

# Reusing an exact clean checkout is allowed; silently accepting revision or
# working-tree drift is not.
"${FIXTURE_ROOT}/tools/fetch-rl-c-client.sh" "${FETCHED_CHECKOUT}" >/dev/null
DIRTY_CHECKOUT="${TEST_ROOT}/dirty"
git clone -q --branch v1.2.3 "${SOURCE_REPOSITORY}" "${DIRTY_CHECKOUT}"
printf 'local modification\n' >"${DIRTY_CHECKOUT}/version.txt"
if "${FIXTURE_ROOT}/tools/fetch-rl-c-client.sh" "${DIRTY_CHECKOUT}" \
    >"${TEST_ROOT}/dirty.out" 2>&1; then
  fail "fetch accepted a dirty checkout at the locked commit"
fi
grep -Fq "locked rl-c-client checkout has local changes" \
  "${TEST_ROOT}/dirty.out" \
  || fail "dirty-checkout failure did not explain the immutable default"

DRIFTED_CHECKOUT="${TEST_ROOT}/drifted"
git clone -q "${SOURCE_REPOSITORY}" "${DRIFTED_CHECKOUT}"
if "${FIXTURE_ROOT}/tools/fetch-rl-c-client.sh" "${DRIFTED_CHECKOUT}" \
    >"${TEST_ROOT}/drift.out" 2>&1; then
  fail "fetch accepted an existing checkout at the floating branch head"
fi
grep -Fq "does not match the dependency lock" "${TEST_ROOT}/drift.out" \
  || fail "drift failure did not explain the lock mismatch"

# Floating branch names are invalid lock input even if they happen to resolve.
write_lock main "${FLOATING_COMMIT}"
if "${FIXTURE_ROOT}/tools/fetch-rl-c-client.sh" "${TEST_ROOT}/floating" \
    >"${TEST_ROOT}/floating.out" 2>&1; then
  fail "fetch accepted a floating branch name"
fi
grep -Fq "invalid rl-c-client release tag" "${TEST_ROOT}/floating.out" \
  || fail "floating-tag failure did not identify the invalid release tag"

# A valid release tag is still rejected when its full locked SHA is wrong.
write_lock v1.2.3 0000000000000000000000000000000000000000
if "${FIXTURE_ROOT}/tools/fetch-rl-c-client.sh" "${TEST_ROOT}/wrong-commit" \
    >"${TEST_ROOT}/wrong-commit.out" 2>&1; then
  fail "fetch accepted a release tag with the wrong locked SHA"
fi
grep -Fq "rl-c-client lock mismatch" "${TEST_ROOT}/wrong-commit.out" \
  || fail "commit failure did not explain the lock mismatch"
[[ ! -e "${TEST_ROOT}/wrong-commit" ]] \
  || fail "failed fetch left a partial destination"

# Default resolution ignores an adjacent development checkout and materializes
# the exact lock. Explicit RCLIENT_DIR remains an intentional escape hatch.
write_lock v1.2.3 "${LOCKED_COMMIT}"
mkdir -p "${TEST_ROOT}/rl-c-client"
RESOLVED_DEFAULT="$(env -u RCLIENT_DIR "${FIXTURE_ROOT}/tools/resolve-rl-c-client.sh" 2>/dev/null)"
[[ "${RESOLVED_DEFAULT}" == "${FIXTURE_ROOT}/_deps/rl-c-client" ]] \
  || fail "default resolver selected an implicit checkout: ${RESOLVED_DEFAULT}"
[[ "$(git -C "${RESOLVED_DEFAULT}" rev-parse HEAD)" == "${LOCKED_COMMIT}" ]] \
  || fail "default resolver did not verify the locked commit"

EXPLICIT_CHECKOUT="${TEST_ROOT}/intentional-client"
git clone -q --branch v1.2.3 "${SOURCE_REPOSITORY}" "${EXPLICIT_CHECKOUT}"
printf 'intentional development modification\n' \
  >"${EXPLICIT_CHECKOUT}/version.txt"
RESOLVED_EXPLICIT="$(RCLIENT_DIR="${EXPLICIT_CHECKOUT}" \
  "${FIXTURE_ROOT}/tools/resolve-rl-c-client.sh")"
[[ "${RESOLVED_EXPLICIT}" == "${EXPLICIT_CHECKOUT}" ]] \
  || fail "resolver rejected or ignored a dirty explicit RCLIENT_DIR"

echo "PASS deterministic rl-c-client bootstrap"
