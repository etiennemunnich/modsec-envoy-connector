#!/usr/bin/env bash
# Fail when the PR title, the PR body or any commit message in BASE..HEAD
# carries a token that makes GitHub skip push / pull_request workflows. On a
# PR head commit it suppresses the PR run; a squash merge copies it onto main,
# whose merge commit then gets no ci run at all.
#
#   PR_TITLE=... PR_BODY=... BASE=<sha> HEAD=<sha> ./scripts/ci-skip-tokens.sh
#
# The commit range must be in this clone (pin-check checks out fetch-depth 0).
set -euo pipefail

BASE="${BASE:?BASE is required}"
HEAD="${HEAD:?HEAD is required}"
re='\[(skip ci|ci skip|no ci|skip actions|actions skip)\]|\*\*\*NO_CI\*\*\*|^skip-checks: *true'

count="$(git rev-list --count "${BASE}..${HEAD}")"
[[ "${count}" -gt 0 ]] || { echo "::error::no commits in ${BASE}..${HEAD}"; exit 1; }

hits=""
check() { # check <where> <text>
  local h
  h=""
  [[ -z "${h}" ]] || hits+="$1: ${h}"$'\n'
}
check "PR title" "${PR_TITLE:-}"
check "PR body" "${PR_BODY:-}"
while read -r sha; do
  check "commit ${sha::12}" "$(git log -1 --format=%B "${sha}")"
done < <(git rev-list "${BASE}..${HEAD}")

if [[ -n "${hits}" ]]; then
  echo "::error::CI-skip token found. Edit the PR title or body; for a commit message, rebuild the branch without it."
  printf '%s' "${hits}"
  exit 1
fi
echo "no CI-skip tokens in the PR title, body or ${count} commit message(s)"
