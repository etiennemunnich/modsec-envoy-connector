#!/usr/bin/env bash
# Fail-mode suite against the running demo, over HTTP/1.1 and/or HTTP/2
# (cleartext, prior knowledge). Every enforcement check asserts the client
# status AND the origin hit delta.
#
#   proto   the client protocol is really in use (curl + Envoy access log by request id)
#   1       connector killed            → 500, origin untouched, failure_mode_allowed unchanged
#   2       connector boot with bad rules → exits non-zero, nothing listening, Envoy 500
#   3       per-request engine/stream error → ImmediateResponse 500 (gRPC harness, see below)
#   4       rule deny (query + body)    → 403, origin untouched
#   5       connector hung (SIGSTOP)    → 504 after message_timeout, origin untouched
#           (SKIP under FULL_DUPLEX_STREAMED: Envoy applies no message_timeout there)
#   6       audit log unwritable        → decisions unchanged or connector refuses to boot
#   fo      negative control: failure_mode_allow: true (temporary Envoy config) lets
#           traffic through on kill and hang — proves the drills above can see fail-open
#   cookie  split Cookie headers / crumbs: benign multi-Cookie 200; XSS in 2nd
#           crumb, 1st crumb, and single joined Cookie → 403 (H1+H2). H3: see
#           cookie-protocols.sh / h3-probe.sh (lab QUIC).
#   body    attack only in the last H1 chunk / last H2 DATA frames → 403 (BUFFERED)
#
# Class 3 cannot be injected through a well-behaved Envoy, so it runs the
# connector's gRPC integration tests (real EngineError + test-only fail-inject,
# product binary keeps fail-inject off) that drive fail_closed → ImmediateResponse 500.
# Floor: MIN_CLASS3_GRPC (default 8).
#
#   ./demo/scripts/fail-modes.sh                    # h1 and h2, all classes
#   ./demo/scripts/fail-modes.sh --proto h2 --class proto,1,4,5
#
# Requires ./demo/scripts/up.sh (with CRS). Transcript: demo/.run/fail-modes/.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

PROTOS="h1 h2"
CLASSES="proto,1,2,3,4,5,6,fo,cookie,body"
ADMIN="http://127.0.0.1:${ENVOY_ADMIN_PORT}"
FMA_STAT="http.ingress_http.ext_proc.modsec_ext_proc.failure_mode_allowed"

usage() {
  sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
  echo "usage: $0 [--proto h1|h2|both] [--class LIST]" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --proto)
      case "$2" in
        h1 | h2) PROTOS="$2" ;;
        both) PROTOS="h1 h2" ;;
        *) echo "unsupported --proto $2 (h1|h2|both; the demo has no HTTP/3 listener)" >&2; exit 2 ;;
      esac
      shift 2
      ;;
    --class) CLASSES="$2"; shift 2 ;;
    -h | --help) usage ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

wait_http "${BASE}/" 50 || { echo "demo not up at ${BASE} — run ./demo/scripts/up.sh" >&2; exit 2; }
grep -q 'failure_mode_allow: false' "${ENVOY_CFG}" || { echo "${ENVOY_CFG} must set failure_mode_allow: false" >&2; exit 2; }

OUT_DIR="${RUN}/fail-modes"
mkdir -p "${OUT_DIR}"
TRANSCRIPT="${OUT_DIR}/$(date -u +%Y%m%dT%H%M%SZ).txt"
exec > >(tee "${TRANSCRIPT}") 2>&1

PASS=0
FAIL=0
SKIP=0
RESULTS=()
record() { # record PASS|FAIL|SKIP <id> <detail> — SKIP is a check that did not run; it never counts as PASS
  local status="$1" id="$2" detail="$3"
  RESULTS+=("${status} ${id} — ${detail}")
  case "${status}" in
    PASS) PASS=$((PASS + 1)) ;;
    SKIP) SKIP=$((SKIP + 1)) ;;
    *) FAIL=$((FAIL + 1)) ;;
  esac
  echo "  [${status}] ${id}: ${detail}"
}
enabled() { [[ ",${CLASSES}," == *",$1,"* ]]; }

