#!/usr/bin/env bash
# Assert versions.lock.md machine-readable pins match CI / agent expectations.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="${ROOT}/versions.lock.md"

ENVOY_PIN="${ENVOY_PIN:-v1.39.1}"
MODSECURITY_PIN="${MODSECURITY_PIN:-v3.0.16}"
CRS_TAG="${CRS_TAG:-v4.29.0}"

die() { echo "pin-check FAIL: $*" >&2; exit 1; }

[[ -f "$LOCK" ]] || die "missing $LOCK"

need() {
  local key="$1" want="$2"
  grep -Eq "^${key}=${want}$" "$LOCK" || die "expected ${key}=${want} in machine-readable block of versions.lock.md"
}

need ENVOY_PIN "$ENVOY_PIN"
need MODSECURITY_PIN "$MODSECURITY_PIN"
need CRS_TAG "$CRS_TAG"

echo "pin-check OK: ENVOY_PIN=$ENVOY_PIN MODSECURITY_PIN=$MODSECURITY_PIN CRS_TAG=$CRS_TAG"
