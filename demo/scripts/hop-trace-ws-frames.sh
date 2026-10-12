#!/usr/bin/env bash
# WebSocket frame-bound proof for the demo (option A - truth + tests).
#
# Honest scope:
#   - Stock demo: no upgrade_configs → handshake rejected (upgrade_failed).
#   - Headers-only + upgrade_configs: handshake can reach ModSec; 101 possible.
#   - Post-upgrade frames are opaque - NOT ModSec/CRS inspected (locked here).
#   - BUFFERED + upgrade hangs (locked with a short timeout cell).
#   - Fail-closed still applies on the *handshake* when the connector is down.
#
# Floors: MIN_WS_FRAME_CHECKS (default 6). Empty suite cannot go green.
#
#   ./demo/scripts/up.sh && ./demo/scripts/hop-trace-ws-frames.sh
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

FAIL=0
PASS=0
MIN_WS_FRAME_CHECKS="${MIN_WS_FRAME_CHECKS:-6}"
WS_ORIGIN_PORT=18091
WS_HITS="${RUN}/ws-origin-hits.log"
WS_HEADERS_CFG="${DEMO}/envoy/envoy-ws-headers.yaml"
WS_BUFFERED_CFG="${DEMO}/envoy/envoy-ws-buffered.yaml"
OUT_DIR="${RUN}/hop-trace-ws-frames"
mkdir -p "${OUT_DIR}"
TRANSCRIPT="${OUT_DIR}/$(date -u +%Y%m%dT%H%M%SZ).txt"
exec > >(tee "${TRANSCRIPT}") 2>&1

pass() { echo "  PASS $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL $*"; FAIL=1; }

[[ -f "${WS_HEADERS_CFG}" ]] || { echo "missing ${WS_HEADERS_CFG}" >&2; exit 2; }
[[ -f "${WS_BUFFERED_CFG}" ]] || { echo "missing ${WS_BUFFERED_CFG}" >&2; exit 2; }
grep -q 'failure_mode_allow: false' "${WS_HEADERS_CFG}" \
  || { echo "${WS_HEADERS_CFG} must keep failure_mode_allow: false" >&2; exit 2; }
grep -q 'request_body_mode: NONE' "${WS_HEADERS_CFG}" \
  || { echo "${WS_HEADERS_CFG} must set request_body_mode: NONE" >&2; exit 2; }
grep -q 'upgrade_type: websocket' "${WS_HEADERS_CFG}" \
  || { echo "${WS_HEADERS_CFG} must enable websocket upgrade_configs" >&2; exit 2; }
grep -q 'request_body_mode: BUFFERED' "${WS_BUFFERED_CFG}" \
  || { echo "${WS_BUFFERED_CFG} must set BUFFERED for hang cell" >&2; exit 2; }

wait_http "http://127.0.0.1:${ENVOY_ADMIN_PORT}/ready" 25 \
  || { echo "Envoy not ready - run ./demo/scripts/up.sh first" >&2; exit 2; }

ws_hits() {
  if [[ -f "${WS_HITS}" ]]; then wc -l <"${WS_HITS}" | tr -d ' '; else echo 0; fi
}

