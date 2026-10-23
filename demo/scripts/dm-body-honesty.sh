#!/usr/bin/env bash
# Body-mode honesty for DEPLOY=dm (STREAMED / NONE / BUFFERED_PARTIAL).
# Separate PASS lines from ext_proc partial-honesty.sh / smoke STREAMED cells.
#
#   DEPLOY=dm BODY_MODE=STREAMED ./demo/scripts/up.sh && ./demo/scripts/dm-body-honesty.sh
#   DEPLOY=dm BODY_MODE=NONE ./demo/scripts/up.sh && ./demo/scripts/dm-body-honesty.sh
#   DEPLOY=dm BODY_MODE=BUFFERED_PARTIAL DM_PARTIAL_SOFT_LIMIT=65536 ./demo/scripts/up.sh && ./demo/scripts/dm-body-honesty.sh
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

if [[ "${DEPLOY}" != "dm" ]]; then
  echo "dm-body-honesty.sh requires DEPLOY=dm" >&2
  exit 2
fi

FAIL=0
PASS=0
pass() { echo "  PASS $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL $*"; FAIL=1; }

wait_http "${BASE}/" 50 || { echo "demo not up" >&2; exit 2; }
WORKDIR="${RUN}/dm-honesty"
mkdir -p "${WORKDIR}"

case "${BODY_MODE}" in
  STREAMED)
    echo "==> STREAMED last-chunk SQLi (403 required; origin delta 0|1)"
    before="$(origin_hits)"
    code="$(
      python3 - "${ENVOY_PORT}" <<'PY'
import socket, sys
port = int(sys.argv[1])
c1 = b"pad=AAAAAAAAAA&"
c2 = b"a=1'%20OR%201%3D1--"
def chunk(data: bytes) -> bytes:
    return f"{len(data):x}\r\n".encode() + data + b"\r\n"
body = chunk(c1) + chunk(c2) + b"0\r\n\r\n"
req = (
    b"POST /login HTTP/1.1\r\nHost: 127.0.0.1\r\n"
    b"Content-Type: application/x-www-form-urlencoded\r\n"
    b"Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
) + body
s = socket.create_connection(("127.0.0.1", port), timeout=20)
s.sendall(req)
data = b""
while True:
    part = s.recv(4096)
    if not part:
        break
    data += part
s.close()
print(data.split(b" ", 2)[1].decode() if data.startswith(b"HTTP/") else "000")
PY
    )"
    sleep 0.2
    delta=$(( $(origin_hits) - before ))
    if [[ "$code" == "403" && ( "$delta" == "0" || "$delta" == "1" ) ]]; then
      pass "[streamed-last-chunk] HTTP 403 origin +${delta}"
    else
      fail "[streamed-last-chunk] HTTP $code origin +$delta"
    fi
    ;;
  NONE)
    echo "==> NONE body bypass honesty"
    before="$(origin_hits)"
    code="$(http_code -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-binary "user=admin'%20UNION%20SELECT%201--" "${BASE}/login")"
    sleep 0.15
    delta=$(( $(origin_hits) - before ))
    if [[ "$code" == "200" && "$delta" == "1" ]]; then
      pass "[none-body-bypass] HTTP 200 origin +1"
    else
      fail "[none-body-bypass] HTTP $code origin +$delta"
    fi
    before="$(origin_hits)"
    code="$(http_code "${BASE}/search?q=1%27%20UNION%20SELECT%201--")"
    sleep 0.15
    delta=$(( $(origin_hits) - before ))
    if [[ "$code" == "403" && "$delta" == "0" ]]; then
      pass "[none-header-deny] HTTP 403 origin +0"
    else
      fail "[none-header-deny] HTTP $code origin +$delta"
    fi
    ;;
  BUFFERED_PARTIAL)
    # Full CRS can 403 a large AAA pad (arg-size / anomaly noise) and mask the
    # prefix miss. Trailing-bypass honesty uses minimal rules + small soft limit
    # (matrix evidence); under-limit CRS smoke stays on the main up.sh cell.
    SOFT=1024
    PAD=$((SOFT * 4))
    echo "==> PARTIAL honesty soft=${SOFT} pad=${PAD} (minimal rules; never CRS-complete)"
    MIN_RULES="${WORKDIR}/partial-min.conf"
    {
      echo "SecRuleEngine On"
      echo "SecRequestBodyAccess On"
      echo "SecRule REQUEST_BODY \"@contains UNION SELECT\" \"id:910001,phase:2,deny,status:403,log,msg:'partial-min body sqli'\""
      # prefix_then_continue ends phase-2 before EOS — waive REQBODY_ERROR.
      echo "SecRuleRemoveById 200002"
    } >"${MIN_RULES}"
    stop_pidfile "${RUN}/envoy.pid" KILL
    python3 "${DEMO}/scripts/mk-envoy-dm-yaml.py" \
      --out "${RUN}/envoy-dm-partial-honesty.yaml" \
      --listen "${ENVOY_PORT}" \
      --admin "${ENVOY_ADMIN_PORT}" \
      --origin "${ORIGIN_PORT}" \
      --body-policy prefix_then_continue \
      --soft-limit "${SOFT}" \
      --rules "${MIN_RULES}" \
      --label "dm-partial-honesty" >/dev/null
    daemonize "${RUN}/envoy-partial-honesty.log" "${RUN}/envoy.pid" \
      env ENVOY_DYNAMIC_MODULES_SEARCH_PATH="${DM_MODULES_DIR}" \
      envoy -c "${RUN}/envoy-dm-partial-honesty.yaml" --concurrency 2 --log-level warn
    if ! wait_http "http://127.0.0.1:${ENVOY_ADMIN_PORT}/ready" 100; then
      fail "[partial] envoy not ready for honesty"
      echo "DM-BODY-HONESTY FAILED body_mode=${BODY_MODE} pass=${PASS}"
      exit 1
    fi

    python3 - <<PY
