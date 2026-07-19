#!/usr/bin/env bash
set -euo pipefail

RN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALLOWLIST="${RN_ROOT}/tools/sanitizer-known-reports.txt"
REPORT_PATTERN='ERROR: AddressSanitizer|ERROR: LeakSanitizer|SUMMARY: AddressSanitizer|runtime error:'

if (( $# != 1 )) || [[ ! -d "$1" ]]; then
  echo "Usage: $0 ARTIFACT_DIRECTORY" >&2
  exit 2
fi

reports="$(mktemp)"
unexpected="$(mktemp)"
next="$(mktemp)"
cleanup() {
  rm -f "${reports}" "${unexpected}" "${next}"
}
trap cleanup EXIT

if ! grep -R -n -E "${REPORT_PATTERN}" "$1" >"${reports}"; then
  echo "[sanitizers] no sanitizer reports found"
  exit 0
fi

cp "${reports}" "${unexpected}"
while IFS= read -r accepted; do
  [[ -z "${accepted}" || "${accepted}" == \#* ]] && continue
  grep -F -v -- "${accepted}" "${unexpected}" >"${next}" || true
  mv "${next}" "${unexpected}"
done <"${ALLOWLIST}"

if [[ -s "${unexpected}" ]]; then
  cat "${unexpected}"
  exit 1
fi

echo "[sanitizers] only exact reviewed upstream-nginx reports found"
