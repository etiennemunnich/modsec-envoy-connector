#!/usr/bin/env bash
# Shared HTTP/3 (QUIC) lab helpers for h3-probe.sh and cookie-protocols.sh.
# Source after demo/scripts/lib.sh. Not product support.
#
# shellcheck disable=SC2034

H3_PORT="${H3_PORT:-18443}"
H3_ADMIN_PORT="${H3_ADMIN_PORT:-18449}"
H3_BASE_ID="${H3_BASE_ID:-17}"
H3_CERT_DIR="${RUN}/h3-certs"
H3_CFG_RENDERED="${RUN}/envoy-h3.yaml"
H3_LOG="${RUN}/envoy-h3.log"
H3_PID="${RUN}/envoy-h3.pid"
H3_TEMPLATE="${DEMO}/envoy/envoy-h3.yaml"
H3GET="${DEMO}/scripts/h3get.py"

h3_die() {
  echo "$*" >&2
  exit 2
}

h3_require_deps() {
  command -v envoy >/dev/null || h3_die "envoy not on PATH — run demo/scripts/install-envoy.sh"
  command -v openssl >/dev/null || h3_die "openssl required for H3 lab certs"
  command -v python3 >/dev/null || h3_die "python3 required"
  [[ -f "${H3GET}" ]] || h3_die "missing ${H3GET}"
  [[ -f "${H3_TEMPLATE}" ]] || h3_die "missing ${H3_TEMPLATE}"
  python3 -c 'import aioquic' 2>/dev/null \
    || h3_die "aioquic missing — pip install aioquic (stock curl often has no --http3)"

  local pin want ver
  pin="$(grep -E '^ENVOY_PIN=' "${ROOT}/versions.lock.md" | head -1 | cut -d= -f2)"
  pin="${pin:-v1.39.4}"
  want="${pin#v}"
  ver="$(envoy --version 2>&1 || true)"
  echo "${ver}" | grep -q "/${want}/" \
    || h3_die "envoy version does not match ENVOY_PIN=${pin} (got: ${ver})"
}

h3_ensure_tcp_stack() {
  # Cookie / hop labs need connector + origin; prefer NONE (headers-only honesty).
  if curl -sf "${METRICS}/healthz" >/dev/null \
    && curl -sf "http://127.0.0.1:${ORIGIN_PORT}/" >/dev/null; then
    echo "==> attaching to running connector ${CONNECTOR_LISTEN} + origin :${ORIGIN_PORT}"
    return 0
  fi
  echo "==> connector/origin down — starting BODY_MODE=NONE demo stack"
  BODY_MODE=NONE "${DEMO}/scripts/up.sh"
  curl -sf "${METRICS}/healthz" >/dev/null \
    || h3_die "connector still not ready at ${METRICS}/healthz after up.sh"
}

h3_stop_envoy() {
  if [[ -f "${H3_PID}" ]]; then
    local pid _
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

h3_ensure_certs() {
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

h3_render_cfg() {
  local cert key
  cert="${H3_CERT_DIR}/servercert.pem"
  key="${H3_CERT_DIR}/serverkey.pem"
  sed -e "s|__H3_CERT__|${cert}|g" -e "s|__H3_KEY__|${key}|g" \
    -e "s|port_value: 18443|port_value: ${H3_PORT}|g" \
    -e "s|port_value: 18449|port_value: ${H3_ADMIN_PORT}|g" \
    -e "s|port_value: 18081|port_value: ${CONNECTOR_PORT}|g" \
    -e "s|port_value: 18098|port_value: ${ORIGIN_PORT}|g" \
    "${H3_TEMPLATE}" >"${H3_CFG_RENDERED}"
  grep -q 'failure_mode_allow: false' "${H3_CFG_RENDERED}" \
    || h3_die "rendered H3 config must keep failure_mode_allow: false"
  grep -q 'request_body_mode: NONE' "${H3_CFG_RENDERED}" \
    || h3_die "rendered H3 config must keep request_body_mode: NONE"
  grep -q 'codec_type: HTTP3' "${H3_CFG_RENDERED}" \
    || h3_die "rendered H3 config must set codec_type: HTTP3"
}

h3_start_envoy() {
  h3_stop_envoy
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

h3_bring_up() {
  h3_require_deps
  h3_ensure_tcp_stack
  h3_ensure_certs
  h3_render_cfg
  envoy --mode validate -c "${H3_CFG_RENDERED}" >/dev/null
  h3_start_envoy
}

h3_get() {
  python3 "${H3GET}" --host 127.0.0.1 --port "${H3_PORT}" "$@"
}

h3_status_of() {
  echo "$1" | awk '/^STATUS /{print $2; exit}'
}

# Capture without aborting the suite on transport errors (set -e safe).
h3_capture() {
  local out rc
  set +e
  out="$(h3_get "$@" 2>&1)"
  rc=$?
  set -e
  H3_LAST_OUT="${out}"
  H3_LAST_RC="${rc}"
}