from pathlib import Path
out = Path("${WORKDIR}")
soft, pad = int("${SOFT}"), int("${PAD}")
(out / "inprefix.bin").write_bytes(b"pad=" + b"A" * 200 + b"&q=1' UNION SELECT 1--")
(out / "trailing.bin").write_bytes(b"pad=" + b"A" * pad + b"&q=1' UNION SELECT 1--")
print(f"soft={soft} pad={pad}")
PY
    post_file() {
      python3 - <<'PY' "${BASE}" "$1"
import socket, sys
from pathlib import Path
from urllib.parse import urlparse
base, path = sys.argv[1], Path(sys.argv[2])
data = path.read_bytes()
u = urlparse(base)
host, port = u.hostname, u.port or 80
parts = [data[i:i+16384] for i in range(0, len(data), 16384)] or [b""]
body = b"".join(f"{len(p):x}\r\n".encode() + p + b"\r\n" for p in parts) + b"0\r\n\r\n"
req = (
    f"POST /login HTTP/1.1\r\nHost: {host}:{port}\r\n"
    "Content-Type: application/x-www-form-urlencoded\r\n"
    "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
).encode() + body
buf = b""
s = socket.create_connection((host, port), timeout=60)
try:
    s.sendall(req)
    while True:
        c = s.recv(4096)
        if not c:
            break
        buf += c
except (ConnectionResetError, BrokenPipeError, TimeoutError):
    print("000")
    raise SystemExit(0)
finally:
    s.close()
line = buf.split(b"\r\n", 1)[0].decode("latin1", "replace") if buf else ""
parts = line.split()
print(parts[1] if len(parts) >= 2 else "000")
PY
    }
    before="$(origin_hits)"
    code="$(post_file "${WORKDIR}/inprefix.bin")"
    sleep 0.2
    delta=$(( $(origin_hits) - before ))
    if [[ "$code" == "403" && "$delta" == "0" ]]; then
      pass "[partial-in-prefix] HTTP 403 origin +0"
    else
      fail "[partial-in-prefix] HTTP $code origin +$delta"
    fi
    before="$(origin_hits)"
    code="$(post_file "${WORKDIR}/trailing.bin")"
    sleep 0.3
    delta=$(( $(origin_hits) - before ))
    if [[ "$delta" == "1" && "$code" != "403" && "$code" != "000" ]]; then
      pass "[partial-trailing-bypass] HTTP $code origin +1"
    else
      fail "[partial-trailing-bypass] HTTP $code origin +$delta (want non-403 +1)"
    fi
    # Restore stock DM config from RULES_FILE / DM_BODY_POLICY.
    stop_pidfile "${RUN}/envoy.pid" KILL
    python3 "${DEMO}/scripts/mk-envoy-dm-yaml.py" \
      --out "${ENVOY_CFG}" \
      --listen "${ENVOY_PORT}" \
      --admin "${ENVOY_ADMIN_PORT}" \
      --origin "${ORIGIN_PORT}" \
      --body-policy "${DM_BODY_POLICY}" \
      --soft-limit "${DM_PARTIAL_SOFT_LIMIT}" \
      --rules "${RULES_FILE}" \
      --label "dm-restore" >/dev/null
    daemonize "${RUN}/envoy.log" "${RUN}/envoy.pid" \
      env ENVOY_DYNAMIC_MODULES_SEARCH_PATH="${DM_MODULES_DIR}" \
      envoy -c "${ENVOY_CFG}" --concurrency 2 --log-level warn
    wait_http "http://127.0.0.1:${ENVOY_ADMIN_PORT}/ready" 100 || true
    ;;
  *)
    echo "dm-body-honesty.sh: BODY_MODE=${BODY_MODE} has no extra honesty cell (BUFFERED covered by smoke-dm)" >&2
    exit 0
    ;;
esac

if [[ "$FAIL" -ne 0 || "$PASS" -lt 1 ]]; then
  echo "DM-BODY-HONESTY FAILED body_mode=${BODY_MODE} pass=${PASS}"
  exit 1
fi
echo "DM-BODY-HONESTY PASSED body_mode=${BODY_MODE} checks=${PASS}"
