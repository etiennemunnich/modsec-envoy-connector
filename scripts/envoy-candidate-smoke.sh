#!/usr/bin/env bash
# Run the demo drills against the Envoy on PATH (a candidate release):
# smoke, fail-closed, and the HTTP/1.1 + HTTP/2 fail-mode suite, with CRS.
#
#   ENVOY_VERSION=v1.38.4 ./scripts/envoy-candidate-smoke.sh
#
# ENVOY_VERSION, when set, must match `envoy --version` (install it with
# ENVOY_VERSION=… ./demo/scripts/install-envoy.sh). The demo Envoy config is
# used unchanged — never relax failure_mode_allow to make a candidate pass.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEMO="${ROOT}/demo/scripts"

command -v envoy >/dev/null || { echo "envoy not on PATH" >&2; exit 2; }
line="$(envoy --version 2>&1 | grep -m1 'version:' || true)"
echo "==> ${line}"
if [[ -n "${ENVOY_VERSION:-}" && "${line}" != *"/${ENVOY_VERSION#v}/"* ]]; then
  echo "envoy on PATH is not ${ENVOY_VERSION}" >&2
  exit 1
fi
grep -q 'failure_mode_allow: false' "${ROOT}/demo/envoy/envoy.yaml" \
  || { echo "demo/envoy/envoy.yaml must keep failure_mode_allow: false" >&2; exit 1; }

cleanup() { "${DEMO}/down.sh" >/dev/null 2>&1 || true; }
trap cleanup EXIT

rc=0
"${DEMO}/up.sh"
for step in smoke fail-closed fail-modes; do
  echo "==> ${step}"
  if ! "${DEMO}/${step}.sh"; then
    echo "==> ${step} FAILED"
    rc=1
  fi
done

if [[ "${rc}" -ne 0 ]]; then
  echo "ENVOY CANDIDATE FAILED (${line})"
  exit 1
fi
echo "ENVOY CANDIDATE PASSED (${line})"