proto_flag() { [[ "${PROTO}" == h2 ]] && echo "--http2-prior-knowledge" || echo "--http1.1"; }

# code <curl args...> — status code over ${PROTO} (000 on transport error).
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$(proto_flag)" "$@" || true; }

# expect <id> <want-code-regex> <want-origin-delta> <curl args...>
expect() {
  local id="$1" want="$2" want_delta="$3"
  shift 3
  local before after got
  before="$(origin_hits)"
  got="$(code "$@")"
  sleep 0.1
  after="$(origin_hits)"
  if [[ "${got}" =~ ^(${want})$ && $((after - before)) -eq "${want_delta}" ]]; then
    record PASS "${id}" "HTTP ${got}, origin +$((after - before))"
  else
    record FAIL "${id}" "HTTP ${got} (want ${want}), origin +$((after - before)) (want +${want_delta})"
  fi
}

stat_value() {
  curl -s --max-time 3 "${ADMIN}/stats" | awk -F': ' -v k="$1" '$1 == k {print $2}' | head -1
}

connector_pid() { cat "${RUN}/connector.pid" 2>/dev/null || true; }

restore_connector() {
  stop_pidfile "${RUN}/connector.pid" KILL
  # Brief pause so the prior listen socket is gone before re-bind (esp. after
  # FO Envoy swaps / rapid kill+restart under FULL_DUPLEX_STREAMED).
  sleep 0.3
  CONNECTOR_RULES="" start_connector
  if ! wait_http "${METRICS}/healthz" 100; then
    echo "restore_connector: healthz not ready, retrying once" >&2
    stop_pidfile "${RUN}/connector.pid" KILL
    sleep 0.5
    CONNECTOR_RULES="" start_connector
    wait_http "${METRICS}/healthz" 100
  fi
}

start_envoy() {
  stop_pidfile "${RUN}/envoy.pid"
  daemonize "${RUN}/envoy.log" "${RUN}/envoy.pid" envoy -c "$1" \
    --concurrency 2 --log-level warn --file-flush-interval-msec 200
  wait_http "${ADMIN}/ready" 100
}

ENVOY_SWAPPED=0
cleanup() {
  kill -CONT "$(connector_pid)" 2>/dev/null || true
  if ! curl -sf -o /dev/null --max-time 2 "${METRICS}/healthz"; then
    restore_connector || echo "cleanup: connector did not come back" >&2
  fi
  if [[ "${ENVOY_SWAPPED}" -eq 1 ]]; then
    start_envoy "${ENVOY_CFG}" || echo "cleanup: envoy did not come back" >&2
  fi
  rm -f "${RUN}"/fail-modes-* "${RUN}"/envoy.fail-open.yaml
}
trap cleanup EXIT

LEAK='/page?q=%3Cscript%3Ealert(1)%3C/script%3E'
FORM=(-X POST -H 'Content-Type: application/x-www-form-urlencoded')

run_proto() {
  local rid="fm-proto-${PROTO}-$$-${RANDOM}" got ver line want_log want_ver
  read -r got ver < <(curl -s -o /dev/null -w '%{http_code} %{http_version}\n' --max-time 10 \
    "$(proto_flag)" -H "x-request-id: ${rid}" "${BASE}/" || echo "000 0")
  sleep 0.5
  line="$(grep -F "rid=${rid} " "${RUN}/envoy.log" | tail -1 || true)"
  if [[ "${PROTO}" == h2 ]]; then want_ver=2 want_log='HTTP/2"'; else want_ver=1.1 want_log='HTTP/1.1"'; fi
  if [[ "${got}" == 200 && "${ver}" == "${want_ver}" && "${line}" == *"${want_log}"* ]]; then
    record PASS "PROTO-${PROTO}" "200, curl http_version=${ver}, Envoy logged ${want_log%\"}"
  else
    record FAIL "PROTO-${PROTO}" "HTTP ${got} version=${ver} envoy='${line:-<no line for rid>}'"
  fi
}

