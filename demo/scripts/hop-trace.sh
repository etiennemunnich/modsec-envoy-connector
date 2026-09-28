#!/usr/bin/env bash
# Trace one request through the running demo by x-request-id:
#   client → Envoy (access log) → connector / ModSecurity phases (connector log)
#   → CRS / rule matches (ModSecurity audit log, when relevant) → origin (hits file).
# Exits non-zero if a hop that must exist has no evidence, or an expectation fails.
#
#   ./demo/scripts/hop-trace.sh /
#   ./demo/scripts/hop-trace.sh --proto h2 --expect-status 403 --expect-origin no \
#       '/search?q=1%27%20UNION%20SELECT%201--'
#   ./demo/scripts/hop-trace.sh --expect-status 403 /login -X POST --data 'user=admin%27--'
#
# WebSocket handshake (honest limits — NOT full WS WAF / NOT frame CRS):
#   ./demo/scripts/hop-trace.sh --proto ws /
#   Demo Envoy has no websocket upgrade config → client gets 403 details=upgrade_failed.
#   Request headers do not reach ModSec request phase; connector may only see
#   local-reply passthrough on the response. WebSocket *frames* are never inspected.
#
# Report: demo/.run/hop-trace/<request-id>.txt
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

PROTO=h1
EXPECT_STATUS=""
EXPECT_ORIGIN=""

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
  echo "usage: $0 [--proto h1|h2|ws] [--expect-status CODE] [--expect-origin yes|no] PATH [curl args...]" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --proto) PROTO="$2"; shift 2 ;;
    --expect-status) EXPECT_STATUS="$2"; shift 2 ;;
    --expect-origin) EXPECT_ORIGIN="$2"; shift 2 ;;
    -h | --help) usage ;;
    -*) echo "unknown option $1 (curl args go after PATH)" >&2; usage ;;
    *) break ;;
  esac
done
[[ $# -ge 1 ]] || usage
REQ_PATH="$1"
shift
case "${PROTO}" in
  h1) FLAG=--http1.1 ;;
  h2) FLAG=--http2-prior-knowledge ;;
  ws) FLAG="" ;;
  *) echo "unsupported --proto ${PROTO} (h1|h2|ws)" >&2; exit 2 ;;
esac
case "${EXPECT_ORIGIN}" in "" | yes | no) ;; *) usage ;; esac

