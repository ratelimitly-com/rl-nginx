#!/usr/bin/env bash
set -euo pipefail

RN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${RN_DIR}/tools/sanitizer-flags.env"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: $0 /path/to/nginx-src [--dynamic] [--compat] [--clean] [--debug] [--sanitize]"
  exit 0
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 /path/to/nginx-src [--dynamic] [--compat] [--clean] [--debug] [--sanitize]"
  exit 1
fi

NGX_SRC="$1"
DYNAMIC=""
COMPAT=""
CLEAN=""
DEBUG=""
SANITIZE=""
for arg in "${@:2}"; do
  case "$arg" in
    --dynamic) DYNAMIC="--dynamic" ;;
    --compat) COMPAT="--compat" ;;
    --clean) CLEAN="--clean" ;;
    --debug) DEBUG="--debug" ;;
    --sanitize) SANITIZE="--sanitize" ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: $0 /path/to/nginx-src [--dynamic] [--compat] [--clean] [--debug] [--sanitize]" >&2
      exit 1
      ;;
  esac
done
C_CLIENT="$("$RN_DIR/tools/resolve-rl-c-client.sh")"

if [[ ! -d "$NGX_SRC" ]]; then
  echo "nginx source not found: $NGX_SRC"
  exit 1
fi

NGX_ROOT="$NGX_SRC"
if [[ ! -f "$NGX_ROOT/configure" && ! -f "$NGX_ROOT/auto/configure" ]]; then
  if [[ -f "$NGX_SRC/../auto/configure" || -f "$NGX_SRC/../configure" ]]; then
    NGX_ROOT="$(cd "$NGX_SRC/.." && pwd)"
    echo "Using nginx root: $NGX_ROOT"
  else
    echo "nginx configure script not found under: $NGX_SRC" >&2
    exit 1
  fi
else
  NGX_ROOT="$(cd "$NGX_ROOT" && pwd)"
fi

FLAGS=()
CC_OPT=()
if [[ "$SANITIZE" == "--sanitize" ]]; then
  read -r -a sanitizer_compile_flags <<<"${RN_SANITIZER_COMPILE_FLAGS}"
  CC_OPT+=("${sanitizer_compile_flags[@]}")
  FLAGS+=("--with-ld-opt=${RN_SANITIZER_LINK_FLAGS}")
fi
if [[ "${RN_TEST_FAULT_INJECTION:-0}" == "1" ]]; then
  CC_OPT+=(-DRN_TEST_FAULT_INJECTION=1)
fi
if (( ${#CC_OPT[@]} > 0 )); then
  FLAGS+=("--with-cc-opt=${CC_OPT[*]}")
fi
if [[ "$DEBUG" == "--debug" ]]; then
  FLAGS+=("--with-debug")
fi
if [[ "$COMPAT" == "--compat" ]]; then
  FLAGS+=("--with-compat")
fi

cd "$NGX_ROOT"
CONFIG="./configure"
if [[ ! -f "$CONFIG" && -f "./auto/configure" ]]; then
  CONFIG="./auto/configure"
fi
if [[ "$CLEAN" == "--clean" ]]; then
  rm -rf objs
fi
if [[ "$DYNAMIC" == "--dynamic" ]]; then
  "$CONFIG" --add-dynamic-module="$RN_DIR" "${FLAGS[@]}"
  if ! grep -Eq -- '(^|[[:space:]])-Werror([[:space:]]|$)' "$NGX_ROOT/objs/Makefile"; then
    echo "nginx build is not treating compiler warnings as errors" >&2
    exit 1
  fi
  make modules
  if [[ ! -f "$NGX_ROOT/objs/ngx_http_rn_module.so" ]]; then
    echo "dynamic module was not produced: $NGX_ROOT/objs/ngx_http_rn_module.so" >&2
    exit 1
  fi
  echo "Built dynamic module: $NGX_ROOT/objs/ngx_http_rn_module.so"
else
  "$CONFIG" --add-module="$RN_DIR" "${FLAGS[@]}"
  if ! grep -Eq -- '(^|[[:space:]])-Werror([[:space:]]|$)' "$NGX_ROOT/objs/Makefile"; then
    echo "nginx build is not treating compiler warnings as errors" >&2
    exit 1
  fi
  make -j
  if [[ ! -x "$NGX_ROOT/objs/nginx" ]]; then
    echo "nginx binary was not produced: $NGX_ROOT/objs/nginx" >&2
    exit 1
  fi
  echo "Built nginx with rl-nginx module"
fi
