#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./tools/fetch-rl-c-client.sh [destination]

Fetches the public rl-c-client release recorded in
dependencies/rl-c-client.env and verifies its full commit SHA.

The default destination is ./_deps/rl-c-client. An existing Git checkout is
accepted only when its HEAD matches the locked commit and its working tree is
clean. Use an explicit RCLIENT_DIR for an intentionally modified development
or packaging checkout.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if (( $# > 1 )); then
  usage >&2
  exit 2
fi

RN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_FILE="$RN_DIR/dependencies/rl-c-client.env"
if [[ ! -f "$LOCK_FILE" ]]; then
  echo "rl-c-client dependency lock not found: $LOCK_FILE" >&2
  exit 1
fi

# The lock is repository-controlled and intentionally shell-readable so CI and
# local tooling consume the same values.
# shellcheck disable=SC1090
source "$LOCK_FILE"

: "${RL_C_CLIENT_REPOSITORY:?missing RL_C_CLIENT_REPOSITORY in dependency lock}"
: "${RL_C_CLIENT_TAG:?missing RL_C_CLIENT_TAG in dependency lock}"
: "${RL_C_CLIENT_COMMIT:?missing RL_C_CLIENT_COMMIT in dependency lock}"

if [[ "$RL_C_CLIENT_REPOSITORY" != https://* ]]; then
  echo "rl-c-client repository must use public HTTPS: $RL_C_CLIENT_REPOSITORY" >&2
  exit 1
fi
if [[ ! "$RL_C_CLIENT_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "invalid rl-c-client release tag in dependency lock: $RL_C_CLIENT_TAG" >&2
  exit 1
fi
if [[ ! "$RL_C_CLIENT_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
  echo "invalid rl-c-client commit in dependency lock: $RL_C_CLIENT_COMMIT" >&2
  exit 1
fi

DESTINATION="${1:-$RN_DIR/_deps/rl-c-client}"
if [[ -e "$DESTINATION" ]]; then
  if [[ -e "$DESTINATION/.git" ]]; then
    ACTUAL_COMMIT="$(git -C "$DESTINATION" rev-parse HEAD)"
    if [[ "$ACTUAL_COMMIT" == "$RL_C_CLIENT_COMMIT" ]]; then
      if ! DIRTY_STATE="$(git -C "$DESTINATION" status \
          --porcelain=v1 --untracked-files=normal)"; then
        echo "could not inspect locked rl-c-client working tree: $DESTINATION" >&2
        exit 1
      fi
      if [[ -n "$DIRTY_STATE" ]]; then
        echo "existing locked rl-c-client checkout has local changes:" >&2
        echo "  path: $DESTINATION" >&2
        echo "Use RCLIENT_DIR for an intentionally modified checkout." >&2
        exit 1
      fi
      echo "rl-c-client $RL_C_CLIENT_TAG is already present ($RL_C_CLIENT_COMMIT)"
      echo "Path: $DESTINATION"
      exit 0
    fi
    echo "existing rl-c-client checkout does not match the dependency lock:" >&2
    echo "  expected: $RL_C_CLIENT_COMMIT" >&2
    echo "  actual:   $ACTUAL_COMMIT" >&2
    exit 1
  fi
  echo "destination already exists: $DESTINATION" >&2
  exit 1
fi

DESTINATION_PARENT="$(dirname "$DESTINATION")"
DESTINATION_NAME="$(basename "$DESTINATION")"
mkdir -p "$DESTINATION_PARENT"
DESTINATION_PARENT="$(cd "$DESTINATION_PARENT" && pwd)"
DESTINATION="$DESTINATION_PARENT/$DESTINATION_NAME"

TEMP_DIR="$(mktemp -d "$DESTINATION_PARENT/.rl-c-client.XXXXXX")"
cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

git clone \
  --quiet \
  --depth=1 \
  --single-branch \
  --branch "$RL_C_CLIENT_TAG" \
  "$RL_C_CLIENT_REPOSITORY" \
  "$TEMP_DIR/checkout"

ACTUAL_COMMIT="$(git -C "$TEMP_DIR/checkout" rev-parse HEAD)"
if [[ "$ACTUAL_COMMIT" != "$RL_C_CLIENT_COMMIT" ]]; then
  echo "rl-c-client lock mismatch:" >&2
  echo "  tag:      $RL_C_CLIENT_TAG" >&2
  echo "  expected: $RL_C_CLIENT_COMMIT" >&2
  echo "  actual:   $ACTUAL_COMMIT" >&2
  exit 1
fi

mv "$TEMP_DIR/checkout" "$DESTINATION"
trap - EXIT
rmdir "$TEMP_DIR"

echo "Fetched rl-c-client $RL_C_CLIENT_TAG ($RL_C_CLIENT_COMMIT)"
echo "Path: $DESTINATION"
