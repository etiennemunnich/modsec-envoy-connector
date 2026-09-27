#!/usr/bin/env bash
# Install / verify Envoy Proxy at the pin in versions.lock.md (v1.39.1).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PIN="$(grep -E '^ENVOY_PIN=' "$ROOT/versions.lock.md" | head -1 | cut -d= -f2)"
PIN="${PIN:-v1.39.1}"
WANT="${PIN#v}"

echo "envoy-modsec-connex demo: Envoy pin is ${PIN}"
echo "Official guide: https://www.envoyproxy.io/docs/envoy/${PIN}/start/install"
echo "Release: https://github.com/envoyproxy/envoy/releases/tag/${PIN}"
echo

if command -v envoy >/dev/null 2>&1; then
  VER="$(envoy --version 2>&1 || true)"
  echo "Found: $VER"
  if echo "$VER" | grep -q "$WANT"; then
    echo "OK: matches pin ${PIN}"
    exit 0
  fi
  echo "WARN: installed Envoy does not match pin ${PIN}. Prefer Docker or a release asset."
  exit 1
fi

if command -v docker >/dev/null 2>&1; then
  echo "envoy binary not on PATH. Trying Docker image envoyproxy/envoy:${PIN}…"
  docker pull "envoyproxy/envoy:${PIN}"
  docker run --rm "envoyproxy/envoy:${PIN}" --version
  echo "OK: Docker image matches pin ${PIN}"
  echo "Tip (macOS): brew install envoy  # currently bottles 1.39.1"
  exit 0
fi

echo "No envoy on PATH and no docker. Install Envoy ${PIN} manually — see demo/README.md"
exit 1
