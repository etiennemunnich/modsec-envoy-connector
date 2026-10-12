#!/usr/bin/env bash
# Install / verify Envoy Proxy at the pin in versions.lock.md (v1.39.3), or at
# ENVOY_VERSION=vX.Y.Z when set.
#
# Linux: downloads the official release binary into ${ENVOY_BIN_DIR:-$HOME/.local/bin}
# and checks its sha256 against the release's checksums.txt.asc (the PGP
# signature on that file is not verified here). That list names each asset
# either as a bare filename or as a /tmp/.../bin/<asset> path; both match.
# Put that directory first on PATH.
# macOS: `brew install envoy`, then the same version check (fails if Homebrew
# has moved past the pin).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../../scripts/envoy-checksum.sh
source "${ROOT}/scripts/envoy-checksum.sh"
PIN="${ENVOY_VERSION:-$(grep -E '^ENVOY_PIN=' "$ROOT/versions.lock.md" | head -1 | cut -d= -f2)}"
PIN="${PIN:-v1.39.3}"
WANT="${PIN#v}"
BIN_DIR="${ENVOY_BIN_DIR:-$HOME/.local/bin}"

echo "modsec-envoy-connector demo: Envoy ${PIN}"
echo "Official guide: https://www.envoyproxy.io/docs/envoy/${PIN}/start/install"
echo "Release: https://github.com/envoyproxy/envoy/releases/tag/${PIN}"
echo

if command -v envoy >/dev/null 2>&1; then
  VER="$(envoy --version 2>&1 || true)"
  echo "Found: $VER"
  if echo "$VER" | grep -q "/${WANT}/"; then
    echo "OK: matches ${PIN}"
    exit 0
  fi
  echo "WARN: installed Envoy does not match ${PIN}."
fi

if [[ "$(uname -s)" == "Linux" ]]; then
  case "$(uname -m)" in
    x86_64 | amd64) ARCH=x86_64 ;;
    aarch64 | arm64) ARCH=aarch_64 ;;
    *) echo "no Envoy release binary for $(uname -m)" >&2; exit 1 ;;
  esac
  ASSET="envoy-${WANT}-linux-${ARCH}"
  URL="https://github.com/envoyproxy/envoy/releases/download/${PIN}"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  echo "Downloading ${URL}/${ASSET}"
  curl -fsSL --connect-timeout 15 --max-time 180 --retry 3 --retry-delay 2 \
    -o "$TMP/envoy" "${URL}/${ASSET}"
  curl -fsSL --connect-timeout 15 --max-time 60 --retry 3 --retry-delay 2 \
    -o "$TMP/checksums.txt.asc" "${URL}/checksums.txt.asc"
  EXPECT="$(envoy_checksum_sha256 "$TMP/checksums.txt.asc" "$ASSET")"
  GOT="$(sha256sum "$TMP/envoy" | cut -d' ' -f1)"
  [[ -n "$EXPECT" ]] || { echo "no checksum for ${ASSET} in checksums.txt.asc" >&2; exit 1; }
  [[ "$GOT" == "$EXPECT" ]] || { echo "sha256 mismatch for ${ASSET}: got ${GOT}, want ${EXPECT}" >&2; exit 1; }
  mkdir -p "$BIN_DIR"
  install -m 0755 "$TMP/envoy" "$BIN_DIR/envoy"
  "$BIN_DIR/envoy" --version
  echo "OK: installed ${PIN} at ${BIN_DIR}/envoy (sha256 ${GOT})"
  case ":$PATH:" in *":$BIN_DIR:"*) ;; *) echo "Add ${BIN_DIR} to the front of PATH." ;; esac
  exit 0
fi

if [[ "$(uname -s)" == "Darwin" ]]; then
  command -v brew >/dev/null 2>&1 || { echo "Homebrew required: https://brew.sh/" >&2; exit 1; }
  if brew list --formula envoy >/dev/null 2>&1; then
    brew upgrade envoy
  else
    brew install envoy
  fi
  VER="$("$(brew --prefix)/bin/envoy" --version 2>&1)"
  echo "Found: $VER"
  if echo "$VER" | grep -q "/${WANT}/"; then
    echo "OK: Homebrew envoy matches ${PIN}"
    exit 0
  fi
  echo "Homebrew envoy is not ${PIN}; the demo is tested at ${PIN} (versions.lock.md)." >&2
  echo "Run the Linux path in a container or VM, or install ${PIN} from https://www.envoyproxy.io/docs/envoy/${PIN}/start/install" >&2
  exit 1
fi

echo "unsupported OS $(uname -s); install Envoy ${PIN}: https://www.envoyproxy.io/docs/envoy/${PIN}/start/install" >&2
exit 1
