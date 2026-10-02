#!/usr/bin/env bash
# One live cell: Envoy → connector → libmodsecurity (+ CRS) on this host, then
# the requested suites. Used by .github/workflows/live-e2e.yml; runs locally
# too (Linux or macOS) once Envoy, libmodsecurity and go-ftw are installed.
#
#   SUITES="smoke fail-closed fail-modes go-ftw-smoke" ./scripts/ci-live-e2e.sh
#
# Env:
#   SUITES           any of: smoke fail-closed fail-modes trailers hop-trace
#                    hop-trace-grpc hop-trace-ws-frames go-ftw-smoke go-ftw-body go-ftw-full
#                    partial-honesty (BUFFERED_PARTIAL only)
#                    buffered-oversize (BUFFERED only) connect-assert
#                    (hop-trace-grpc needs go + grpcurl; Mac/local — not default CI)
#   BODY_MODE        BUFFERED (default) | STREAMED | BUFFERED_PARTIAL | FULL_DUPLEX_STREAMED
#                    | REQ_BUFFERED_RESP_STREAMED | REQ_STREAMED_RESP_BUFFERED
#                    selects demo/envoy YAML (asymmetric = independent req/resp axes)
#   ENVOY_VERSION    assert `envoy --version` is this tag (default: ENVOY_PIN)
#   MODSECURITY_PIN  assert pkg-config reports this tag (default: lock pin)
#   CRS_TAG          CRS tag to load (default: lock pin); fetched into demo/.crs-<tag>
#   E2E_REPORT       markdown report path (default demo/.run/e2e-report.md);
#                    also appended to $GITHUB_STEP_SUMMARY when set
#   EXPECT_ARCH      fail unless `uname -m` is this (CI passes the matrix arch)
#   MIN_*            per-suite floors, see floor() below
#
# failure_mode_allow stays false in all Envoy configs.
# A suite passes only if it exits 0 AND its summary reports at least the
# floor of passing checks, so a suite that silently runs fewer checks (or a
# go-ftw include that selects nothing) is a failure, not a green.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEMO="${ROOT}/demo/scripts"
pin() { grep -E "^$1=" "${ROOT}/versions.lock.md" | head -1 | cut -d= -f2; }

SUITES="${SUITES:-smoke fail-closed fail-modes go-ftw-smoke}"
export BODY_MODE="${BODY_MODE:-BUFFERED}"
ENVOY_VERSION="${ENVOY_VERSION:-$(pin ENVOY_PIN)}"
MODSECURITY_PIN="${MODSECURITY_PIN:-$(pin MODSECURITY_PIN)}"
export CRS_TAG="${CRS_TAG:-$(pin CRS_TAG)}"
export CRS_DIR="${CRS_DIR:-${ROOT}/demo/.crs-${CRS_TAG}}"
REPORT="${E2E_REPORT:-${ROOT}/demo/.run/e2e-report.md}"

die() { echo "ci-live-e2e: $*" >&2; exit 1; }

arch="$(uname -m)"
[[ -z "${EXPECT_ARCH:-}" || "${arch}" == "${EXPECT_ARCH}" ]] || die "running on ${arch}, want EXPECT_ARCH=${EXPECT_ARCH}"
case "${BODY_MODE}" in
  BUFFERED) envoy_cfg="${ROOT}/demo/envoy/envoy.yaml"; req_mode=BUFFERED; resp_mode=BUFFERED ;;
  STREAMED) envoy_cfg="${ROOT}/demo/envoy/envoy-streamed.yaml"; req_mode=STREAMED; resp_mode=STREAMED ;;
  BUFFERED_PARTIAL) envoy_cfg="${ROOT}/demo/envoy/envoy-buffered-partial.yaml"; req_mode=BUFFERED_PARTIAL; resp_mode=BUFFERED_PARTIAL ;;
  FULL_DUPLEX_STREAMED) envoy_cfg="${ROOT}/demo/envoy/envoy-full-duplex.yaml"; req_mode=FULL_DUPLEX_STREAMED; resp_mode=FULL_DUPLEX_STREAMED ;;
  REQ_BUFFERED_RESP_STREAMED)
    envoy_cfg="${ROOT}/demo/envoy/envoy-req-buffered-resp-streamed.yaml"
    req_mode=BUFFERED; resp_mode=STREAMED
    ;;
  REQ_STREAMED_RESP_BUFFERED)
    envoy_cfg="${ROOT}/demo/envoy/envoy-req-streamed-resp-buffered.yaml"
    req_mode=STREAMED; resp_mode=BUFFERED
    ;;
  *) die "BODY_MODE must be BUFFERED, STREAMED, BUFFERED_PARTIAL, FULL_DUPLEX_STREAMED, REQ_BUFFERED_RESP_STREAMED, or REQ_STREAMED_RESP_BUFFERED (got '${BODY_MODE}')" ;;
