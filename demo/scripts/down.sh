#!/usr/bin/env bash
# Stop Envoy, the connector and the demo origin.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

stop_pidfile "${RUN}/envoy.pid"
stop_pidfile "${RUN}/connector.pid"
stop_pidfile "${RUN}/origin.pid"
# Stragglers from a previous run that lost its pid files.
for port in "${ENVOY_PORT}" "${CONNECTOR_PORT}" "${METRICS_PORT}" "${ORIGIN_PORT}" "${ENVOY_ADMIN_PORT}"; do
  pid="$(port_pid "$port")"
  if [[ -n "$pid" ]] && ps -p "$pid" -o command= | grep -Eq 'envoy|ext-proc-modsec|origin\.py'; then
    kill "$pid" 2>/dev/null || true
  fi
done
echo "Demo down."