# ws_handshake <rid> <path> [timeout_sec] → prints "code=<n> upgraded=<0|1>"
ws_handshake() {
  local rid="$1" path="$2" timeout="${3:-8}"
  BASE_URL="${BASE}" RID="${rid}" PATH_URI="${path}" TIMEOUT="${timeout}" python3 - <<'PY'
import base64, os, socket, urllib.parse
base = os.environ["BASE_URL"]
rid = os.environ["RID"]
path = os.environ["PATH_URI"]
timeout = float(os.environ["TIMEOUT"])
u = urllib.parse.urlparse(base)
host = u.hostname or "127.0.0.1"
port = u.port or 80
key = base64.b64encode(os.urandom(16)).decode()
req = (
    f"GET {path} HTTP/1.1\r\n"
    f"Host: {host}:{port}\r\n"
    "Upgrade: websocket\r\n"
    "Connection: Upgrade\r\n"
    f"Sec-WebSocket-Key: {key}\r\n"
    "Sec-WebSocket-Version: 13\r\n"
    f"x-request-id: {rid}\r\n"
    "\r\n"
)
try:
    s = socket.create_connection((host, port), timeout=timeout)
    s.settimeout(timeout)
    s.sendall(req.encode())
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = s.recv(4096)
        if not chunk:
            break
        data += chunk
    head = data.split(b"\r\n\r\n", 1)[0].decode("latin1", "replace")
    status_line = head.split("\r\n", 1)[0]
    parts = status_line.split()
    code = parts[1] if len(parts) >= 2 and parts[1].isdigit() else "000"
    upgraded = 1 if code == "101" else 0
    print(f"code={code} upgraded={upgraded}")
    # Keep socket open only if caller will continue (not here).
    s.close()
except Exception as e:
    print(f"code=000 upgraded=0 err={type(e).__name__}")
PY
}

# After 101, send a masked text frame with payload; expect echo. Prints "echoed=<0|1>".
ws_send_frame_after_upgrade() {
  local rid="$1" path="$2" payload="$3"
  BASE_URL="${BASE}" RID="${rid}" PATH_URI="${path}" PAYLOAD="${payload}" python3 - <<'PY'
import base64, os, socket, struct, urllib.parse
base = os.environ["BASE_URL"]
rid = os.environ["RID"]
path = os.environ["PATH_URI"]
payload = os.environ["PAYLOAD"].encode()
u = urllib.parse.urlparse(base)
host = u.hostname or "127.0.0.1"
port = u.port or 80
key = base64.b64encode(os.urandom(16)).decode()
req = (
    f"GET {path} HTTP/1.1\r\n"
    f"Host: {host}:{port}\r\n"
    "Upgrade: websocket\r\n"
    "Connection: Upgrade\r\n"
    f"Sec-WebSocket-Key: {key}\r\n"
    "Sec-WebSocket-Version: 13\r\n"
    f"x-request-id: {rid}\r\n"
    "\r\n"
)
s = socket.create_connection((host, port), timeout=8)
s.settimeout(8)
s.sendall(req.encode())
data = b""
while b"\r\n\r\n" not in data:
    chunk = s.recv(4096)
    if not chunk:
        break
    data += chunk
head, rest = data.split(b"\r\n\r\n", 1)
status = head.split(b"\r\n", 1)[0].decode("latin1", "replace")
if " 101 " not in status:
    print("echoed=0 reason=no-101")
    s.close()
    raise SystemExit(0)
# Build masked text frame
mask = os.urandom(4)
masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
frame = bytearray([0x81, 0x80 | len(payload)]) + mask + masked
s.sendall(frame)
# Read echo frame
hdr = s.recv(2)
if len(hdr) < 2:
    print("echoed=0 reason=no-frame")
    s.close()
    raise SystemExit(0)
b1, b2 = hdr[0], hdr[1]
length = b2 & 0x7F
if length == 126:
    length = struct.unpack("!H", s.recv(2))[0]
elif length == 127:
    length = struct.unpack("!Q", s.recv(8))[0]
body = b""
while len(body) < length:
    chunk = s.recv(length - len(body))
    if not chunk:
        break
    body += chunk
s.close()
print("echoed=1" if body == payload else f"echoed=0 got={body[:40]!r}")
PY
}

