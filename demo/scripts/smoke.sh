#!/usr/bin/env bash
# Live smoke through Envoy → connector → libmodsecurity (+ CRS) → origin.
# Requires ./demo/scripts/up.sh. Exits non-zero on any failed expectation.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

FAIL=0
pass() { echo "  PASS $*"; }
fail() { echo "  FAIL $*"; FAIL=1; }

# expect <name> <want-code> <want-origin-delta> <curl args...>
expect() {
  local name="$1" want="$2" want_delta="$3"
  shift 3
  local before after code delta
  before="$(origin_hits)"
  code="$(http_code "$@")"
  sleep 0.1
  after="$(origin_hits)"
  delta=$((after - before))
  if [[ "$code" == "$want" && "$delta" == "$want_delta" ]]; then
    pass "[$name] HTTP $code, origin hits +$delta"
  else
    fail "[$name] HTTP $code (want $want), origin hits +$delta (want +$want_delta)"
  fi
}

wait_http "${BASE}/" 50 || { echo "demo not up at ${BASE} — run ./demo/scripts/up.sh" >&2; exit 2; }
echo "==> connector readiness"
code="$(http_code "${METRICS}/healthz")"
[[ "$code" == "200" ]] && pass "[healthz] 200" || fail "[healthz] $code"

echo "==> benign traffic (expect 200, reaches origin)"
expect "get-root" 200 1 "${BASE}/"
expect "get-static" 200 1 "${BASE}/assets/app.css"
expect "get-query" 200 1 "${BASE}/search?q=running+shoes"
expect "post-form" 200 1 -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-binary 'name=alice&note=hello+world' "${BASE}/post"
expect "post-json" 200 1 -X POST -H 'Content-Type: application/json' \
  --data-binary '{"name":"alice","qty":2}' "${BASE}/api/order"

echo "==> request-line attacks (CRS; expect 403, never reach origin)"
expect "sqli-query" 403 0 "${BASE}/search?q=1%27%20UNION%20SELECT%20username,password%20FROM%20users--"
expect "sqli-tautology" 403 0 "${BASE}/item?id=1%27%20OR%20%271%27=%271"
expect "xss-query" 403 0 "${BASE}/page?q=%3Cscript%3Ealert(document.cookie)%3C/script%3E"
expect "xss-img" 403 0 "${BASE}/page?q=%3Cimg%20src=x%20onerror=alert(1)%3E"
expect "path-traversal" 403 0 "${BASE}/download?file=../../../../etc/passwd"

echo "==> request-body attacks (BUFFERED body → phase 2; expect 403, never reach origin)"
expect "sqli-form-body" 403 0 -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-binary "user=admin'%20UNION%20SELECT%201,2,3--" "${BASE}/login"
expect "xss-form-body" 403 0 -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-binary 'comment=<script>alert(1)</script>' "${BASE}/comment"
expect "sqli-json-body" 403 0 -X POST -H 'Content-Type: application/json' \
  --data-binary "{\"q\":\"1' UNION SELECT password FROM users--\"}" "${BASE}/api/search"

echo "==> response path (origin answers; phase-4 rule blocks the leak)"
expect "response-body-leak" 403 1 "${BASE}/leak"

echo "==> connector metrics"
m="$(curl -s "${METRICS}/metrics")"
echo "${m}" | grep -E '^ext_proc_(requests|allow|deny|fail_closed)_total ' | sed 's/^/  /'
deny="$(echo "${m}" | awk '/^ext_proc_deny_total /{print $2}')"
fc="$(echo "${m}" | awk '/^ext_proc_fail_closed_total /{print $2}')"
[[ "${deny:-0}" -ge 9 ]] && pass "[metrics] deny_total=${deny}" || fail "[metrics] deny_total=${deny:-?} (want ≥ 9)"
[[ "${fc:-0}" -eq 0 ]] && pass "[metrics] fail_closed_total=0" || fail "[metrics] fail_closed_total=${fc}"

if [[ "$FAIL" -ne 0 ]]; then
  echo "SMOKE FAILED"
  exit 1
fi
echo "SMOKE PASSED"
