#!/usr/bin/env bash
# Shared settings + helpers for the demo scripts. Source, do not execute.
# Variables set here are read by the scripts that source this file.
# shellcheck disable=SC2034

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEMO="${ROOT}/demo"
RUN="${DEMO}/.run"
CRS_DIR="${CRS_DIR:-${DEMO}/.crs}"
DM_MODULES_DIR="${DM_MODULES_DIR:-${RUN}/modules}"
DM_SO="${DM_SO:-${DM_MODULES_DIR}/libmodsec_dm.so}"

# libmodsecurity built by install-libmodsecurity.sh on Linux lives under
# ~/.local (or MODSECURITY_PREFIX); put it on the pkg-config and loader paths
# so cargo and the connector / DM .so find it without manual exports.
_modsec_prefix="${MODSECURITY_PREFIX:-${HOME}/.local}"
if [[ -f "${_modsec_prefix}/lib/pkgconfig/modsecurity.pc" ]]; then
  case ":${PKG_CONFIG_PATH:-}:" in *":${_modsec_prefix}/lib/pkgconfig:"*) ;; *)
    export PKG_CONFIG_PATH="${_modsec_prefix}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}" ;;
  esac
  case ":${LD_LIBRARY_PATH:-}:" in *":${_modsec_prefix}/lib:"*) ;; *)
    export LD_LIBRARY_PATH="${_modsec_prefix}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" ;;
  esac
fi
unset _modsec_prefix

# DEPLOY selects the Envoy hop (alpha dual option; elect one):
#   ext_proc (default) — out-of-process connector
#   dm                 — in-process dynamic module (libmodsec_dm.so)
# Persist in demo/.run/deploy when up.sh starts so suites match without re-export.
if [[ -z "${DEPLOY:-}" && -f "${RUN}/deploy" ]]; then
  DEPLOY="$(tr -d '[:space:]' <"${RUN}/deploy")"
fi
DEPLOY="${DEPLOY:-ext_proc}"
case "${DEPLOY}" in
  ext_proc|dm) ;;
  *)
    echo "DEPLOY must be ext_proc or dm (got '${DEPLOY}')" >&2
    return 2 2>/dev/null || exit 2
    ;;
esac

# BODY_MODE selects inspection intent:
#   BUFFERED (default) | STREAMED | BUFFERED_PARTIAL | NONE | FULL_DUPLEX_STREAMED
#   REQ_BUFFERED_RESP_STREAMED | REQ_STREAMED_RESP_BUFFERED  (asymmetric labs; ext_proc only)
# Under DEPLOY=ext_proc these are Envoy BodySendMode values.
# Under DEPLOY=dm they map to native body_policy (not BodySendMode):
#   BUFFERED→buffer_until_eos, STREAMED→stream_chunks, NONE→headers_only,
#   BUFFERED_PARTIAL→prefix_then_continue; FULL_DUPLEX_STREAMED is UNSUPPORTED (config reject).
# `up.sh` writes demo/.run/body_mode so later scripts match the running Envoy.
if [[ -z "${BODY_MODE:-}" && -f "${RUN}/body_mode" ]]; then
  BODY_MODE="$(tr -d '[:space:]' <"${RUN}/body_mode")"
fi
BODY_MODE="${BODY_MODE:-BUFFERED}"
BODY_REPLY=common
REQUEST_BODY_MODE="${BODY_MODE}"
RESPONSE_BODY_MODE="${BODY_MODE}"
DM_BODY_POLICY=""
DM_PARTIAL_SOFT_LIMIT="${DM_PARTIAL_SOFT_LIMIT:-1048576}"
case "${BODY_MODE}" in
  BUFFERED)
    ENVOY_CFG="${DEMO}/envoy/envoy.yaml"
    DM_BODY_POLICY=buffer_until_eos
    ;;
  STREAMED)
    ENVOY_CFG="${DEMO}/envoy/envoy-streamed.yaml"
    DM_BODY_POLICY=stream_chunks
    ;;
  BUFFERED_PARTIAL)
    ENVOY_CFG="${DEMO}/envoy/envoy-buffered-partial.yaml"
    DM_BODY_POLICY=prefix_then_continue
    ;;
  NONE)
    ENVOY_CFG="${DEMO}/envoy/envoy-none.yaml"
    DM_BODY_POLICY=headers_only
    ;;
  FULL_DUPLEX_STREAMED)
    ENVOY_CFG="${DEMO}/envoy/envoy-full-duplex.yaml"
    BODY_REPLY=streamed
    DM_BODY_POLICY=full_duplex_hold
    ;;
  REQ_BUFFERED_RESP_STREAMED)
    ENVOY_CFG="${DEMO}/envoy/envoy-req-buffered-resp-streamed.yaml"
    REQUEST_BODY_MODE=BUFFERED
    RESPONSE_BODY_MODE=STREAMED
    DM_BODY_POLICY=""
    ;;
  REQ_STREAMED_RESP_BUFFERED)
    ENVOY_CFG="${DEMO}/envoy/envoy-req-streamed-resp-buffered.yaml"
    REQUEST_BODY_MODE=STREAMED
    RESPONSE_BODY_MODE=BUFFERED
    DM_BODY_POLICY=""
    ;;
  *)
    echo "BODY_MODE must be BUFFERED, STREAMED, BUFFERED_PARTIAL, NONE, FULL_DUPLEX_STREAMED, REQ_BUFFERED_RESP_STREAMED, or REQ_STREAMED_RESP_BUFFERED (got '${BODY_MODE}')" >&2
    return 2 2>/dev/null || exit 2
    ;;
esac
if [[ "${DEPLOY}" == "dm" ]]; then
  if [[ -z "${DM_BODY_POLICY}" ]]; then
    echo "DEPLOY=dm does not support asymmetric BODY_MODE=${BODY_MODE}" >&2
    return 2 2>/dev/null || exit 2
  fi
  # Materialized by up.sh into .run/envoy-dm.yaml (rules_path + ports).
  ENVOY_CFG="${RUN}/envoy-dm.yaml"
fi
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

# shellcheck source=../../scripts/remap-demo-ports.sh
source "${ROOT}/scripts/remap-demo-ports.sh"

# When using a non-default port base, materialize a remapped Envoy YAML under .run/
if [[ "${DEMO_PORT_BASE}" != "18080" ]]; then
  mkdir -p "${RUN}"
  REMAPPED_ENVOY_CFG="${RUN}/envoy-port-remap.yaml"
  remap_stock_ports "${ENVOY_CFG}" "${REMAPPED_ENVOY_CFG}" \
    "${ENVOY_ADMIN_PORT}" "${ENVOY_PORT}" "${CONNECTOR_PORT}" "${ORIGIN_PORT}"
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
