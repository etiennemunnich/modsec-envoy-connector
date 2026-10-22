#!/usr/bin/env bash
# HTTP/2 trailer EOS drill for DEPLOY=dm (proves on_request_trailers finishes
# ModSec body). Same cells as h2-trailers.sh with DM stream_chunks honesty:
# body-sqli may hit origin (+0|+1) under forward-before-deny; query-sqli must
# still be phase-1 deny with origin +0.
#
#   DEPLOY=dm ./demo/scripts/up.sh && DEPLOY=dm ./demo/scripts/h2-trailers-dm.sh
#   DEPLOY=dm BODY_MODE=STREAMED ./demo/scripts/up.sh && DEPLOY=dm ./demo/scripts/h2-trailers-dm.sh
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

if [[ "${DEPLOY}" != "dm" ]]; then
  echo "h2-trailers-dm.sh requires DEPLOY=dm (got '${DEPLOY}')" >&2
  exit 2
fi

H2C="${DEMO}/scripts/h2c.py"
FAIL=0
PASS=0
if [[ "${BODY_MODE}" == "NONE" ]]; then
  MIN_H2_TRAILER_CHECKS="${MIN_H2_TRAILER_CHECKS:-3}"
else
  MIN_H2_TRAILER_CHECKS="${MIN_H2_TRAILER_CHECKS:-4}"
fi
OUT_DIR="${RUN}/h2-trailers-dm"
ART="${ART:-/opt/cursor/artifacts/dm-private-validate}"
mkdir -p "${OUT_DIR}" "${ART}/h2-trailers"
TRANSCRIPT="${OUT_DIR}/$(date -u +%Y%m%dT%H%M%SZ)-${BODY_MODE}.txt"
exec > >(tee "${TRANSCRIPT}" "${ART}/h2-trailers/dm-${BODY_MODE}.log") 2>&1

pass() { echo "  PASS $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL $*"; FAIL=1; }

wait_http "${BASE}/" 50 || { echo "demo not up at ${BASE}" >&2; exit 2; }

FORM=(--header "content-type:application/x-www-form-urlencoded")
SQLI_BODY="q=1' UNION SELECT username,password FROM users--"
SQLI_QS="/search?q=1%27%20UNION%20SELECT%20username,password%20FROM%20users--"

# Settle so a prior cell's delayed origin hit cannot bleed into the next before=.
settle() { sleep 0.5; }

# cell <name> <want-status> <want-delta-or-OR> <h2c args...>
# want-delta-or-OR: "0" | "1" | "0|1"
cell() {
  local name="$1" want="$2" want_delta="$3"
  shift 3
  local before after code delta ok=0
  settle
  before="$(origin_hits)"
  code="$(python3 "${H2C}" "${ENVOY_PORT}" "$@")"
  settle
  after="$(origin_hits)"
  delta=$((after - before))
  if [[ "${code}" == "${want}" ]]; then
    case "${want_delta}" in
      "0|1") [[ "${delta}" == "0" || "${delta}" == "1" ]] && ok=1 ;;
      *) [[ "${delta}" == "${want_delta}" ]] && ok=1 ;;
    esac
  fi
  if [[ "${ok}" -eq 1 ]]; then
    pass "[${name}] HTTP ${code}, origin +${delta}"
  else
    fail "[${name}] HTTP ${code} (want ${want}), origin +${delta} (want ${want_delta})"
  fi
}

echo "==> h2-trailers-dm body_mode=${BODY_MODE} body_policy=${DM_BODY_POLICY} envoy=${ENVOY_PORT}"

if [[ "${BODY_MODE}" == "NONE" ]]; then
  echo "  SKIP [body-sqli+trailers] NONE does not inspect bodies"
else
  # Hold policies: deny before origin (+0). stream_chunks: forward-before-deny (+0|1).
  body_delta="0"
  if [[ "${BODY_MODE}" == "STREAMED" ]]; then
    body_delta="0|1"
  fi
  cell body-sqli+trailers 403 "${body_delta}" /search "${FORM[@]}" --data "${SQLI_BODY}" --trailer x-t:1
fi

# CRS SQLi on ARGS often fires at phase 2 (anomaly @ trailer/body EOS), not phase 1.
# Hold policies: headers StopIteration → deny before origin (+0).
# stream_chunks: headers Continue → origin may see the request before trailer EOS
# finishes phase 2 (+0|1). Trailers still finish ModSec (client 403).
query_delta="0"
if [[ "${BODY_MODE}" == "STREAMED" ]]; then
  query_delta="0|1"
fi
cell query-sqli+trailers 403 "${query_delta}" "${SQLI_QS}" "${FORM[@]}" --trailer x-t:1
cell benign-body+trailers 200 1 /post "${FORM[@]}" --data "name=alice" --trailer x-t:1
cell benign+trailers 200 1 /post "${FORM[@]}" --trailer x-t:1

if [[ "${PASS}" -ge "${MIN_H2_TRAILER_CHECKS}" ]]; then
  pass "[floor] h2 trailer checks PASS=${PASS} (≥ ${MIN_H2_TRAILER_CHECKS})"
else
  fail "[floor] h2 trailer checks PASS=${PASS} < ${MIN_H2_TRAILER_CHECKS}"
fi

if [[ "${FAIL}" -ne 0 ]]; then
  echo "H2-TRAILERS-DM FAILED body_mode=${BODY_MODE} PASS=${PASS}"
  exit 1
fi
echo "H2-TRAILERS-DM PASSED body_mode=${BODY_MODE} checks=${PASS}"