esac
command -v envoy >/dev/null || die "envoy not on PATH"
envoy_line="$(envoy --version 2>&1 | grep -m1 'version:' || true)"
[[ "${envoy_line}" == *"/${ENVOY_VERSION#v}/"* ]] || die "envoy on PATH is not ${ENVOY_VERSION}: ${envoy_line}"
modsec_ver="$(pkg-config --modversion modsecurity)"
[[ "${modsec_ver}" == "${MODSECURITY_PIN#v}" ]] || die "pkg-config reports libmodsecurity ${modsec_ver}, want ${MODSECURITY_PIN}"
grep -q 'failure_mode_allow: false' "${envoy_cfg}" || die "${envoy_cfg} must keep failure_mode_allow: false"
grep -q "request_body_mode: ${req_mode}" "${envoy_cfg}" || die "${envoy_cfg} must set request_body_mode: ${req_mode}"
grep -q "response_body_mode: ${resp_mode}" "${envoy_cfg}" || die "${envoy_cfg} must set response_body_mode: ${resp_mode}"
if [[ "${BODY_MODE}" == "BUFFERED_PARTIAL" ]]; then
  grep -q 'per_connection_buffer_limit_bytes: 1048576' "${envoy_cfg}" \
    || die "${envoy_cfg} must set per_connection_buffer_limit_bytes: 1048576 (1 MiB PARTIAL)"
fi
if [[ "${BODY_MODE}" == "FULL_DUPLEX_STREAMED" ]]; then
  grep -q 'request_trailer_mode: SEND' "${envoy_cfg}" \
    || die "${envoy_cfg} must set request_trailer_mode: SEND for FULL_DUPLEX_STREAMED"
fi
# STREAMED may run go-ftw-smoke/body (local tip parity with BUFFERED). Hosted
# go-ftw-full stays on BUFFERED (crs-full / monthly) for Actions cost — not a
# STREAMED correctness refuse. BUFFERED_PARTIAL may run go-ftw-smoke/body
# (under-limit CRS) but never go-ftw-full (would pretend PARTIAL equals
# BUFFERED CRS fidelity). FULL_DUPLEX_STREAMED may run go-ftw-smoke/body;
# go-ftw-full stays a local/deep lab (push CI uses smoke + fail-closed +
# go-ftw-smoke). Asymmetric modes may run smoke/FC/go-ftw-smoke; not go-ftw-full.
if [[ "${BODY_MODE}" == "BUFFERED_PARTIAL" && "${SUITES}" == *go-ftw-full* ]]; then
  die "go-ftw-full is not allowed under BODY_MODE=BUFFERED_PARTIAL (prefix CRS dishonest)"
fi
if [[ "${BODY_MODE}" == "FULL_DUPLEX_STREAMED" && "${SUITES}" == *go-ftw-full* ]]; then
  die "go-ftw-full is not allowed under BODY_MODE=FULL_DUPLEX_STREAMED in CI (local lab only; hang budget loss)"
fi
if [[ "${BODY_MODE}" == REQ_* && "${SUITES}" == *go-ftw-full* ]]; then
  die "go-ftw-full is not allowed under asymmetric BODY_MODE=${BODY_MODE} in CI (lab cell)"
fi
if [[ "${SUITES}" == *buffered-oversize* && "${BODY_MODE}" != "BUFFERED" ]]; then
  die "buffered-oversize requires BODY_MODE=BUFFERED (got '${BODY_MODE}')"
fi

"${DEMO}/install-crs.sh" >/dev/null
crs_got="$(git -C "${CRS_DIR}" describe --tags --exact-match 2>/dev/null || true)"
[[ "${crs_got}" == "${CRS_TAG}" ]] || die "${CRS_DIR} is at '${crs_got}', want ${CRS_TAG}"

