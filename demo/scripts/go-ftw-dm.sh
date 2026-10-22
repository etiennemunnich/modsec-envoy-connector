#!/usr/bin/env bash
# CRS / demo go-ftw against DEPLOY=dm (HTTP/1.x only — not H2 WAF proven).
#
#   DEPLOY=dm ./demo/scripts/up.sh
#   DEPLOY=dm ./demo/scripts/go-ftw-dm.sh smoke
#
# Floors (no vacuous pass): demo success ≥ MIN_FTW_DM_DEMO; body success ≥
# MIN_FTW_DM_BODY when body CRS is claimed. NONE skips body CRS.
#
# Env: FTW_BIN, FTW_INCLUDE, FTW_OVERRIDES, MIN_FTW_DM_DEMO, MIN_FTW_DM_BODY
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

MODE="${1:-smoke}"
FTW_DIR="${DEMO}/ftw"
CONFIG="${FTW_DIR}/.ftw.yaml"
OVERRIDES="${FTW_OVERRIDES:-${FTW_DIR}/envoy-overrides.yaml}"
CRS_TESTS="${CRS_DIR}/tests/regression/tests"
OUT_DIR="${RUN}/go-ftw-dm"
ART="${ART:-/opt/cursor/artifacts/dm-private-validate}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DEFAULT_BODY_INCLUDE='^(942100|942130|942140|942160|942170|941100|941110|941160)-'
BODY_INCLUDE="${FTW_INCLUDE:-${DEFAULT_BODY_INCLUDE}}"
MIN_DEMO="${MIN_FTW_DM_DEMO:-8}"
MIN_BODY="${MIN_FTW_DM_BODY:-50}"

if [[ "${DEPLOY}" != "dm" ]]; then
  echo "go-ftw-dm.sh requires DEPLOY=dm (got '${DEPLOY}')" >&2
  exit 2
fi

if [[ -n "${FTW_BIN:-}" ]]; then
  FTW="${FTW_BIN}"
elif [[ -x "${HOME}/.local/bin/ftw" ]]; then
  FTW="${HOME}/.local/bin/ftw"
else
  FTW="$(command -v ftw || command -v go-ftw || true)"
fi
[[ -n "${FTW}" ]] || { echo "go-ftw not found — run demo/scripts/install-go-ftw.sh" >&2; exit 2; }
[[ -d "${CRS_TESTS}" ]] || { echo "missing ${CRS_TESTS} — run demo/scripts/install-crs.sh" >&2; exit 2; }
grep -q "^Include ${CRS_DIR}/rules/" "${RULES_FILE}" 2>/dev/null \
  || { echo "demo not running with CRS — DEPLOY=dm ./demo/scripts/up.sh (without DEMO_CRS=0)" >&2; exit 2; }
wait_http "${BASE}/" 50 || { echo "demo not up at ${BASE}" >&2; exit 2; }
mkdir -p "${OUT_DIR}" "${ART}/ftw"

# Resolve demo YAML by body_policy / BODY_MODE.
DEMO_GLOB="demo-tests-dm.yaml"
RUN_BODY_CRS=1
case "${BODY_MODE}" in
  BUFFERED|BUFFERED_PARTIAL)
    DEMO_GLOB="demo-tests-dm.yaml"
    ;;
  STREAMED)
    DEMO_GLOB="demo-tests-dm-streamed.yaml"
    ;;
  NONE)
    DEMO_GLOB="demo-tests-dm-none.yaml"
    RUN_BODY_CRS=0
    ;;
  FULL_DUPLEX_STREAMED)
    echo "go-ftw-dm: FULL_DUPLEX unsupported on DM — use fail-closed-dm / up reject, not ftw" >&2
    exit 2
    ;;
  *)
    echo "go-ftw-dm: unsupported BODY_MODE=${BODY_MODE}" >&2
    exit 2
    ;;
esac

override_args=()
if [[ "${OVERRIDES}" != "none" ]]; then
  [[ -f "${OVERRIDES}" ]] || { echo "missing overrides ${OVERRIDES}" >&2; exit 2; }
  override_args=(--overrides "${OVERRIDES}")
fi

body_rule_ids() {
  if [[ "${BODY_INCLUDE}" == "${DEFAULT_BODY_INCLUDE}" ]]; then
    echo "942100 942130 942140 942160 942170 941100 941110 941160"
    return 0
  fi
  local alts
  alts="$(sed -nE 's/^\^\(([^)]+)\)-.*/\1/p' <<<"${BODY_INCLUDE}")"
  [[ -n "${alts}" ]] || return 0
  echo "${alts}" | tr '|' ' '
}

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

ftw_success_count() {
  local json="$1"
  python3 - "${json}" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        data = json.load(fh)
except (OSError, ValueError):
    print(0)
    raise SystemExit(0)
v = data.get("success") or []
print(len(v) if isinstance(v, list) else int(v or 0))
PY
}

summarize_json() {
  local json="$1" log="${2:-}"
  if [[ ! -s "${json}" ]]; then
    echo "no-summary (empty json)"
    return 0
  fi
  python3 - "${json}" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
def n(key):
    v = data.get(key) or []
    return len(v) if isinstance(v, list) else v
print(f"success={n('success')} failed={n('failed')} skipped={n('skipped')} ignored={n('ignored')}")
failed = data.get("failed") or []
if failed:
    print("failed ids: " + " ".join(sorted(map(str, failed))[:40]))
PY
}