restore_stock() {
  stop_pidfile "${RUN}/ws-echo.pid" TERM
  stop_pidfile "${RUN}/connector.pid" KILL
  stop_pidfile "${RUN}/envoy.pid" TERM
  {
    echo "# Generated by hop-trace-ws-frames.sh restore - do not edit."
    echo "Include ${DEMO}/rules/engine.conf"
    echo "SecTmpDir ${RUN}/tmp"
    echo "SecDataDir ${RUN}/data"
    echo "SecAuditEngine RelevantOnly"
    echo "SecAuditLogRelevantStatus \"^(?:5|4(?!04))\""
    echo "SecAuditLogParts ABIJDEFHZ"
    echo "SecAuditLogFormat JSON"
    echo "SecAuditLogType Serial"
    echo "SecAuditLog ${RUN}/modsec-audit.log"
    if [[ "${DEMO_CRS:-1}" == "1" ]]; then
      [[ -d "${CRS_DIR}/rules" ]] || "${DEMO}/scripts/install-crs.sh" >&2
      echo "Include ${CRS_DIR}/crs-setup.conf"
      echo "Include ${CRS_DIR}/rules/*.conf"
    fi
    echo "Include ${DEMO}/rules/demo-response.conf"
  } >"${RULES_FILE}"
  CONNECTOR_RULES="" start_connector
  wait_http "${METRICS}/healthz" 100 || return 1
  daemonize "${RUN}/envoy.log" "${RUN}/envoy.pid" \
    envoy -c "${ENVOY_CFG}" --concurrency 2 --log-level warn --file-flush-interval-msec 200
  wait_http "http://127.0.0.1:${ENVOY_ADMIN_PORT}/ready" 100 \
    || { echo "failed to restore Envoy ${ENVOY_CFG}" >&2; return 1; }
}

echo "==> limits  WS frame suite locks: handshake ModSec possible; frames NOT CRS."
echo "  Not claimed: WebSocket frame CRS, full-duplex WS WAF, or BUFFERED+upgrade."

echo "==> 1. stock demo handshake (upgrade_failed; ModSec request-phase not entered)"
if "${DEMO}/scripts/hop-trace-ws.sh"; then
  pass "[stock] hop-trace-ws handshake bound"
else
  fail "[stock] hop-trace-ws FAILED"
fi

echo "==> start ws-echo :${WS_ORIGIN_PORT}"
: >"${WS_HITS}"
stop_pidfile "${RUN}/ws-echo.pid" TERM
if [[ -n "$(port_pid "${WS_ORIGIN_PORT}")" ]]; then
  kill -KILL "$(port_pid "${WS_ORIGIN_PORT}")" 2>/dev/null || true
  sleep 0.2
fi
daemonize "${RUN}/ws-echo.log" "${RUN}/ws-echo.pid" \
  python3 "${DEMO}/scripts/ws-echo.py" "${WS_ORIGIN_PORT}" "${WS_HITS}"
ready=0
for _ in $(seq 1 50); do
  if [[ -n "$(port_pid "${WS_ORIGIN_PORT}")" ]]; then ready=1; break; fi
  sleep 0.1
done
if [[ "${ready}" -eq 1 ]]; then pass "ws-echo listening"; else fail "ws-echo not listening"; exit 1; fi

echo "==> reload connector with CRS + demo-ws.conf (phase-1 UNION deny)"
# Without phase-1 deny, CRS can Continue headers then block at phase 2 after the
# upgrade already reached the origin (measured). Early deny keeps origin clean.
{
  echo "# Generated by hop-trace-ws-frames.sh - do not edit."
  echo "Include ${DEMO}/rules/engine.conf"
  echo "SecTmpDir ${RUN}/tmp"
  echo "SecDataDir ${RUN}/data"
  echo "SecAuditEngine RelevantOnly"
  echo "SecAuditLogRelevantStatus \"^(?:5|4(?!04))\""
  echo "SecAuditLogParts ABIJDEFHZ"
  echo "SecAuditLogFormat JSON"
  echo "SecAuditLogType Serial"
  echo "SecAuditLog ${RUN}/modsec-audit.log"
  [[ -d "${CRS_DIR}/rules" ]] || "${DEMO}/scripts/install-crs.sh" >&2
  echo "Include ${CRS_DIR}/crs-setup.conf"
  echo "Include ${CRS_DIR}/rules/*.conf"
  echo "Include ${DEMO}/rules/demo-response.conf"
  echo "Include ${DEMO}/rules/demo-ws.conf"
} >"${RUN}/modsec-ws.conf"
stop_pidfile "${RUN}/connector.pid" KILL
CONNECTOR_RULES="${RUN}/modsec-ws.conf" start_connector
wait_http "${METRICS}/healthz" 100 \
  || { echo "ws connector failed:"; tail -n 40 "${RUN}/connector.log"; exit 1; }

