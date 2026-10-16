#!/usr/bin/env bash
# Fetch OWASP CRS at the pin in versions.lock.md (or CRS_TAG) into demo/.crs
# (or CRS_DIR) and create crs-setup.conf from the shipped example (review it
# before production use).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PIN="${CRS_TAG:-$(grep -E '^CRS_TAG=' "$ROOT/versions.lock.md" | head -1 | cut -d= -f2)}"
PIN="${PIN:-v4.30.0}"
DEST="${CRS_DIR:-$ROOT/demo/.crs}"

echo "CRS pin ${PIN} → ${DEST}"
echo "Release: https://github.com/coreruleset/coreruleset/releases/tag/${PIN}"

command -v git >/dev/null || { echo "git is required (or download CRS ${PIN} into ${DEST})" >&2; exit 1; }
if [[ -d "$DEST/.git" ]]; then
  if ! git -C "$DEST" rev-parse --quiet --verify "refs/tags/${PIN}^{commit}" >/dev/null; then
    git -C "$DEST" fetch --depth 1 --quiet origin "refs/tags/${PIN}:refs/tags/${PIN}"
  fi
  git -c advice.detachedHead=false -C "$DEST" checkout --quiet "refs/tags/${PIN}" || {
    echo "could not checkout ${PIN}; remove ${DEST} and re-run" >&2
    exit 1
  }
else
  mkdir -p "$(dirname "$DEST")"
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$PIN" \
    https://github.com/coreruleset/coreruleset.git "$DEST"
fi
got="$(git -C "$DEST" describe --tags --exact-match HEAD 2>/dev/null || true)"
[[ "$got" == "$PIN" ]] || { echo "${DEST} is at '${got:-no tag}', want ${PIN}" >&2; exit 1; }

if [[ ! -f "$DEST/crs-setup.conf" ]]; then
  cp "$DEST/crs-setup.conf.example" "$DEST/crs-setup.conf"
  echo "created ${DEST}/crs-setup.conf from crs-setup.conf.example"
fi

echo "OK: CRS ${got} with $(find "$DEST/rules" -name '*.conf' | wc -l | tr -d ' ') rule files"