cleanup() { "${DEMO}/down.sh" >/dev/null 2>&1 || true; }
trap cleanup EXIT

mkdir -p "$(dirname "${REPORT}")"
{
  echo "### live e2e — $(uname -s) ${arch} · body_mode=${BODY_MODE}"
  echo
  echo "Envoy \`${ENVOY_VERSION}\` · libmodsecurity \`${MODSECURITY_PIN}\` · CRS \`${CRS_TAG}\` · body_mode \`${BODY_MODE}\` · connector \`$(git -C "${ROOT}" rev-parse --short HEAD 2>/dev/null || echo '?')\`"
  echo
  echo "| Suite | Result | Seconds | Summary |"
  echo "|-------|--------|---------|---------|"
} >"${REPORT}"

# Floors (measured 2026-09-27 at the pins: go-ftw demo 8, body ids 118, full
# 5091; fail-modes 59). fail-modes is 57 when the engine refuses to boot with
# an unwritable audit log (class 6 then records 3 checks per protocol, not 4).
#
# CRS body-id floor is version-aware: the pin bar stays MIN_FTW_BODY_PIN (100).
# When the installed CRS tag genuinely ships fewer BODY_INCLUDE tests (e.g.
# v4.19.0 has exactly 92), the floor drops to that available count so the
# year-axis cell can go green without weakening the pin CRS bar. An empty
# selection still fails (available < MIN_FTW_BODY_ABS). Explicit MIN_FTW_BODY
# in the environment always wins.
MIN_FAIL_MODES="${MIN_FAIL_MODES:-57}"
MIN_FTW_DEMO="${MIN_FTW_DEMO:-8}"
MIN_FTW_BODY_PIN="${MIN_FTW_BODY_PIN:-100}"
MIN_FTW_BODY_ABS="${MIN_FTW_BODY_ABS:-50}"
MIN_FTW_FULL="${MIN_FTW_FULL:-5000}"
MIN_SMOKE_BODY="${MIN_SMOKE_BODY:-5}"
MIN_TRAILERS="${MIN_TRAILERS:-5}"
MIN_GRPC_HOP="${MIN_GRPC_HOP:-6}"
MIN_WS_FRAMES="${MIN_WS_FRAMES:-6}"
MIN_PARTIAL_HONESTY="${MIN_PARTIAL_HONESTY:-3}"
MIN_BUFFERED_OVERSIZE="${MIN_BUFFERED_OVERSIZE:-4}"
MIN_CONNECT_ASSERT="${MIN_CONNECT_ASSERT:-1}"

# count_ftw_body_tests — how many tests match the default BODY_INCLUDE rule set.
count_ftw_body_tests() {
  local root="${CRS_DIR}/tests/regression/tests" total=0 rule f n
  [[ -d "${root}" ]] || { echo 0; return 0; }
  for rule in 942100 942130 942140 942160 942170 941100 941110 941160; do
    f="$(find "${root}" \( -name "${rule}.yaml" -o -name "${rule}.yml" \) 2>/dev/null | head -1 || true)"
    [[ -n "${f}" ]] || continue
    n="$(grep -cE '^[[:space:]]+- test_id:' "${f}" 2>/dev/null || true)"
    n="${n:-0}"
    total=$((total + n))
  done
  echo "${total}"
}

if [[ -z "${MIN_FTW_BODY:-}" ]]; then
  FTW_BODY_AVAILABLE="$(count_ftw_body_tests)"
  if [[ "${FTW_BODY_AVAILABLE}" -ge "${MIN_FTW_BODY_ABS}" && "${FTW_BODY_AVAILABLE}" -lt "${MIN_FTW_BODY_PIN}" ]]; then
    MIN_FTW_BODY="${FTW_BODY_AVAILABLE}"
    echo "ci-live-e2e: CRS ${CRS_TAG} BODY_INCLUDE available=${FTW_BODY_AVAILABLE} < pin floor ${MIN_FTW_BODY_PIN}; using version-aware floor ${MIN_FTW_BODY}"
  else
    MIN_FTW_BODY="${MIN_FTW_BODY_PIN}"
  fi
fi

