#!/usr/bin/env bash
# Lab HTTP/3 (QUIC) demo suite — durable local test, not product H3 support.
#
# Usage:
#   BODY_MODE=NONE ./demo/scripts/up.sh   # optional if not already up
#   ./demo/scripts/h3-probe.sh
#   H3_PROBE_KEEP=1 ./demo/scripts/h3-probe.sh   # leave H3 Envoy running
#
# If the connector/origin are down, this script starts them with BODY_MODE=NONE
# (headers-only honesty matches the H3 config). It always manages a second Envoy
# process on UDP (default :18443) with --base-id so it does not clash with the
# TCP demo Envoy.
#
# Dependencies (exit 2 if missing, with a clear message):
#   - envoy at ENVOY_PIN (Linux release binary includes QUIC)
#   - python3 + aioquic (`pip install aioquic`); stock curl often has no --http3
#   - openssl (throwaway self-signed cert under demo/.run/h3-certs/)
#
# Asserts (PASS floor ≥ MIN_H3_CHECKS, default 9; summary carries checks=N):
#   - benign GET → 200, origin +1; Envoy access log shows HTTP/3
#   - connector logs http_version=3.0
#   - SQLi in query → 403, origin +0
#   - SQLi in body (NONE) → 200, origin +1 (body not inspected)
#   - connector killed → 500, origin +0; restore → ready
#   - connector hung (SIGSTOP) → 504, origin +0
#   - failure_mode_allowed = 0
#
# Does NOT prove: product H3 WAF, BUFFERED/STREAMED CRS on QUIC, go-ftw on H3,
# or CI coverage (demo-only; not on every PR).
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
# Floor: 3 hop cells + access-log + connector version + killed + restore + hung + fma.
MIN_H3_CHECKS="${MIN_H3_CHECKS:-9}"
FAIL=0
PASS=0
STARTED_STACK=0

pass() { echo "  PASS $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL $*"; FAIL=$((FAIL + 1)); }

die_deps() {
  echo "$*" >&2
  exit 2
}

require_deps() {
  command -v envoy >/dev/null || die_deps "envoy not on PATH — run demo/scripts/install-envoy.sh"
  command -v openssl >/dev/null || die_deps "openssl required for H3 lab certs"
  command -v python3 >/dev/null || die_deps "python3 required"
  [[ -f "${H3GET}" ]] || die_deps "missing ${H3GET}"
  [[ -f "${TEMPLATE}" ]] || die_deps "missing ${TEMPLATE}"
  python3 -c 'import aioquic' 2>/dev/null \
    || die_deps "aioquic missing — pip install aioquic (stock curl often has no --http3)"

  local pin want ver
  pin="$(grep -E '^ENVOY_PIN=' "${ROOT}/versions.lock.md" | head -1 | cut -d= -f2)"
  pin="${pin:-v1.39.4}"
  want="${pin#v}"
  ver="$(envoy --version 2>&1 || true)"
  echo "${ver}" | grep -q "/${want}/" \
    || die_deps "envoy version does not match ENVOY_PIN=${pin} (got: ${ver})"
  echo "==> H3 lab suite Envoy ${want} (not product H3 support)"
}

ensure_stack() {
  if curl -sf "${METRICS}/healthz" >/dev/null \
    && curl -sf "http://127.0.0.1:${ORIGIN_PORT}/" >/dev/null; then
    echo "==> attaching to running connector ${CONNECTOR_LISTEN} + origin :${ORIGIN_PORT}"
    return 0
  fi
  echo "==> connector/origin down — starting BODY_MODE=NONE demo stack"
  BODY_MODE=NONE "${DEMO}/scripts/up.sh"
  STARTED_STACK=1
  curl -sf "${METRICS}/healthz" >/dev/null \
    || die_deps "connector still not ready at ${METRICS}/healthz after up.sh"
}

stop_h3_envoy() {
  if [[ -f "${H3_PID}" ]]; then
    local pid
    pid="$(tr -d '[:space:]' <"${H3_PID}" || true)"
    if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
      local _
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
    echo "==> generating self-signed cert in ${H3_CERT_DIR}"
    openssl req -x509 -newkey rsa:2048 \
      -keyout "${H3_CERT_DIR}/serverkey.pem" \
      -out "${H3_CERT_DIR}/servercert.pem" \
      -days 1 -nodes \
      -subj '/CN=localhost' \
      -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' >/dev/null 2>&1
  fi
}

render_cfg() {
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
    || die_deps "rendered H3 config must keep failure_mode_allow: false"
  grep -q 'request_body_mode: NONE' "${H3_CFG_RENDERED}" \
    || die_deps "rendered H3 config must keep request_body_mode: NONE"
  grep -q 'codec_type: HTTP3' "${H3_CFG_RENDERED}" \
    || die_deps "rendered H3 config must set codec_type: HTTP3"
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
  echo "$1" | awk '/^STATUS /{print $2; exit}'
}

# Run the H3 client without aborting the suite on transport errors.
h3_capture() {
  local out rc
  set +e
  out="$(h3 "$@" 2>&1)"
  rc=$?
  set -e
  H3_LAST_OUT="${out}"
  H3_LAST_RC="${rc}"
}

expect_h3() {
  local name="$1" want_status="$2" want_delta="$3"
  shift 3
  local before after code delta
  before="$(origin_hits)"
  h3_capture "$@"
  sleep 0.1
  after="$(origin_hits)"
  delta=$((after - before))
  code="$(status_of "${H3_LAST_OUT}")"
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

require_deps
ensure_stack
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
code="$(status_of "${H3_LAST_OUT}")"
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
code="$(status_of "${H3_LAST_OUT}")"
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

# Default: stop H3 Envoy. Keep with H3_PROBE_KEEP=1 (or legacy H3_PROBE_DOWN=0).
if [[ "${H3_PROBE_KEEP:-0}" == "1" || "${H3_PROBE_DOWN:-1}" == "0" ]]; then
  echo "==> H3 Envoy still up (UDP :${H3_PORT}, admin :${H3_ADMIN_PORT}, log ${H3_LOG})"
  echo "    stop with: kill \$(cat ${H3_PID})  or  ./demo/scripts/down.sh"
else
  stop_h3_envoy
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
