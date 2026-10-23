#!/usr/bin/env bash
# Release gate: may this commit be published? Exits 0 only when
#   1. the commit is on main (main's tip or an ancestor of it), and
#   2. a ci.yml run for exactly this commit, from this repository, concluded
#      success, and every required check below is a successful GitHub Actions
#      check run in that run's check suite. A check of the same name from
#      another app or another workflow does not count.
#
#   SHA=<commit> GITHUB_REPOSITORY=<owner/name> ./scripts/release-gate.sh
#   (tests: GATE_COMPARE_STATUS=<status>, GATE_RUNS_JSON=<file> and
#    GATE_CHECKS_JSON=<file> stand in for the API)
set -euo pipefail

SHA="${SHA:?SHA is required}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
die() { echo "::error::release gate: $*"; exit 1; }
[[ "${SHA}" =~ ^[0-9a-f]{40}$ ]] || die "SHA '${SHA}' is not a commit id"

REQUIRED=(
  "ci-ok" "pin-check" "rust-quality (x86_64)" "rust-quality (aarch64)" "msrv (rust-version)"
  "supply-chain (cargo-deny)" "protos (gen-protos --check)"
  "e2e-pin / e2e (x86_64, BUFFERED)" "e2e-pin / e2e (aarch64, BUFFERED)"
  "e2e-streamed / e2e (x86_64, STREAMED)" "e2e-streamed / e2e (aarch64, STREAMED)"
  "e2e-full-duplex / e2e (x86_64, FULL_DUPLEX_STREAMED)" "e2e-full-duplex / e2e (aarch64, FULL_DUPLEX_STREAMED)"
  "e2e-dm (x86_64)" "e2e-dm (aarch64)"
)

# identical = main's tip, behind = an ancestor of main; ahead/diverged = not on main.
status="${GATE_COMPARE_STATUS:-$(gh api "repos/${REPO}/compare/main...${SHA}" -q .status)}"
case "${status}" in
  identical | behind) echo "${SHA::7} is on main (${status})" ;;
  *) die "${SHA::7} is not on main (compare: ${status:-none})" ;;
esac

if [[ -n "${GATE_RUNS_JSON:-}" ]]; then
  runs="$(cat "${GATE_RUNS_JSON}")"
else
  runs="$(gh api "repos/${REPO}/actions/workflows/ci.yml/runs?head_sha=${SHA}&status=success&per_page=100")"
fi
suites="$(jq -r --arg sha "${SHA}" --arg repo "${REPO}" \
  '.workflow_runs[] | select(.head_sha == $sha and .conclusion == "success"
     and .path == ".github/workflows/ci.yml" and .head_repository.full_name == $repo)
   | "\(.check_suite_id) \(.html_url)"' <<<"${runs}")"
[[ -n "${suites}" ]] || die "no successful ci run for ${SHA::7} (run ci on main for it first: gh workflow run ci.yml --ref main)"

if [[ -n "${GATE_CHECKS_JSON:-}" ]]; then
  checks="$(cat "${GATE_CHECKS_JSON}")"
else
  checks="$(gh api --paginate "repos/${REPO}/commits/${SHA}/check-runs?per_page=100" -q '.check_runs[]' | jq -s '{check_runs: .}')"
fi

while read -r suite url; do
  green="$(jq -r --argjson suite "${suite}" \
    '.check_runs[] | select(.conclusion == "success" and .app.slug == "github-actions"
       and .check_suite.id == $suite) | .name' <<<"${checks}")"
  missing=()
  for n in "${REQUIRED[@]}"; do
    grep -qxF "${n}" <<<"${green}" || missing+=("${n}")
  done
  if [[ "${#missing[@]}" -eq 0 ]]; then
    printf 'green: %s\n' "${REQUIRED[@]}"
    echo "release gate OK: ${#REQUIRED[@]} checks from ${url}"
    exit 0
  fi
  echo "${url}: not green: ${missing[*]}"
done <<<"${suites}"
die "no successful ci run for ${SHA::7} has all ${#REQUIRED[@]} required checks green (a merge that skipped the heavy jobs needs a ci run on main: gh workflow run ci.yml --ref main)"
