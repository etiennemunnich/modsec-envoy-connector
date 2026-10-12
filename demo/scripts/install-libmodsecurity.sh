#!/usr/bin/env bash
# Install / verify libmodsecurity at the pin in versions.lock.md (v3.0.17).
#   macOS: Homebrew bottle.
#   Linux: builds the pinned tag from source into ${MODSECURITY_PREFIX:-~/.local}
#          via scripts/install-libmodsecurity-ubuntu.sh (apt build deps; Ubuntu/Debian).
# Fails unless pkg-config then reports exactly the pin.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PIN="$(grep -E '^MODSECURITY_PIN=' "$ROOT/versions.lock.md" | head -1 | cut -d= -f2)"
PIN="${PIN:-v3.0.17}"
WANT="${PIN#v}"
PREFIX="${MODSECURITY_PREFIX:-${HOME}/.local}"
export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"

echo "libmodsecurity pin ${PIN}"
echo "Release: https://github.com/owasp-modsecurity/ModSecurity/releases/tag/${PIN}"

have_pin() {
  command -v pkg-config >/dev/null 2>&1 && pkg-config --exists modsecurity 2>/dev/null \
    && [[ "$(pkg-config --modversion modsecurity)" == "$WANT" ]]
}

cargo_hint() {
  # demo/scripts/*.sh add these themselves; plain `cargo build` needs them.
  if [[ -f "${PREFIX}/lib/pkgconfig/modsecurity.pc" ]]; then
    echo "For cargo outside the demo scripts:"
    echo "  export PKG_CONFIG_PATH=${PREFIX}/lib/pkgconfig LD_LIBRARY_PATH=${PREFIX}/lib"
  fi
}

if have_pin; then
  echo "OK: pkg-config modsecurity $(pkg-config --modversion modsecurity)"
  cargo_hint
  exit 0
fi

case "$(uname -s)" in
  Darwin)
    command -v brew >/dev/null || { echo "Homebrew required: https://brew.sh/" >&2; exit 1; }
    brew install modsecurity pkg-config
    ;;
  Linux)
    MODSECURITY_PIN="$PIN" PREFIX="$PREFIX" "$ROOT/scripts/install-libmodsecurity-ubuntu.sh"
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
cargo_hint
