#!/usr/bin/env bash
# Latency samples through the live demo (Envoy → ext_proc → libmodsecurity+CRS → origin).
# Not an SLO — records p50/p99 so empty or wrong-status runs cannot look green.
#
#   ./demo/scripts/up.sh
#   ./demo/scripts/perf.sh              # default PERF_N=40
#   PERF_N=20 ./demo/scripts/perf.sh    # shorter local pass
#
# Floors (fail-closed for the harness itself):
#   - PERF_N ≥ MIN_PERF_N (default 10)
#   - every required WAF path: status_match == N (no silent wrong-status)
#   - ≥ MIN_PERF_PATHS completed WAF paths (default 6)
# Fail-closed traffic behaviour is unchanged — this only times allow/deny paths.
#
# Env: PERF_N, MIN_PERF_N, MIN_PERF_PATHS, SKIP_ECHO=1, ORIGIN_HTTP
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

N="${PERF_N:-40}"
MIN_N="${MIN_PERF_N:-10}"
MIN_PATHS="${MIN_PERF_PATHS:-6}"
ORIGIN_HTTP="${ORIGIN_HTTP:-http://127.0.0.1:${ORIGIN_PORT}}"
OUT_DIR="${RUN}/perf"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${OUT_DIR}/latency-${STAMP}.txt"
HOST="$(uname -s)-$(uname -m)"

if ! [[ "${N}" =~ ^[1-9][0-9]*$ ]] || [[ "${N}" -lt "${MIN_N}" ]]; then
  echo "PERF FAILED: PERF_N=${N} must be an integer ≥ MIN_PERF_N=${MIN_N}" >&2
  exit 1
fi

wait_http "${BASE}/" 50 || {
  echo "demo not up at ${BASE} — run ./demo/scripts/up.sh" >&2
  exit 2
}
wait_http "${METRICS}/healthz" 25 || {
  echo "connector /healthz not ready" >&2
  exit 2
}

mkdir -p "${OUT_DIR}"

SMALL_BENIGN="name=alice&note=hello-demo-perf"
SMALL_SQLI="var=1'%20UNION%20SELECT%201,2--"
MEDIUM_PAD="$(python3 -c 'print("x"*8000)')"
MEDIUM_BENIGN="name=alice&blob=${MEDIUM_PAD}"
MEDIUM_SQLI="var=1'%20UNION%20SELECT%201,2--&blob=${MEDIUM_PAD}"

PATHS_OK=0
FAIL=0

percentile() {
  local file="$1" count p50_idx p99_idx sorted p50s p99s
  count="$(wc -l <"$file" | tr -d ' ')"
  if [[ "${count}" -lt 1 ]]; then
    echo "0 0"
    return
  fi
  p50_idx=$(( (50 * count + 99) / 100 ))
  p99_idx=$(( (99 * count + 99) / 100 ))
  [[ "${p50_idx}" -lt 1 ]] && p50_idx=1
  [[ "${p99_idx}" -lt 1 ]] && p99_idx=1
  [[ "${p50_idx}" -gt "${count}" ]] && p50_idx=$count
  [[ "${p99_idx}" -gt "${count}" ]] && p99_idx=$count
  sorted="$(mktemp)"
  sort -n "$file" >"$sorted"
  p50s="$(sed -n "${p50_idx}p" "$sorted")"
  p99s="$(sed -n "${p99_idx}p" "$sorted")"
  rm -f "$sorted"
  awk -v a="$p50s" -v b="$p99s" 'BEGIN{printf "%.2f %.2f", a*1000, b*1000}'
}

# sample_get NAME URL WANT [required=1]
sample_get() {
  local name="$1" url="$2" want="$3" required="${4:-1}"
  local times code_ok=0 code_bad=0 _ i line code t p50 p99
  times="$(mktemp)"
  echo "==> ${name} N=${N} GET ${url} expect=${want}"
  for _ in 1 2 3 4 5; do
    curl -s -o /dev/null --max-time 10 "$url" || true
  done
  for _ in $(seq 1 "$N"); do
    line="$(curl -s -o /dev/null --max-time 10 -w "%{http_code} %{time_total}" "$url" || true)"
    [[ -z "$line" ]] && line="000 0"
    code="${line%% *}"
    t="${line#* }"
    echo "$t" >>"$times"
    if [[ "$code" == "$want" ]]; then
      code_ok=$((code_ok + 1))
    else
      code_bad=$((code_bad + 1))
    fi
  done
  # shellcheck disable=SC2046
  set -- $(percentile "$times")
  p50="$1"
  p99="$2"
  echo "  status match ${want}: ${code_ok}/${N} (other=${code_bad})"
  echo "  p50_ms=${p50}  p99_ms=${p99}"
  {
    echo "name=${name}"
    echo "method=GET"
    echo "url=${url}"
    echo "expect_status=${want}"
    echo "n=${N}"
    echo "status_match=${code_ok}"
    echo "status_other=${code_bad}"
    echo "p50_ms=${p50}"
    echo "p99_ms=${p99}"
    echo "stamp=${STAMP}"
    echo "---"
  } >>"${OUT}"
  rm -f "$times"
  if [[ "${required}" -eq 1 ]]; then
    if [[ "${code_ok}" -eq "${N}" && "${code_bad}" -eq 0 ]]; then
      PATHS_OK=$((PATHS_OK + 1))
    else
      echo "  FAIL ${name}: wrong status floor (match ${code_ok}/${N})" >&2
      FAIL=1
    fi
  fi
}

