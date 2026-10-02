#!/usr/bin/env bash
# Live smoke through Envoy → connector → libmodsecurity (+ CRS) → origin.
# Requires ./demo/scripts/up.sh. Exits non-zero on any failed expectation.
# Works for BODY_MODE=BUFFERED (default), STREAMED, and BUFFERED_PARTIAL.
# Floors: ≥ 5 body-path checks (benign form/json + 3 body attacks) must PASS.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

FAIL=0
BODY_PASS=0
MIN_BODY_CHECKS="${MIN_BODY_CHECKS:-5}"
pass() { echo "  PASS $*"; }
fail() { echo "  FAIL $*"; FAIL=1; }
body_pass() { pass "$@"; BODY_PASS=$((BODY_PASS + 1)); }

# expect <name> <want-code> <want-origin-delta> [--body] <curl args...>
expect() {
  local name="$1" want="$2" want_delta="$3"
  shift 3
  local body_cell=0
  if [[ "${1:-}" == "--body" ]]; then body_cell=1; shift; fi
  local before after code delta
  before="$(origin_hits)"
  code="$(http_code "$@")"
  sleep 0.1
  after="$(origin_hits)"
  delta=$((after - before))
  if [[ "$code" == "$want" && "$delta" == "$want_delta" ]]; then
    if [[ "$body_cell" -eq 1 ]]; then
      body_pass "[$name] HTTP $code, origin hits +$delta"
    else
      pass "[$name] HTTP $code, origin hits +$delta"
    fi
  else
    fail "[$name] HTTP $code (want $want), origin hits +$delta (want +$want_delta)"
  fi
}

wait_http "${BASE}/" 50 || { echo "demo not up at ${BASE} — run ./demo/scripts/up.sh" >&2; exit 2; }
echo "==> body_mode=${BODY_MODE} (config $(basename "${ENVOY_CFG}"))"
echo "==> connector readiness"
code="$(http_code "${METRICS}/healthz")"
[[ "$code" == "200" ]] && pass "[healthz] 200" || fail "[healthz] $code"

echo "==> benign traffic (expect 200, reaches origin)"
expect "get-root" 200 1 "${BASE}/"
expect "get-static" 200 1 "${BASE}/assets/app.css"
expect "get-query" 200 1 "${BASE}/search?q=running+shoes"
expect "post-form" 200 1 --body -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-binary 'name=alice&note=hello+world' "${BASE}/post"
expect "post-json" 200 1 --body -X POST -H 'Content-Type: application/json' \
  --data-binary '{"name":"alice","qty":2}' "${BASE}/api/order"

echo "==> request-line attacks (CRS; expect 403, never reach origin)"
expect "sqli-query" 403 0 "${BASE}/search?q=1%27%20UNION%20SELECT%20username,password%20FROM%20users--"
expect "sqli-tautology" 403 0 "${BASE}/item?id=1%27%20OR%20%271%27=%271"
expect "xss-query" 403 0 "${BASE}/page?q=%3Cscript%3Ealert(document.cookie)%3C/script%3E"
expect "xss-img" 403 0 "${BASE}/page?q=%3Cimg%20src=x%20onerror=alert(1)%3E"
expect "path-traversal" 403 0 "${BASE}/download?file=../../../../etc/passwd"

echo "==> request-body attacks (${BODY_MODE} → phase 2; expect 403, never reach origin)"
expect "sqli-form-body" 403 0 --body -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-binary "user=admin'%20UNION%20SELECT%201,2,3--" "${BASE}/login"
expect "xss-form-body" 403 0 --body -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-binary 'comment=<script>alert(1)</script>' "${BASE}/comment"
expect "sqli-json-body" 403 0 --body -X POST -H 'Content-Type: application/json' \
  --data-binary "{\"q\":\"1' UNION SELECT password FROM users--\"}" "${BASE}/api/search"

if [[ "${REQUEST_BODY_MODE}" == "STREAMED" ]]; then
  echo "==> STREAMED chunked body (attack only in last chunk; expect 403, origin untouched)"
  before="$(origin_hits)"
  chunked_code="$(
    python3 - "${ENVOY_PORT}" <<'PY'
import socket, sys
port = int(sys.argv[1])
head = b"name=alice&q="
tail = b"1' UNION SELECT password FROM users--"
req = (
    b"POST /login HTTP/1.1\r\nHost: 127.0.0.1\r\n"
    b"Content-Type: application/x-www-form-urlencoded\r\n"
    b"Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
)
for chunk in (head, tail):
    req += b"%x\r\n" % len(chunk) + chunk + b"\r\n"
req += b"0\r\n\r\n"
s = socket.create_connection(("127.0.0.1", port), timeout=10)
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
  sleep 0.1
  after="$(origin_hits)"
  delta=$((after - before))
  if [[ "${chunked_code}" == "403" && "${delta}" == "0" ]]; then
    body_pass "[chunked-sqli-last] HTTP 403, origin hits +0"
  else
    fail "[chunked-sqli-last] HTTP ${chunked_code} (want 403), origin hits +${delta} (want +0)"
  fi
fi

echo "==> response path (origin answers; phase-4 rule blocks the leak)"
expect "response-body-leak" 403 1 --body "${BASE}/leak"

echo "==> CONNECT carve-out (direct 403; ext_proc disabled)"
before="$(origin_hits)"
connect_result="$(
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
code = data.split(b" ", 2)[1].decode() if data.startswith(b"HTTP/") else "000"
print(f"{code} {elapsed:.3f}")
PY
)"
connect_code="${connect_result%% *}"
connect_elapsed="${connect_result##* }"
sleep 0.1
delta=$(( $(origin_hits) - before ))
if [[ "${connect_code}" == "403" && "${delta}" == "0" ]] \
  && python3 -c "import sys; sys.exit(0 if float('${connect_elapsed}') < 1.5 else 1)"; then
  pass "[connect] HTTP 403 origin +0 in ${connect_elapsed}s"
else
  fail "[connect] HTTP ${connect_code} origin +${delta} elapsed=${connect_elapsed}s (want 403 / +0 / <1.5s)"
fi

echo "==> connector metrics"
m="$(curl -s "${METRICS}/metrics")"
echo "${m}" | grep -E '^ext_proc_(requests|allow|deny|fail_closed)_total ' | sed 's/^/  /'
deny="$(echo "${m}" | awk '/^ext_proc_deny_total /{print $2}')"
fc="$(echo "${m}" | awk '/^ext_proc_fail_closed_total /{print $2}')"
want_deny=9
[[ "${REQUEST_BODY_MODE}" == "STREAMED" ]] && want_deny=10
[[ "${deny:-0}" -ge "${want_deny}" ]] && pass "[metrics] deny_total=${deny}" || fail "[metrics] deny_total=${deny:-?} (want ≥ ${want_deny})"
[[ "${fc:-0}" -eq 0 ]] && pass "[metrics] fail_closed_total=0" || fail "[metrics] fail_closed_total=${fc}"

[[ "${BODY_PASS}" -ge "${MIN_BODY_CHECKS}" ]] \
  && pass "[floor] body-path checks PASS=${BODY_PASS} (≥ ${MIN_BODY_CHECKS})" \
  || fail "[floor] body-path checks PASS=${BODY_PASS} < ${MIN_BODY_CHECKS}"

if [[ "$FAIL" -ne 0 ]]; then
  echo "SMOKE FAILED body_mode=${BODY_MODE}"
  exit 1
fi
echo "SMOKE PASSED body_mode=${BODY_MODE} body_checks=${BODY_PASS}"