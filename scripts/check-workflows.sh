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

[[ "${bad}" -eq 0 ]] || exit 1
echo "check-workflows OK: ${#files[@]} files"
