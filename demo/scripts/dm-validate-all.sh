#!/usr/bin/env bash
# Full DM validation harness (local / private). Logs under ART.
# No git push. Not fail-closed absolute.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

ART="${ART:-/opt/cursor/artifacts/dm-private-validate}"
mkdir -p "${ART}"
SUMMARY="${ART}/suite-summary.txt"
: >"${SUMMARY}"

record() {
  local name="$1" rc="$2"
  if [[ "$rc" -eq 0 ]]; then
    echo "PASS ${name}" | tee -a "${SUMMARY}"
  else
    echo "FAIL ${name} rc=${rc}" | tee -a "${SUMMARY}"
  fi
}

export LIBCLANG_PATH="${LIBCLANG_PATH:-/usr/lib/llvm-18/lib}"
export PATH="${HOME}/.local/bin:${PATH}"

echo "==> rebuild libmodsec_dm.so"
(cd "${ROOT}" && cargo build -p modsec-dm --locked 2>&1 | tee "${ART}/build.log")
so_src="${ROOT}/target/debug/libmodsec_dm.so"
mkdir -p "${DM_MODULES_DIR}"
cp -f "${so_src}" "${DM_SO}"
sha256sum "${DM_SO}" | tee "${ART}/libmodsec_dm.sha256"

echo "==> unit tests"
set +e
(cd "${ROOT}" && cargo test -p modsec-dm --locked -- --nocapture) 2>&1 | tee "${ART}/unit-tests.log"
record "unit-tests" "${PIPESTATUS[0]}"
set -e

run_mode() {
  local mode="$1"
  local soft_args=()
  if [[ "$mode" == "BUFFERED_PARTIAL" ]]; then
    soft_args=(DM_PARTIAL_SOFT_LIMIT=65536)
  fi
  echo ""
  echo "======== MODE ${mode} ========"
  "${DEMO}/scripts/down.sh" >/dev/null 2>&1 || true
  set +e
  env DEPLOY=dm BODY_MODE="${mode}" "${soft_args[@]}" "${DEMO}/scripts/up.sh" \
    >"${ART}/up-${mode}.log" 2>&1
  record "up-${mode}" $?
  set -e
  set +e
  env DEPLOY=dm BODY_MODE="${mode}" "${soft_args[@]}" "${DEMO}/scripts/smoke-dm.sh" \
    >"${ART}/smoke-${mode}.log" 2>&1
  record "smoke-${mode}" "${PIPESTATUS[0]}"
  set -e
  case "${mode}" in
    STREAMED|NONE|BUFFERED_PARTIAL)
      set +e
      env DEPLOY=dm BODY_MODE="${mode}" "${soft_args[@]}" "${DEMO}/scripts/dm-body-honesty.sh" \
        >"${ART}/honesty-${mode}.log" 2>&1
      record "honesty-${mode}" "${PIPESTATUS[0]}"
      set -e
      ;;
  esac
}

run_mode BUFFERED

# fail-closed-dm needs live BUFFERED demo
set +e
env DEPLOY=dm BODY_MODE=BUFFERED "${DEMO}/scripts/fail-closed-dm.sh" \
  >"${ART}/fail-closed-dm.log" 2>&1
record "fail-closed-dm" "${PIPESTATUS[0]}"
set -e

run_mode STREAMED
run_mode NONE
run_mode BUFFERED_PARTIAL

# FULL_DUPLEX reject (up.sh should exit 2 before start)
echo ""
echo "======== FULL_DUPLEX reject ========"
"${DEMO}/scripts/down.sh" >/dev/null 2>&1 || true
set +e
env DEPLOY=dm BODY_MODE=FULL_DUPLEX_STREAMED "${DEMO}/scripts/up.sh" \
  >"${ART}/full-duplex-reject.log" 2>&1
fd_rc=$?
set -e
if [[ "$fd_rc" -ne 0 ]] && grep -qiE 'does not support FULL_DUPLEX|UNSUPPORTED' "${ART}/full-duplex-reject.log"; then
  record "full-duplex-reject" 0
else
  echo "unexpected FULL_DUPLEX up rc=${fd_rc}" | tee -a "${ART}/full-duplex-reject.log"
  record "full-duplex-reject" 1
fi

"${DEMO}/scripts/down.sh" >/dev/null 2>&1 || true
set +e
ART="${ART}" "${DEMO}/scripts/fail-closed-dm-negctl.sh" >"${ART}/negctl.log" 2>&1
record "fail-closed-dm-negctl" "${PIPESTATUS[0]}"
set -e

"${DEMO}/scripts/down.sh" >/dev/null 2>&1 || true

fails="$(grep -c '^FAIL ' "${SUMMARY}" || true)"
passes="$(grep -c '^PASS ' "${SUMMARY}" || true)"
echo "" | tee -a "${SUMMARY}"
echo "TOTAL_PASS=${passes} TOTAL_FAIL=${fails}" | tee -a "${SUMMARY}"
if [[ "${fails}" -gt 0 ]]; then
  echo "DM-VALIDATE FAILED" | tee -a "${SUMMARY}"
  exit 1
fi
echo "DM-VALIDATE PASSED" | tee -a "${SUMMARY}"
