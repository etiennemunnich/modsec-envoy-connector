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
# Default body-heavy rule ids (SQLi + XSS detectors that exercise POST bodies).
DEFAULT_BODY_INCLUDE='^(942100|942130|942140|942160|942170|941100|941110|941160)-'
BODY_INCLUDE="${FTW_INCLUDE:-${DEFAULT_BODY_INCLUDE}}"

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

# body_rule_ids — numeric rule prefixes implied by BODY_INCLUDE (empty if custom).
body_rule_ids() {
  # Default pattern ^(id|id|...)- → extract the alternation. Custom FTW_INCLUDE
  # that is not this shape returns empty (caller falls back to the full tree).
  if [[ "${BODY_INCLUDE}" == "${DEFAULT_BODY_INCLUDE}" ]]; then
    echo "942100 942130 942140 942160 942170 941100 941110 941160"
    return 0
  fi
  local alts
  alts="$(sed -nE 's/^\^\(([^)]+)\)-.*/\1/p' <<<"${BODY_INCLUDE}")"
  [[ -n "${alts}" ]] || return 0
  echo "${alts}" | tr '|' ' '
}

# stage_body_tests <dest> — symlink only BODY_INCLUDE rule YAML into dest.
# go-ftw parses every YAML under --dir *before* applying --include, so a
# single unreadable file elsewhere in the CRS tree (CRS v4.23.0 920640.yaml
# ships `status: [400]`; go-ftw 2.6.0 rejects that as !!seq→int) aborts the
# body smoke with an empty JSON summary. Staging keeps smoke/body honest for
# every tag in the year window without excluding the tag from the matrix.
stage_body_tests() {
  local dest="$1" ids rule f n=0
  mkdir -p "${dest}"
  ids="$(body_rule_ids)"
  [[ -n "${ids}" ]] || return 1
  for rule in ${ids}; do
    f="$(find "${CRS_TESTS}" \( -name "${rule}.yaml" -o -name "${rule}.yml" \) 2>/dev/null | head -1 || true)"
    [[ -n "${f}" ]] || continue
    ln -sfn "${f}" "${dest}/$(basename "${f}")"
    n=$((n + 1))
  done
  [[ "${n}" -ge 1 ]]
}

# summarize_json <json> [log] — prints success=/failed=… or no-summary with log hint.
summarize_json() {
  local json="$1" log="${2:-}"
  if [[ ! -s "${json}" ]]; then
    local hint=""
    if [[ -n "${log}" && -f "${log}" ]]; then
      hint="$(grep -E -m2 '^(Error:|yaml:)|cannot construct' "${log}" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' || true)"
    fi
    if [[ -n "${hint}" ]]; then
      echo "no-summary (empty json; ${hint})"
    else
      echo "no-summary (empty json)"
    fi
    return 0
  fi
  python3 - "${json}" <<'PY'
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

# run_ftw <tests-dir> <name> [extra go-ftw args...] — sets LAST_SUMMARY.
run_ftw() {
  local dir="$1" name="$2"
  shift 2
  local json="${OUT_DIR}/${name}-${STAMP}.json" log="${OUT_DIR}/${name}-${STAMP}.log" rc=0 pid se health
  pid="$(cat "${RUN}/connector.pid" 2>/dev/null || true)"
  se="$(stream_errors)"
  [[ -n "${se}" ]] || { LAST_SUMMARY="no-summary connector=UNRESPONSIVE before the run exit=1 log=${log}"; return 1; }
  : >"${json}"
  "${FTW}" run --config "${CONFIG}" --cloud --dir "${dir}" \
    --output json --file "${json}" \
    --wait-for-host "${BASE}/" --wait-for-expect-status-code 200 --wait-for-timeout 30s \
    "${override_args[@]+"${override_args[@]}"}" "$@" >"${log}" 2>&1 || rc=$?
  health="$(connector_after "${pid}" "${se}")" || rc=1
  LAST_SUMMARY="$(summarize_json "${json}" "${log}") connector=${health} exit=${rc} log=${log}"
  return "${rc}"
}

# Resolve the CRS tests dir for body-id runs (staged when possible).
BODY_TESTS_DIR="${CRS_TESTS}"
BODY_STAGE=""
cleanup_body_stage() {
  [[ -n "${BODY_STAGE}" && -d "${BODY_STAGE}" ]] && rm -rf "${BODY_STAGE}" || true
}
if [[ "${MODE}" == "smoke" || "${MODE}" == "body" ]]; then
  BODY_STAGE="$(mktemp -d "${OUT_DIR}/body-stage.XXXXXX")"
  trap cleanup_body_stage EXIT
  if stage_body_tests "${BODY_STAGE}"; then
    BODY_TESTS_DIR="${BODY_STAGE}"
  else
    echo "go-ftw: body-stage empty (custom FTW_INCLUDE?); using full CRS tree" >&2
    cleanup_body_stage
    BODY_STAGE=""
    trap - EXIT
  fi
fi

echo "==> $("${FTW}" -v 2>&1 | head -1) mode=${MODE} target=${BASE}"
echo "    CRS $(git -C "${CRS_DIR}" describe --tags 2>/dev/null || echo '?')  overrides=${OVERRIDES}"
[[ "${BODY_TESTS_DIR}" == "${CRS_TESTS}" ]] || echo "    body tests staged from BODY_INCLUDE rule files (avoids unrelated YAML parse poison)"

rc=0
case "${MODE}" in
  smoke)
    run_ftw "${FTW_DIR}" smoke-demo --glob "demo-tests.yaml" || rc=1
    echo "demo tests:     ${LAST_SUMMARY}"
    run_ftw "${BODY_TESTS_DIR}" smoke-crs --include "${BODY_INCLUDE}" || rc=1
    echo "CRS body ids:   ${LAST_SUMMARY}"
    ;;
  body)
    run_ftw "${BODY_TESTS_DIR}" body --include "${BODY_INCLUDE}" || rc=1
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
