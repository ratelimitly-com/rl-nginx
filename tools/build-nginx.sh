#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./tools/build-nginx.sh /path/to/nginx-src [--dynamic] [--compat] [--clean] [--debug] [--sanitize] [--skip-rclient-build]

Builds rl-c-client and then configures/builds nginx with the rl-nginx module.

Environment:
  RCLIENT_DIR=/path/to/rl-c-client   C client checkout path.

Defaults:
  Without RCLIENT_DIR, the exact release in dependencies/rl-c-client.env is
  fetched or verified under ./_deps/rl-c-client. Adjacent development
  checkouts are never selected implicitly.

Sanitizers:
  --sanitize instruments nginx and the module. Use
  ./tools/sanitized-lifecycle.sh to instrument the C client and run the complete
  lifecycle gate as well.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 1
fi

RN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NGX_SRC="$1"
shift

SKIP_RCLIENT_BUILD=0
BUILD_ARGS=()

for arg in "$@"; do
  case "$arg" in
    --dynamic|--compat|--clean|--debug|--sanitize)
      BUILD_ARGS+=("$arg")
      ;;
    --skip-rclient-build)
      SKIP_RCLIENT_BUILD=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      usage >&2
      exit 1
      ;;
  esac
done

RCLIENT_DIR="$("$RN_DIR/tools/resolve-rl-c-client.sh")"

if [[ ! -d "$NGX_SRC" ]]; then
  echo "nginx source not found: $NGX_SRC" >&2
  exit 1
fi

if (( ! SKIP_RCLIENT_BUILD )); then
  make -C "$RCLIENT_DIR"
fi

RCLIENT_DIR="$RCLIENT_DIR" "$RN_DIR/tests/build-nginx.sh" "$NGX_SRC" "${BUILD_ARGS[@]}"
