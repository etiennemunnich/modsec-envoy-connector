#!/usr/bin/env bash
# Static rules for .github/ (run by ci.yml pin-check, which also owns the
# docs/tree skip signal). Each rule prints the offending file:line and the
# script exits 1 if any rule is broken.
#
#   ./scripts/check-workflows.sh
set -euo pipefail
cd "$(dirname "$0")/.."

bad=0
rule() { # rule <message> <grep output>
  if [[ -n "$2" ]]; then
    echo "check-workflows FAIL: $1" >&2
    echo "$2" | sed 's/^/  /' >&2
    bad=1
  fi
}

files=(.github/workflows/*.yml .github/actions/*/action.yml)

# Remote actions: full 40-hex commit SHA plus a "# vX.Y.Z" comment; never a tag or branch.
rule "remote action not pinned by commit SHA with a # vX.Y.Z comment" \
  "$(grep -nE '^[[:space:]-]*uses:[[:space:]]*[^.[:space:]]' "${files[@]}" \
    | grep -vE 'uses:[[:space:]]*[^@[:space:]]+@[0-9a-f]{40}[[:space:]]+#[[:space:]]*v[0-9]+\.[0-9]+\.[0-9]+[[:space:]]*$' || true)"

# Both architectures on one pinned Ubuntu release, GitHub-hosted only: every
# runs-on is ubuntu-24.04, ubuntu-24.04-arm or a matrix runner, and every
# matrix runner value is one of the two.
rule "floating runner label (use ubuntu-24.04 / ubuntu-24.04-arm)" \
  "$(grep -nE 'ubuntu-latest' "${files[@]}" || true)"
rule "runs-on outside ubuntu-24.04 / ubuntu-24.04-arm / \${{ matrix.runner }}" \
  "$(grep -nE '^[[:space:]]*runs-on:' "${files[@]}" \
    | grep -vE 'runs-on:[[:space:]]*(ubuntu-24\.04|ubuntu-24\.04-arm|\$\{\{ matrix\.runner \}\})[[:space:]]*$' || true)"
rule "matrix runner outside ubuntu-24.04 / ubuntu-24.04-arm" \
  "$(grep -nE '(^|[{,[:space:]])runner:[[:space:]]*[^[:space:],}]+' "${files[@]}" \
    | grep -vE 'runs-on' \
    | grep -vE 'runner:[[:space:]]*(ubuntu-24\.04|ubuntu-24\.04-arm)[[:space:]]*([,}]|$)' || true)"

# Every job that runs on a runner has a timeout (never the 360-minute default).
rule "job without timeout-minutes" \
  "$(for f in .github/workflows/*.yml; do
    awk -v f="${f}" '
      function flush() { if (job != "" && runs && !timeout) print f ": job " job " has runs-on but no timeout-minutes" }
      /^jobs:/ { injobs = 1; next }
      injobs && /^[^[:space:]#]/ { flush(); injobs = 0; job = "" }
      injobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { flush(); job = $1; sub(/:$/, "", job); runs = 0; timeout = 0; next }
      injobs && /^    runs-on:/ { runs = 1 }
      injobs && /^    timeout-minutes:/ { timeout = 1 }
      END { flush() }
    ' "${f}"
  done)"

# A concurrency group cancels in-progress runs only off main (AGENTS.md rule 7):
# a literal true would also cancel scheduled and main runs.
rule "cancel-in-progress: true (use \${{ github.ref != 'refs/heads/main' }})" \
  "$(grep -nE '^[[:space:]]*cancel-in-progress:[[:space:]]*true' "${files[@]}" || true)"

# No job pushes via git, so no checkout may leave the token in the git config.
rule "actions/checkout without persist-credentials: false in its with: block" \
  "$(for f in "${files[@]}"; do
    awk -v f="${f}" '
      pending != "" && /^[[:space:]]*-[[:space:]]/ { print pending; pending = "" }
      pending != "" && /persist-credentials:[[:space:]]*false/ { pending = "" }
      /uses:[[:space:]]*actions\/checkout@/ { pending = f ":" FNR ": " $0 }
      END { if (pending != "") print pending }
    ' "${f}"
  done)"

