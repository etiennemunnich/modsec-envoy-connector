#!/usr/bin/env bash
# Live trailer safety cells through Envoy → connector → origin.
#
# Every stock config with a body mode sends trailers (trailer mode SEND), so
# the connector can end a body that trailers follow. For BUFFERED / STREAMED
# this suite restarts Envoy with its own trailer SEND config; FULL_DUPLEX
# reuses the stock one. HTTP/2 trailer cells live in h2-trailers.sh.
#
# Honest bounds:
#   - Trailer *values* are NOT CRS-inspected (attack only in a trailer → 200).
#   - Trailers alone / no session → 500 is gRPC-only (Envoy always sends
#     request headers before trailers on a real HTTP exchange).
#   - When trailers mark body end (last body chunk eos=false), unfinished body
#     is still finalized → body SQLi still 403, origin untouched.
#
# Floors (empty suite cannot go green):
#   MIN_TRAILER_CHECKS (default 5) proven cells must PASS; SKIP cells and the
#   floor check itself are not counted.
#
# Usage:
#   ./demo/scripts/up.sh && ./demo/scripts/trailers.sh
#   BODY_MODE=STREAMED ./demo/scripts/up.sh && ./demo/scripts/trailers.sh
#   BODY_MODE=FULL_DUPLEX_STREAMED ./demo/scripts/up.sh && ./demo/scripts/trailers.sh
#   (FULL_DUPLEX stock YAML already has trailer SEND; suite restarts with the same config.)
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

FAIL=0
PASS=0
SKIP=0
MIN_TRAILER_CHECKS="${MIN_TRAILER_CHECKS:-5}"
OUT_DIR="${RUN}/trailers"
mkdir -p "${OUT_DIR}"
TRANSCRIPT="${OUT_DIR}/$(date -u +%Y%m%dT%H%M%SZ).txt"
exec > >(tee "${TRANSCRIPT}") 2>&1

pass() { echo "  PASS $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL $*"; FAIL=1; }
skip() { echo "  SKIP $*"; SKIP=$((SKIP + 1)); }
# Prints nothing when /metrics does not answer; the caller treats that as a FAIL.
fail_closed_total() {
  local m
  m="$(curl -s --max-time 5 "${METRICS}/metrics")" || return 0
  awk '/^ext_proc_fail_closed_total /{print $2; exit}' <<<"${m}"
}

wait_http "${BASE}/" 50 || { echo "demo not up at ${BASE} — run ./demo/scripts/up.sh" >&2; exit 2; }

case "${BODY_MODE}" in
  BUFFERED) TRAILER_CFG="${DEMO}/envoy/envoy-trailers.yaml" ;;
  STREAMED) TRAILER_CFG="${DEMO}/envoy/envoy-streamed-trailers.yaml" ;;
  # FULL_DUPLEX_STREAMED already requires trailer SEND on the stock demo YAML —
  # reuse ENVOY_CFG (already port-remapped when DEMO_PORT_BASE ≠ 18080).
  FULL_DUPLEX_STREAMED) TRAILER_CFG="${ENVOY_CFG}" ;;
  *) echo "BODY_MODE must be BUFFERED, STREAMED, or FULL_DUPLEX_STREAMED" >&2; exit 2 ;;
esac
# Remap BUFFERED/STREAMED trailer YAMLs when the demo is not on stock ports.
if [[ "${BODY_MODE}" != "FULL_DUPLEX_STREAMED" && "${DEMO_PORT_BASE}" != "18080" ]]; then
  remapped_trailers="${RUN}/envoy-trailers-port-remap.yaml"
  remap_stock_ports "${TRAILER_CFG}" "${remapped_trailers}" \
    "${ENVOY_ADMIN_PORT}" "${ENVOY_PORT}" "${CONNECTOR_PORT}" "${ORIGIN_PORT}"
  TRAILER_CFG="${remapped_trailers}"
fi
grep -q "request_body_mode: ${BODY_MODE}" "${TRAILER_CFG}" \
  || { echo "${TRAILER_CFG} must set request_body_mode: ${BODY_MODE}" >&2; exit 2; }
