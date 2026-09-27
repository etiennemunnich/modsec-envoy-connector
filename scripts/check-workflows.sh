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

[[ "${bad}" -eq 0 ]] || exit 1
echo "check-workflows OK: ${#files[@]} files"
