#!/usr/bin/env bash
# Install go-ftw, the OWASP CRS regression test runner.
#   https://github.com/coreruleset/go-ftw
# Homebrew (coreruleset/tap) on macOS; `go install` elsewhere.
set -euo pipefail

if command -v ftw >/dev/null 2>&1 || command -v go-ftw >/dev/null 2>&1; then
  bin="$(command -v ftw || command -v go-ftw)"
  echo "OK: $("${bin}" -v 2>&1 | head -1) at ${bin}"
  exit 0
fi

if command -v brew >/dev/null 2>&1; then
  brew tap coreruleset/tap
  brew install coreruleset/tap/go-ftw
elif command -v go >/dev/null 2>&1; then
  go install github.com/coreruleset/go-ftw/v2@latest
  gobin="$(go env GOPATH)/bin"
  echo "installed into ${gobin} — make sure it is on PATH"
  export PATH="${gobin}:${PATH}"
else
  echo "need Homebrew or Go: brew tap coreruleset/tap && brew install go-ftw" >&2
  echo "                     go install github.com/coreruleset/go-ftw/v2@latest" >&2
  exit 2
fi

bin="$(command -v ftw || command -v go-ftw)"
echo "OK: $("${bin}" -v 2>&1 | head -1) at ${bin}"
