#!/usr/bin/env bash
# Fail-closed drills against the running demo. Every drill asserts the
# client status AND that the origin received nothing.
#
#   1. connector killed (SIGKILL)      → Envoy 500, origin untouched
#   2. connector hung (SIGSTOP)        → Envoy 504 after message_timeout, origin untouched
#   3. connector restarted with broken rules → process exits non-zero, Envoy 500
#   4. connector restored              → 200 again
#
# Requires ./demo/scripts/up.sh.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

FAIL=0
pass() { echo "  PASS $*"; }
fail() { echo "  FAIL $*"; FAIL=1; }

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
[[ "$code" == "200" ]] && pass "[baseline] 200" || { fail "[baseline] $code"; exit 1; }

echo "==> 1. connector killed (SIGKILL)"
kill -KILL "$(connector_pid)"
sleep 0.3
drill "killed-get" "500" "${BASE}/"
drill "killed-post" "500" -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-binary 'name=alice' "${BASE}/post"
drill "killed-attack" "500" "${BASE}/search?q=1%27%20UNION%20SELECT%201--"
restore && pass "[restore] connector ready" || fail "[restore] connector not ready"

echo "==> 2. connector hung (SIGSTOP; Envoy message_timeout 2s)"
kill -STOP "$(connector_pid)"
t0=$(date +%s)
drill "hung-get" "504" "${BASE}/"
t1=$(date +%s)
echo "  (answered in $((t1 - t0))s)"
kill -CONT "$(connector_pid)"
restore && pass "[restore] connector ready" || fail "[restore] connector not ready"

echo "==> 3. connector restarted with broken rules (boot must refuse to serve)"
stop_pidfile "${RUN}/connector.pid" KILL
bad="${RUN}/broken-rules.conf"
echo 'SecRule THIS_IS_NOT_VALID_SECLANG' >"${bad}"
set +e
"${CONNECTOR_BIN}" --listen "${CONNECTOR_LISTEN}" --metrics-listen 127.0.0.1:18082 \
  --modsec-rules "${bad}" >>"${RUN}/connector.log" 2>&1
rc=$?
set -e
[[ "$rc" -ne 0 ]] && pass "[bad-rules] connector exited rc=${rc}" || fail "[bad-rules] connector exited 0"
[[ -z "$(port_pid 18081)" ]] && pass "[bad-rules] nothing listening on :18081" || fail "[bad-rules] :18081 is listening"
drill "bad-rules-get" "500" "${BASE}/"

echo "==> 4. restore"
restore && pass "[restore] connector ready" || fail "[restore] connector not ready"
code="$(http_code "${BASE}/")"
[[ "$code" == "200" ]] && pass "[restored] 200" || fail "[restored] $code"

echo "==> Envoy ext_proc counters"
curl -s "http://127.0.0.1:${ENVOY_ADMIN_PORT}/stats" \
  | grep -E 'ext_proc\.modsec_ext_proc\.(streams_failed|message_timeouts|failure_mode_allowed|streams_started)' \
  | sed 's/^/  /' || true

if [[ "$FAIL" -ne 0 ]]; then
  echo "FAIL-CLOSED DRILLS FAILED"
  exit 1
fi
echo "FAIL-CLOSED DRILLS PASSED"
