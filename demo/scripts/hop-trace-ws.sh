#!/usr/bin/env bash
# WebSocket handshake hop-trace proof for the connex demo.
# Honest scope: HTTP Upgrade handshake only. Not frame CRS. Not "full WS WAF".
#
#   ./demo/scripts/up.sh
#   ./demo/scripts/hop-trace-ws.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"

echo "==> WS hop-trace: benign upgrade path (expect Envoy upgrade_failed 403, origin no)"
"${ROOT}/hop-trace.sh" --proto ws --expect-status 403 --expect-origin no /

echo
echo "==> WS hop-trace: SQLi in upgrade request-line (still Envoy upgrade_failed — not CRS)"
"${ROOT}/hop-trace.sh" --proto ws --expect-status 403 --expect-origin no \
  '/search?q=1%27%20UNION%20SELECT%201--'

echo
echo "HOP-TRACE-WS PASSED (handshake only; frame CRS not claimed)"
