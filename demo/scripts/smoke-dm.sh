#!/usr/bin/env bash
# Live smoke for DEPLOY=dm (dynamic module). Separate PASS line from ext_proc smoke.sh.
# Requires: DEPLOY=dm ./demo/scripts/up.sh
# Floors: BUFFERED body path ≥5; STREAMED 403 with origin delta 0|1 honesty;
#         NONE header denials + body-bypass honesty.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

if [[ "${DEPLOY}" != "dm" ]]; then
  echo "smoke-dm.sh requires DEPLOY=dm (got '${DEPLOY}'). Start with: DEPLOY=dm ./demo/scripts/up.sh" >&2
  exit 2
fi

FAIL=0
BODY_PASS=0
HEADER_PASS=0
MIN_BODY_CHECKS="${MIN_BODY_CHECKS:-5}"
MIN_HEADER_CHECKS="${MIN_HEADER_CHECKS:-5}"
pass() { echo "  PASS $*"; }
fail() { echo "  FAIL $*"; FAIL=1; }
body_pass() { pass "$@"; BODY_PASS=$((BODY_PASS + 1)); }
header_pass() { pass "$@"; HEADER_PASS=$((HEADER_PASS + 1)); }

expect() {
  local name="$1" want="$2" want_delta="$3"
  shift 3
  local cell=plain
  if [[ "${1:-}" == "--body" ]]; then cell=body; shift; fi
  if [[ "${1:-}" == "--header" ]]; then cell=header; shift; fi
  local before after code delta
  before="$(origin_hits)"
  code="$(http_code "$@")"
  sleep 0.15
  after="$(origin_hits)"
  delta=$((after - before))
  if [[ "$code" == "$want" && "$delta" == "$want_delta" ]]; then
    case "${cell}" in
      body) body_pass "[$name] HTTP $code, origin hits +$delta" ;;
      header) header_pass "[$name] HTTP $code, origin hits +$delta" ;;
      *) pass "[$name] HTTP $code, origin hits +$delta" ;;
    esac
  else
    fail "[$name] HTTP $code (want $want), origin hits +$delta (want +$want_delta)"
  fi
}

wait_http "${BASE}/" 50 || { echo "demo not up at ${BASE} — run DEPLOY=dm ./demo/scripts/up.sh" >&2; exit 2; }
echo "==> DEPLOY=dm body_mode=${BODY_MODE} body_policy=${DM_BODY_POLICY} (config $(basename "${ENVOY_CFG}"))"
code="$(http_code "http://127.0.0.1:${ENVOY_ADMIN_PORT}/ready")"
if [[ "$code" == "200" ]]; then pass "[admin/ready] 200"; else fail "[admin/ready] $code"; fi

echo "==> benign traffic (expect 200, reaches origin)"
expect "get-root" 200 1 "${BASE}/"
expect "get-static" 200 1 "${BASE}/assets/app.css"
expect "get-query" 200 1 "${BASE}/search?q=running+shoes"
expect "post-form" 200 1 --body -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-binary 'name=alice&note=hello+world' "${BASE}/post"
expect "post-json" 200 1 --body -X POST -H 'Content-Type: application/json' \
  --data-binary '{"name":"alice","qty":2}' "${BASE}/api/order"

echo "==> request-line attacks (CRS; expect 403, never reach origin)"
expect "sqli-query" 403 0 --header "${BASE}/search?q=1%27%20UNION%20SELECT%20username,password%20FROM%20users--"
expect "sqli-tautology" 403 0 --header "${BASE}/item?id=1%27%20OR%20%271%27=%271"
expect "xss-query" 403 0 --header "${BASE}/page?q=%3Cscript%3Ealert(document.cookie)%3C/script%3E"
expect "xss-img" 403 0 --header "${BASE}/page?q=%3Cimg%20src=x%20onerror=alert(1)%3E"
expect "path-traversal" 403 0 --header "${BASE}/download?file=../../../../etc/passwd"

if [[ "${BODY_MODE}" == "NONE" ]]; then
  echo "==> request-body attacks (NONE → body bypass honesty; expect 200, origin +1)"
  expect "sqli-form-body-bypass" 200 1 -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-binary "user=admin'%20UNION%20SELECT%201,2,3--" "${BASE}/login"
  expect "xss-form-body-bypass" 200 1 -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-binary 'comment=<script>alert(1)</script>' "${BASE}/comment"
