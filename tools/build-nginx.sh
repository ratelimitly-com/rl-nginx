#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./tools/build-nginx.sh /path/to/nginx-src [--dynamic] [--compat] [--clean] [--debug] [--skip-rclient-build]

Builds rl-c-client and then configures/builds nginx with the rl-nginx module.

Environment:
  RCLIENT_DIR=/path/to/rl-c-client   C client checkout path.

Defaults:
  RCLIENT_DIR is auto-detected as ../rl-c-client when present.
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
    --dynamic|--compat|--clean|--debug)
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

detect_rclient_dir() {
  if [[ -n "${RCLIENT_DIR:-}" ]]; then
    (cd "$RCLIENT_DIR" && pwd)
    return 0
  fi
  if [[ -d "$RN_DIR/../rl-c-client" ]]; then
    (cd "$RN_DIR/../rl-c-client" && pwd)
    return 0
  fi
  return 1
}

RCLIENT_DIR="$(detect_rclient_dir || true)"
if [[ -z "$RCLIENT_DIR" ]]; then
  echo "C client not found. Set RCLIENT_DIR or clone rl-c-client next to this repo:" >&2
  echo "  git clone https://github.com/ratelimitly-com/rl-c-client.git ../rl-c-client" >&2
  exit 1
fi

if [[ ! -d "$NGX_SRC" ]]; then
  echo "nginx source not found: $NGX_SRC" >&2
  exit 1
fi

if (( ! SKIP_RCLIENT_BUILD )); then
  make -C "$RCLIENT_DIR"
fi

RCLIENT_DIR="$RCLIENT_DIR" "$RN_DIR/tests/build-nginx.sh" "$NGX_SRC" "${BUILD_ARGS[@]}"
