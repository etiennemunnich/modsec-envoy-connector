#!/usr/bin/env bash
# Initial basic latency samples for DEPLOY=dm per body mode (PERF_N≈40 after warmups).
# Not an SLO. Not production-ready. Worker-stall risk remains under large CRS.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

ART="${ART:-/opt/cursor/artifacts/dm-private-validate}"
N="${PERF_N:-40}"
MIN_N="${MIN_PERF_N:-10}"
mkdir -p "${ART}/perf"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
CSV="${ART}/perf/dm-latency-by-mode-${STAMP}.csv"
RAW_DIR="${ART}/perf/raw-${STAMP}"
mkdir -p "${RAW_DIR}"
echo "mode,path,want,n,match,p50_ms,p95_ms,p99_ms" >"${CSV}"

if ! [[ "${N}" =~ ^[1-9][0-9]*$ ]] || [[ "${N}" -lt "${MIN_N}" ]]; then
  echo "PERF_N=${N} must be ≥ ${MIN_N}" >&2
  exit 2
fi

percentile() {
  local file="$1" count p50_idx p95_idx p99_idx sorted
  count="$(wc -l <"$file" | tr -d ' ')"
  [[ "${count}" -lt 1 ]] && { echo "0 0 0"; return; }
  p50_idx=$(( (50 * count + 99) / 100 ))
  p95_idx=$(( (95 * count + 99) / 100 ))
  p99_idx=$(( (99 * count + 99) / 100 ))
  [[ "${p50_idx}" -lt 1 ]] && p50_idx=1
  [[ "${p95_idx}" -lt 1 ]] && p95_idx=1
  [[ "${p99_idx}" -lt 1 ]] && p99_idx=1
  [[ "${p50_idx}" -gt "${count}" ]] && p50_idx=$count
  [[ "${p95_idx}" -gt "${count}" ]] && p95_idx=$count
  [[ "${p99_idx}" -gt "${count}" ]] && p99_idx=$count
  sorted="$(mktemp)"
  sort -n "$file" >"$sorted"
  awk -v a="$(sed -n "${p50_idx}p" "$sorted")" \
      -v b="$(sed -n "${p95_idx}p" "$sorted")" \
      -v c="$(sed -n "${p99_idx}p" "$sorted")" \
      'BEGIN{printf "%.2f %.2f %.2f", a*1000, b*1000, c*1000}'
  rm -f "$sorted"
}

sample_get() {
  local mode="$1" name="$2" url="$3" want="$4"
  local times code_ok=0 line code t p50 p95 p99
  times="${RAW_DIR}/${mode}-${name}.times"
  : >"${times}"
  echo "==> ${mode} ${name} N=${N} expect=${want}"
  local _
  for _ in 1 2 3 4 5; do curl -s -o /dev/null --max-time 10 "$url" || true; done
  for _ in $(seq 1 "$N"); do
    line="$(curl -s -o /dev/null --max-time 15 -w "%{http_code} %{time_total}" "$url" || true)"
    [[ -z "$line" ]] && line="000 0"
    code="${line%% *}"
    t="${line#* }"
    echo "$t" >>"${times}"
    [[ "$code" == "$want" ]] && code_ok=$((code_ok + 1))
  done
  # shellcheck disable=SC2046
  set -- $(percentile "$times")
  p50="$1"; p95="$2"; p99="$3"
  echo "  match ${code_ok}/${N}  p50=${p50}ms p95=${p95}ms p99=${p99}ms"
  echo "${mode},${name},${want},${N},${code_ok},${p50},${p95},${p99}" >>"${CSV}"
  if [[ "${code_ok}" -ne "${N}" ]]; then
    echo "  FAIL status match for ${mode}/${name}" >&2
    return 1
  fi
  return 0
}

