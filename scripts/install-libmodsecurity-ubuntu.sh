#!/usr/bin/env bash
# Build/install libmodsecurity from source on Ubuntu (CI and Linux demo hosts).
# Distro packages on Ubuntu 24.04 (Noble) ship 3.0.12; the connector is built
# and tested against MODSECURITY_PIN in versions.lock.md. Only that exact
# version counts as installed. Sources are cloned into a per-tag cache dir.
#
# Usage (CI):
#   PREFIX=$HOME/.local ./scripts/install-libmodsecurity-ubuntu.sh
# Then export PKG_CONFIG_PATH / LD_LIBRARY_PATH / LIBRARY_PATH for cargo.
set -euo pipefail

PIN="${MODSECURITY_PIN:-v3.0.17}"
WANT="${PIN#v}"
PREFIX="${PREFIX:-$HOME/.local}"
SRC_DIR="${MODSECURITY_SRC_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/modsec-envoy-connector/ModSecurity-${PIN}}"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This script targets Ubuntu/Linux CI. On macOS use demo/scripts/install-libmodsecurity.sh." >&2
  exit 1
fi

# Only the exact pin counts as installed; anything else is rebuilt into PREFIX.
if command -v pkg-config >/dev/null 2>&1; then
  ver="$(PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
    pkg-config --modversion modsecurity 2>/dev/null || true)"
  if [[ "$ver" == "$WANT" ]]; then
    echo "libmodsecurity $ver already installed (pkg-config); pin is $PIN."
    exit 0
  fi
  [[ -z "$ver" ]] || echo "Found libmodsecurity $ver, pin is $PIN; building $PIN into $PREFIX"
fi

# Root in containers has no sudo; CI runners are non-root and need sudo.
if [[ "$(id -u)" -eq 0 ]]; then
  APT=(apt-get)
else
  APT=(sudo apt-get)
fi
"${APT[@]}" update
"${APT[@]}" install -y --no-install-recommends \
  autoconf \
  automake \
  build-essential \
  ca-certificates \
  flex \
  bison \
  git \
  libcurl4-openssl-dev \
  libgeoip-dev \
  liblmdb-dev \
  libpcre2-dev \
  libtool \
  libxml2-dev \
  libyajl-dev \
  pkg-config \
  pkgconf \
  zlib1g-dev

mkdir -p "$(dirname "$SRC_DIR")"
if [[ ! -d "$SRC_DIR/.git" ]]; then
  git -c advice.detachedHead=false clone --depth 1 --branch "$PIN" \
    https://github.com/owasp-modsecurity/ModSecurity.git "$SRC_DIR"
fi
tag="$(git -C "$SRC_DIR" describe --tags --exact-match HEAD 2>/dev/null || true)"
if [[ "$tag" != "$PIN" ]]; then
  echo "$SRC_DIR is at '${tag:-no tag}', not $PIN; remove it or set MODSECURITY_SRC_DIR" >&2
  exit 1
fi

cd "$SRC_DIR"
git submodule update --init --recursive

./build.sh
./configure --prefix="$PREFIX" --with-pcre2
make -j"$(nproc)"
make install

ver="$(PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" pkg-config --modversion modsecurity)"
echo "Installed libmodsecurity $ver at $PREFIX"
PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" pkg-config --cflags --libs modsecurity
if [[ "$ver" != "$WANT" ]]; then
  echo "ERROR: built libmodsecurity $ver, pin is $PIN" >&2
  exit 1
fi
