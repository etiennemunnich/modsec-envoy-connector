#!/usr/bin/env bash
# Static rules for .github/ (run by ci.yml pin-check). Each rule prints the
# offending file:line and the script exits 1 if any rule is broken.
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

# Both architectures on one pinned Ubuntu release.
rule "floating runner label (use ubuntu-24.04 / ubuntu-24.04-arm)" \
  "$(grep -nE 'ubuntu-latest' "${files[@]}" || true)"

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

[[ "${bad}" -eq 0 ]] || exit 1
echo "check-workflows OK: ${#files[@]} files"
