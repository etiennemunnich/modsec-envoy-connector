#!/usr/bin/env bash
# Has this exact tree already passed ci.yml on a pull request? A push to main
# whose git tree matches a successful pull_request run from a branch of this
# repository can skip the heavy jobs: tree hashes are content-addressed, so
# the same hash is the same files, workflows and lockfiles included. A pull
# request run tests the merge with its base, which is the head's tree when
# the branch was up to date; a branch that was behind gives main a different
# tree, so nothing matches and everything runs.
# Prints tested=true|false (also to $GITHUB_OUTPUT when set).
#
#   TREE=<tree sha> GITHUB_REPOSITORY=<owner/name> ./scripts/ci-tested-tree.sh
#   (tests: CI_TESTED_RUNS_JSON=<file> stands in for the API)
#
# No tree id, a re-run, an API error or no match all mean false: when in
# doubt, run everything.
set -euo pipefail

out() {
  echo "tested=$1${2:+ ($2)}"
  [[ -z "${GITHUB_OUTPUT:-}" ]] || echo "tested=$1" >>"${GITHUB_OUTPUT}"
  exit 0
}

TREE="${TREE:-}"
REPO="${GITHUB_REPOSITORY:-}"
[[ "${TREE}" =~ ^[0-9a-f]{40}$ ]] || out false "no tree id"
[[ "${GITHUB_RUN_ATTEMPT:-1}" == 1 ]] || out false "a re-run"

if [[ -n "${CI_TESTED_RUNS_JSON:-}" ]]; then
  runs="$(cat "${CI_TESTED_RUNS_JSON}")"
else
  runs="$(gh api "repos/${REPO}/actions/workflows/ci.yml/runs?event=pull_request&status=success&per_page=100" 2>/dev/null)" \
    || out false "could not list earlier runs"
fi
url="$(jq -r --arg tree "${TREE}" --arg repo "${REPO}" \
  '[.workflow_runs[] | select(.head_repository.full_name == $repo and .head_commit.tree_id == $tree)][0].html_url // empty' \
  <<<"${runs}" 2>/dev/null)" || out false "unreadable run list"
[[ -n "${url}" ]] || out false "no passing pull request run of this tree"
out true "${url}"
