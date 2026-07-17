#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./tools/resolve-rl-c-client.sh

Prints the absolute rl-c-client checkout path for build and test helpers.

With no RCLIENT_DIR override, the helper fetches or verifies the exact public
release locked by dependencies/rl-c-client.env under ./_deps/rl-c-client.
An explicit RCLIENT_DIR is treated as an intentional development or packaging
override and must name an existing directory.
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

RN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -n "${RCLIENT_DIR:-}" ]]; then
  if [[ ! -d "${RCLIENT_DIR}" ]]; then
    echo "rl-c-client override not found: ${RCLIENT_DIR}" >&2
    exit 1
  fi
  (cd "${RCLIENT_DIR}" && pwd)
  exit 0
fi

LOCKED_RCLIENT_DIR="${RN_DIR}/_deps/rl-c-client"
"${RN_DIR}/tools/fetch-rl-c-client.sh" "${LOCKED_RCLIENT_DIR}" >&2
(cd "${LOCKED_RCLIENT_DIR}" && pwd)
