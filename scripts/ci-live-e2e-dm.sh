#!/usr/bin/env bash
# Lean live cell for DEPLOY=dm (in-process dynamic module) on this host.
# Used by ci.yml e2e-dm × {x86_64, aarch64}. Not fail-closed absolute.
#
#   ./scripts/ci-live-e2e-dm.sh
#
# Env:
#   ENVOY_VERSION / MODSECURITY_PIN / CRS_TAG — pin asserts (default: lock)
#   EXPECT_ARCH — fail unless uname -m matches (CI matrix)
#   E2E_REPORT — markdown summary path
#
# Suites (fixed, lean): BUFFERED smoke-dm + fail-closed-dm; STREAMED smoke-dm.
# No go-ftw matrix here (minutes). FULL_DUPLEX reject covered by fail-closed-dm.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEMO="${ROOT}/demo/scripts"
pin() { grep -E "^$1=" "${ROOT}/versions.lock.md" | head -1 | cut -d= -f2; }

ENVOY_VERSION="${ENVOY_VERSION:-$(pin ENVOY_PIN)}"
MODSECURITY_PIN="${MODSECURITY_PIN:-$(pin MODSECURITY_PIN)}"
export CRS_TAG="${CRS_TAG:-$(pin CRS_TAG)}"
export CRS_DIR="${CRS_DIR:-${ROOT}/demo/.crs-${CRS_TAG}}"
REPORT="${E2E_REPORT:-${ROOT}/demo/.run/e2e-dm-report.md}"
export LIBCLANG_PATH="${LIBCLANG_PATH:-/usr/lib/llvm-18/lib}"
export DEPLOY=dm

die() { echo "ci-live-e2e-dm: $*" >&2; exit 1; }

arch="$(uname -m)"
[[ -z "${EXPECT_ARCH:-}" || "${arch}" == "${EXPECT_ARCH}" ]] || die "running on ${arch}, want EXPECT_ARCH=${EXPECT_ARCH}"
command -v envoy >/dev/null || die "envoy not on PATH"
envoy_line="$(envoy --version 2>&1 | grep -m1 'version:' || true)"
[[ "${envoy_line}" == *"/${ENVOY_VERSION#v}/"* ]] || die "envoy on PATH is not ${ENVOY_VERSION}: ${envoy_line}"
modsec_ver="$(pkg-config --modversion modsecurity)"
[[ "${modsec_ver}" == "${MODSECURITY_PIN#v}" ]] || die "pkg-config reports libmodsecurity ${modsec_ver}, want ${MODSECURITY_PIN}"
# Idempotent pin checkout (same layout as ci-live-e2e.sh).
"${DEMO}/install-crs.sh" >/dev/null
crs_got="$(git -C "${CRS_DIR}" describe --tags --exact-match 2>/dev/null || true)"
[[ "${crs_got}" == "${CRS_TAG}" ]] || die "${CRS_DIR} is at '${crs_got}', want ${CRS_TAG}"

mkdir -p "$(dirname "${REPORT}")" "${ROOT}/demo/.run"
: >"${REPORT}"

pass=0
fail=0
record() {
  local name="$1" rc="$2" detail="${3:-}"
  if [[ "${rc}" -eq 0 ]]; then
    echo "PASS ${name}${detail:+ — ${detail}}" | tee -a "${REPORT}"
    pass=$((pass + 1))
  else
    echo "FAIL ${name} rc=${rc}${detail:+ — ${detail}}" | tee -a "${REPORT}"
    fail=1
  fi
}

{
  echo "### live e2e-dm — $(uname -s) ${arch}"
  echo
  echo "Envoy \`${ENVOY_VERSION}\` · libmodsecurity \`${MODSECURITY_PIN}\` · CRS \`${CRS_TAG}\` · DEPLOY=dm · tip \`$(git -C "${ROOT}" rev-parse --short HEAD 2>/dev/null || echo '?')\`"
  echo
  echo "Lean cell: BUFFERED smoke-dm + fail-closed-dm; STREAMED smoke-dm. Not fail-closed absolute."
  echo
} | tee "${REPORT}"

