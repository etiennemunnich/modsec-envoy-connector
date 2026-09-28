#!/usr/bin/env bash
# One live cell: Envoy → connector → libmodsecurity (+ CRS) on this host, then
# the requested suites. Used by .github/workflows/live-e2e.yml; runs locally
# too (Linux or macOS) once Envoy, libmodsecurity and go-ftw are installed.
#
#   SUITES="smoke fail-closed fail-modes go-ftw-smoke" ./scripts/ci-live-e2e.sh
#
# Env:
#   SUITES           any of: smoke fail-closed fail-modes hop-trace go-ftw-smoke go-ftw-body go-ftw-full
#   BODY_MODE        BUFFERED (default) or STREAMED — selects demo/envoy/envoy{,-streamed}.yaml
#   ENVOY_VERSION    assert `envoy --version` is this tag (default: ENVOY_PIN)
#   MODSECURITY_PIN  assert pkg-config reports this tag (default: lock pin)
#   CRS_TAG          CRS tag to load (default: lock pin); fetched into demo/.crs-<tag>
#   E2E_REPORT       markdown report path (default demo/.run/e2e-report.md);
#                    also appended to $GITHUB_STEP_SUMMARY when set
#   EXPECT_ARCH      fail unless `uname -m` is this (CI passes the matrix arch)
#   MIN_*            per-suite floors, see floor() below
#
# failure_mode_allow stays false in both Envoy configs.
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
  BUFFERED) envoy_cfg="${ROOT}/demo/envoy/envoy.yaml" ;;
  STREAMED) envoy_cfg="${ROOT}/demo/envoy/envoy-streamed.yaml" ;;
  *) die "BODY_MODE must be BUFFERED or STREAMED (got '${BODY_MODE}')" ;;
esac
command -v envoy >/dev/null || die "envoy not on PATH"
envoy_line="$(envoy --version 2>&1 | grep -m1 'version:' || true)"
[[ "${envoy_line}" == *"/${ENVOY_VERSION#v}/"* ]] || die "envoy on PATH is not ${ENVOY_VERSION}: ${envoy_line}"
modsec_ver="$(pkg-config --modversion modsecurity)"
[[ "${modsec_ver}" == "${MODSECURITY_PIN#v}" ]] || die "pkg-config reports libmodsecurity ${modsec_ver}, want ${MODSECURITY_PIN}"
grep -q 'failure_mode_allow: false' "${envoy_cfg}" || die "${envoy_cfg} must keep failure_mode_allow: false"
grep -q "request_body_mode: ${BODY_MODE}" "${envoy_cfg}" || die "${envoy_cfg} must set request_body_mode: ${BODY_MODE}"
# Full CRS / go-ftw stay on BUFFERED unless explicitly overridden (STREAMED e2e is thin).
if [[ "${BODY_MODE}" == "STREAMED" && "${SUITES}" == *go-ftw* ]]; then
  die "go-ftw suites require BODY_MODE=BUFFERED (got STREAMED); keep STREAMED e2e thin"
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
# an unwritable audit log (class 6 then records 3 checks per protocol, not 4);
# body ids leave room for older CRS lines in stable-window cells.
MIN_FAIL_MODES="${MIN_FAIL_MODES:-57}"
MIN_FTW_DEMO="${MIN_FTW_DEMO:-8}"
MIN_FTW_BODY="${MIN_FTW_BODY:-100}"
MIN_FTW_FULL="${MIN_FTW_FULL:-5000}"
MIN_SMOKE_BODY="${MIN_SMOKE_BODY:-5}"

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
      n="$(grep -Eo 'body_checks=[0-9]+' "$2" | tail -1 | cut -d= -f2 || true)"
      [[ "${n:-0}" -ge "${MIN_SMOKE_BODY}" ]] || { echo "body_checks=${n:-0} < ${MIN_SMOKE_BODY}"; return 1; }
      ;;
    fail-modes)
      n="$(grep -Eo 'summary: PASS=[0-9]+' "$2" | tail -1 | cut -d= -f2 || true)"
      [[ "${n:-0}" -ge "${MIN_FAIL_MODES}" ]] || { echo "PASS=${n:-0} < ${MIN_FAIL_MODES}"; return 1; }
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
  record up PASS $((SECONDS - t0)) "Envoy :18080 → connector :18081 → origin :18098"
else
  cat "${ROOT}/demo/.run/e2e-up.log" >&2
  record up FAIL $((SECONDS - t0)) "demo did not start"
  SUITES=""
fi

for suite in ${SUITES}; do
  echo "==> ${suite}"
  log="${ROOT}/demo/.run/e2e-${suite}.log"
  case "${suite}" in
    smoke | fail-closed | fail-modes) cmd=("${DEMO}/${suite}.sh") ;;
    hop-trace) cmd=("${DEMO}/hop-trace.sh" --expect-status 403 --expect-origin no '/search?q=1%27%20UNION%20SELECT%201--') ;;
    go-ftw-smoke | go-ftw-body | go-ftw-full) cmd=("${DEMO}/go-ftw.sh" "${suite#go-ftw-}") ;;
    *) record "${suite}" FAIL 0 "unknown suite"; continue ;;
  esac
  t0=$SECONDS
  if "${cmd[@]}" 2>&1 | tee "${log}"; then result=PASS; else result=FAIL; fi
  summary="$(grep -E 'summary: PASS=|^(demo tests|CRS body ids|CRS full):|PASSED$|FAILED$|HOP-TRACE' "${log}" \
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
