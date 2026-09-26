#!/usr/bin/env bash
# Stub: fetch OWASP CRS at the pin in versions.lock.md (v4.29.0).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PIN="$(grep -E '^CRS_TAG=' "$ROOT/versions.lock.md" | head -1 | cut -d= -f2)"
PIN="${PIN:-v4.29.0}"
DEST="${CRS_DIR:-$ROOT/demo/.crs}"

echo "envoy-modsec-connex demo: CRS pin is ${PIN}"
echo "Release: https://github.com/coreruleset/coreruleset/releases/tag/${PIN}"
echo "Target directory: ${DEST}"
echo

if [[ -d "$DEST/.git" ]]; then
  echo "CRS checkout already present at ${DEST}"
  git -C "$DEST" fetch --tags --quiet || true
  git -C "$DEST" checkout --quiet "$PIN" || {
    echo "WARN: could not checkout ${PIN}; remove ${DEST} and re-run"
    exit 1
  }
  echo "OK: CRS at ${PIN}"
  exit 0
fi

mkdir -p "$(dirname "$DEST")"
if command -v git >/dev/null 2>&1; then
  git clone --depth 1 --branch "$PIN" https://github.com/coreruleset/coreruleset.git "$DEST"
  echo "OK: cloned CRS ${PIN} → ${DEST}"
  exit 0
fi

echo "git not available. Download CRS ${PIN} manually — see demo/README.md"
exit 1
