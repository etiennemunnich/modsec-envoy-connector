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
H3GET="${DEMO}/scripts/h3get.py"

# Elect-one template: ext_proc (sidecar) vs dm (in-process module).
if [[ "${DEPLOY}" == "dm" ]]; then
  H3_TEMPLATE="${DEMO}/envoy/envoy-h3-dm.yaml"
else
  H3_TEMPLATE="${DEMO}/envoy/envoy-h3.yaml"
fi

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
  # Matrix cells may pin a non-tip Envoy via ENVOY_VERSION; tip uses ENVOY_PIN.
  pin="${ENVOY_VERSION:-$(grep -E '^ENVOY_PIN=' "${ROOT}/versions.lock.md" | head -1 | cut -d= -f2)}"
  pin="${pin:-v1.40.2}"
  want="${pin#v}"
  ver="$(envoy --version 2>&1 || true)"
  echo "${ver}" | grep -q "/${want}/" \
    || h3_die "envoy version does not match ${pin} (got: ${ver})"

  if [[ "${DEPLOY}" == "dm" ]]; then
    [[ -f "${DM_SO}" ]] || h3_die "missing ${DM_SO} — run DEPLOY=dm ./demo/scripts/up.sh first"
    [[ -f "${RULES_FILE}" ]] || h3_die "missing ${RULES_FILE} — run DEPLOY=dm ./demo/scripts/up.sh first"
  fi
}

h3_ensure_tcp_stack() {
  # Cookie / hop labs need origin (+ connector for ext_proc). Prefer NONE (headers-only).
  if [[ "${DEPLOY}" == "dm" ]]; then
    if curl -sf "http://127.0.0.1:${ENVOY_ADMIN_PORT}/ready" >/dev/null \
      && curl -sf "http://127.0.0.1:${ORIGIN_PORT}/" >/dev/null \
      && [[ -f "${DM_SO}" && -f "${RULES_FILE}" ]]; then
      echo "==> attaching to running DEPLOY=dm stack (origin :${ORIGIN_PORT}, module ${DM_SO})"
      return 0
    fi
    echo "==> DM/origin down — starting DEPLOY=dm BODY_MODE=NONE demo stack"
    DEPLOY=dm BODY_MODE=NONE "${DEMO}/scripts/up.sh"
    curl -sf "http://127.0.0.1:${ENVOY_ADMIN_PORT}/ready" >/dev/null \
      || h3_die "DM Envoy still not ready at admin :${ENVOY_ADMIN_PORT} after up.sh"
    [[ -f "${DM_SO}" ]] || h3_die "missing ${DM_SO} after DEPLOY=dm up.sh"
    return 0
  fi
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
  if [[ "${DEPLOY}" == "dm" ]]; then
    sed -e "s|__H3_CERT__|${cert}|g" -e "s|__H3_KEY__|${key}|g" \
      -e "s|__DM_RULES__|${RULES_FILE}|g" \
      -e "s|__DM_SO_DIR__|${DM_MODULES_DIR}|g" \
      -e "s|port_value: 18443|port_value: ${H3_PORT}|g" \
      -e "s|port_value: 18449|port_value: ${H3_ADMIN_PORT}|g" \
      -e "s|port_value: 18098|port_value: ${ORIGIN_PORT}|g" \
      "${H3_TEMPLATE}" >"${H3_CFG_RENDERED}"
    grep -q 'body_policy":"headers_only"' "${H3_CFG_RENDERED}" \
      || h3_die "rendered DM H3 config must keep body_policy headers_only"
    grep -q 'name: modsec_dm' "${H3_CFG_RENDERED}" \
      || h3_die "rendered DM H3 config must load dynamic module modsec_dm"
  else
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
  fi
  grep -q 'codec_type: HTTP3' "${H3_CFG_RENDERED}" \
    || h3_die "rendered H3 config must set codec_type: HTTP3"
}

h3_start_envoy() {
  h3_stop_envoy
  : >"${H3_LOG}"
  echo "==> envoy HTTP/3 UDP :${H3_PORT} (admin :${H3_ADMIN_PORT}, base-id ${H3_BASE_ID}, deploy=${DEPLOY})"
  if [[ "${DEPLOY}" == "dm" ]]; then
    daemonize "${H3_LOG}" "${H3_PID}" \
      env ENVOY_DYNAMIC_MODULES_SEARCH_PATH="${DM_MODULES_DIR}" \
      envoy -c "${H3_CFG_RENDERED}" \
      --concurrency 1 --log-level info --base-id "${H3_BASE_ID}" \
      --file-flush-interval-msec 200
  else
    daemonize "${H3_LOG}" "${H3_PID}" envoy -c "${H3_CFG_RENDERED}" \
      --concurrency 1 --log-level info --base-id "${H3_BASE_ID}" \
      --file-flush-interval-msec 200
  fi
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
  if [[ "${DEPLOY}" == "dm" ]]; then
    env ENVOY_DYNAMIC_MODULES_SEARCH_PATH="${DM_MODULES_DIR}" \
      envoy --mode validate -c "${H3_CFG_RENDERED}" >/dev/null
  else
    envoy --mode validate -c "${H3_CFG_RENDERED}" >/dev/null
  fi
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
