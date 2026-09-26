#!/usr/bin/env bash
# Stub smoke: verify pins tools + build the workspace connector crate.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

echo "== demo smoke (stub) =="
./demo/scripts/install-envoy.sh || echo "(envoy check soft-failed — continue with cargo)"
echo
cargo build -p ext-proc-modsec
cargo test --workspace
echo
echo "OK: cargo build/test passed."
echo "Next: wire Envoy ext_proc with failure_mode_allow: false — see demo/README.md"
