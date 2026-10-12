#!/usr/bin/env bash
# Fail-closed drills against the running demo. Every drill asserts the
# client status AND that the origin received nothing.
#
#   1. connector killed (SIGKILL)      → Envoy 500, origin untouched
#   2. connector hung (SIGSTOP)        → Envoy 504 after message_timeout, origin untouched
#                                        (SKIP under FULL_DUPLEX_STREAMED: no message_timeout)
#   3. connector restarted with broken rules → process exits non-zero, Envoy 500
#   4. connector restored              → 200 again
#   Envoy failure_mode_allowed stays 0 throughout.
#
# Requires ./demo/scripts/up.sh.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

FAIL=0
PASS=0
SKIP=0
pass() { echo "  PASS $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL $*"; FAIL=1; }
skip() { echo "  SKIP $*"; SKIP=$((SKIP + 1)); }

# drill <name> <allowed-codes-regex> <curl args...>
drill() {
  local name="$1" want="$2"
  shift 2
  local before after code
  before="$(origin_hits)"
  code="$(http_code "$@")"
  sleep 0.1
  after="$(origin_hits)"
  if [[ "$code" =~ ^(${want})$ && "$after" == "$before" ]]; then
    pass "[$name] HTTP $code, origin hits unchanged ($after)"
  else
    fail "[$name] HTTP $code (want ${want}), origin hits ${before}→${after}"
  fi
}

connector_pid() { cat "${RUN}/connector.pid" 2>/dev/null || true; }

restore() {
  stop_pidfile "${RUN}/connector.pid" KILL
  CONNECTOR_RULES="" start_connector
  wait_http "${METRICS}/healthz" 100
}

wait_http "${BASE}/" 50 || { echo "demo not up at ${BASE} — run ./demo/scripts/up.sh" >&2; exit 2; }

echo "==> baseline"
code="$(http_code "${BASE}/")"
if [[ "$code" == "200" ]]; then pass "[baseline] 200"; else fail "[baseline] $code"; exit 1; fi

echo "==> 1. connector killed (SIGKILL)"
kill -KILL "$(connector_pid)"
sleep 0.3
drill "killed-get" "500" "${BASE}/"
drill "killed-post" "500" -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-binary 'name=alice' "${BASE}/post"
drill "killed-attack" "500" "${BASE}/search?q=1%27%20UNION%20SELECT%201--"
if restore; then pass "[restore] connector ready"; else fail "[restore] connector not ready"; fi

if [[ "${BODY_MODE}" == "FULL_DUPLEX_STREAMED" ]]; then
  # Envoy disables message_timeout under FULL_DUPLEX_STREAMED — hang→504 is N/A.
  echo "==> 2. connector hung (not run under FULL_DUPLEX_STREAMED — no message_timeout)"
  skip "[hung-get] Envoy disables message_timeout for FULL_DUPLEX_STREAMED"
else
  echo "==> 2. connector hung (SIGSTOP; Envoy message_timeout 2s)"
  kill -STOP "$(connector_pid)"
  t0=$(date +%s)
  drill "hung-get" "504" "${BASE}/"
  t1=$(date +%s)
  echo "  (answered in $((t1 - t0))s)"
  kill -CONT "$(connector_pid)"
  if restore; then pass "[restore] connector ready"; else fail "[restore] connector not ready"; fi
fi

echo "==> 3. connector restarted with broken rules (boot must refuse to serve)"
stop_pidfile "${RUN}/connector.pid" KILL
bad="${RUN}/broken-rules.conf"
echo 'SecRule THIS_IS_NOT_VALID_SECLANG' >"${bad}"
set +e
"${CONNECTOR_BIN}" --listen "${CONNECTOR_LISTEN}" --metrics-listen "127.0.0.1:${METRICS_PORT}" \
  --modsec-rules "${bad}" >>"${RUN}/connector.log" 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then pass "[bad-rules] connector exited rc=${rc}"; else fail "[bad-rules] connector exited 0"; fi
if [[ -z "$(port_pid "${CONNECTOR_PORT}")" ]]; then
  pass "[bad-rules] nothing listening on :${CONNECTOR_PORT}"
else
  fail "[bad-rules] :${CONNECTOR_PORT} is listening"
fi
drill "bad-rules-get" "500" "${BASE}/"

echo "==> 4. restore"
if restore; then pass "[restore] connector ready"; else fail "[restore] connector not ready"; fi
code="$(http_code "${BASE}/")"
if [[ "$code" == "200" ]]; then pass "[restored] 200"; else fail "[restored] $code"; fi

echo "==> Envoy ext_proc counters"
stats="$(curl -s --max-time 5 "http://127.0.0.1:${ENVOY_ADMIN_PORT}/stats")"
grep -E 'ext_proc\.modsec_ext_proc\.(streams_failed|message_timeouts|failure_mode_allowed|streams_started)' <<<"${stats}" \
  | sed 's/^/  /'
fma="$(awk -F': ' '$1 ~ /ext_proc\.modsec_ext_proc\.failure_mode_allowed$/ {print $2; exit}' <<<"${stats}")"
if [[ "${fma}" == "0" ]]; then
  pass "[envoy] failure_mode_allowed=0 (no request was let through on a connector failure)"
else
  fail "[envoy] failure_mode_allowed='${fma}' (want 0)"
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo "FAIL-CLOSED DRILLS FAILED checks=${PASS} skipped=${SKIP}"
  exit 1
fi
echo "FAIL-CLOSED DRILLS PASSED checks=${PASS} skipped=${SKIP}"
