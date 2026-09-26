#!/usr/bin/env bash
# Stub: install / verify libmodsecurity at the pin in versions.lock.md (v3.0.16).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PIN="$(grep -E '^MODSECURITY_PIN=' "$ROOT/versions.lock.md" | head -1 | cut -d= -f2)"
PIN="${PIN:-v3.0.16}"
WANT="${PIN#v}"

echo "envoy-modsec-connex demo: libmodsecurity pin is ${PIN}"
echo "Release: https://github.com/owasp-modsecurity/ModSecurity/releases/tag/${PIN}"
echo

if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists modsecurity 2>/dev/null; then
  VER="$(pkg-config --modversion modsecurity)"
  echo "Found via pkg-config: $VER"
  if [[ "$VER" == "$WANT"* ]]; then
    echo "OK: matches pin ${PIN}"
    exit 0
  fi
  echo "WARN: installed libmodsecurity ($VER) does not match pin ${PIN}"
  exit 1
fi

if [[ "$(uname -s)" == "Darwin" ]] && command -v brew >/dev/null 2>&1; then
  echo "No matching pkg-config modsecurity. On macOS you can try:"
  echo "  brew install modsecurity"
  echo "  pkg-config --modversion modsecurity"
  echo "Confirm version ${WANT}. Distro bottles may lag; build from source if needed."
  exit 1
fi

echo "libmodsecurity not found. Install ${PIN} from source or package — see demo/README.md"
exit 1