echo "==> restart Envoy with headers-only + websocket upgrade (${WS_HEADERS_CFG})"
stop_pidfile "${RUN}/envoy.pid" TERM
daemonize "${RUN}/envoy.log" "${RUN}/envoy.pid" \
  envoy -c "${WS_HEADERS_CFG}" --concurrency 2 --log-level warn --file-flush-interval-msec 200
wait_http "http://127.0.0.1:${ENVOY_ADMIN_PORT}/ready" 100 \
  || { echo "ws-headers Envoy failed:"; tail -n 40 "${RUN}/envoy.log"; restore_stock || true; exit 1; }
trap 'restore_stock || true' EXIT

echo "==> 2. headers-only upgrade benign (expect 101, origin UPGRADE, ModSec allow)"
RID="ws-allow-$(date -u +%Y%m%dT%H%M%SZ)-$$"
before="$(ws_hits)"
summary="$(ws_handshake "${RID}" /)"
echo "  client ${summary}"
sleep 0.4
after="$(ws_hits)"
if [[ "${summary}" == *upgraded=1* ]] && grep -qF "UPGRADE / rid=${RID}" "${WS_HITS}" \
  && grep -F "request_id=\"${RID}\"" "${RUN}/connector.log" | grep -q 'action="allow"'; then
  pass "[handshake-allow] 101 + origin upgrade + ModSec allow"
else
  fail "[handshake-allow] ${summary} hits ${before}→${after}"
  grep -F "request_id=\"${RID}\"" "${RUN}/connector.log" | tail -5 || true
fi

echo "==> 3. handshake deny: SQLi in upgrade path (expect no 101, origin untouched)"
RID="ws-deny-$(date -u +%Y%m%dT%H%M%SZ)-$$"
summary="$(ws_handshake "${RID}" '/search?q=1%27%20UNION%20SELECT%201--')"
echo "  client ${summary}"
sleep 0.5
denied=0
if grep -F "request_id=\"${RID}\"" "${RUN}/connector.log" | grep -q 'action="deny"'; then
  denied=1
fi
line="$(grep -F "rid=${RID} " "${RUN}/envoy.log" | tail -1 || true)"
if [[ "${line}" == *"modsecurity_intervention"* ]]; then
  denied=1
fi
# Assert this rid never appears in ws-echo hits (totals can move from other cells).
if [[ "${summary}" == *upgraded=0* ]] && [[ "${denied}" -eq 1 ]] \
  && ! grep -qF "rid=${RID}" "${WS_HITS}" 2>/dev/null; then
  pass "[handshake-deny] no 101, ModSec deny, origin never saw rid"
else
  fail "[handshake-deny] ${summary} denied=${denied} origin_hit=$(grep -cF "rid=${RID}" "${WS_HITS}" 2>/dev/null || echo 0)"
  grep -F "${RID}" "${WS_HITS}" || true
fi

