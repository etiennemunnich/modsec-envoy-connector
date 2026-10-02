#!/usr/bin/env bash
# Shared settings + helpers for the demo scripts. Source, do not execute.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEMO="${ROOT}/demo"
RUN="${DEMO}/.run"
CRS_DIR="${CRS_DIR:-${DEMO}/.crs}"

# BODY_MODE selects Envoy request/response body modes:
#   BUFFERED (default) | STREAMED | BUFFERED_PARTIAL | FULL_DUPLEX_STREAMED
#   REQ_BUFFERED_RESP_STREAMED | REQ_STREAMED_RESP_BUFFERED  (asymmetric labs)
# `up.sh` writes demo/.run/body_mode so later scripts (smoke, fail-closed) match
# the running Envoy without re-exporting BODY_MODE.
# BUFFERED_PARTIAL is ProcessPartial-class: under-limit CRS can pass; over-limit
# trailing body attacks may miss. Not a full-CRS fidelity mode.
# FULL_DUPLEX_STREAMED requires connector --body-reply streamed (StreamedBodyResponse)
# and trailer modes SEND; Envoy disables message_timeout under this mode.
# Asymmetric modes keep request/response axes independent (matrix gap close).
if [[ -z "${BODY_MODE:-}" && -f "${RUN}/body_mode" ]]; then
  BODY_MODE="$(tr -d '[:space:]' <"${RUN}/body_mode")"
fi
BODY_MODE="${BODY_MODE:-BUFFERED}"
BODY_REPLY=common
REQUEST_BODY_MODE="${BODY_MODE}"
RESPONSE_BODY_MODE="${BODY_MODE}"
case "${BODY_MODE}" in
  BUFFERED) ENVOY_CFG="${DEMO}/envoy/envoy.yaml" ;;
  STREAMED) ENVOY_CFG="${DEMO}/envoy/envoy-streamed.yaml" ;;
  BUFFERED_PARTIAL) ENVOY_CFG="${DEMO}/envoy/envoy-buffered-partial.yaml" ;;
  FULL_DUPLEX_STREAMED)
    ENVOY_CFG="${DEMO}/envoy/envoy-full-duplex.yaml"
    BODY_REPLY=streamed
    ;;
  REQ_BUFFERED_RESP_STREAMED)
    ENVOY_CFG="${DEMO}/envoy/envoy-req-buffered-resp-streamed.yaml"
    REQUEST_BODY_MODE=BUFFERED
    RESPONSE_BODY_MODE=STREAMED
    ;;
  REQ_STREAMED_RESP_BUFFERED)
    ENVOY_CFG="${DEMO}/envoy/envoy-req-streamed-resp-buffered.yaml"
    REQUEST_BODY_MODE=STREAMED
    RESPONSE_BODY_MODE=BUFFERED
    ;;
  *)
    echo "BODY_MODE must be BUFFERED, STREAMED, BUFFERED_PARTIAL, FULL_DUPLEX_STREAMED, REQ_BUFFERED_RESP_STREAMED, or REQ_STREAMED_RESP_BUFFERED (got '${BODY_MODE}')" >&2
    return 2 2>/dev/null || exit 2
    ;;
esac
CONNECTOR_BIN="${ROOT}/target/debug/ext-proc-modsec"
RULES_FILE="${RUN}/modsec.conf"
HITS_FILE="${RUN}/origin-hits.log"

# DEMO_PORT_BASE remaps the demo ports (default 18080). Use e.g. 18380 to
# avoid colliding with another agent on the stock ports.
DEMO_PORT_BASE="${DEMO_PORT_BASE:-18080}"
ENVOY_PORT="${DEMO_PORT_BASE}"
CONNECTOR_PORT=$((DEMO_PORT_BASE + 1))
METRICS_PORT=$((DEMO_PORT_BASE + 2))
ENVOY_ADMIN_PORT=$((DEMO_PORT_BASE + 9))
ORIGIN_PORT=$((DEMO_PORT_BASE + 18))

BASE="http://127.0.0.1:${ENVOY_PORT}"
CONNECTOR_LISTEN="127.0.0.1:${CONNECTOR_PORT}"
METRICS="http://127.0.0.1:${METRICS_PORT}"

# When using a non-default port base, materialize a remapped Envoy YAML under .run/
if [[ "${DEMO_PORT_BASE}" != "18080" ]]; then
  mkdir -p "${RUN}"
  REMAPPED_ENVOY_CFG="${RUN}/envoy-port-remap.yaml"
  sed \
    -e "s/port_value: 18089/port_value: ${ENVOY_ADMIN_PORT}/g" \
    -e "s/port_value: 18080/port_value: ${ENVOY_PORT}/g" \
    -e "s/port_value: 18081/port_value: ${CONNECTOR_PORT}/g" \
    -e "s/port_value: 18098/port_value: ${ORIGIN_PORT}/g" \
    "${ENVOY_CFG}" >"${REMAPPED_ENVOY_CFG}"
  ENVOY_CFG="${REMAPPED_ENVOY_CFG}"
fi

port_pid() {
  lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null | head -1 || true
}

wait_http() {
  # wait_http <url> <tries> — 0 once the URL answers 200.
  local url="$1" tries="${2:-50}" i
  for ((i = 0; i < tries; i++)); do
    if curl -sf -o /dev/null --max-time 2 "$url"; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

http_code() {
  # http_code <curl args...> — prints the status code (000 on transport error).
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@" || true
}

origin_hits() {
  if [[ -f "${HITS_FILE}" ]]; then wc -l <"${HITS_FILE}" | tr -d ' '; else echo 0; fi
}

start_connector() {
  # start_connector [extra args...] — rules from ${RULES_FILE} unless overridden.
  # Always pass --body-reply so FULL_DUPLEX_STREAMED restores stay on StreamedBodyResponse.
  local rules="${CONNECTOR_RULES:-${RULES_FILE}}"
  daemonize "${RUN}/connector.log" "${RUN}/connector.pid" "${CONNECTOR_BIN}" \
    --listen "${CONNECTOR_LISTEN}" \
    --metrics-listen "127.0.0.1:${METRICS_PORT}" \
    --modsec-rules "${rules}" \
    --body-reply "${BODY_REPLY}" \
    "$@"
}

daemonize() {
  # daemonize <logfile> <pidfile> <command...> — survives the calling shell.
  local log="$1" pidf="$2"
  shift 2
  python3 "${DEMO}/scripts/daemonize.py" "$log" "$pidf" -- "$@"
}

ports_free_or_die() {
  local port pid
  for port in "${ENVOY_PORT}" "${CONNECTOR_PORT}" "${METRICS_PORT}" "${ORIGIN_PORT}" "${ENVOY_ADMIN_PORT}"; do
    pid="$(port_pid "$port")"
    if [[ -n "$pid" ]]; then
      echo "port ${port} is in use by: $(ps -p "$pid" -o command= | cut -c1-120)" >&2
      return 1
    fi
  done
}

stop_pidfile() {
  local f="$1" sig="${2:-TERM}" p
  [[ -f "$f" ]] || return 0
  p="$(cat "$f" 2>/dev/null || true)"
  if [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; then
    kill -CONT "$p" 2>/dev/null || true
    kill "-${sig}" "$p" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$p" 2>/dev/null || break
      sleep 0.2
    done
    kill -KILL "$p" 2>/dev/null || true
  fi
  rm -f "$f"
}
