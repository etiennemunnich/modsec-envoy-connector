#!/usr/bin/env bash
# Fetch OWASP CRS at the pin in versions.lock.md into demo/.crs and create
# crs-setup.conf from the shipped example (review it before production use).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PIN="$(grep -E '^CRS_TAG=' "$ROOT/versions.lock.md" | head -1 | cut -d= -f2)"
PIN="${PIN:-v4.29.0}"
DEST="${CRS_DIR:-$ROOT/demo/.crs}"

echo "CRS pin ${PIN} → ${DEST}"
echo "Release: https://github.com/coreruleset/coreruleset/releases/tag/${PIN}"

if [[ -d "$DEST/.git" ]]; then
  git -C "$DEST" fetch --depth 1 --quiet origin "refs/tags/${PIN}:refs/tags/${PIN}" || true
  git -C "$DEST" checkout --quiet "$PIN" || {
    echo "could not checkout ${PIN}; remove ${DEST} and re-run" >&2
    exit 1
  }
else
  command -v git >/dev/null || { echo "git is required (or download CRS ${PIN} into ${DEST})" >&2; exit 1; }
  mkdir -p "$(dirname "$DEST")"
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$PIN" \
    https://github.com/coreruleset/coreruleset.git "$DEST"
fi

if [[ ! -f "$DEST/crs-setup.conf" ]]; then
  cp "$DEST/crs-setup.conf.example" "$DEST/crs-setup.conf"
  echo "created ${DEST}/crs-setup.conf from crs-setup.conf.example"
fi

echo "OK: CRS $(git -C "$DEST" describe --tags 2>/dev/null || echo "$PIN") with $(find "$DEST/rules" -name '*.conf' | wc -l | tr -d ' ') rule files"
