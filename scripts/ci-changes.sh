#!/usr/bin/env bash
# Decide whether a ci.yml run is docs-only (heavy jobs may then be skipped).
# Prints docs_only=true|false (also to $GITHUB_OUTPUT when set).
#
#   BASE=<sha> HEAD=<sha> GITHUB_REPOSITORY=<owner/name> ./scripts/ci-changes.sh
#   (tests: CI_BASE_RUNS_JSON=<file> stands in for the API)
#
# docs_only=true only when BASE is a known commit, every changed file is
# under docs/ or ends in .md (except versions.lock.md: pins always run CI),
# and BASE itself passed ci.yml (a successful ci run for that exact commit
# from this repository). Without that last check a docs change on top of an
# untested commit would inherit a green ci-ok it never earned. No base, an
# unknown base, an empty diff, an unproven base or an API error all mean
# false: when in doubt, run everything.
set -euo pipefail
cd "$(dirname "$0")/.."

HEAD="${HEAD:-$(git rev-parse HEAD)}"
BASE="${BASE:-}"
REPO="${GITHUB_REPOSITORY:-}"

out() {
  echo "docs_only=$1${2:+ ($2)}"
  [[ -z "${GITHUB_OUTPUT:-}" ]] || echo "docs_only=$1" >>"${GITHUB_OUTPUT}"
  exit 0
}

[[ "${BASE}" =~ ^[0-9a-f]{40}$ && ! "${BASE}" =~ ^0+$ ]] || out false "no base commit"
git cat-file -e "${BASE}^{commit}" 2>/dev/null || out false "base ${BASE} not in this clone"

changed="$(git diff --name-only "${BASE}" "${HEAD}")"
[[ -n "${changed}" ]] || out false "empty diff"
echo "${changed}" | sed 's/^/  changed: /'
code="$(echo "${changed}" | grep -vE '(^docs/|\.md$)' || true)"
lock="$(echo "${changed}" | grep -xF 'versions.lock.md' || true)"
[[ -z "${code}" && -z "${lock}" ]] || out false "code or pins changed"

if [[ -n "${CI_BASE_RUNS_JSON:-}" ]]; then
  runs="$(cat "${CI_BASE_RUNS_JSON}")"
else
  [[ -n "${REPO}" ]] || out false "no GITHUB_REPOSITORY to prove the base"
  runs="$(gh api "repos/${REPO}/actions/workflows/ci.yml/runs?head_sha=${BASE}&status=success&per_page=100" 2>/dev/null)" \
    || out false "could not list ci runs of the base"
fi
url="$(jq -r --arg sha "${BASE}" --arg repo "${REPO}" \
  '[.workflow_runs[] | select(.head_sha == $sha and .conclusion == "success"
     and .path == ".github/workflows/ci.yml" and .head_repository.full_name == $repo)][0].html_url // empty' \
  <<<"${runs}" 2>/dev/null)" || out false "unreadable run list"
url=${url:-unproven}
out true "only docs/ and *.md; base passed ${url}"
