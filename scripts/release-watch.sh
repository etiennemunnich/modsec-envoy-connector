#!/usr/bin/env bash
# Find stable Envoy (v1.x) / libmodsecurity (v3.0.x) / CRS (v4.x) releases
# newer than the pins in versions.lock.md and test each one with
# stable-candidate.yml (x86_64 + aarch64), which comments the result on the
# issue "stable-candidate: <axis> <tag>".
#
# Candidates per axis: the latest stable if newer than the pin, and the top
# patch of the pin's own minor line if newer (Envoy ships patches on several
# lines the same day). Recent stable tags newer than the pin that the axis
# pattern does not cover (a new line such as v3.1.0 / v5.0.0) are reported as
# "new line — not tracked" and fail nothing.
#
# Dedupe is on recorded results, not on "an issue exists": a tag is skipped
# once its issue has a "## ✅" result, or MAX_FAILS "## ❌" results (flakes are
# retried until then). The issue is only created after the dispatch succeeded.
# An older open issue on the same minor line (v1.40.1 vs v1.40.2, not v1.41)
# is closed once a newer tag on that line has a passing result. DRY_RUN reports
# that close and does not perform it.
#
#   ./scripts/release-watch.sh
#   FORCE=envoy:v1.38.4 ./scripts/release-watch.sh   # also test this tag (even if
#                                                    # not newer / already tested)
#   DRY_RUN=1 ./scripts/release-watch.sh             # report only
#
# Env: GH_TOKEN (actions: write, issues: write), GITHUB_REPOSITORY,
#      GITHUB_REF_NAME or WATCH_REF (ref to dispatch on), MAX_FAILS (default 3),
#      LOCK_FILE (see stable-releases.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SR="${ROOT}/scripts/stable-releases.sh"
REPO="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
REF="${WATCH_REF:-${GITHUB_REF_NAME:-main}}"
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${REPO}/actions/runs/${GITHUB_RUN_ID:-local}"
MAX_FAILS="${MAX_FAILS:-3}"

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
# results <issue> -> "<passed> <failed>" result comments written by ci-report.sh
results() {
  gh issue view "$1" --repo "${REPO}" --json comments \
    -q '[.comments[].body] | "\(map(select(startswith("## ✅"))) | length) \(map(select(startswith("## ❌"))) | length)"'
}
# Close open stable-candidate issues older than a passing tag on the same
# minor line. A pass on v1.41 does not close v1.40.
close_superseded() {
  local list rows number state axis tag counts passed key found win i j title
  local -a numbers=()
  local -a states=()
  local -a axes=()
  local -a tags=()
  local -a passeds=()
  local -a best_keys=()
  local -a best_tags=()
  list="$(mktemp)"
  rows="$(mktemp)"
  gh issue list --repo "${REPO}" --state all --limit 100 \
    --search "\"stable-candidate:\" in:title" --json number,title,state >"${list}"
  python3 - "${list}" >"${rows}" <<'PY'
import json, sys
items = json.load(open(sys.argv[1]))
for item in items:
    title = item.get("title") or ""
    prefix = "stable-candidate: "
    if not title.startswith(prefix):
        continue
    rest = title[len(prefix):]
    axis, sep, tag = rest.partition(" ")
    if not sep or axis not in ("envoy", "modsecurity", "crs"):
        continue
    parts = tag[1:].split(".") if tag.startswith("v") else []
    if len(parts) != 3 or not all(part.isdigit() for part in parts):
        continue
    state = (item.get("state") or "").upper()
    print(f"{item['number']}\t{state}\t{axis}\t{tag}")
PY
  while IFS=$'\t' read -r number state axis tag; do
    [[ -n "${number}" ]] || continue
    counts="$(results "${number}")"
    passed="${counts%% *}"
    numbers+=("${number}")
    states+=("${state}")
    axes+=("${axis}")
    tags+=("${tag}")
    passeds+=("${passed}")
  done <"${rows}"
  rm -f "${list}" "${rows}"
  if [[ ${#passeds[@]} -gt 0 ]]; then
    for i in "${!passeds[@]}"; do
      [[ "${passeds[i]}" -gt 0 ]] || continue
      key="${axes[i]} ${tags[i]%.*}"
      found=0
      if [[ ${#best_keys[@]} -gt 0 ]]; then
        for j in "${!best_keys[@]}"; do
          [[ "${best_keys[j]}" == "${key}" ]] || continue
          found=1
          if newer "${tags[i]}" "${best_tags[j]}"; then
            best_tags[j]="${tags[i]}"
          fi
        done
      fi
      if [[ "${found}" -eq 0 ]]; then
        best_keys+=("${key}")
        best_tags+=("${tags[i]}")
      fi
    done
  fi
  if [[ ${#numbers[@]} -eq 0 ]]; then
    return 0
  fi
  for i in "${!numbers[@]}"; do
    [[ "${states[i]}" == "OPEN" ]] || continue
    key="${axes[i]} ${tags[i]%.*}"
    win=""
    if [[ ${#best_keys[@]} -gt 0 ]]; then
      for j in "${!best_keys[@]}"; do
        if [[ "${best_keys[j]}" == "${key}" ]]; then
          win="${best_tags[j]}"
          break
        fi
      done
    fi
    [[ -n "${win}" ]] || continue
    newer "${win}" "${tags[i]}" || continue
    title="stable-candidate: ${axes[i]} ${tags[i]}"
    if [[ -n "${DRY_RUN:-}" ]]; then
      say "- ${title}: would close #${numbers[i]}, superseded by stable-candidate: ${axes[i]} ${win} (dry run)"
      continue
    fi
    gh issue comment "${numbers[i]}" --repo "${REPO}" \
      --body "Superseded by stable-candidate: ${axes[i]} ${win}, which passed on this minor line. ${RUN_URL}"
    gh issue close "${numbers[i]}" --repo "${REPO}" --reason completed
    say "- ${title}: closed #${numbers[i]}, superseded by stable-candidate: ${axes[i]} ${win}"
  done
}

candidates=()
add() {
  local c
  for c in ${candidates[@]+"${candidates[@]}"}; do [[ "${c}" != "$1" ]] || return 0; done
  candidates+=("$1")
}

say "| Axis | Pin | Latest stable | Top of pinned line | Window | Status |"
say "|------|-----|---------------|--------------------|--------|--------|"
for axis in envoy modsecurity crs; do
  pin="$("${SR}" pin "${axis}")"
  latest="$("${SR}" latest "${axis}")"
  line="$("${SR}" line "${axis}" "${pin}")"
  window="$("${SR}" window "${axis}" | tr '\n' ' ')"
  untracked="$("${SR}" untracked "${axis}" | tr '\n' ' ')"
  status=()
  if newer "${latest}" "${pin}"; then
    add "${axis}:${latest}"
    status+=("**new stable** ${latest}")
  fi
  if [[ -n "${line}" && "${line}" != "${latest}" ]] && newer "${line}" "${pin}"; then
    add "${axis}:${line}"
    status+=("**patch on pinned line** ${line}")
  fi
  if [[ -n "${untracked// /}" ]]; then
    status+=("**new line — not tracked**: ${untracked% }")
    echo "::warning::${axis}: ${untracked% } newer than ${pin} but outside the tracked pattern"
  fi
  [[ ${#status[@]} -gt 0 ]] || status=("up to date")
  joined="$(printf '%s; ' "${status[@]}")"
  say "| ${axis} | \`${pin}\` | \`${latest}\` | \`${line}\` | ${window} | ${joined%; } |"
done

forced=""
if [[ -n "${FORCE:-}" ]]; then
  "${SR}" valid "${FORCE%%:*}" "${FORCE#*:}" || { echo "FORCE=${FORCE} is not <axis>:<stable tag>" >&2; exit 2; }
  forced="${FORCE}"
  add "${FORCE}"
fi
say ""
close_superseded

for c in ${candidates[@]+"${candidates[@]}"}; do
  axis="${c%%:*}" tag="${c#*:}"
  title="stable-candidate: ${axis} ${tag}"
  issue="$(find_issue "${title}")"
  if [[ -n "${issue}" && "${c}" != "${forced}" ]]; then
    counts="$(results "${issue}")"
    read -r passed failed <<<"${counts}"
    if [[ "${passed}" -gt 0 ]]; then
      say "- ${title}: passed in #${issue}, skipped"
      continue
    fi
    if [[ "${failed}" -ge "${MAX_FAILS}" ]]; then
      say "- ${title}: failed ${failed}× in #${issue}, not retried (dispatch stable-candidate by hand)"
      continue
    fi
    [[ "${failed}" -eq 0 ]] || say "- ${title}: ${failed} failed result(s) in #${issue}, retrying"
  fi
  if [[ -n "${DRY_RUN:-}" ]]; then
    say "- ${title}: would dispatch stable-candidate.yml on ${REF} (dry run)"
    continue
  fi
  # Empty issue is fine: stable-candidate's report finds or creates it by title.
  gh workflow run stable-candidate.yml --repo "${REPO}" --ref "${REF}" \
    -f component="${axis}" -f version="${tag}" -f issue="${issue}"
  if [[ -z "${issue}" ]]; then
    url="$(gh issue create --repo "${REPO}" --title "${title}" \
      --body "⏳ Testing \`${tag}\` for **${axis}** on x86_64 + aarch64 (other axes at their pins). Found by ${RUN_URL}.")"
    issue="${url##*/}"
  fi
  say "- ${title}: dispatched stable-candidate.yml on ${REF} → #${issue}"
done
[[ ${#candidates[@]} -gt 0 ]] || say "No new stable releases."
