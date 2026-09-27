#!/usr/bin/env bash
# Build and test the connector against exactly one libmodsecurity tag.
#
#   MODSECURITY_PIN=v3.0.15 ./scripts/probe-modsec-pin.sh               # Linux: builds the tag
#   MODSECURITY_PIN=v3.0.15 ./scripts/probe-modsec-pin.sh --skip-install # already on PKG_CONFIG_PATH
#
# Builds into ${PREFIX:-$HOME/.local/modsecurity-<tag>} so tags never mix, and
# fails unless pkg-config reports the requested version.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN="${MODSECURITY_PIN:-$(grep -E '^MODSECURITY_PIN=' "$ROOT/versions.lock.md" | cut -d= -f2)}"
PREFIX="${PREFIX:-$HOME/.local/modsecurity-${PIN}}"
SKIP_INSTALL=0

for arg in "$@"; do
  case "$arg" in
    --skip-install) SKIP_INSTALL=1 ;;
    -h | --help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

if [[ "$SKIP_INSTALL" -eq 0 ]]; then
  [[ "$(uname -s)" == "Linux" ]] || { echo "building a tag needs Linux; use --skip-install with an existing install" >&2; exit 2; }
  export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig"
  MODSECURITY_PIN="$PIN" PREFIX="$PREFIX" MODSECURITY_SRC_DIR="${HOME}/src/ModSecurity-${PIN}" \
    "${ROOT}/scripts/install-libmodsecurity-ubuntu.sh"
  export LD_LIBRARY_PATH="${PREFIX}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  export LIBRARY_PATH="${PREFIX}/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
fi

ver="$(pkg-config --modversion modsecurity)"
[[ "$ver" == "${PIN#v}" ]] || { echo "pkg-config reports libmodsecurity ${ver}, want ${PIN#v}" >&2; exit 1; }
echo "==> libmodsecurity ${ver} ($(pkg-config --variable=libdir modsecurity))"

cd "$ROOT"
echo "==> cargo fmt --check"
cargo fmt --all -- --check
echo "==> cargo clippy -D warnings"
cargo clippy --workspace --all-targets -- -D warnings
echo "==> cargo test"
cargo test --workspace
echo "==> cargo build -p ext-proc-modsec"
cargo build -p ext-proc-modsec
echo "PROBE PASSED: connector against libmodsecurity ${ver}"
