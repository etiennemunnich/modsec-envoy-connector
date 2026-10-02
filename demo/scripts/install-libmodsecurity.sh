#!/usr/bin/env bash
# Install / verify libmodsecurity at the pin in versions.lock.md (v3.0.17).
#   macOS: Homebrew bottle.
#   Linux: builds the pinned tag from source via scripts/install-libmodsecurity-ubuntu.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PIN="$(grep -E '^MODSECURITY_PIN=' "$ROOT/versions.lock.md" | head -1 | cut -d= -f2)"
PIN="${PIN:-v3.0.17}"
WANT="${PIN#v}"

echo "libmodsecurity pin ${PIN}"
echo "Release: https://github.com/owasp-modsecurity/ModSecurity/releases/tag/${PIN}"

have_pin() {
  command -v pkg-config >/dev/null 2>&1 && pkg-config --exists modsecurity 2>/dev/null \
    && [[ "$(pkg-config --modversion modsecurity)" == "$WANT" ]]
}

if have_pin; then
  echo "OK: pkg-config modsecurity $(pkg-config --modversion modsecurity)"
  exit 0
fi

case "$(uname -s)" in
  Darwin)
    command -v brew >/dev/null || { echo "Homebrew required: https://brew.sh/" >&2; exit 1; }
    brew install modsecurity pkg-config
    ;;
  Linux)
    MODSECURITY_PIN="$PIN" "$ROOT/scripts/install-libmodsecurity-ubuntu.sh"
    echo "Export for cargo: PKG_CONFIG_PATH=\${PREFIX:-\$HOME/.local}/lib/pkgconfig LD_LIBRARY_PATH=\${PREFIX:-\$HOME/.local}/lib"
    exit 0
    ;;
  *)
    echo "unsupported OS; build ModSecurity ${PIN} from source" >&2
    exit 1
    ;;
esac

if have_pin; then
  echo "OK: pkg-config modsecurity $(pkg-config --modversion modsecurity)"
else
  echo "installed libmodsecurity is $(pkg-config --modversion modsecurity 2>/dev/null || echo missing), pin is ${WANT}" >&2
  exit 1
fi