run_class1() {
  local id="FC1-${PROTO}" before after
  before="$(stat_value "${FMA_STAT}")"
  kill -KILL "$(connector_pid)"
  sleep 0.3
  expect "${id}-get" 500 0 "${BASE}/"
  expect "${id}-post" 500 0 "${FORM[@]}" --data-binary 'name=alice' "${BASE}/post"
  expect "${id}-attack" 500 0 "${BASE}${LEAK}"
  after="$(stat_value "${FMA_STAT}")"
  if [[ "${after:-0}" == "${before:-0}" ]]; then
    record PASS "${id}-stat" "failure_mode_allowed unchanged (${after:-0})"
  else
    record FAIL "${id}-stat" "failure_mode_allowed ${before:-0}→${after:-0}"
  fi
  restore_connector
  expect "${id}-restored" 200 1 "${BASE}/"
}

run_class2() {
  local id="FC2-${PROTO}" name bad rc hz
  for name in invalid-seclang missing-include; do
    bad="${RUN}/fail-modes-${name}.conf"
    case "${name}" in
      invalid-seclang) echo 'SecRule THIS_IS_NOT_VALID_SECLANG' >"${bad}" ;;
      missing-include) printf 'SecRuleEngine On\nInclude /nonexistent/demo/rules.conf\n' >"${bad}" ;;
    esac
    stop_pidfile "${RUN}/connector.pid" KILL
    rc=0
    "${CONNECTOR_BIN}" --listen "${CONNECTOR_LISTEN}" --metrics-listen "127.0.0.1:${METRICS_PORT}" \
      --modsec-rules "${bad}" >>"${RUN}/connector.log" 2>&1 || rc=$?
    hz="$(http_code "${METRICS}/healthz")"
    if [[ "${rc}" -ne 0 && -z "$(port_pid "${CONNECTOR_PORT}")" && "${hz}" != 200 ]]; then
      record PASS "${id}-${name}-boot" "exit ${rc}, nothing on :${CONNECTOR_PORT}, healthz ${hz}"
    else
      record FAIL "${id}-${name}-boot" "exit ${rc}, listener pid '$(port_pid "${CONNECTOR_PORT}")', healthz ${hz}"
    fi
    expect "${id}-${name}-get" 500 0 "${BASE}/"
  done
  restore_connector
  expect "${id}-restored" 200 1 "${BASE}/"
}

CLASS3_DONE=0
# Floor: mid-exchange engine Err / protocol-violation fail-closed cases in grpc.rs.
MIN_CLASS3_GRPC="${MIN_CLASS3_GRPC:-8}"
run_class3() {
  local id="FC3" log="${OUT_DIR}/class3-cargo-test.log" tests n
  if [[ "${CLASS3_DONE}" -eq 1 ]]; then
    return 0
  fi
  CLASS3_DONE=1
  if (cd "${ROOT}" && cargo test -q -p ext-proc-modsec --test grpc -- fails_closed fail_closed) >"${log}" 2>&1; then
    tests="$(grep -Eo '[0-9]+ passed' "${log}" | tail -1 | awk '{print $1}')"
    n="${tests:-0}"
    if [[ "${n}" -ge "${MIN_CLASS3_GRPC}" ]]; then
      record PASS "${id}-grpc" "${n} fail-closed gRPC tests → ImmediateResponse 500 (real engine Err / phase-order; no Envoy live inject)"
    else
      record FAIL "${id}-grpc" "only ${n} passed (floor ≥ ${MIN_CLASS3_GRPC}) — see ${log}"
    fi
  else
    record FAIL "${id}-grpc" "cargo test failed — see ${log}"
  fi
}

run_class4() {
  local id="FC4-${PROTO}"
  expect "${id}-query" 403 0 "${BASE}${LEAK}"
  expect "${id}-body" 403 0 "${FORM[@]}" --data-binary "user=admin'%20UNION%20SELECT%201,2,3--" "${BASE}/login"
  expect "${id}-response" 403 1 "${BASE}/leak"
}

