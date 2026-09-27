#!/usr/bin/env bash
# Decide whether a ci.yml run is docs-only (heavy jobs may then be skipped).
# Prints docs_only=true|false (also to $GITHUB_OUTPUT when set).
#
#   BASE=<sha> HEAD=<sha> ./scripts/ci-changes.sh
#
# docs_only=true only when BASE is a known commit and every changed file is
# under docs/ or ends in .md, except versions.lock.md (pins always run CI).
# No base (new branch, dispatch, schedule), an unknown base or an empty diff
# all mean false: when in doubt, run everything.
set -euo pipefail
cd "$(dirname "$0")/.."

HEAD="${HEAD:-$(git rev-parse HEAD)}"
BASE="${BASE:-}"

out() {
  echo "docs_only=$1${2:+ ($2)}"
  [[ -z "${GITHUB_OUTPUT:-}" ]] || echo "docs_only=$1" >>"${GITHUB_OUTPUT}"
  exit 0
}

[[ -n "${BASE}" && ! "${BASE}" =~ ^0+$ ]] || out false "no base commit"
git cat-file -e "${BASE}^{commit}" 2>/dev/null || out false "base ${BASE} not in this clone"

changed="$(git diff --name-only "${BASE}" "${HEAD}")"
[[ -n "${changed}" ]] || out false "empty diff"
echo "${changed}" | sed 's/^/  changed: /'
code="$(echo "${changed}" | grep -vE '(^docs/|\.md$)' || true)"
lock="$(echo "${changed}" | grep -xF 'versions.lock.md' || true)"
if [[ -z "${code}" && -z "${lock}" ]]; then out true "only docs/ and *.md"; fi
out false "code or pins changed"
