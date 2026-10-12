#!/usr/bin/env bash
# versions.lock.md is the only place a pin is set. Assert its machine-readable
# block is well formed, and that every install script's offline fallback
# (used when versions.lock.md cannot be read) equals the lock.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="${ROOT}/versions.lock.md"

die() { echo "pin-check FAIL: $*" >&2; exit 1; }

[[ -f "$LOCK" ]] || die "missing $LOCK"

lock() { # lock <key> <pattern> — the value, checked against the pattern
  local v
  v="$(grep -E "^$1=" "$LOCK" | head -1 | cut -d= -f2 || true)"
  [[ -n "$v" ]] || die "no $1= line in the machine-readable block of versions.lock.md"
  [[ "$v" =~ $2 ]] || die "$1=$v does not match $2"
  echo "$v"
}

ENVOY_PIN="$(lock ENVOY_PIN '^v1\.[0-9]+\.[0-9]+$')"
MODSECURITY_PIN="$(lock MODSECURITY_PIN '^v3\.0\.[0-9]+$')"
CRS_TAG="$(lock CRS_TAG '^v4\.[0-9]+\.[0-9]+$')"
ASH_PIN="$(lock ASH_PIN '^[0-9a-f]{40}$')"
GO_FTW_PIN="$(lock GO_FTW_PIN '^v2\.[0-9]+\.[0-9]+$')"

fallback() { # fallback <file> <want> — the ${VAR:-vX.Y.Z} default in that script must be <want>
  local got
  got="$(grep -Eo '^PIN="\$\{[A-Z_]+:-v[0-9]+\.[0-9]+\.[0-9]+\}"' "${ROOT}/$1" | grep -Eo 'v[0-9]+\.[0-9]+\.[0-9]+' || true)"
  [[ -n "$got" ]] || die "$1: no PIN=\"\${VAR:-vX.Y.Z}\" fallback found"
  [[ "$got" == "$2" ]] || die "$1 falls back to $got, versions.lock.md pins $2"
}

fallback demo/scripts/install-envoy.sh "$ENVOY_PIN"
fallback demo/scripts/install-crs.sh "$CRS_TAG"
fallback demo/scripts/install-libmodsecurity.sh "$MODSECURITY_PIN"
fallback scripts/install-libmodsecurity-ubuntu.sh "$MODSECURITY_PIN"
fallback demo/scripts/install-go-ftw.sh "$GO_FTW_PIN"

# ASH is installed from git by commit SHA (not a movable tag). The workflow line
# must use the same 40-hex as ASH_PIN.
ASH_WF="${ROOT}/.github/workflows/ash.yml"
[[ -f "$ASH_WF" ]] || die "missing $ASH_WF"
ash_got="$(grep -Eo 'git\+https://github.com/awslabs/automated-security-helper\.git@[0-9a-f]{40}' "$ASH_WF" \
  | head -1 | grep -Eo '[0-9a-f]{40}$' || true)"
[[ -n "$ash_got" ]] || die "ash.yml: no commit-pinned automated-security-helper pip install line"
[[ "$ash_got" == "$ASH_PIN" ]] || die "ash.yml installs @$ash_got, versions.lock.md ASH_PIN=$ASH_PIN"

echo "pin-check OK: ENVOY_PIN=$ENVOY_PIN MODSECURITY_PIN=$MODSECURITY_PIN CRS_TAG=$CRS_TAG GO_FTW_PIN=$GO_FTW_PIN ASH_PIN=$ASH_PIN (install-script fallbacks + ash.yml match)"