run_class5() {
  local id="FC5-${PROTO}" t0 t1
  if [[ "${BODY_MODE}" == "FULL_DUPLEX_STREAMED" ]]; then
    # Envoy disables message_timeout under FULL_DUPLEX_STREAMED — hang→504 is N/A.
    record SKIP "${id}-hang" "not run: no message_timeout under FULL_DUPLEX_STREAMED"
    record SKIP "${id}-timing" "not run: no message_timeout under FULL_DUPLEX_STREAMED"
    expect "${id}-restored" 200 1 "${BASE}/"
    return 0
  fi
  kill -STOP "$(connector_pid)"
  t0=$(date +%s)
  expect "${id}-hang" 504 0 "${BASE}/"
  t1=$(date +%s)
  kill -CONT "$(connector_pid)"
  if [[ $((t1 - t0)) -ge 2 && $((t1 - t0)) -le 5 ]]; then
    record PASS "${id}-timing" "answered in $((t1 - t0))s (message_timeout 2s)"
  else
    record FAIL "${id}-timing" "answered in $((t1 - t0))s (want 2–5s)"
  fi
  restore_connector
  expect "${id}-restored" 200 1 "${BASE}/"
}

run_class6() {
  local id="FC6-${PROTO}" rules="${RUN}/fail-modes-audit.conf" hz
  sed "s#^SecAuditLog .*#SecAuditLog /nonexistent/demo/modsec-audit.log#" "${RULES_FILE}" >"${rules}"
  grep -q '^SecAuditLog /nonexistent/' "${rules}" || { record FAIL "${id}" "could not rewrite SecAuditLog"; return 0; }
  stop_pidfile "${RUN}/connector.pid" KILL
  CONNECTOR_RULES="${rules}" start_connector
  sleep 1
  hz="$(http_code "${METRICS}/healthz")"
  if [[ "${hz}" == 200 ]]; then
    record PASS "${id}-boot" "connector serves with an unwritable audit log (healthz 200)"
    expect "${id}-attack" 403 0 "${BASE}${LEAK}"
    expect "${id}-benign" 200 1 "${BASE}/"
  else
    record PASS "${id}-boot" "connector refused to serve with an unwritable audit log (healthz ${hz})"
    expect "${id}-closed" 500 0 "${BASE}/"
  fi
  restore_connector
  expect "${id}-restored" 200 1 "${BASE}/"
}

run_fail_open_control() {
  local id="FO-${PROTO}" tmp="${RUN}/envoy.fail-open.yaml" before after
  sed 's/failure_mode_allow: false/failure_mode_allow: true/' "${ENVOY_CFG}" >"${tmp}"
  grep -q 'failure_mode_allow: true' "${tmp}" || { record FAIL "${id}" "could not rewrite Envoy config"; return 0; }
  ENVOY_SWAPPED=1
  start_envoy "${tmp}"
  before="$(stat_value "${FMA_STAT}")"
  kill -KILL "$(connector_pid)"
  sleep 0.3
  expect "${id}-kill-lets-through" 200 1 "${BASE}${LEAK}"
  after="$(stat_value "${FMA_STAT}")"
  if [[ "${after:-0}" -gt "${before:-0}" ]]; then
    record PASS "${id}-kill-stat" "failure_mode_allowed ${before:-0}→${after}"
  else
    record FAIL "${id}-kill-stat" "failure_mode_allowed did not rise (${before:-0}→${after:-0})"
  fi
  restore_connector
  if [[ "${BODY_MODE}" == "FULL_DUPLEX_STREAMED" ]]; then
    record SKIP "${id}-hang-lets-through" "not run: no message_timeout under FULL_DUPLEX_STREAMED"
  else
    kill -STOP "$(connector_pid)"
    expect "${id}-hang-lets-through" 200 1 "${BASE}/"
    kill -CONT "$(connector_pid)"
    restore_connector
  fi
  start_envoy "${ENVOY_CFG}"
  ENVOY_SWAPPED=0
  kill -KILL "$(connector_pid)"
  sleep 0.3
  expect "${id}-default-closed-again" 500 0 "${BASE}/"
  restore_connector
}

