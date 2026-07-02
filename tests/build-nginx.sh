#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: $0 /path/to/nginx-src [--dynamic] [--compat] [--clean] [--debug]"
  exit 0
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 /path/to/nginx-src [--dynamic] [--compat] [--clean] [--debug]"
  exit 1
fi

NGX_SRC="$1"
DYNAMIC=""
COMPAT=""
CLEAN=""
DEBUG=""
for arg in "${@:2}"; do
  case "$arg" in
    --dynamic) DYNAMIC="--dynamic" ;;
    --compat) COMPAT="--compat" ;;
    --clean) CLEAN="--clean" ;;
    --debug) DEBUG="--debug" ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: $0 /path/to/nginx-src [--dynamic] [--compat] [--clean] [--debug]" >&2
      exit 1
      ;;
  esac
done
RN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -n "${RCLIENT_DIR:-}" ]]; then
  if [[ ! -d "$RCLIENT_DIR" ]]; then
    echo "rl-c-client path not found: $RCLIENT_DIR" >&2
    exit 1
  fi
  C_CLIENT="$(cd "$RCLIENT_DIR" && pwd)"
elif [[ -d "$RN_DIR/../rl-c-client" ]]; then
  C_CLIENT="$(cd "$RN_DIR/../rl-c-client" && pwd)"
else
  echo "rl-c-client not found." >&2
  echo "Set RCLIENT_DIR or clone rl-c-client next to this repo:" >&2
  echo "  git clone https://github.com/ratelimitly-com/rl-c-client.git ../rl-c-client" >&2
  exit 1
fi

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

FLAGS=(
  "--with-cc-opt=-I${C_CLIENT}/include"
  "--with-ld-opt=-L${C_CLIENT} -lrclient -lcrypto -lssl -Wl,-rpath,${C_CLIENT}"
)
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
  make modules
  if [[ ! -f "$NGX_ROOT/objs/ngx_http_rn_module.so" ]]; then
    echo "dynamic module was not produced: $NGX_ROOT/objs/ngx_http_rn_module.so" >&2
    exit 1
  fi
  echo "Built dynamic module: $NGX_ROOT/objs/ngx_http_rn_module.so"
else
  "$CONFIG" --add-module="$RN_DIR" "${FLAGS[@]}"
  make -j
  if [[ ! -x "$NGX_ROOT/objs/nginx" ]]; then
    echo "nginx binary was not produced: $NGX_ROOT/objs/nginx" >&2
    exit 1
  fi
  echo "Built nginx with rl-nginx module"
fi
