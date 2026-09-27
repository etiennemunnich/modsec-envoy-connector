#!/usr/bin/env bash
# Find stable Envoy (v1.x) / libmodsecurity (v3.0.x) / CRS (v4.x) releases
# newer than the pins in versions.lock.md. For each new one: open a tracking
# issue "stable-candidate: <axis> <tag>" and dispatch stable-candidate.yml,
# which tests it on x86_64 + aarch64 and comments the result on that issue.
# The issue title is the dedupe key, so re-runs never test a tag twice.
#
#   ./scripts/release-watch.sh
#   FORCE=envoy:v1.38.4 ./scripts/release-watch.sh   # also test this tag (even if
#                                                    # not newer / already tested)
#   DRY_RUN=1 ./scripts/release-watch.sh             # report only
#
# Env: GH_TOKEN (actions: write, issues: write), GITHUB_REPOSITORY, GITHUB_REF_NAME.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SR="${ROOT}/scripts/stable-releases.sh"
REPO="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
REF="${GITHUB_REF_NAME:-main}"
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${REPO}/actions/runs/${GITHUB_RUN_ID:-local}"

say() {
  echo "$*"
  [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || echo "$*" >>"${GITHUB_STEP_SUMMARY}"
}
newer() { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" ]]; }
find_issue() {
  TITLE="$1" gh issue list --repo "${REPO}" --state all --limit 100 \
    --search "\"$1\" in:title" --json number,title \
    --jq '.[] | select(.title == env.TITLE) | .number' | head -1
}

candidates=()
say "| Axis | Pin | Latest stable | Window | Status |"
say "|------|-----|---------------|--------|--------|"
for axis in envoy modsecurity crs; do
  pin="$("${SR}" pin "${axis}")"
  latest="$("${SR}" latest "${axis}")"
  window="$("${SR}" window "${axis}" | tr '\n' ' ')"
  status="up to date"
  if newer "${latest}" "${pin}"; then
    candidates+=("${axis}:${latest}")
    status="**new stable**"
  fi
  say "| ${axis} | \`${pin}\` | \`${latest}\` | ${window} | ${status} |"
done

forced=""
if [[ -n "${FORCE:-}" ]]; then
  "${SR}" valid "${FORCE%%:*}" "${FORCE#*:}" || { echo "FORCE=${FORCE} is not <axis>:<stable tag>" >&2; exit 2; }
  forced="${FORCE}"
  candidates+=("${FORCE}")
fi
say ""

for c in ${candidates[@]+"${candidates[@]}"}; do
  axis="${c%%:*}" tag="${c#*:}"
  title="stable-candidate: ${axis} ${tag}"
  issue="$(find_issue "${title}")"
  if [[ -n "${issue}" && "${c}" != "${forced}" ]]; then
    say "- ${title}: already tracked in #${issue}, skipped"
    continue
  fi
  if [[ -n "${DRY_RUN:-}" ]]; then
    say "- ${title}: would dispatch stable-candidate.yml (dry run)"
    continue
  fi
  if [[ -z "${issue}" ]]; then
    url="$(gh issue create --repo "${REPO}" --title "${title}" \
      --body "⏳ Testing \`${tag}\` for **${axis}** on x86_64 + aarch64 (other axes at their pins). Found by ${RUN_URL}.")"
    issue="${url##*/}"
  fi
  gh workflow run stable-candidate.yml --repo "${REPO}" --ref "${REF}" \
    -f component="${axis}" -f version="${tag}" -f issue="${issue}"
  say "- ${title}: dispatched stable-candidate.yml → #${issue}"
done
[[ ${#candidates[@]} -gt 0 ]] || say "No new stable releases."
