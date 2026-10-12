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
# gRPC (honest limits — headers/path/metadata only; NOT protobuf CRS):
#   Requires demo/scripts/hop-trace-grpc.sh (or equivalent) to have switched Envoy
#   to demo/envoy/envoy-grpc.yaml and started demo/grpc-echo on :18090.
#   ./demo/scripts/hop-trace.sh --proto grpc --expect-grpc-ok yes --expect-origin yes
#   ./demo/scripts/hop-trace.sh --proto grpc --expect-grpc-ok no --expect-origin no \
#       --grpc-header 'x-demo-grpc-probe: deny'
#
# Report: demo/.run/hop-trace/<request-id>.txt
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

PROTO=h1
EXPECT_STATUS=""
EXPECT_ORIGIN=""
EXPECT_GRPC_OK=""
GRPC_METHOD="echo.Echo/Unary"
GRPC_DATA='{"text":"hop-trace"}'
GRPC_HEADERS=()
GRPC_HITS="${RUN}/grpc-origin-hits.log"
GRPC_ECHO_DIR="${DEMO}/grpc-echo"

usage() {
  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
  echo "usage: $0 [--proto h1|h2|ws|grpc] [--expect-status CODE] [--expect-origin yes|no]" >&2
  echo "          [--expect-grpc-ok yes|no] [--grpc-method M] [--grpc-header 'k: v']..." >&2
  echo "          [PATH [curl args...]]" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --proto) PROTO="$2"; shift 2 ;;
    --expect-status) EXPECT_STATUS="$2"; shift 2 ;;
    --expect-origin) EXPECT_ORIGIN="$2"; shift 2 ;;
    --expect-grpc-ok) EXPECT_GRPC_OK="$2"; shift 2 ;;
    --grpc-method) GRPC_METHOD="$2"; shift 2 ;;
    --grpc-data) GRPC_DATA="$2"; shift 2 ;;
    --grpc-header) GRPC_HEADERS+=("$2"); shift 2 ;;
    -h | --help) usage ;;
    -*)
      if [[ "${PROTO}" == "grpc" ]]; then
        echo "unknown option $1" >&2
        usage
      fi
      echo "unknown option $1 (curl args go after PATH)" >&2
      usage
      ;;
    *) break ;;
  esac
done

case "${PROTO}" in
  h1 | h2 | ws | grpc) ;;
  *) echo "unsupported --proto ${PROTO} (h1|h2|ws|grpc)" >&2; exit 2 ;;
esac
case "${EXPECT_ORIGIN}" in "" | yes | no) ;; *) usage ;; esac
case "${EXPECT_GRPC_OK}" in "" | yes | no) ;; *) usage ;; esac

