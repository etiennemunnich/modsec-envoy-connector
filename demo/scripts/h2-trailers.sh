#!/usr/bin/env bash
# HTTP/2 requests whose body ends with trailers, through the running demo
# (Envoy → connector → origin), asserting origin hits per cell.
#
# Envoy marks a body that trailers follow with end_of_stream=false, and with
# HEADERS then trailers (no DATA) it sends no body message at all. The
# connector ends the body phase at the trailers (trailer mode SEND in every
# shipped non-NONE config) and fails closed when Envoy forwards a request
# whose body phase never ran. Each attack cell must answer 403 with origin
# untouched; each benign cell 200 with origin +1.
#
# Cells (h2c prior knowledge, demo/scripts/h2c.py):
#   body-sqli+trailers    POST, SQLi form body, DATA without END_STREAM, trailers
#   query-sqli+trailers   POST, SQLi query, HEADERS then trailers, no DATA
#   benign-body+trailers  POST, benign form body, trailers
#   benign+trailers       POST, HEADERS then trailers, no DATA
# BODY_MODE=NONE skips body-sqli+trailers: NONE never inspects bodies.
#
# Floor: MIN_H2_TRAILER_CHECKS (default 4; 3 under NONE) cells must PASS.
#
# Usage:
#   ./demo/scripts/up.sh && ./demo/scripts/h2-trailers.sh
#   BODY_MODE=STREAMED ./demo/scripts/up.sh && ./demo/scripts/h2-trailers.sh
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

H2C="${DEMO}/scripts/h2c.py"
FAIL=0
PASS=0
if [[ "${BODY_MODE}" == "NONE" ]]; then
  MIN_H2_TRAILER_CHECKS="${MIN_H2_TRAILER_CHECKS:-3}"
else
  MIN_H2_TRAILER_CHECKS="${MIN_H2_TRAILER_CHECKS:-4}"
fi
OUT_DIR="${RUN}/h2-trailers"
mkdir -p "${OUT_DIR}"
TRANSCRIPT="${OUT_DIR}/$(date -u +%Y%m%dT%H%M%SZ).txt"
exec > >(tee "${TRANSCRIPT}") 2>&1

pass() { echo "  PASS $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL $*"; FAIL=1; }

wait_http "${BASE}/" 50 || { echo "demo not up at ${BASE} — run ./demo/scripts/up.sh" >&2; exit 2; }

FORM=(--header "content-type:application/x-www-form-urlencoded")
SQLI_BODY="q=1' UNION SELECT username,password FROM users--"
SQLI_QS="/search?q=1%27%20UNION%20SELECT%20username,password%20FROM%20users--"

# cell <name> <want-status> <want-origin-delta> <h2c args...>
cell() {
  local name="$1" want="$2" want_delta="$3"
  shift 3
  local before after code delta
  before="$(origin_hits)"
  code="$(python3 "${H2C}" "${ENVOY_PORT}" "$@")"
  sleep 0.3
  after="$(origin_hits)"
  delta=$((after - before))
  if [[ "${code}" == "${want}" && "${delta}" == "${want_delta}" ]]; then
    pass "[${name}] HTTP ${code}, origin +${delta}"
  else
    fail "[${name}] HTTP ${code} (want ${want}), origin +${delta} (want +${want_delta})"
  fi
}

echo "==> h2 trailers body_mode=${BODY_MODE} envoy=${ENVOY_PORT}"
if [[ "${BODY_MODE}" == "NONE" ]]; then
  echo "  SKIP [body-sqli+trailers] NONE does not inspect bodies"
else
  cell body-sqli+trailers 403 0 /search "${FORM[@]}" --data "${SQLI_BODY}" --trailer x-t:1
fi
cell query-sqli+trailers 403 0 "${SQLI_QS}" "${FORM[@]}" --trailer x-t:1
cell benign-body+trailers 200 1 /post "${FORM[@]}" --data "name=alice" --trailer x-t:1
cell benign+trailers 200 1 /post "${FORM[@]}" --trailer x-t:1

if [[ "${PASS}" -ge "${MIN_H2_TRAILER_CHECKS}" ]]; then
  pass "[floor] h2 trailer checks PASS=${PASS} (≥ ${MIN_H2_TRAILER_CHECKS})"
else
  fail "[floor] h2 trailer checks PASS=${PASS} < ${MIN_H2_TRAILER_CHECKS}"
fi

if [[ "${FAIL}" -ne 0 ]]; then
  echo "H2 TRAILERS FAILED body_mode=${BODY_MODE} PASS=${PASS}"
  exit 1
fi
echo "H2 TRAILERS PASSED body_mode=${BODY_MODE} checks=${PASS}"