# WS defaults: demo rejects upgrades at Envoy (upgrade_failed); origin untouched.
if [[ "${PROTO}" == "ws" ]]; then
  [[ -n "${EXPECT_STATUS}" ]] || EXPECT_STATUS=403
  [[ -n "${EXPECT_ORIGIN}" ]] || EXPECT_ORIGIN=no
  if [[ $# -gt 0 ]]; then
    echo "ws mode does not take curl args (got: $*)" >&2
    exit 2
  fi
fi

wait_http "http://127.0.0.1:${ENVOY_ADMIN_PORT}/ready" 25 \
  || { echo "Envoy not ready — run ./demo/scripts/up.sh" >&2; exit 2; }

RID="hop-$(date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM}"
mkdir -p "${RUN}/hop-trace"
REPORT="${RUN}/hop-trace/${RID}.txt"
exec > >(tee "${REPORT}") 2>&1

FAIL=0
ok() { echo "  OK   $*"; }
bad() { echo "  FAIL $*"; FAIL=1; }

CODE=""
VER="0"
if [[ "${PROTO}" == "ws" ]]; then
  echo "==> limits  WebSocket hop-trace covers HTTP Upgrade *handshake* only."
  echo "  Not claimed: WebSocket frame CRS, full-duplex WS WAF, or upgrade success."
  # Raw upgrade (no websocat). Envoy without upgrade_configs → upgrade_failed.
  read -r CODE <<EOF
$(
  BASE_URL="${BASE}" RID="${RID}" PATH_URI="${REQ_PATH}" python3 - <<'PY'
import base64, os, socket, urllib.parse
base = os.environ["BASE_URL"]
rid = os.environ["RID"]
path = os.environ["PATH_URI"]
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
try:
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
    print(code)
except Exception:
    print("000")
finally:
    try:
        s.close()
    except Exception:
        pass
PY
)
EOF
  VER="1.1"
else
  read -r CODE VER < <(curl -s -o /dev/null -w '%{http_code} %{http_version}\n' --max-time 10 \
    "${FLAG}" -H "x-request-id: ${RID}" "$@" "${BASE}${REQ_PATH}" || echo "000 0")
fi
sleep 0.6

echo "==> client  ${PROTO} ${BASE}${REQ_PATH}  rid=${RID}"
echo "  HTTP ${CODE} (http_version ${VER})"
if [[ -n "${EXPECT_STATUS}" && "${CODE}" == "${EXPECT_STATUS}" ]]; then
  ok "status ${CODE}"
elif [[ -n "${EXPECT_STATUS}" ]]; then
  bad "status ${CODE}, want ${EXPECT_STATUS}"
fi

echo "==> Envoy access log"
line="$(grep -F "rid=${RID} " "${RUN}/envoy.log" | tail -1 || true)"
if [[ -n "${line}" ]]; then
  echo "  ${line}"
  ok "Envoy saw the request"
  if [[ "${PROTO}" == "ws" ]]; then
    if [[ "${line}" == *"details=upgrade_failed"* ]]; then
      ok "details=upgrade_failed (demo has no websocket upgrade_configs)"
    else
      echo "  note: expected upgrade_failed on stock demo; got other details"
    fi
  fi
else
  bad "no Envoy access-log line for ${RID}"
fi

echo "==> connector / ModSecurity phases"
phases="$(grep -F "request_id=\"${RID}\"" "${RUN}/connector.log" \
  | grep -E 'modsec phase complete|fail-closed' \
  | grep -Eo 'phase="[a-z_]+" action="[a-z_]+"( status=[0-9]+)?|error=.*$' || true)"
if [[ -n "${phases}" ]]; then
  while IFS= read -r p; do echo "  ${p}"; done <<<"${phases}"
  ok "connector inspected the request"
elif [[ "${PROTO}" == "ws" ]]; then
  # Measured: Envoy rejects the upgrade before request-phase ext_proc; connector
  # may only log local-reply passthrough (no request_id on the client rid).
  passthrough="$(grep -E 'local_reply_passthrough|Envoy local reply without request phase' \
    "${RUN}/connector.log" | tail -3 || true)"
  if [[ -n "${passthrough}" ]]; then
    while IFS= read -r p; do echo "  ${p}"; done <<<"${passthrough}"
  fi
  ok "no ModSec request-phase for this rid (upgrade stopped at Envoy — not CRS header WAF)"
elif [[ "${line}" == *"details=ext_proc"* ]]; then
  details="${line##*details=}"
  ok "no connector evidence; Envoy failed the ext_proc call itself (${details%% *})"
else
  bad "no connector log lines for ${RID}"
fi

echo "==> ModSecurity audit log (rule matches)"
python3 - "${RUN}/modsec-audit.log" "${RID}" <<'PY'
import json, sys
path, rid = sys.argv[1], sys.argv[2]
found = False
try:
    with open(path, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            try:
                entry = json.loads(raw)
            except ValueError:
                continue
            tx = entry.get("transaction", {})
            if tx.get("unique_id") != rid:
                continue
            found = True
            for m in tx.get("messages", []):
                d = m.get("details", {})
                print(f"  rule {d.get('ruleId', '?')}: {m.get('message', '')}")
except OSError:
    pass
if not found:
    print("  (no audit entry — nothing relevant matched, or audit logging is off)")
PY
if [[ "${PROTO}" == "ws" ]]; then
  echo "  (WS: frame/body CRS not applicable; handshake never entered ModSec request phase)"
fi

echo "==> origin"
if grep -qF "rid=${RID}" "${HITS_FILE}" 2>/dev/null; then
  origin=yes
  echo "  $(grep -F "rid=${RID}" "${HITS_FILE}" | tail -1)"
else
  origin=no
  echo "  (origin never received ${RID})"
fi
if [[ -n "${EXPECT_ORIGIN}" && "${origin}" == "${EXPECT_ORIGIN}" ]]; then
  ok "origin reached: ${origin}"
elif [[ -n "${EXPECT_ORIGIN}" ]]; then
  bad "origin reached: ${origin}, want ${EXPECT_ORIGIN}"
fi

echo "report: ${REPORT}"
if [[ "${FAIL}" -ne 0 ]]; then
  echo "HOP-TRACE FAILED"
  exit 1
fi
if [[ "${PROTO}" == "ws" ]]; then
  echo "HOP-TRACE OK (ws handshake only — not full WS WAF)"
else
  echo "HOP-TRACE OK"
fi
