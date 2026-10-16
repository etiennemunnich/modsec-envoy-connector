#!/usr/bin/env bash
# Has this exact tree already passed ci.yml on a pull request? A push to main
# whose git tree matches the tree a successful pull_request run tested can
# skip the heavy jobs: tree hashes are content-addressed, so the same hash is
# the same files, workflows and lockfiles included.
#
# A pull_request run tests refs/pull/N/merge, not the branch head, so ci-ok
# records that merge tree as the artifact tested-tree-<tree> once every job
# passed. This script looks the artifact up and accepts it only from a
# successful ci.yml pull_request run of a branch in this repository.
# Prints tested=true|false (also to $GITHUB_OUTPUT when set).
#
#   TREE=<tree sha> GITHUB_REPOSITORY=<owner/name> ./scripts/ci-tested-tree.sh
#   (tests: CI_TESTED_ARTIFACTS_JSON=<file> and CI_TESTED_RUNS_DIR=<dir of
#    <run id>.json> stand in for the API)
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

if [[ -n "${CI_TESTED_ARTIFACTS_JSON:-}" ]]; then
  arts="$(cat "${CI_TESTED_ARTIFACTS_JSON}")"
else
  arts="$(gh api "repos/${REPO}/actions/artifacts?name=tested-tree-${TREE}&per_page=100" 2>/dev/null)" \
    || out false "could not list tested-tree artifacts"
fi
ids="$(jq -r --arg name "tested-tree-${TREE}" \
  '.artifacts[] | select(.name == $name and .expired == false) | .workflow_run.id' <<<"${arts}" 2>/dev/null)" \
  || out false "unreadable artifact list"

for id in ${ids}; do
  [[ "${id}" =~ ^[0-9]+$ ]] || continue
  if [[ -n "${CI_TESTED_RUNS_DIR:-}" ]]; then
    run="$(cat "${CI_TESTED_RUNS_DIR}/${id}.json" 2>/dev/null)" || continue
  else
    run="$(gh api "repos/${REPO}/actions/runs/${id}" 2>/dev/null)" || continue
  fi
  url="$(jq -r --arg repo "${REPO}" \
    'select(.path == ".github/workflows/ci.yml" and .event == "pull_request" and .conclusion == "success"
       and .head_repository.full_name == $repo) | .html_url' <<<"${run}" 2>/dev/null || true)"
  [[ -z "${url}" ]] || out true "${url}"
done
out false "no passing pull request run tested this tree"