# Suite summary lines for the report table. Must match mid-line suffixes
# (e.g. "SMOKE PASSED body_mode=BUFFERED body_checks=6") — not only EOL PASSED.
# Shared with scripts/test-ci-scripts.sh (keep in sync).
SUMMARY_RE='summary: PASS=|^(demo tests|CRS body ids|CRS full):|\bPASSED\b|\bFAILED\b|HOP-TRACE|TRAILERS|PARTIAL-HONESTY|BUFFERED-OVERSIZE|CONNECT-ASSERT'

# ftw_success <log> <line prefix> — go-ftw success= count on that summary line (0 if absent).
ftw_success() {
  local n
  n="$(grep -E "^$2: +success=[0-9]+" "$1" | tail -1 | sed -E 's/.*success=([0-9]+).*/\1/' || true)"
  echo "${n:-0}"
}

# floor <suite> <log> — prints a reason and returns 1 when the suite ran fewer checks than its floor.
floor() {
  local n
  case "$1" in
    smoke)
      # Require an explicit SMOKE PASSED line (not just body_checks=N from a fake log).
      grep -qE '\bSMOKE PASSED\b' "$2" || { echo "missing SMOKE PASSED"; return 1; }
      n="$(grep -Eo 'body_checks=[0-9]+' "$2" | tail -1 | cut -d= -f2 || true)"
      [[ "${n:-0}" -ge "${MIN_SMOKE_BODY}" ]] || { echo "body_checks=${n:-0} < ${MIN_SMOKE_BODY}"; return 1; }
      ;;
    fail-modes)
      n="$(grep -Eo 'summary: PASS=[0-9]+' "$2" | tail -1 | cut -d= -f2 || true)"
      [[ "${n:-0}" -ge "${MIN_FAIL_MODES}" ]] || { echo "PASS=${n:-0} < ${MIN_FAIL_MODES}"; return 1; }
      ;;
    trailers)
      grep -qE '\bTRAILERS PASSED\b' "$2" || { echo "missing TRAILERS PASSED"; return 1; }
      n="$(grep -Eo 'trailer_checks=[0-9]+' "$2" | tail -1 | cut -d= -f2 || true)"
      [[ "${n:-0}" -ge "${MIN_TRAILERS}" ]] || { echo "trailer_checks=${n:-0} < ${MIN_TRAILERS}"; return 1; }
      ;;
    hop-trace-grpc)
      grep -qE '\bHOP-TRACE-GRPC PASSED\b' "$2" || { echo "missing HOP-TRACE-GRPC PASSED"; return 1; }
      n="$(grep -Eo 'checks=[0-9]+' "$2" | tail -1 | cut -d= -f2 || true)"
      [[ "${n:-0}" -ge "${MIN_GRPC_HOP}" ]] || { echo "checks=${n:-0} < ${MIN_GRPC_HOP}"; return 1; }
      ;;
    hop-trace-ws-frames)
      grep -qE '\bHOP-TRACE-WS-FRAMES PASSED\b' "$2" || { echo "missing HOP-TRACE-WS-FRAMES PASSED"; return 1; }
      n="$(grep -Eo 'checks=[0-9]+' "$2" | tail -1 | cut -d= -f2 || true)"
      [[ "${n:-0}" -ge "${MIN_WS_FRAMES}" ]] || { echo "checks=${n:-0} < ${MIN_WS_FRAMES}"; return 1; }
      ;;
    partial-honesty)
      grep -qE '\bPARTIAL-HONESTY PASSED\b' "$2" || { echo "missing PARTIAL-HONESTY PASSED"; return 1; }
      n="$(grep -Eo 'checks=[0-9]+' "$2" | tail -1 | cut -d= -f2 || true)"
      [[ "${n:-0}" -ge "${MIN_PARTIAL_HONESTY}" ]] || { echo "checks=${n:-0} < ${MIN_PARTIAL_HONESTY}"; return 1; }
      ;;
    buffered-oversize)
      grep -qE '\bBUFFERED-OVERSIZE PASSED\b' "$2" || { echo "missing BUFFERED-OVERSIZE PASSED"; return 1; }
      n="$(grep -Eo 'checks=[0-9]+' "$2" | tail -1 | cut -d= -f2 || true)"
      [[ "${n:-0}" -ge "${MIN_BUFFERED_OVERSIZE}" ]] || { echo "checks=${n:-0} < ${MIN_BUFFERED_OVERSIZE}"; return 1; }
      ;;
    connect-assert)
      grep -qE '\bCONNECT-ASSERT PASSED\b' "$2" || { echo "missing CONNECT-ASSERT PASSED"; return 1; }
      n="$(grep -Eo 'checks=[0-9]+' "$2" | tail -1 | cut -d= -f2 || true)"
      [[ "${n:-0}" -ge "${MIN_CONNECT_ASSERT}" ]] || { echo "checks=${n:-0} < ${MIN_CONNECT_ASSERT}"; return 1; }
      ;;
    go-ftw-smoke)
      n="$(ftw_success "$2" 'demo tests')"
      [[ "${n}" -ge "${MIN_FTW_DEMO}" ]] || { echo "demo tests success=${n} < ${MIN_FTW_DEMO}"; return 1; }
      n="$(ftw_success "$2" 'CRS body ids')"
      [[ "${n}" -ge "${MIN_FTW_BODY}" ]] || { echo "CRS body ids success=${n} < ${MIN_FTW_BODY}"; return 1; }
      ;;
    go-ftw-body)
      n="$(ftw_success "$2" 'CRS body ids')"
      [[ "${n}" -ge "${MIN_FTW_BODY}" ]] || { echo "CRS body ids success=${n} < ${MIN_FTW_BODY}"; return 1; }
      ;;
    go-ftw-full)
      n="$(ftw_success "$2" 'CRS full')"
      [[ "${n}" -ge "${MIN_FTW_FULL}" ]] || { echo "CRS full success=${n} < ${MIN_FTW_FULL}"; return 1; }
      ;;
  esac
  return 0
}

