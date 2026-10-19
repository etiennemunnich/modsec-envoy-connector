#!/usr/bin/env bash
# EXPERIMENT — measured HTTP/3 (QUIC) hop through ext_proc. Not product support.
#
# Prerequisites:
#   - Envoy at ENVOY_PIN (release binary includes QUIC on Linux)
#   - connector + origin already up (e.g. BODY_MODE=NONE ./demo/scripts/up.sh)
#   - Python 3 + aioquic (`pip install aioquic`); stock curl often has no --http3
#   - openssl for a throwaway self-signed cert
#
# What this proves (when green):
#   - Envoy QUIC listener accepts HTTP/3; access log shows HTTP/3
#   - connector sees http_version=3.0; header/query CRS can 403
#   - body mode NONE → body attacks reach origin (honest bypass)
#   - failure_mode_allow: false → kill→500, hang→504, origin untouched
#
# What this does NOT prove: product H3 support, BUFFERED/STREAMED body CRS on
# QUIC, go-ftw on H3, or CI coverage.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

H3_PORT="${H3_PORT:-18443}"
H3_ADMIN_PORT="${H3_ADMIN_PORT:-18449}"
H3_BASE_ID="${H3_BASE_ID:-17}"
H3_CERT_DIR="${RUN}/h3-certs"
H3_CFG_RENDERED="${RUN}/envoy-h3.yaml"
H3_LOG="${RUN}/envoy-h3.log"
H3_PID="${RUN}/envoy-h3.pid"
TEMPLATE="${DEMO}/envoy/envoy-h3.yaml"
H3GET="${DEMO}/scripts/h3get.py"
FAIL=0

pass() { echo "  PASS $*"; }
fail() { echo "  FAIL $*"; FAIL=$((FAIL + 1)); }

require_connector() {
  curl -sf "${METRICS}/healthz" >/dev/null \
    || { echo "connector not ready at ${METRICS}/healthz — run BODY_MODE=NONE ./demo/scripts/up.sh first" >&2; exit 2; }
  curl -sf "http://127.0.0.1:${ORIGIN_PORT}/" >/dev/null \
    || { echo "origin not ready on :${ORIGIN_PORT}" >&2; exit 2; }
}

stop_h3_envoy() {
  if [[ -f "${H3_PID}" ]]; then
    pid="$(tr -d '[:space:]' <"${H3_PID}" || true)"
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
      for _ in $(seq 1 30); do
        kill -0 "${pid}" 2>/dev/null || break
        sleep 0.1
      done
      kill -9 "${pid}" 2>/dev/null || true
    fi
    rm -f "${H3_PID}"
  fi
}

ensure_certs() {
  mkdir -p "${H3_CERT_DIR}"
  if [[ ! -f "${H3_CERT_DIR}/servercert.pem" || ! -f "${H3_CERT_DIR}/serverkey.pem" ]]; then
    command -v openssl >/dev/null || { echo "openssl required for H3 experiment certs" >&2; exit 2; }
    openssl req -x509 -newkey rsa:2048 \
      -keyout "${H3_CERT_DIR}/serverkey.pem" \
      -out "${H3_CERT_DIR}/servercert.pem" \
      -days 1 -nodes \
      -subj '/CN=localhost' \
      -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' >/dev/null 2>&1
  fi
}

render_cfg() {
  [[ -f "${TEMPLATE}" ]] || { echo "missing ${TEMPLATE}" >&2; exit 2; }
  # Escape paths for sed replacement.
  local cert key
  cert="${H3_CERT_DIR}/servercert.pem"
  key="${H3_CERT_DIR}/serverkey.pem"
  sed -e "s|__H3_CERT__|${cert}|g" -e "s|__H3_KEY__|${key}|g" \
    -e "s|port_value: 18443|port_value: ${H3_PORT}|g" \
    -e "s|port_value: 18449|port_value: ${H3_ADMIN_PORT}|g" \
    -e "s|port_value: 18081|port_value: ${CONNECTOR_PORT}|g" \
    -e "s|port_value: 18098|port_value: ${ORIGIN_PORT}|g" \
    "${TEMPLATE}" >"${H3_CFG_RENDERED}"
  grep -q 'failure_mode_allow: false' "${H3_CFG_RENDERED}" \
    || { echo "rendered H3 config must keep failure_mode_allow: false" >&2; exit 2; }
  grep -q 'request_body_mode: NONE' "${H3_CFG_RENDERED}" \
    || { echo "rendered H3 config must keep request_body_mode: NONE" >&2; exit 2; }
}

start_h3_envoy() {
  stop_h3_envoy
  : >"${H3_LOG}"
  echo "==> envoy HTTP/3 UDP :${H3_PORT} (admin :${H3_ADMIN_PORT}, base-id ${H3_BASE_ID})"
  daemonize "${H3_LOG}" "${H3_PID}" envoy -c "${H3_CFG_RENDERED}" \
    --concurrency 1 --log-level info --base-id "${H3_BASE_ID}" \
    --file-flush-interval-msec 200
  if ! wait_http "http://127.0.0.1:${H3_ADMIN_PORT}/ready" 100; then
    echo "H3 Envoy failed to become ready:" >&2
    tail -n 40 "${H3_LOG}" >&2
    exit 1
  fi
}