elif [[ "${BODY_MODE}" == "STREAMED" ]]; then
  echo "==> request-body attacks (STREAMED: 403 required; origin delta 0|1 honesty)"
  for name_payload in \
    "sqli-form-body|user=admin'%20UNION%20SELECT%201,2,3--|application/x-www-form-urlencoded|/login" \
    "xss-form-body|comment=<script>alert(1)</script>|application/x-www-form-urlencoded|/comment" \
    "sqli-json-body|{\"q\":\"1' UNION SELECT password FROM users--\"}|application/json|/api/search"
  do
    IFS='|' read -r name payload ctype path <<<"${name_payload}"
    before="$(origin_hits)"
    code="$(http_code -X POST -H "Content-Type: ${ctype}" --data-binary "${payload}" "${BASE}${path}")"
    sleep 0.15
    delta=$(( $(origin_hits) - before ))
    if [[ "$code" == "403" && ( "$delta" == "0" || "$delta" == "1" ) ]]; then
      body_pass "[$name] HTTP 403 origin +${delta} (STREAMED honesty)"
    else
      fail "[$name] HTTP $code origin +$delta (want 403, delta 0|1)"
    fi
  done
else
  echo "==> request-body attacks (${BODY_MODE} → phase 2; expect 403, origin +0)"
  expect "sqli-form-body" 403 0 --body -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-binary "user=admin'%20UNION%20SELECT%201,2,3--" "${BASE}/login"
  expect "xss-form-body" 403 0 --body -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-binary 'comment=<script>alert(1)</script>' "${BASE}/comment"
  expect "sqli-json-body" 403 0 --body -X POST -H 'Content-Type: application/json' \
    --data-binary "{\"q\":\"1' UNION SELECT password FROM users--\"}" "${BASE}/api/search"
fi

if [[ "${BODY_MODE}" == "NONE" ]]; then
  echo "==> response path (NONE → no response body to ModSec; leak reaches client)"
  expect "response-body-leak-bypass" 200 1 "${BASE}/leak"
elif [[ "${BODY_MODE}" == "STREAMED" ]]; then
  # STREAMED response: headers Continue may release body before phase-4 deny.
  # Accept 403 (caught) or 200 (early release honesty); origin +1 either way.
  echo "==> response path (STREAMED honesty: phase-4 may or may not beat early release)"
  before="$(origin_hits)"
  code="$(http_code "${BASE}/leak")"
  sleep 0.15
  delta=$(( $(origin_hits) - before ))
  if [[ "$delta" == "1" && ( "$code" == "403" || "$code" == "200" ) ]]; then
    body_pass "[response-body-leak] HTTP $code origin +1 (STREAMED response honesty)"
  else
    fail "[response-body-leak] HTTP $code origin +$delta (want 200|403, +1)"
  fi
else
  echo "==> response path (origin answers; phase-4 demo rule blocks the leak)"
  expect "response-body-leak" 403 1 --body "${BASE}/leak"
fi

echo "==> CONNECT carve-out (direct 403)"
before="$(origin_hits)"
connect_code="$(
  python3 - "${ENVOY_PORT}" <<'PY'
import socket, sys
port = int(sys.argv[1])
req = b"CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\nConnection: close\r\n\r\n"
s = socket.create_connection(("127.0.0.1", port), timeout=5)
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
except TimeoutError:
    pass
s.close()
print(data.split(b" ", 2)[1].decode() if data.startswith(b"HTTP/") else "000")
PY
)"
delta=$(( $(origin_hits) - before ))
if [[ "${connect_code}" == "403" && "${delta}" == "0" ]]; then
  pass "[connect] HTTP 403 origin +0"
else
  fail "[connect] HTTP ${connect_code} origin +${delta}"
fi

# Cookie crumb (H1 Cookie header present → still allow/deny via CRS).
echo "==> cookie crumb (H1 Cookie header reaches ModSec)"
expect "cookie-benign" 200 1 -H 'Cookie: session=abc; theme=light' "${BASE}/"
expect "cookie-sqli-query" 403 0 --header -H 'Cookie: session=abc' \
  "${BASE}/search?q=1%27%20UNION%20SELECT%201--"

if [[ "${BODY_MODE}" == "NONE" ]]; then
  if [[ "${HEADER_PASS}" -ge "${MIN_HEADER_CHECKS}" ]]; then
    pass "[floor] header-path checks PASS=${HEADER_PASS} (≥ ${MIN_HEADER_CHECKS})"
  else
    fail "[floor] header-path checks PASS=${HEADER_PASS} < ${MIN_HEADER_CHECKS}"
  fi
else
  if [[ "${BODY_PASS}" -ge "${MIN_BODY_CHECKS}" ]]; then
    pass "[floor] body-path checks PASS=${BODY_PASS} (≥ ${MIN_BODY_CHECKS})"
  else
    fail "[floor] body-path checks PASS=${BODY_PASS} < ${MIN_BODY_CHECKS}"
  fi
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo "DM-SMOKE FAILED body_mode=${BODY_MODE} body_policy=${DM_BODY_POLICY}"
  exit 1
fi
echo "DM-SMOKE PASSED body_mode=${BODY_MODE} body_policy=${DM_BODY_POLICY} body_checks=${BODY_PASS} header_checks=${HEADER_PASS}"