run_cookie() {
  local id="C2-${PROTO}"
  # Multi-Cookie field lines on one request (H1: separate headers; H2: curl may
  # send multiple cookie fields — Envoy reconstitutes before ModSec).
  expect "${id}-benign" 200 1 -H 'cookie: session=ok' -H 'cookie: theme=dark' "${BASE}/"
  expect "${id}-attack-in-2nd" 403 0 -H 'cookie: session=ok' \
    -H 'cookie: theme=<script>alert(1)</script>' "${BASE}/"
  expect "${id}-attack-in-1st" 403 0 \
    -H 'cookie: theme=<script>alert(1)</script>' -H 'cookie: session=ok' "${BASE}/"
  expect "${id}-joined-xss" 403 0 \
    -H 'cookie: session=ok; theme=<script>alert(1)</script>' "${BASE}/"
}

run_tail_body() {
  local id="C7-${PROTO}" before after got payload
  payload="${RUN}/fail-modes-tail-body.bin"
  python3 - "${payload}" <<'PY'
import sys
pad = b"name=alice&note=" + b"A" * 40000 + b"&"
with open(sys.argv[1], "wb") as f:
    f.write(pad + b"q=1'+OR+'1'='1")
PY
  before="$(origin_hits)"
  if [[ "${PROTO}" == h2 ]]; then
    # 40 KB body → curl sends several 16 KB DATA frames; the attack is in the last one.
    got="$(code "${FORM[@]}" --data-binary "@${payload}" "${BASE}/post")"
  else
    got="$(python3 - "${payload}" "${ENVOY_PORT}" <<'PY'
import socket, sys
data = open(sys.argv[1], "rb").read()
port = int(sys.argv[2])
head, tail = data[:-14], data[-14:]
host = f"127.0.0.1:{port}".encode()
req = (b"POST /post HTTP/1.1\r\nHost: " + host + b"\r\n"
       b"Content-Type: application/x-www-form-urlencoded\r\n"
       b"Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
for chunk in (head, tail):
    req += b"%x\r\n" % len(chunk) + chunk + b"\r\n"
req += b"0\r\n\r\n"
s = socket.create_connection(("127.0.0.1", port), timeout=10)
s.sendall(req)
resp = b""
while b"\r\n" not in resp:
    part = s.recv(4096)
    if not part:
        break
    resp += part
s.close()
parts = resp.split(b"\r\n", 1)[0].split()
print(parts[1].decode() if len(parts) > 1 else "000")
PY
)"
  fi
  sleep 0.1
  after="$(origin_hits)"
  if [[ "${got}" == 403 && "${after}" == "${before}" ]]; then
    record PASS "${id}-last-chunk" "HTTP 403, origin +0 (attack only in the final chunk/frames)"
  else
    record FAIL "${id}-last-chunk" "HTTP ${got} (want 403), origin +$((after - before))"
  fi
  expect "${id}-benign-large" 200 1 "${FORM[@]}" --data-binary "name=alice&note=$(printf 'A%.0s' $(seq 1 20000))" "${BASE}/post"
}

echo "==> fail-modes protos=[${PROTOS}] classes=${CLASSES}"
echo "    envoy $(envoy --version 2>&1 | grep -o '1\.[0-9]*\.[0-9]*' | head -1), failure_mode_allow: false, message_timeout: 2s"
echo "    transcript ${TRANSCRIPT}"

for PROTO in ${PROTOS}; do
  echo "==> PROTO=${PROTO}"
  # `if`, not `enabled X && run_X`: inside an && list errexit is off for the whole function.
  if enabled proto; then run_proto; fi
  if enabled 1; then run_class1; fi
  if enabled 2; then run_class2; fi
  if enabled 3; then run_class3; fi
  if enabled 4; then run_class4; fi
  if enabled 5; then run_class5; fi
  if enabled 6; then run_class6; fi
  if enabled fo; then run_fail_open_control; fi
  if enabled cookie; then run_cookie; fi
  if enabled body; then run_tail_body; fi
done

echo
echo "======== fail-modes summary ========"
for r in "${RESULTS[@]}"; do echo "  ${r}"; done
echo "summary: PASS=${PASS} FAIL=${FAIL} SKIP=${SKIP}"
if [[ "${FAIL}" -ne 0 ]]; then
  echo "FAIL-MODES FAILED"
  exit 1
fi
echo "FAIL-MODES PASSED"
