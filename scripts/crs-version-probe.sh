#!/usr/bin/env bash
# Probe one CRS tag through the demo: fetch it into its own directory, load it
# in the pinned engine behind Envoy, then run smoke and go-ftw.
#
#   CRS_TAG=v4.28.0 ./scripts/crs-version-probe.sh
#   CRS_TAG=v4.28.0 FTW_MODE=full ./scripts/crs-version-probe.sh
#
# The go-ftw overrides in demo/ftw/ were measured on the pinned CRS; test ids
# that changed between tags can show up as failures in full mode.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEMO="${ROOT}/demo/scripts"
: "${CRS_TAG:?set CRS_TAG, e.g. CRS_TAG=v4.28.0}"
export CRS_TAG
export CRS_DIR="${CRS_DIR:-${ROOT}/demo/.crs-${CRS_TAG}}"
FTW_MODE="${FTW_MODE:-smoke}"

"${DEMO}/install-crs.sh"
got="$(git -C "${CRS_DIR}" describe --tags --exact-match 2>/dev/null || true)"
[[ "${got}" == "${CRS_TAG}" ]] || { echo "${CRS_DIR} is at '${got}', want ${CRS_TAG}" >&2; exit 1; }

cleanup() { "${DEMO}/down.sh" >/dev/null 2>&1 || true; }
trap cleanup EXIT

rc=0
"${DEMO}/up.sh"
echo "==> smoke"
"${DEMO}/smoke.sh" || rc=1
echo "==> go-ftw ${FTW_MODE}"
"${DEMO}/go-ftw.sh" "${FTW_MODE}" || rc=1

if [[ "${rc}" -ne 0 ]]; then
  echo "CRS PROBE FAILED (${CRS_TAG})"
  exit 1
fi
echo "CRS PROBE PASSED (${CRS_TAG}, go-ftw ${FTW_MODE})"