# always() also runs after a cancel, so a cancelled run would file a failure issue.
rule "always() in a condition (use \${{ !cancelled() }})" \
  "$(grep -nE 'if:.*always\(\)' "${files[@]}" || true)"

# Scheduled version gates must keep an explicit cron (and stay dispatchable).
# A missing cron is a silent regression: the weekly/monthly path never fires.
# Only enforced when the product workflows are present (skip throwaway fixtures
# used by scripts/test-ci-scripts.sh).
require_cron() { # require_cron <workflow> <expected-cron-substring>
  local wf=".github/workflows/$1" want="$2"
  if [[ ! -f "$wf" ]]; then
    echo "$wf: missing workflow file"
    return
  fi
  if ! grep -qE '^[[:space:]]*schedule:' "$wf"; then
    echo "$wf: missing on.schedule"
    return
  fi
  if ! grep -qF "$want" "$wf"; then
    echo "$wf: expected cron containing '$want'"
    return
  fi
  if ! grep -qE '^[[:space:]]*workflow_dispatch:' "$wf"; then
    echo "$wf: missing workflow_dispatch (needed to prove the path before schedule fires)"
  fi
}
if [[ -f .github/workflows/stable-window.yml || -f .github/workflows/crs-full.yml ]]; then
  rule "stable-window / crs-full must keep schedule cron + workflow_dispatch" \
    "$( {
        require_cron stable-window.yml '23 4 * * 1'
        require_cron crs-full.yml '41 3 7 * *'
      } )"
fi
if [[ -f .github/workflows/e2e-lab.yml || -f .github/workflows/ash.yml ]]; then
  rule "e2e-lab / ash must keep schedule cron + workflow_dispatch" \
    "$( {
        require_cron e2e-lab.yml '47 5 * * 1'
        require_cron ash.yml '11 3 * * 1'
      } )"
fi

# ci.yml must not re-introduce branch-push CI on cursor/** (triple-run waste).
# Match YAML values only (quoted or bare), not header comments that mention the ban.
if [[ -f .github/workflows/ci.yml ]]; then
  rule "ci.yml must not trigger on push to cursor/**" \
    "$(grep -nE '^[[:space:]]*-[[:space:]]*["'\'']?cursor/\*\*' .github/workflows/ci.yml || true)"
fi

# ci-ok is the single verdict: it must need every other job in ci.yml, or a
# job added later could fail without failing ci-ok.
if [[ -f .github/workflows/ci.yml ]]; then
  rule "ci.yml: ci-ok.needs is missing jobs" \
    "$(awk '
      /^jobs:/ { injobs = 1; next }
      injobs && /^[^[:space:]#]/ { injobs = 0 }
      injobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { job = $1; sub(/:$/, "", job); if (job != "ci-ok") jobs[job] = 1; next }
      injobs && job == "ci-ok" && /^    needs:/ {
        line = $0; sub(/^    needs:[[:space:]]*\[?/, "", line); sub(/\][[:space:]]*$/, "", line)
        n = split(line, a, /[[:space:],]+/); for (i = 1; i <= n; i++) if (a[i] != "") needs[a[i]] = 1
        seen = 1
      }
      END {
        if (!seen) { print ".github/workflows/ci.yml: ci-ok has no needs: [...] line"; exit }
        for (j in jobs) if (!(j in needs)) print ".github/workflows/ci.yml: ci-ok does not need " j
      }
    ' .github/workflows/ci.yml)"
fi

# ASH install must be a 40-hex commit, never a movable tag like @v3.7.1.
if [[ -f .github/workflows/ash.yml ]]; then
  rule "ash.yml must pip-install automated-security-helper at a 40-hex commit" \
    "$(grep -nE 'automated-security-helper\.git@' .github/workflows/ash.yml \
      | grep -vE 'automated-security-helper\.git@[0-9a-f]{40}' || true)"
fi

[[ "${bad}" -eq 0 ]] || exit 1
echo "check-workflows OK: ${#files[@]} files"