rc=0
record() {
  local name="$1" result="$2" secs="$3" summary="$4"
  echo "| ${name} | ${result} | ${secs} | ${summary} |" >>"${REPORT}"
  [[ "${result}" == "PASS" ]] || rc=1
}

mkdir -p "${ROOT}/demo/.run"
t0=$SECONDS
if "${DEMO}/up.sh" >"${ROOT}/demo/.run/e2e-up.log" 2>&1; then
  record up PASS $((SECONDS - t0)) "Envoy → connector → origin (body_mode=${BODY_MODE})"
else
  cat "${ROOT}/demo/.run/e2e-up.log" >&2
  record up FAIL $((SECONDS - t0)) "demo did not start"
  SUITES=""
fi

for suite in ${SUITES}; do
  echo "==> ${suite}"
  log="${ROOT}/demo/.run/e2e-${suite}.log"
  case "${suite}" in
    smoke | fail-closed | fail-modes | trailers | partial-honesty | buffered-oversize | connect-assert) cmd=("${DEMO}/${suite}.sh") ;;
    hop-trace) cmd=("${DEMO}/hop-trace.sh" --expect-status 403 --expect-origin no '/search?q=1%27%20UNION%20SELECT%201--') ;;
    hop-trace-grpc) cmd=("${DEMO}/hop-trace-grpc.sh") ;;
    hop-trace-ws-frames) cmd=("${DEMO}/hop-trace-ws-frames.sh") ;;
    go-ftw-smoke | go-ftw-body | go-ftw-full) cmd=("${DEMO}/go-ftw.sh" "${suite#go-ftw-}") ;;
    *) record "${suite}" FAIL 0 "unknown suite"; continue ;;
  esac
  t0=$SECONDS
  if "${cmd[@]}" 2>&1 | tee "${log}"; then result=PASS; else result=FAIL; fi
  # grep may find nothing on unknown suites; keep the pipeline from aborting under pipefail.
  summary="$( { grep -E "${SUMMARY_RE}" "${log}" || true; } \
    | sed -E 's/ exit=[0-9]+ log=.*//; s/\|/\//g' | tr '\n' ';' | sed 's/;$//; s/;/; /g')"
  if [[ "${result}" == PASS ]] && ! why="$(floor "${suite}" "${log}")"; then
    result=FAIL
    summary="below floor (${why}); ${summary}"
    echo "::error::${suite} below floor: ${why}"
  fi
  record "${suite}" "${result}" $((SECONDS - t0)) "${summary}"
done

cat "${REPORT}"
[[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || cat "${REPORT}" >>"${GITHUB_STEP_SUMMARY}"
if [[ "${rc}" -ne 0 ]]; then
  echo "LIVE E2E FAILED"
  exit 1
fi
echo "LIVE E2E PASSED"
