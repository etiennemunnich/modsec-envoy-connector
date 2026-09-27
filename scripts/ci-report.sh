#!/usr/bin/env bash
# File this workflow run's result as a GitHub issue (Actions only).
#
#   ci-report.sh --title "stable-candidate: envoy v1.40.0" --mode always [--issue N] [--pass-note FILE]
#   ci-report.sh --title "stable-window: failing cells" --mode on-failure
#
# The body is a table of this run's jobs (except the report job itself) with
# conclusion, runner and measured wall time; "min" rounds each job up to the
# next whole minute, as Actions billing does.
#   always      comment on the issue with that title (created if missing), pass or fail
#   on-failure  create / comment on failure; on success, close an open issue with
#               a "passing again" comment
# Env: GH_TOKEN, GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_SERVER_URL, GITHUB_JOB.
set -euo pipefail

TITLE="" MODE="always" ISSUE="" PASS_NOTE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --title) TITLE="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --issue) ISSUE="$2"; shift 2 ;;
    --pass-note) PASS_NOTE="$2"; shift 2 ;;
    *) echo "unknown arg $1" >&2; exit 2 ;;
  esac
done
[[ -n "${TITLE}" ]] || { echo "--title is required" >&2; exit 2; }
: "${GITHUB_REPOSITORY:?}" "${GITHUB_RUN_ID:?}"
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"

jobs_json="$(mktemp)"
gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/jobs?per_page=100" >"${jobs_json}"

body="$(mktemp)"
verdict="$(python3 - "${jobs_json}" "${body}" "${RUN_URL}" <<'PY'
import json, math, sys
from datetime import datetime
jobs = json.load(open(sys.argv[1]))["jobs"]
out, run_url = sys.argv[2], sys.argv[3]
def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None
rows, total_s, total_min, ok = [], 0, 0, True
for j in jobs:
    if j["name"].endswith("report"):
        continue
    concl = j.get("conclusion") or j.get("status")
    if concl not in ("success", "skipped"):
        ok = False
    start, end = ts(j.get("started_at")), ts(j.get("completed_at"))
    secs = int((end - start).total_seconds()) if start and end and concl != "skipped" else 0
    mins = math.ceil(secs / 60) if secs else 0
    total_s += secs
    total_min += mins
    runner = ",".join(j.get("labels") or []) or "-"
    icon = {"success": "✅", "skipped": "➖"}.get(concl, "❌")
    rows.append(f"| {icon} {j['name']} | {concl} | `{runner}` | {secs // 60}m{secs % 60:02d}s | {mins} |")
with open(out, "w") as f:
    f.write(f"**Run:** {run_url}\n\n")
    f.write("| Job | Result | Runner | Wall | min |\n|---|---|---|---|---|\n")
    f.write("\n".join(rows) + "\n")
    f.write(f"| **total** | | | {total_s // 60}m{total_s % 60:02d}s | **{total_min}** |\n")
print("pass" if ok else "fail")
PY
)"

if [[ "${verdict}" == "pass" && -n "${PASS_NOTE}" && -f "${PASS_NOTE}" ]]; then
  { echo; cat "${PASS_NOTE}"; } >>"${body}"
fi
headline="$([[ "${verdict}" == pass ]] && echo "✅ passed" || echo "❌ failed")"
{ echo "## ${headline}"; echo; cat "${body}"; } >"${body}.md"
cat "${body}.md"
[[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || cat "${body}.md" >>"${GITHUB_STEP_SUMMARY}"

export TITLE
find_issue() {
  gh issue list --repo "${GITHUB_REPOSITORY}" --state "$1" --limit 100 \
    --search "\"${TITLE}\" in:title" --json number,title \
    --jq '.[] | select(.title == env.TITLE) | .number' | head -1
}

if [[ "${MODE}" == "on-failure" && "${verdict}" == "pass" ]]; then
  open="$(find_issue open)"
  if [[ -n "${open}" ]]; then
    gh issue comment "${open}" --repo "${GITHUB_REPOSITORY}" --body-file "${body}.md"
    gh issue close "${open}" --repo "${GITHUB_REPOSITORY}" --reason completed
  fi
  exit 0
fi

[[ -n "${ISSUE}" ]] || ISSUE="$(find_issue all)"
if [[ -z "${ISSUE}" ]]; then
  gh issue create --repo "${GITHUB_REPOSITORY}" --title "${TITLE}" --body-file "${body}.md"
else
  gh issue comment "${ISSUE}" --repo "${GITHUB_REPOSITORY}" --body-file "${body}.md"
  if [[ "${verdict}" == "fail" ]]; then
    gh issue reopen "${ISSUE}" --repo "${GITHUB_REPOSITORY}" >/dev/null 2>&1 || true
  fi
fi