# --- BUFFERED ---
echo "==> DEPLOY=dm BODY_MODE=BUFFERED up + smoke-dm"
set +e
env DEPLOY=dm BODY_MODE=BUFFERED "${DEMO}/up.sh" >"${ROOT}/demo/.run/e2e-dm-up-BUFFERED.log" 2>&1
up_rc=$?
set -e
record "up-BUFFERED" "${up_rc}"
if [[ "${up_rc}" -eq 0 ]]; then
  set +e
  out="$(env DEPLOY=dm BODY_MODE=BUFFERED "${DEMO}/smoke-dm.sh" 2>&1)"
  sm_rc=$?
  set -e
  printf '%s\n' "${out}" | tee "${ROOT}/demo/.run/e2e-dm-smoke-BUFFERED.log" | tee -a "${REPORT}" >/dev/null
  echo "${out}" | grep -q 'DM-SMOKE PASSED' || sm_rc=1
  # Floor: body_checks ≥ 5 in summary (no vacuous pass)
  echo "${out}" | grep -Eq 'body_checks=([5-9]|[1-9][0-9]+)' || sm_rc=1
  record "smoke-dm-BUFFERED" "${sm_rc}"

  set +e
  out="$(env DEPLOY=dm BODY_MODE=BUFFERED "${DEMO}/fail-closed-dm.sh" 2>&1)"
  fc_rc=$?
  set -e
  printf '%s\n' "${out}" | tee "${ROOT}/demo/.run/e2e-dm-fail-closed.log" | tee -a "${REPORT}" >/dev/null
  echo "${out}" | grep -q 'FAIL-CLOSED-DM PASSED' || fc_rc=1
  echo "${out}" | grep -Eq 'checks=([4-9]|[1-9][0-9]+)' || fc_rc=1
  record "fail-closed-dm" "${fc_rc}"
fi

# --- STREAMED ---
echo "==> DEPLOY=dm BODY_MODE=STREAMED up + smoke-dm"
set +e
env DEPLOY=dm BODY_MODE=STREAMED "${DEMO}/up.sh" >"${ROOT}/demo/.run/e2e-dm-up-STREAMED.log" 2>&1
up_rc=$?
set -e
record "up-STREAMED" "${up_rc}"
if [[ "${up_rc}" -eq 0 ]]; then
  set +e
  out="$(env DEPLOY=dm BODY_MODE=STREAMED "${DEMO}/smoke-dm.sh" 2>&1)"
  sm_rc=$?
  set -e
  printf '%s\n' "${out}" | tee "${ROOT}/demo/.run/e2e-dm-smoke-STREAMED.log" | tee -a "${REPORT}" >/dev/null
  echo "${out}" | grep -q 'DM-SMOKE PASSED' || sm_rc=1
  echo "${out}" | grep -Eq 'body_checks=([5-9]|[1-9][0-9]+)' || sm_rc=1
  record "smoke-dm-STREAMED" "${sm_rc}"
fi

"${DEMO}/down.sh" >/dev/null 2>&1 || true

{
  echo
  echo "e2e-dm summary: pass=${pass} fail=${fail}"
} | tee -a "${REPORT}"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat "${REPORT}" >>"${GITHUB_STEP_SUMMARY}"
fi

# NEGCTL (not for merge): force e2e-dm red — impossible floor so the check fails.
# Minimum suite count (no vacuous pass): up×2 + smoke×2 + fail-closed = 5
[[ "${pass}" -ge 999 ]] || die "pass=${pass} < 999 (negctl deliberate fail)"
[[ "${fail}" -eq 0 ]] || die "one or more cells failed — see ${REPORT}"
echo "ci-live-e2e-dm PASSED pass=${pass}"