# sample_post NAME URL DATA WANT [required=1]
sample_post() {
  local name="$1" url="$2" data="$3" want="$4" required="${5:-1}"
  local times code_ok=0 code_bad=0 blen _ i line code t p50 p99
  times="$(mktemp)"
  blen="$(printf '%s' "$data" | wc -c | tr -d ' ')"
  echo "==> ${name} N=${N} POST ${url} body_bytes=${blen} expect=${want}"
  for _ in 1 2 3 4 5; do
    curl -s -o /dev/null --max-time 10 -X POST \
      -H "Content-Type: application/x-www-form-urlencoded" \
      --data-binary "$data" "$url" || true
  done
  for _ in $(seq 1 "$N"); do
    line="$(curl -s -o /dev/null --max-time 10 -w "%{http_code} %{time_total}" \
      -X POST -H "Content-Type: application/x-www-form-urlencoded" \
      --data-binary "$data" "$url" || true)"
    [[ -z "$line" ]] && line="000 0"
    code="${line%% *}"
    t="${line#* }"
    echo "$t" >>"$times"
    if [[ "$code" == "$want" ]]; then
      code_ok=$((code_ok + 1))
    else
      code_bad=$((code_bad + 1))
    fi
  done
  # shellcheck disable=SC2046
  set -- $(percentile "$times")
  p50="$1"
  p99="$2"
  echo "  status match ${want}: ${code_ok}/${N} (other=${code_bad})"
  echo "  p50_ms=${p50}  p99_ms=${p99}"
  {
    echo "name=${name}"
    echo "method=POST"
    echo "url=${url}"
    echo "body_bytes=${blen}"
    echo "expect_status=${want}"
    echo "n=${N}"
    echo "status_match=${code_ok}"
    echo "status_other=${code_bad}"
    echo "p50_ms=${p50}"
    echo "p99_ms=${p99}"
    echo "stamp=${STAMP}"
    echo "---"
  } >>"${OUT}"
  rm -f "$times"
  if [[ "${required}" -eq 1 ]]; then
    if [[ "${code_ok}" -eq "${N}" && "${code_bad}" -eq 0 ]]; then
      PATHS_OK=$((PATHS_OK + 1))
    else
      echo "  FAIL ${name}: wrong status floor (match ${code_ok}/${N})" >&2
      FAIL=1
    fi
  fi
}

{
  echo "# demo latency samples — not an SLO"
  echo "# path: Envoy→ext_proc→libmodsecurity+CRS (BUFFERED bodies)→demo origin"
  echo "# stamp=${STAMP} host=${HOST} body_mode=${BODY_MODE} base=${BASE} origin=${ORIGIN_HTTP}"
  echo "# floors: PERF_N≥${MIN_N} status_match==N on ≥${MIN_PATHS} WAF paths"
} >"${OUT}"

echo "==> body_mode=${BODY_MODE} host=${HOST} N=${N}"
echo "==> WAF path (security ON)"
sample_get "waf_benign_get" "${BASE}/" "200"
sample_get "waf_blocked_sqli_get" "${BASE}/search?q=1%27%20UNION%20SELECT%201,2--" "403"
sample_post "waf_benign_post_small" "${BASE}/post" "${SMALL_BENIGN}" "200"
sample_post "waf_blocked_sqli_post_small" "${BASE}/post" "${SMALL_SQLI}" "403"
sample_post "waf_benign_post_medium" "${BASE}/post" "${MEDIUM_BENIGN}" "200"
sample_post "waf_blocked_sqli_post_medium" "${BASE}/post" "${MEDIUM_SQLI}" "403"

if [[ "${SKIP_ECHO:-0}" != "1" ]] && curl -sf -o /dev/null --max-time 2 "${ORIGIN_HTTP}/"; then
  echo "==> origin baseline (no Envoy/WAF) on ${ORIGIN_HTTP}"
  sample_get "origin_benign_get" "${ORIGIN_HTTP}/" "200" 0
  sample_post "origin_benign_post_small" "${ORIGIN_HTTP}/post" "${SMALL_BENIGN}" "200" 0
  sample_post "origin_benign_post_medium" "${ORIGIN_HTTP}/post" "${MEDIUM_BENIGN}" "200" 0
else
  echo "==> origin baseline skipped"
fi

echo
echo "Wrote ${OUT}"
echo "summary: WAF_PATHS_OK=${PATHS_OK} MIN_PERF_PATHS=${MIN_PATHS} PERF_N=${N}"

if [[ "${PATHS_OK}" -lt "${MIN_PATHS}" ]]; then
  echo "PERF FAILED: WAF_PATHS_OK=${PATHS_OK} < MIN_PERF_PATHS=${MIN_PATHS} (empty/partial run cannot go green)" >&2
  FAIL=1
fi

if [[ "${FAIL}" -ne 0 ]]; then
  echo "PERF FAILED" >&2
  exit 1
fi
echo "PERF PASSED host=${HOST} body_mode=${BODY_MODE} paths=${PATHS_OK} n=${N}"
