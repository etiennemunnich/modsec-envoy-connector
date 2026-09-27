#!/usr/bin/env bash
# CRS regression through the running demo with go-ftw (cloud mode: HTTP
# status only). HTTP/1.x only — go-ftw does not speak HTTP/2, so a green run
# says nothing about H2 (see demo/scripts/fail-modes.sh --proto h2).
#
#   ./demo/scripts/go-ftw.sh smoke   demo-tests.yaml + body-heavy CRS SQLi/XSS ids (gate)
#   ./demo/scripts/go-ftw.sh body    body-heavy CRS SQLi/XSS ids only
#   ./demo/scripts/go-ftw.sh full    the whole CRS tests/regression/tests tree
#
# Env:
#   FTW_BIN        go-ftw binary (default: ftw or go-ftw on PATH)
#   FTW_INCLUDE    Go regex for --include (overrides the body-heavy id list)
#   FTW_OVERRIDES  overrides file, or "none" to measure without Envoy overrides
#
# Results: demo/.run/go-ftw/<mode>-<stamp>.{json,log}. Requires ./demo/scripts/up.sh
# with CRS loaded (the default).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

MODE="${1:-smoke}"
FTW_DIR="${DEMO}/ftw"
CONFIG="${FTW_DIR}/.ftw.yaml"
OVERRIDES="${FTW_OVERRIDES:-${FTW_DIR}/envoy-overrides.yaml}"
CRS_TESTS="${CRS_DIR}/tests/regression/tests"
OUT_DIR="${RUN}/go-ftw"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BODY_INCLUDE="${FTW_INCLUDE:-^(942100|942130|942140|942160|942170|941100|941110|941160)-}"

FTW="${FTW_BIN:-$(command -v ftw || command -v go-ftw || true)}"
[[ -n "${FTW}" ]] || { echo "go-ftw not found — run demo/scripts/install-go-ftw.sh" >&2; exit 2; }
[[ -d "${CRS_TESTS}" ]] || { echo "missing ${CRS_TESTS} — run demo/scripts/install-crs.sh" >&2; exit 2; }
grep -q "^Include ${CRS_DIR}/rules/" "${RULES_FILE}" 2>/dev/null \
  || { echo "demo is not running with CRS — run ./demo/scripts/up.sh (without DEMO_CRS=0)" >&2; exit 2; }
wait_http "${BASE}/" 50 || { echo "demo not up at ${BASE} — run ./demo/scripts/up.sh" >&2; exit 2; }
mkdir -p "${OUT_DIR}"

override_args=()
if [[ "${OVERRIDES}" != "none" ]]; then
  [[ -f "${OVERRIDES}" ]] || { echo "missing overrides ${OVERRIDES}" >&2; exit 2; }
  override_args=(--overrides "${OVERRIDES}")
fi

# Several overrides accept a transport error (expect_error) for attack payloads
# Envoy itself rejects, which a crashed or hung connector would also produce.
# So every run must end with the same connector process serving /metrics and
# no new gRPC stream errors.
stream_errors() {
  curl -sf --max-time 3 "${METRICS}/metrics" | awk '$1 == "ext_proc_stream_errors_total" { print $2 }' || true
}

# connector_after <pid> <stream errors before> — prints "ok" or the problem; 1 on a problem.
connector_after() {
  local pid="$1" before="$2" now
  if [[ -z "${pid}" ]] || ! kill -0 "${pid}" 2>/dev/null; then
    echo "DEAD (pid ${pid:-?} gone)"
    return 1
  fi
  now="$(stream_errors)"
  if [[ -z "${now}" ]]; then
    echo "UNRESPONSIVE (/metrics did not answer; pid ${pid} state $(ps -o stat= -p "${pid}" | tr -d ' '))"
    return 1
  fi
  if [[ "${now}" != "${before}" ]]; then
    echo "stream_errors_total ${before}→${now}"
    return 1
  fi
  echo ok
}

# run_ftw <tests-dir> <name> [extra go-ftw args...] — sets LAST_SUMMARY.
run_ftw() {
  local dir="$1" name="$2"
  shift 2
  local json="${OUT_DIR}/${name}-${STAMP}.json" log="${OUT_DIR}/${name}-${STAMP}.log" rc=0 pid se health
  pid="$(cat "${RUN}/connector.pid" 2>/dev/null || true)"
  se="$(stream_errors)"
  [[ -n "${se}" ]] || { LAST_SUMMARY="no-summary connector=UNRESPONSIVE before the run exit=1 log=${log}"; return 1; }
  "${FTW}" run --config "${CONFIG}" --cloud --dir "${dir}" \
    --output json --file "${json}" \
    --wait-for-host "${BASE}/" --wait-for-expect-status-code 200 --wait-for-timeout 30s \
    "${override_args[@]+"${override_args[@]}"}" "$@" >"${log}" 2>&1 || rc=$?
  health="$(connector_after "${pid}" "${se}")" || rc=1
  LAST_SUMMARY="$(summarize "${json}") connector=${health} exit=${rc} log=${log}"
  return "${rc}"
}

summarize() {
  python3 - "$1" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        data = json.load(fh)
except (OSError, ValueError) as e:
    print(f"no-summary ({e})")
    sys.exit(0)
def n(key):
    v = data.get(key) or []
    return len(v) if isinstance(v, list) else v
print(f"success={n('success')} failed={n('failed')} skipped={n('skipped')} ignored={n('ignored')} forced_pass={n('forcedpass')} forced_fail={n('forcedfail')}")
failed = data.get("failed") or []
if failed:
    print("failed ids: " + " ".join(sorted(failed)[:60]) + (" …" if len(failed) > 60 else ""))
PY
}

echo "==> $("${FTW}" -v 2>&1 | head -1) mode=${MODE} target=${BASE}"
echo "    CRS $(git -C "${CRS_DIR}" describe --tags 2>/dev/null || echo '?')  overrides=${OVERRIDES}"

rc=0
case "${MODE}" in
  smoke)
    run_ftw "${FTW_DIR}" smoke-demo --glob "demo-tests.yaml" || rc=1
    echo "demo tests:     ${LAST_SUMMARY}"
    run_ftw "${CRS_TESTS}" smoke-crs --include "${BODY_INCLUDE}" || rc=1
    echo "CRS body ids:   ${LAST_SUMMARY}"
    ;;
  body)
    run_ftw "${CRS_TESTS}" body --include "${BODY_INCLUDE}" || rc=1
    echo "CRS body ids:   ${LAST_SUMMARY}"
    ;;
  full)
    run_ftw "${CRS_TESTS}" full || rc=1
    echo "CRS full:       ${LAST_SUMMARY}"
    ;;
  *)
    echo "usage: $0 [smoke|body|full]" >&2
    exit 2
    ;;
esac

if [[ "${rc}" -ne 0 ]]; then
  echo "GO-FTW ${MODE} FAILED"
  exit 1
fi
echo "GO-FTW ${MODE} PASSED"
