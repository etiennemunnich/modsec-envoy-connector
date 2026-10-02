#!/usr/bin/env bash
# Build/install libmodsecurity from source on Ubuntu (CI and Linux demo hosts).
# Distro packages on Ubuntu 24.04 (Noble) ship 3.0.12, which fails
# modsecurity-sys. Lab pin is v3.0.17 — latest stable v3 (see versions.lock.md).
#
# Usage (CI):
#   PREFIX=$HOME/.local ./scripts/install-libmodsecurity-ubuntu.sh
# Then export PKG_CONFIG_PATH / LD_LIBRARY_PATH / LIBRARY_PATH for cargo.
set -euo pipefail

PIN="${MODSECURITY_PIN:-v3.0.17}"
PREFIX="${PREFIX:-$HOME/.local}"
SRC_DIR="${MODSECURITY_SRC_DIR:-$HOME/src/ModSecurity}"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This script targets Ubuntu/Linux CI. On macOS use demo/scripts/install-libmodsecurity.sh." >&2
  exit 1
fi

if command -v pkg-config >/dev/null 2>&1; then
  if pkg-config --exists modsecurity; then
    ver="$(pkg-config --modversion modsecurity)"
    # Accept anything ≥ 3.0.13 already on PKG_CONFIG_PATH / system.
    if printf '%s\n' "$ver" | awk -F. '{
      exit !($1 > 3 || ($1 == 3 && $2 > 0) || ($1 == 3 && $2 == 0 && $3 >= 13))
    }'; then
      echo "libmodsecurity $ver already satisfies ≥ 3.0.13 (pkg-config)."
      pkg-config --cflags --libs modsecurity
      exit 0
    fi
    echo "Found libmodsecurity $ver (< 3.0.13); building $PIN into $PREFIX"
  fi
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
  rm -rf "$SRC_DIR"
  git clone --depth 1 --branch "$PIN" \
    https://github.com/owasp-modsecurity/ModSecurity.git "$SRC_DIR"
fi

cd "$SRC_DIR"
git submodule update --init --recursive

./build.sh
./configure --prefix="$PREFIX" --with-pcre2
make -j"$(nproc)"
make install

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
ver="$(pkg-config --modversion modsecurity)"
echo "Installed libmodsecurity $ver at $PREFIX"
pkg-config --cflags --libs modsecurity

# Soft assert ≥ 3.0.13
printf '%s\n' "$ver" | awk -F. '{
  if (!($1 > 3 || ($1 == 3 && $2 > 0) || ($1 == 3 && $2 == 0 && $3 >= 13))) {
    print "ERROR: need libmodsecurity ≥ 3.0.13, got " $0 > "/dev/stderr"
    exit 1
  }
}'