REQ_PATH="/"
CURL_ARGS=()
if [[ "${PROTO}" != "grpc" ]]; then
  [[ $# -ge 1 ]] || usage
  REQ_PATH="$1"
  shift
  CURL_ARGS=("$@")
elif [[ $# -gt 0 ]]; then
  echo "grpc mode does not take a PATH argument (got: $*)" >&2
  exit 2
fi

case "${PROTO}" in
  h1) FLAG=--http1.1 ;;
  h2) FLAG=--http2-prior-knowledge ;;
  ws | grpc) FLAG="" ;;
esac

# WS defaults: demo rejects upgrades at Envoy (upgrade_failed); origin untouched.
if [[ "${PROTO}" == "ws" ]]; then
  [[ -n "${EXPECT_STATUS}" ]] || EXPECT_STATUS=403
  [[ -n "${EXPECT_ORIGIN}" ]] || EXPECT_ORIGIN=no
  if [[ ${#CURL_ARGS[@]} -gt 0 ]]; then
    echo "ws mode does not take curl args (got: ${CURL_ARGS[*]})" >&2
    exit 2
  fi
fi

if [[ "${PROTO}" == "grpc" ]]; then
  command -v grpcurl >/dev/null || { echo "grpcurl not on PATH" >&2; exit 2; }
  [[ -f "${GRPC_ECHO_DIR}/echo.proto" ]] || { echo "missing ${GRPC_ECHO_DIR}/echo.proto" >&2; exit 2; }
  [[ -n "${EXPECT_ORIGIN}" ]] || EXPECT_ORIGIN=yes
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
GRPC_RC=""
GRPC_STATUS=""

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
elif [[ "${PROTO}" == "grpc" ]]; then
  echo "==> limits  gRPC hop-trace covers headers / :path / metadata only."
  echo "  Not claimed: protobuf CRS, streaming RPC WAF, or full gRPC body inspection."
  GRPC_OUT="${RUN}/hop-trace/${RID}.grpc-out"
  GRPC_ERR="${RUN}/hop-trace/${RID}.grpc-err"
  set +e
  if [[ ${#GRPC_HEADERS[@]} -gt 0 ]]; then
    hdr_args=()
    for h in "${GRPC_HEADERS[@]}"; do
      hdr_args+=(-H "${h}")
    done
    grpcurl -plaintext -v \
      -import-path "${GRPC_ECHO_DIR}" -proto echo.proto \
      -H "x-request-id: ${RID}" \
      "${hdr_args[@]}" \
      -d "${GRPC_DATA}" \
      "127.0.0.1:18080" "${GRPC_METHOD}" \
      >"${GRPC_OUT}" 2>"${GRPC_ERR}"
  else
    grpcurl -plaintext -v \
      -import-path "${GRPC_ECHO_DIR}" -proto echo.proto \
      -H "x-request-id: ${RID}" \
      -d "${GRPC_DATA}" \
      "127.0.0.1:18080" "${GRPC_METHOD}" \
      >"${GRPC_OUT}" 2>"${GRPC_ERR}"
  fi
  GRPC_RC=$?
  set -e
  GRPC_STATUS="$(grep -i 'grpc-status:' "${GRPC_ERR}" | tail -1 | awk '{print $2}' | tr -d '\r' || true)"
  CODE="$(grep -iE '^< HTTP/|HTTP/2 ' "${GRPC_ERR}" | tail -1 | awk '{print $2}' | tr -d '\r' || true)"
  CODE="${CODE:-000}"
  VER="2"
else
  curl_cmd=(curl -s -o /dev/null -w '%{http_code} %{http_version}\n' --max-time 10 \
    "${FLAG}" -H "x-request-id: ${RID}")
  if [[ ${#CURL_ARGS[@]} -gt 0 ]]; then
    curl_cmd+=("${CURL_ARGS[@]}")
  fi
  curl_cmd+=("${BASE}${REQ_PATH}")
  read -r CODE VER < <("${curl_cmd[@]}" || echo "000 0")
fi
sleep 0.6

if [[ "${PROTO}" == "grpc" ]]; then
  echo "==> client  grpc ${GRPC_METHOD}  rid=${RID}"
  echo "  grpcurl rc=${GRPC_RC} grpc-status=${GRPC_STATUS:-?} http=${CODE}"
  if [[ "${EXPECT_GRPC_OK}" == "yes" ]]; then
    if [[ "${GRPC_RC}" -eq 0 ]]; then ok "grpc OK"; else bad "grpc want OK got rc=${GRPC_RC} status=${GRPC_STATUS:-?}"; fi
  elif [[ "${EXPECT_GRPC_OK}" == "no" ]]; then
    if [[ "${GRPC_RC}" -ne 0 ]]; then ok "grpc non-OK as expected (rc=${GRPC_RC})"; else bad "grpc unexpectedly OK"; fi
  fi
  if [[ -n "${EXPECT_STATUS}" && "${CODE}" == "${EXPECT_STATUS}" ]]; then
    ok "http status ${CODE}"
  elif [[ -n "${EXPECT_STATUS}" ]]; then
    bad "http status ${CODE}, want ${EXPECT_STATUS}"
  fi
else
  echo "==> client  ${PROTO} ${BASE}${REQ_PATH}  rid=${RID}"
  echo "  HTTP ${CODE} (http_version ${VER})"
  if [[ -n "${EXPECT_STATUS}" && "${CODE}" == "${EXPECT_STATUS}" ]]; then
    ok "status ${CODE}"
  elif [[ -n "${EXPECT_STATUS}" ]]; then
    bad "status ${CODE}, want ${EXPECT_STATUS}"
  fi
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
elif [[ "${PROTO}" == "grpc" ]]; then
  echo "  (gRPC: protobuf body CRS not claimed; headers/path/metadata only)"
fi

echo "==> origin"
ORIGIN_FILE="${HITS_FILE}"
if [[ "${PROTO}" == "grpc" ]]; then
  ORIGIN_FILE="${GRPC_HITS}"
fi
if grep -qF "rid=${RID}" "${ORIGIN_FILE}" 2>/dev/null; then
  origin=yes
  echo "  $(grep -F "rid=${RID}" "${ORIGIN_FILE}" | tail -1)"
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
elif [[ "${PROTO}" == "grpc" ]]; then
  echo "HOP-TRACE OK (grpc headers/path only — not protobuf CRS)"
else
  echo "HOP-TRACE OK"
fi
