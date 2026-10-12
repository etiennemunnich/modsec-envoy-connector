#!/usr/bin/env bash
# CONNECT carve-out assertion.
# Demo Envoy answers CONNECT with direct_response 403 and ExtProcPerRoute
# disabled so BUFFERED ext_proc never waits for end_of_stream.
#
# Proves:
#   - CONNECT → 403 (not hang / empty / 200)
#   - origin untouched
#   - response arrives quickly (ext_proc disabled path; hang would miss budget)
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

FAIL=0
PASS=0
pass() { echo "  PASS $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL $*"; FAIL=1; }

wait_http "${BASE}/" 50 || { echo "demo not up at ${BASE} — run ./demo/scripts/up.sh" >&2; exit 2; }

# Config lock: CONNECT route must disable ext_proc.
grep -q 'connect_matcher' "${ENVOY_CFG}" \
  || { echo "${ENVOY_CFG} missing connect_matcher route" >&2; exit 2; }
# The CONNECT route block must set ExtProcPerRoute disabled: true nearby.
python3 - "${ENVOY_CFG}" <<'PY'
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
idx = text.find("connect_matcher")
if idx < 0:
    sys.exit("no connect_matcher")
# Look ahead in the CONNECT route (~25 lines / ~800 chars) for disabled: true
window = text[idx : idx + 800]
if "disabled: true" not in window:
    sys.exit("CONNECT route missing ExtProcPerRoute disabled: true")
if "status: 403" not in window:
    sys.exit("CONNECT route missing direct_response status 403")
print("config ok")
PY

echo "==> CONNECT → 403 (ext_proc disabled carve-out) body_mode=${BODY_MODE}"

before="$(origin_hits)"
# Raw CONNECT: curl -X CONNECT is unreliable across versions; speak HTTP/1.1.
result="$(
  python3 - "${ENVOY_PORT}" <<'PY'
import socket, time, sys
port = int(sys.argv[1])
req = (
    b"CONNECT example.com:443 HTTP/1.1\r\n"
    b"Host: example.com:443\r\n"
    b"Connection: close\r\n\r\n"
)
t0 = time.monotonic()
s = socket.create_connection(("127.0.0.1", port), timeout=5)
s.settimeout(5)
s.sendall(req)
data = b""
try:
    while True:
        part = s.recv(4096)
        if not part:
            break
        data += part
        if b"\r\n\r\n" in data:
            break
except socket.timeout:
    pass
elapsed = time.monotonic() - t0
s.close()
if data.startswith(b"HTTP/"):
    code = data.split(b" ", 2)[1].decode()
else:
    code = "000"
print(f"{code} {elapsed:.3f}")
PY
)"
code="${result%% *}"
elapsed="${result##* }"
sleep 0.1
delta=$(( $(origin_hits) - before ))

# Must be 403, origin +0, and fast (< 2s — message_timeout is 2s; hang would be ≥2s).
ok=1
if [[ "$code" != "403" ]]; then
  fail "[connect] HTTP $code (want 403) elapsed=${elapsed}s origin +${delta}"
  ok=0
fi
if [[ "$delta" != "0" ]]; then
  fail "[connect] origin +${delta} (want +0)"
  ok=0
fi
# bash arithmetic compare for float-ish elapsed
python3 - "$elapsed" <<'PY' || { fail "[connect] slow response ${elapsed}s (want < 1.5s; ext_proc hang risk)"; exit 0; }
import sys
elapsed = float(sys.argv[1])
sys.exit(0 if elapsed < 1.5 else 1)
PY
if [[ "$ok" -eq 1 && "$code" == "403" && "$delta" == "0" ]]; then
  pass "[connect] HTTP 403 origin +0 in ${elapsed}s (ext_proc disabled)"
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo "CONNECT-ASSERT FAILED body_mode=${BODY_MODE}"
  exit 1
fi
echo "CONNECT-ASSERT PASSED body_mode=${BODY_MODE} checks=${PASS}"