grep -q "request_trailer_mode: SEND" "${TRAILER_CFG}" \
  || { echo "${TRAILER_CFG} must set request_trailer_mode: SEND" >&2; exit 2; }

restore_envoy() {
  stop_pidfile "${RUN}/envoy.pid" TERM
  daemonize "${RUN}/envoy.log" "${RUN}/envoy.pid" \
    envoy -c "${ENVOY_CFG}" --concurrency 2 --log-level warn --file-flush-interval-msec 200
  wait_http "http://127.0.0.1:${ENVOY_ADMIN_PORT}/ready" 100 \
    || { echo "failed to restore default Envoy ${ENVOY_CFG}" >&2; return 1; }
}

echo "==> trailers safety body_mode=${BODY_MODE}"
echo "==> restart Envoy with trailer SEND (${TRAILER_CFG})"
stop_pidfile "${RUN}/envoy.pid" TERM
daemonize "${RUN}/envoy.log" "${RUN}/envoy.pid" \
  envoy -c "${TRAILER_CFG}" --concurrency 2 --log-level warn --file-flush-interval-msec 200
if ! wait_http "http://127.0.0.1:${ENVOY_ADMIN_PORT}/ready" 100; then
  echo "trailer Envoy failed to become ready:" >&2
  tail -n 40 "${RUN}/envoy.log" >&2
  restore_envoy || true
  exit 1
fi
trap 'restore_envoy || true' EXIT
fc_before="$(fail_closed_total)"

# h1_chunked_post_trailers <path> <body> <trailer-name> <trailer-value> → status
# HTTP/1.1 chunked + trailers. Host: localhost avoids CRS 920350 (numeric IP)
# stacking with 920180 (Envoy strips Transfer-Encoding before ext_proc, so TE
# looks absent to ModSec). Product smoke uses Content-Length; trailers require
# chunked on H1. Trailer *values* are still not CRS-inspected.
h1_chunked_post_trailers() {
  local path="$1" body="$2" tname="$3" tval="$4"
  python3 - "$path" "$body" "$tname" "$tval" "${ENVOY_PORT}" <<'PY'
import socket, sys
path, body, tname, tval = sys.argv[1:5]
port = int(sys.argv[5])
body_b = body.encode()
req = (
    f"POST {path} HTTP/1.1\r\nHost: localhost\r\n"
    f"Content-Type: application/x-www-form-urlencoded\r\n"
    f"Transfer-Encoding: chunked\r\n"
    f"Trailer: {tname}\r\nConnection: close\r\n\r\n"
).encode()
req += b"%x\r\n" % len(body_b) + body_b + b"\r\n"
req += b"0\r\n"
req += f"{tname}: {tval}\r\n\r\n".encode()
s = socket.create_connection(("127.0.0.1", port), timeout=10)
s.sendall(req)
data = b""
while True:
    part = s.recv(4096)
    if not part:
        break
    data += part
s.close()
print(data.split(b" ", 2)[1].decode() if data.startswith(b"HTTP/") else "000")
PY
}

echo "==> 1. allowed body + trailers → 200, origin hit (trailer attack uninspected)"
before="$(origin_hits)"
code="$(h1_chunked_post_trailers /post 'name=alice&note=hello' x-attack "1' UNION SELECT password FROM users--")"
sleep 0.15
after="$(origin_hits)"
delta=$((after - before))
if [[ "${code}" == "200" && "${delta}" == "1" ]]; then
  pass "[allow+trailers] HTTP 200, origin +1 (trailer SQLi not CRS-inspected)"
else
  fail "[allow+trailers] HTTP ${code} (want 200), origin +${delta} (want +1)"
fi