run_ftw() {
  local dir="$1" name="$2"
  shift 2
  local json="${OUT_DIR}/${name}-${STAMP}.json" log="${OUT_DIR}/${name}-${STAMP}.log" rc=0
  : >"${json}"
  "${FTW}" run --config "${CONFIG}" --cloud --dir "${dir}" \
    --output json --file "${json}" \
    --wait-for-host "${BASE}/" --wait-for-expect-status-code 200 --wait-for-timeout 30s \
    "${override_args[@]+"${override_args[@]}"}" "$@" >"${log}" 2>&1 || rc=$?
  cp -f "${json}" "${log}" "${ART}/ftw/" 2>/dev/null || true
  LAST_SUMMARY="$(summarize_json "${json}" "${log}") exit=${rc} log=${log}"
  LAST_JSON="${json}"
  return "${rc}"
}

BODY_TESTS_DIR="${CRS_TESTS}"
BODY_STAGE=""
cleanup_body_stage() {
  if [[ -n "${BODY_STAGE}" && -d "${BODY_STAGE}" ]]; then rm -rf "${BODY_STAGE}"; fi
}
if [[ "${MODE}" == "smoke" || "${MODE}" == "body" ]] && [[ "${RUN_BODY_CRS}" -eq 1 ]]; then
  BODY_STAGE="$(mktemp -d "${OUT_DIR}/body-stage.XXXXXX")"
  trap cleanup_body_stage EXIT
  if stage_body_tests "${BODY_STAGE}"; then
    BODY_TESTS_DIR="${BODY_STAGE}"
  else
    echo "go-ftw-dm: body-stage empty; using full CRS tree" >&2
    cleanup_body_stage
    BODY_STAGE=""
    trap - EXIT
  fi
fi

echo "==> $("${FTW}" -v 2>&1 | head -1) mode=${MODE} DEPLOY=dm BODY_MODE=${BODY_MODE} body_policy=${DM_BODY_POLICY} target=${BASE}"
echo "    demo=${DEMO_GLOB}  overrides=${OVERRIDES}  H1-only"

rc=0
DEMO_OK=0
BODY_OK=0

case "${MODE}" in
  smoke)
    run_ftw "${FTW_DIR}" "dm-${BODY_MODE}-demo" --glob "${DEMO_GLOB}" || rc=1
    echo "demo tests:     ${LAST_SUMMARY}"
    DEMO_OK="$(ftw_success_count "${LAST_JSON}")"
    if [[ "${DEMO_OK}" -lt "${MIN_DEMO}" ]]; then
      echo "FLOOR FAIL: demo success=${DEMO_OK} < ${MIN_DEMO}" >&2
      rc=1
    else
      echo "FLOOR OK: demo success=${DEMO_OK} ≥ ${MIN_DEMO}"
    fi
    if [[ "${RUN_BODY_CRS}" -eq 1 ]]; then
      run_ftw "${BODY_TESTS_DIR}" "dm-${BODY_MODE}-crs-body" --include "${BODY_INCLUDE}" || rc=1
      echo "CRS body ids:   ${LAST_SUMMARY}"
      BODY_OK="$(ftw_success_count "${LAST_JSON}")"
      if [[ "${BODY_OK}" -lt "${MIN_BODY}" ]]; then
        echo "FLOOR FAIL: CRS body success=${BODY_OK} < ${MIN_BODY}" >&2
        rc=1
      else
        echo "FLOOR OK: CRS body success=${BODY_OK} ≥ ${MIN_BODY}"
      fi
      if [[ "${BODY_MODE}" == "BUFFERED_PARTIAL" ]]; then
        echo "NOTE: PARTIAL is not CRS-complete; body floor is under-limit smoke only"
      fi
    else
      echo "CRS body ids:   SKIP (NONE / headers_only — no body CRS claim)"
    fi
    ;;
  body)
    if [[ "${RUN_BODY_CRS}" -ne 1 ]]; then
      echo "go-ftw-dm body: N/A under NONE" >&2
      exit 2
    fi
    run_ftw "${BODY_TESTS_DIR}" "dm-${BODY_MODE}-crs-body" --include "${BODY_INCLUDE}" || rc=1
    echo "CRS body ids:   ${LAST_SUMMARY}"
    BODY_OK="$(ftw_success_count "${LAST_JSON}")"
    if [[ "${BODY_OK}" -lt "${MIN_BODY}" ]]; then
      echo "FLOOR FAIL: CRS body success=${BODY_OK} < ${MIN_BODY}" >&2
      rc=1
    fi
    ;;
  *)
    echo "usage: $0 [smoke|body]" >&2
    exit 2
    ;;
esac

{
  echo "BODY_MODE=${BODY_MODE} body_policy=${DM_BODY_POLICY} mode=${MODE}"
  echo "demo_success=${DEMO_OK} body_success=${BODY_OK} min_demo=${MIN_DEMO} min_body=${MIN_BODY}"
  echo "rc=${rc}"
} | tee "${ART}/ftw/go-ftw-dm-${BODY_MODE}-${MODE}-${STAMP}.summary.txt"

if [[ "${rc}" -ne 0 ]]; then
  echo "GO-FTW-DM ${MODE} FAILED BODY_MODE=${BODY_MODE}"
  exit 1
fi
echo "GO-FTW-DM ${MODE} PASSED BODY_MODE=${BODY_MODE} demo=${DEMO_OK} body=${BODY_OK}"
