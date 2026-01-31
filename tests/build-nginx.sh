#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 /path/to/nginx-src [--dynamic] [--clean]"
  exit 1
fi

NGX_SRC="$1"
DYNAMIC=""
CLEAN=""
for arg in "${@:2}"; do
  case "$arg" in
    --dynamic) DYNAMIC="--dynamic" ;;
    --clean) CLEAN="--clean" ;;
  esac
done
ROOT="/home/wojtek/glar"
RN_DIR="$ROOT/rn"
C_CLIENT="$ROOT/rl/clients/c"

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
fi

FLAGS=(
  "--with-cc-opt=-I${C_CLIENT}/include"
  "--with-ld-opt=-L${C_CLIENT} -lrclient -lcrypto -lssl -Wl,-rpath,${C_CLIENT}"
)

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
  echo "Built dynamic module in $NGX_SRC/objs"
else
  "$CONFIG" --add-module="$RN_DIR" "${FLAGS[@]}"
  make -j
  echo "Built nginx with rn module"
fi