echo "==> 2. body SQLi + trailers mark EOS → 403, origin untouched"
before="$(origin_hits)"
code="$(h1_chunked_post_trailers /login "user=admin'%20UNION%20SELECT%201,2,3--" x-harmless 'trailers-not-inspected')"
sleep 0.15
after="$(origin_hits)"
delta=$((after - before))
if [[ "${code}" == "403" && "${delta}" == "0" ]]; then
  pass "[body-deny+trailers] HTTP 403, origin +0 (body still denied at trailer EOS)"
else
  fail "[body-deny+trailers] HTTP ${code} (want 403), origin +${delta} (want +0)"
fi

echo "==> 3. benign body + trailers → 200, no spurious 500"
before="$(origin_hits)"
code="$(h1_chunked_post_trailers /post 'name=bob&qty=2' x-meta 'trailer-ok')"
sleep 0.15
after="$(origin_hits)"
delta=$((after - before))
if [[ "${code}" == "200" && "${delta}" == "1" ]]; then
  pass "[benign+trailers] HTTP 200, origin +1 (no spurious fail-closed)"
else
  fail "[benign+trailers] HTTP ${code} (want 200), origin +${delta} (want +1)"
fi

# Prove Envoy delivered request_trailers (connector logs trailers_continue).
# Use grep (not ripgrep): GitHub-hosted runners do not ship `rg`.
# Under FULL_DUPLEX_STREAMED Envoy may fold client trailers into body
# end_of_stream instead of emitting a separate RequestTrailers message — the
# functional cells above still prove trailer-marked EOS (body deny → 403).
echo "==> live trailers delivered to connector"
if grep -q 'action="trailers_continue"' "${RUN}/connector.log"; then
  pass "[envoy→connector] request_trailers delivered (trailers_continue logged)"
elif [[ "${BODY_MODE}" == "FULL_DUPLEX_STREAMED" ]]; then
  skip "[envoy→connector] FULL_DUPLEX: no separate RequestTrailers (Envoy folds trailers into body EOS; the body-deny cell above covers EOS)"
else
  fail "[envoy→connector] no trailers_continue in connector.log — Envoy may not have sent trailers"
fi

echo "==> 4. gRPC: trailers alone / no session → 500 (Envoy cannot send this live)"
grpc_log="${OUT_DIR}/grpc-trailers-alone.log"
if (cd "${ROOT}" && cargo test -q -p ext-proc-modsec --test grpc -- trailers_without_session_fail_closed --exact --nocapture) \
  >"${grpc_log}" 2>&1; then
  pass "[trailers-alone gRPC] trailers_without_session_fail_closed → 500"
else
  fail "[trailers-alone gRPC] see ${grpc_log}"
  tail -n 30 "${grpc_log}" || true
fi

echo "==> connector metrics after trailer cells"
curl -s --max-time 5 "${METRICS}/metrics" | grep -E '^ext_proc_(deny|fail_closed|allow)_total ' | sed 's/^/  /'
# The gRPC cell runs its own in-process server, so the live connector's
# fail_closed counter must not move during the live cells.
fc_after="$(fail_closed_total)"
if [[ -n "${fc_before}" && "${fc_after}" == "${fc_before}" ]]; then
  pass "[live connector] ext_proc_fail_closed_total unchanged (${fc_after})"
else
  fail "[live connector] ext_proc_fail_closed_total '${fc_before}' → '${fc_after}'"
fi

if [[ "${PASS}" -ge "${MIN_TRAILER_CHECKS}" ]]; then
  echo "  floor: trailer checks PASS=${PASS} (≥ ${MIN_TRAILER_CHECKS}), SKIP=${SKIP}"
else
  fail "[floor] trailer checks PASS=${PASS} < ${MIN_TRAILER_CHECKS}"
fi

echo "==> restore default Envoy (${ENVOY_CFG})"
# trap also restores; call explicitly so the summary runs after restore is attempted
trap - EXIT
restore_envoy

if [[ "${FAIL}" -ne 0 ]]; then
  echo "TRAILERS FAILED body_mode=${BODY_MODE} PASS=${PASS}"
  exit 1
fi
echo "TRAILERS PASSED body_mode=${BODY_MODE} trailer_checks=${PASS} skipped=${SKIP}"
