#!/usr/bin/env bash
# release-version.sh <tag> — the release workflow's version check.
#
# Succeeds only if <tag> is vX.Y.Z or vX.Y.Z-<pre-release> and equals "v" plus
# the version of every crate in crates/*/Cargo.toml, pre-release included:
# v0.1.0-alpha.2 needs 0.1.0-alpha.2, and neither 0.1.0 nor 0.1.0-alpha.1.
# RELEASE_VERSION_ROOT points at another tree (for scripts/test-ci-scripts.sh).
set -euo pipefail

ROOT="${RELEASE_VERSION_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
tag="${1:-}"
[[ -n "${tag}" ]] || { echo "usage: release-version.sh <tag>" >&2; exit 2; }

if [[ ! "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
  echo "::error::tag ${tag} is not vX.Y.Z or vX.Y.Z-<pre-release>"
  exit 1
fi

n=0
for toml in "${ROOT}"/crates/*/Cargo.toml; do
  [[ -f "${toml}" ]] || continue
  ver="$(awk -F'"' '/^version[[:space:]]*=/ { print $2; exit }' "${toml}")"
  if [[ -z "${ver}" ]]; then
    echo "::error::no version line in ${toml#"${ROOT}"/}"
    exit 1
  fi
  if [[ "${tag}" != "v${ver}" ]]; then
    echo "::error::tag ${tag} != v${ver} (${toml#"${ROOT}"/}); the tag must equal v + the crate version"
    exit 1
  fi
  n=$((n + 1))
done
if [[ "${n}" -eq 0 ]]; then
  echo "::error::no crates/*/Cargo.toml under ${ROOT}"
  exit 1
fi
echo "release version ${tag} matches ${n} crates"