echo "==> 4. post-upgrade frame with SQLi text (expect echo - NOT CRS frame deny)"
RID="ws-frame-$(date -u +%Y%m%dT%H%M%SZ)-$$"
before="$(ws_hits)"
# Payload that would 403 on HTTP body CRS if frames were ModSec-inspected.
payload="comment=1' UNION SELECT 1,2-- <script>alert(1)</script>"
frame_summary="$(ws_send_frame_after_upgrade "${RID}" / "${payload}")"
echo "  client ${frame_summary}"
sleep 0.5
after="$(ws_hits)"
# Must have upgraded + frame recorded; must NOT see a ModSec deny for this rid on a frame phase.
if [[ "${frame_summary}" == echoed=1* ]] \
  && grep -qF "UPGRADE / rid=${RID}" "${WS_HITS}" \
  && grep -qF "FRAME " "${WS_HITS}" \
  && grep -qF "rid=${RID}" "${WS_HITS}"; then
  # No deny action after allow for this rid (handshake allow only).
  if grep -F "request_id=\"${RID}\"" "${RUN}/connector.log" | grep -q 'action="deny"'; then
    fail "[frame] ModSec denied something for rid=${RID} - unexpected for opaque frames"
  else
    pass "[frame] SQLi-shaped frame echoed; origin saw FRAME; no ModSec frame deny"
  fi
else
  fail "[frame] ${frame_summary} hits ${before}→${after}"
  grep -F "${RID}" "${WS_HITS}" || true
fi

echo "==> 5. fail-closed on handshake (connector killed → no 101)"
RID="ws-fc-$(date -u +%Y%m%dT%H%M%SZ)-$$"
before="$(ws_hits)"
kill -KILL "$(cat "${RUN}/connector.pid")"
sleep 0.3
summary="$(ws_handshake "${RID}" /)"
echo "  client ${summary}"
after="$(ws_hits)"
if [[ "${summary}" == *upgraded=0* ]] && [[ "${after}" == "${before}" ]]; then
  pass "[fail-closed] no 101 with connector down, origin untouched"
else
  fail "[fail-closed] ${summary} hits ${before}→${after}"
fi
CONNECTOR_RULES="" start_connector
if wait_http "${METRICS}/healthz" 100; then
  pass "[fail-closed] connector restored"
else
  fail "[fail-closed] connector restore failed"
fi

echo "==> 6. BUFFERED + upgrade hang bound (short timeout; must not 101)"
stop_pidfile "${RUN}/envoy.pid" TERM
daemonize "${RUN}/envoy.log" "${RUN}/envoy.pid" \
  envoy -c "${WS_BUFFERED_CFG}" --concurrency 2 --log-level warn --file-flush-interval-msec 200
wait_http "http://127.0.0.1:${ENVOY_ADMIN_PORT}/ready" 100 \
  || { fail "[buffered] Envoy failed"; exit 1; }
RID="ws-buf-$(date -u +%Y%m%dT%H%M%SZ)-$$"
before="$(ws_hits)"
# 3s timeout: hang manifests as no 101 / code=000 / connection drop - not success.
summary="$(ws_handshake "${RID}" / 3)"
echo "  client ${summary}"
after="$(ws_hits)"
if [[ "${summary}" == *upgraded=1* ]]; then
  fail "[buffered] unexpectedly upgraded under BUFFERED+upgrade (hang bound broken)"
else
  pass "[buffered] no 101 within 3s under BUFFERED+upgrade (hang/DC bound locked)"
fi
# Switch back to headers-only briefly so restore_stock path is clean.
stop_pidfile "${RUN}/envoy.pid" TERM
daemonize "${RUN}/envoy.log" "${RUN}/envoy.pid" \
  envoy -c "${WS_HEADERS_CFG}" --concurrency 2 --log-level warn --file-flush-interval-msec 200
wait_http "http://127.0.0.1:${ENVOY_ADMIN_PORT}/ready" 100 || true

echo
if [[ "${PASS}" -ge "${MIN_WS_FRAME_CHECKS}" ]]; then
  echo "  floor PASS=${PASS} (≥ ${MIN_WS_FRAME_CHECKS})"
else
  fail "[floor] PASS=${PASS} < ${MIN_WS_FRAME_CHECKS}"
fi

echo "transcript: ${TRANSCRIPT}"
if [[ "${FAIL}" -ne 0 ]]; then
  echo "HOP-TRACE-WS-FRAMES FAILED (${PASS} passed)"
  exit 1
fi
echo "HOP-TRACE-WS-FRAMES PASSED checks=${PASS} (handshake ModSec yes; frame CRS no)"