h3() {
  python3 "${H3GET}" --host 127.0.0.1 --port "${H3_PORT}" "$@"
}

status_of() {
  # First line: STATUS <code>
  echo "$1" | awk '/^STATUS /{print $2; exit}'
}

expect_h3() {
  local name="$1" want_status="$2" want_delta="$3"
  shift 3
  local before after out code delta
  before="$(origin_hits)"
  out="$(h3 "$@" 2>&1)" || true
  sleep 0.1
  after="$(origin_hits)"
  delta=$((after - before))
  code="$(status_of "${out}")"
  if [[ "${code}" == "${want_status}" && "${delta}" == "${want_delta}" ]]; then
    pass "[${name}] HTTP ${code}, origin hits +${delta}"
  else
    fail "[${name}] HTTP ${code:-?} (want ${want_status}), origin +${delta} (want +${want_delta})"
    echo "${out}" | sed 's/^/    /'
  fi
}

echo "==> H3 experiment (not product support) pin=$(envoy --version 2>&1 | grep -o '1\.[0-9]*\.[0-9]*' | head -1)"
python3 -c 'import aioquic' 2>/dev/null \
  || { echo "aioquic missing — pip install aioquic" >&2; exit 2; }
require_connector
ensure_certs
render_cfg
envoy --mode validate -c "${H3_CFG_RENDERED}" >/dev/null
start_h3_envoy

echo "==> hop: benign GET → 200, origin +1"
expect_h3 "h3-get" 200 1 --path /

echo "==> hop: SQLi in query → 403, origin +0"
expect_h3 "h3-sqli-query" 403 0 \
  --path "/search?q=1%27%20UNION%20SELECT%20username,password%20FROM%20users--"

echo "==> NONE honesty: SQLi in body → 200, origin +1"
expect_h3 "h3-sqli-body-bypass" 200 1 \
  --method POST --path /login --body "user=admin'%20UNION%20SELECT%201,2,3--"

if ! rg -q '"GET / HTTP/3" 200' "${H3_LOG}"; then
  fail "[access-log] missing HTTP/3 200 line in ${H3_LOG}"
else
  pass "[access-log] HTTP/3 present"
fi
if ! rg -q 'http_version="3.0"' "${RUN}/connector.log"; then
  fail "[connector] missing http_version=3.0 in connector.log"
else
  pass "[connector] http_version=3.0 logged"
fi

echo "==> fail-closed: kill connector → 500, origin untouched"
before="$(origin_hits)"
kill -9 "$(cat "${RUN}/connector.pid")"
for _ in $(seq 1 30); do
  curl -sf "${METRICS}/healthz" >/dev/null 2>&1 || break
  sleep 0.1
done
out="$(h3 --path / 2>&1)" || true
sleep 0.1
delta=$(( $(origin_hits) - before ))
code="$(status_of "${out}")"
if [[ "${code}" == "500" && "${delta}" == "0" ]]; then
  pass "[h3-killed] HTTP 500, origin hits +0"
else
  fail "[h3-killed] HTTP ${code:-?} (want 500), origin +${delta} (want 0)"
fi
start_connector
if ! wait_http "${METRICS}/healthz" 100; then
  fail "[restore] connector not ready"
else
  pass "[restore] connector ready"
fi

echo "==> fail-closed: hang connector (SIGSTOP) → 504, origin untouched"
before="$(origin_hits)"
kill -STOP "$(cat "${RUN}/connector.pid")"
out="$(h3 --path / --timeout 8 2>&1)" || true
sleep 0.1
delta=$(( $(origin_hits) - before ))
code="$(status_of "${out}")"
kill -CONT "$(cat "${RUN}/connector.pid")" 2>/dev/null || true
if [[ "${code}" == "504" && "${delta}" == "0" ]]; then
  pass "[h3-hung] HTTP 504, origin hits +0"
else
  fail "[h3-hung] HTTP ${code:-?} (want 504), origin +${delta} (want 0)"
fi
if ! curl -sf "${METRICS}/healthz" >/dev/null; then
  start_connector
  wait_http "${METRICS}/healthz" 100 >/dev/null || true
fi

fma="$(curl -s "http://127.0.0.1:${H3_ADMIN_PORT}/stats" \
  | awk '/ext_proc.modsec_ext_proc_h3.failure_mode_allowed:/{print $2; exit}')"
if [[ "${fma:-}" == "0" ]]; then
  pass "[envoy] failure_mode_allowed=0"
else
  fail "[envoy] failure_mode_allowed=${fma:-?} (want 0)"
fi

# Leave H3 Envoy up for manual follow-up unless H3_PROBE_DOWN=1.
if [[ "${H3_PROBE_DOWN:-0}" == "1" ]]; then
  stop_h3_envoy
  echo "==> H3 Envoy stopped (H3_PROBE_DOWN=1)"
else
  echo "==> H3 Envoy still up (UDP :${H3_PORT}, admin :${H3_ADMIN_PORT}, log ${H3_LOG})"
  echo "    stop with: kill \$(cat ${H3_PID})"
fi

if [[ "${FAIL}" -ne 0 ]]; then
  echo "H3 PROBE FAILED checks_failed=${FAIL}"
  exit 1
fi
echo "H3 PROBE PASSED (experiment only — not product H3 support)"