sample_post() {
  local mode="$1" name="$2" url="$3" want="$4" data="$5" ctype="${6:-application/x-www-form-urlencoded}"
  local times code_ok=0 line code t p50 p95 p99
  times="${RAW_DIR}/${mode}-${name}.times"
  : >"${times}"
  echo "==> ${mode} ${name} N=${N} POST expect=${want}"
  local _
  for _ in 1 2 3 4 5; do
    curl -s -o /dev/null --max-time 10 -X POST -H "Content-Type: ${ctype}" --data-binary "${data}" "$url" || true
  done
  for _ in $(seq 1 "$N"); do
    line="$(curl -s -o /dev/null --max-time 15 -w "%{http_code} %{time_total}" \
      -X POST -H "Content-Type: ${ctype}" --data-binary "${data}" "$url" || true)"
    [[ -z "$line" ]] && line="000 0"
    code="${line%% *}"
    t="${line#* }"
    echo "$t" >>"${times}"
    [[ "$code" == "$want" ]] && code_ok=$((code_ok + 1))
  done
  # shellcheck disable=SC2046
  set -- $(percentile "$times")
  p50="$1"; p95="$2"; p99="$3"
  echo "  match ${code_ok}/${N}  p50=${p50}ms p95=${p95}ms p99=${p99}ms"
  echo "${mode},${name},${want},${N},${code_ok},${p50},${p95},${p99}" >>"${CSV}"
  if [[ "${code_ok}" -ne "${N}" ]]; then
    echo "  FAIL status match for ${mode}/${name}" >&2
    return 1
  fi
  return 0
}

FAIL=0
run_dm_mode() {
  local mode="$1"
  local soft_args=()
  [[ "$mode" == "BUFFERED_PARTIAL" ]] && soft_args=(DM_PARTIAL_SOFT_LIMIT=65536)
  echo ""
  echo "======== PERF DM ${mode} ========"
  "${DEMO}/scripts/down.sh" >/dev/null 2>&1 || true
  env DEPLOY=dm BODY_MODE="${mode}" "${soft_args[@]}" "${DEMO}/scripts/up.sh" \
    >"${ART}/perf/up-${mode}.log" 2>&1
  wait_http "${BASE}/" 50 || { echo "up failed ${mode}"; FAIL=1; return; }
  sample_get "${mode}" "benign-get" "${BASE}/" 200 || FAIL=1
  sample_get "${mode}" "deny-sqli-query" \
    "${BASE}/search?q=1%27%20UNION%20SELECT%20username,password%20FROM%20users--" 403 || FAIL=1
  case "${mode}" in
    NONE)
      # Body not inspected — time a benign POST instead of body deny.
      sample_post "${mode}" "benign-post" "${BASE}/post" 200 "name=alice&note=perf" || FAIL=1
      ;;
    STREAMED)
      # STREAMED body deny may be 403 with early origin; status still 403.
      sample_post "${mode}" "deny-body-sqli" "${BASE}/login" 403 \
        "user=admin'%20UNION%20SELECT%201,2,3--" || FAIL=1
      ;;
    *)
      sample_post "${mode}" "deny-body-sqli" "${BASE}/login" 403 \
        "user=admin'%20UNION%20SELECT%201,2,3--" || FAIL=1
      ;;
  esac
}

# Optional ext_proc BUFFERED baseline (one column).
run_extproc_baseline() {
  echo ""
  echo "======== PERF ext_proc BUFFERED baseline ========"
  "${DEMO}/scripts/down.sh" >/dev/null 2>&1 || true
  env DEPLOY=ext_proc BODY_MODE=BUFFERED "${DEMO}/scripts/up.sh" \
    >"${ART}/perf/up-extproc-BUFFERED.log" 2>&1
  wait_http "${BASE}/" 50 || { echo "ext_proc up failed"; FAIL=1; return; }
  sample_get "ext_proc_BUFFERED" "benign-get" "${BASE}/" 200 || FAIL=1
  sample_get "ext_proc_BUFFERED" "deny-sqli-query" \
    "${BASE}/search?q=1%27%20UNION%20SELECT%20username,password%20FROM%20users--" 403 || FAIL=1
  sample_post "ext_proc_BUFFERED" "deny-body-sqli" "${BASE}/login" 403 \
    "user=admin'%20UNION%20SELECT%201,2,3--" || FAIL=1
}

run_dm_mode BUFFERED
run_dm_mode STREAMED
run_dm_mode NONE
run_dm_mode BUFFERED_PARTIAL
run_extproc_baseline

"${DEMO}/scripts/down.sh" >/dev/null 2>&1 || true
cp -f "${CSV}" "${ART}/perf/dm-latency-by-mode-latest.csv"
echo "Wrote ${CSV}"
if [[ "${FAIL}" -ne 0 ]]; then
  echo "DM-PERF FAILED" >&2
  exit 1
fi
echo "DM-PERF PASSED N=${N}"
