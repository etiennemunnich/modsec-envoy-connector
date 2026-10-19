#!/usr/bin/env bash
# Lab HTTP/3 (QUIC) demo suite — durable local test, not product H3 support.
#
# Usage:
#   ./demo/scripts/h3-probe.sh
#   H3_PROBE_KEEP=1 ./demo/scripts/h3-probe.sh   # leave H3 Envoy running
#
# If the connector/origin are down, starts them with BODY_MODE=NONE. Always
# manages a second Envoy on UDP (default :18443) with --base-id.
#
# Dependencies (exit 2 if missing):
#   - envoy at ENVOY_PIN (Linux release binary includes QUIC)
#   - python3 + aioquic (`pip install aioquic`)
#   - openssl (throwaway cert under demo/.run/h3-certs/)
#
# Asserts (PASS floor ≥ MIN_H3_CHECKS, default 14):
#   Hop / fail-closed: GET 200, query SQLi 403, NONE body bypass, HTTP/3 log,
#     http_version=3.0, kill→500, restore, hang→504, failure_mode_allowed=0
#   Cookie crumbs: benign multi-Cookie 200; XSS in 2nd/1st crumb 403; joined
#     XSS 403; empty crumb + benign 200 (Envoy drops empty Cookie on H3)
#
# Does NOT prove: product H3 WAF, BUFFERED CRS on QUIC, go-ftw on H3, or CI
# coverage (demo-only).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=h3-lib.sh
source "$(dirname "$0")/h3-lib.sh"

MIN_H3_CHECKS="${MIN_H3_CHECKS:-14}"
FAIL=0
PASS=0
XSS='theme=<script>alert(1)</script>'

pass() { echo "  PASS $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL $*"; FAIL=$((FAIL + 1)); }

expect_h3() {
  local name="$1" want_status="$2" want_delta="$3"
  shift 3
  local before after code delta
  before="$(origin_hits)"
  h3_capture "$@"
  sleep 0.1
  after="$(origin_hits)"
  delta=$((after - before))
  code="$(h3_status_of "${H3_LAST_OUT}")"
  if [[ -z "${code}" ]]; then
    fail "[${name}] no STATUS (client rc=${H3_LAST_RC})"
    echo "${H3_LAST_OUT}" | sed 's/^/    /'
    return 0
  fi
  if [[ "${code}" == "${want_status}" && "${delta}" == "${want_delta}" ]]; then
    pass "[${name}] HTTP ${code}, origin hits +${delta}"
  else
    fail "[${name}] HTTP ${code} (want ${want_status}), origin +${delta} (want +${want_delta})"
    echo "${H3_LAST_OUT}" | sed 's/^/    /'
  fi
}

echo "==> H3 lab suite (not product H3 support)"
h3_bring_up

echo "==> hop: benign GET → 200, origin +1"
expect_h3 "h3-get" 200 1 --path /

echo "==> hop: SQLi in query → 403, origin +0"
expect_h3 "h3-sqli-query" 403 0 \
  --path "/search?q=1%27%20UNION%20SELECT%20username,password%20FROM%20users--"

echo "==> NONE honesty: SQLi in body → 200, origin +1"
expect_h3 "h3-sqli-body-bypass" 200 1 \
  --method POST --path /login --body "user=admin'%20UNION%20SELECT%201,2,3--"

if grep -qE '"GET / HTTP/3" 200' "${H3_LOG}"; then
  pass "[access-log] HTTP/3 present"
else
  fail "[access-log] missing HTTP/3 200 line in ${H3_LOG}"
fi
if grep -qE 'http_version="3\.0"' "${RUN}/connector.log"; then
  pass "[connector] http_version=3.0 logged"
else
  fail "[connector] missing http_version=3.0 in connector.log"
fi

echo "==> Cookie crumbs (Envoy ; coalesce → CRS)"
expect_h3 "cookie-benign-crumbs" 200 1 \
  --path / -H 'cookie: session=ok' -H 'cookie: theme=dark'
expect_h3 "cookie-attack-2nd" 403 0 \
  --path / -H 'cookie: session=ok' -H "cookie: ${XSS}"
expect_h3 "cookie-attack-1st" 403 0 \
  --path / -H "cookie: ${XSS}" -H 'cookie: session=ok'
expect_h3 "cookie-joined-xss" 403 0 \
  --path / -H "cookie: session=ok; ${XSS}"
expect_h3 "cookie-empty-dropped" 200 1 \
  --path / -H 'cookie: session=ok' -H 'cookie:'

echo "==> fail-closed: kill connector → 500, origin untouched"
before="$(origin_hits)"
kill -9 "$(cat "${RUN}/connector.pid")"
for _ in $(seq 1 30); do
  if ! curl -sf "${METRICS}/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
h3_capture --path /
sleep 0.1
delta=$(( $(origin_hits) - before ))
code="$(h3_status_of "${H3_LAST_OUT}")"
if [[ "${code}" == "500" && "${delta}" == "0" ]]; then
  pass "[h3-killed] HTTP 500, origin hits +0"
else
  fail "[h3-killed] HTTP ${code:-?} (want 500), origin +${delta} (want 0)"
fi
start_connector
if wait_http "${METRICS}/healthz" 100; then
  pass "[restore] connector ready"
else
  fail "[restore] connector not ready"
fi

echo "==> fail-closed: hang connector (SIGSTOP) → 504, origin untouched"
before="$(origin_hits)"
kill -STOP "$(cat "${RUN}/connector.pid")"
h3_capture --path / --timeout 8
sleep 0.1
delta=$(( $(origin_hits) - before ))
code="$(h3_status_of "${H3_LAST_OUT}")"
kill -CONT "$(cat "${RUN}/connector.pid")" 2>/dev/null || true
if [[ "${code}" == "504" && "${delta}" == "0" ]]; then
  pass "[h3-hung] HTTP 504, origin hits +0"
else
  fail "[h3-hung] HTTP ${code:-?} (want 504), origin +${delta} (want 0)"
fi
if ! curl -sf "${METRICS}/healthz" >/dev/null; then
  start_connector
  if ! wait_http "${METRICS}/healthz" 100; then
    fail "[restore-after-hang] connector not ready"
  fi
fi

fma="$(curl -s "http://127.0.0.1:${H3_ADMIN_PORT}/stats" \
  | awk '/ext_proc.modsec_ext_proc_h3.failure_mode_allowed:/{print $2; exit}')"
if [[ "${fma:-}" == "0" ]]; then
  pass "[envoy] failure_mode_allowed=0"
else
  fail "[envoy] failure_mode_allowed=${fma:-?} (want 0)"
fi

if [[ "${H3_PROBE_KEEP:-0}" == "1" || "${H3_PROBE_DOWN:-1}" == "0" ]]; then
  echo "==> H3 Envoy still up (UDP :${H3_PORT}, admin :${H3_ADMIN_PORT}, log ${H3_LOG})"
  echo "    stop with: kill \$(cat ${H3_PID})  or  ./demo/scripts/down.sh"
else
  h3_stop_envoy
  echo "==> H3 Envoy stopped"
fi

if [[ "${FAIL}" -ne 0 ]]; then
  echo "H3 PROBE FAILED checks_failed=${FAIL} pass=${PASS}"
  exit 1
fi
if [[ "${PASS}" -lt "${MIN_H3_CHECKS}" ]]; then
  echo "H3 PROBE FAILED pass=${PASS} < MIN_H3_CHECKS=${MIN_H3_CHECKS}"
  exit 1
fi
echo "H3 PROBE PASSED checks=${PASS} (lab only — not product H3 support)"
