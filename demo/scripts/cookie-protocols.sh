#!/usr/bin/env bash
# Cookie / multi-Cookie (crumb) CRS across HTTP/1.1, HTTP/2, and lab HTTP/3.
#
# Locks Envoy → ext_proc → libmodsecurity + CRS behavior when the client sends
# several Cookie field lines on one request (browser H2/H3 crumbling; curl -H
# twice on H1). Envoy H2/H3 coalesce with "; " before ModSec; H1 often keeps
# separate Cookie headers — both must still deny XSS in any crumb.
#
#   ./demo/scripts/cookie-protocols.sh              # h1 + h2 + h3
#   ./demo/scripts/cookie-protocols.sh --proto h1
#   ./demo/scripts/cookie-protocols.sh --proto h2,h3
#
# Requires demo stack (attaches or starts BODY_MODE=NONE). H3 needs aioquic
# (`pip install aioquic`) and uses demo/envoy/envoy-h3.yaml (lab only).
#
# Not product H3 WAF support. Not go-ftw. failure_mode_allow stays false.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=h3-lib.sh
source "$(dirname "$0")/h3-lib.sh"

PROTOS="h1 h2 h3"
# Floor: 4 core cells × 3 protos = 12; H3 adds optional empty-cookie cell (+1).
MIN_COOKIE_PROTOCOLS="${MIN_COOKIE_PROTOCOLS:-13}"
H3_STARTED=0
FAIL=0
PASS=0

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
  echo "usage: $0 [--proto h1|h2|h3|LIST|all]" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --proto)
      case "$2" in
        all) PROTOS="h1 h2 h3" ;;
        h1 | h2 | h3) PROTOS="$2" ;;
        *)
          PROTOS="$(echo "$2" | tr ',+' '  ')"
          for p in ${PROTOS}; do
            case "$p" in h1 | h2 | h3) ;; *)
              echo "unsupported proto in --proto: $p (h1|h2|h3|all)" >&2
              exit 2
              ;;
            esac
          done
          ;;
      esac
      shift 2
      ;;
    -h | --help) usage ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

pass() { echo "  PASS $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL $*"; FAIL=$((FAIL + 1)); }

need_h3=0
for p in ${PROTOS}; do
  [[ "$p" == h3 ]] && need_h3=1
done

if [[ "${need_h3}" -eq 1 ]]; then
  h3_bring_up
  H3_STARTED=1
else
  if ! curl -sf "${METRICS}/healthz" >/dev/null \
    || ! curl -sf "http://127.0.0.1:${ORIGIN_PORT}/" >/dev/null; then
    echo "==> starting BODY_MODE=NONE demo stack for cookie suite"
    BODY_MODE=NONE "${DEMO}/scripts/up.sh"
  fi
fi

wait_http "${BASE}/" 50 \
  || { echo "TCP demo not up at ${BASE}" >&2; exit 2; }
grep -q 'failure_mode_allow: false' "${ENVOY_CFG}" \
  || { echo "${ENVOY_CFG} must set failure_mode_allow: false" >&2; exit 2; }

XSS='theme=<script>alert(1)</script>'

# H1/H2 via curl; H3 via aioquic (h3_capture).
h12_code() {
  local proto="$1"
  shift
  local flag
  if [[ "${proto}" == h2 ]]; then
    flag="--http2-prior-knowledge"
  else
    flag="--http1.1"
  fi
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${flag}" "$@" || echo "000"
}

expect_h12() {
  local proto="$1" name="$2" want="$3" want_delta="$4"
  shift 4
  local before after got delta
  before="$(origin_hits)"
  got="$(h12_code "${proto}" "$@")"
  sleep 0.1
  after="$(origin_hits)"
  delta=$((after - before))
  if [[ "${got}" == "${want}" && "${delta}" == "${want_delta}" ]]; then
    pass "[${proto}/${name}] HTTP ${got}, origin +${delta}"
  else
    fail "[${proto}/${name}] HTTP ${got:-?} (want ${want}), origin +${delta} (want +${want_delta})"
  fi
}

expect_h3() {
  local name="$1" want="$2" want_delta="$3"
  shift 3
  local before after code delta
  before="$(origin_hits)"
  h3_capture "$@"
  sleep 0.1
  after="$(origin_hits)"
  delta=$((after - before))
  code="$(h3_status_of "${H3_LAST_OUT}")"
  if [[ -z "${code}" ]]; then
    fail "[h3/${name}] no STATUS (client rc=${H3_LAST_RC})"
    echo "${H3_LAST_OUT}" | sed 's/^/    /'
    return 0
  fi
  if [[ "${code}" == "${want}" && "${delta}" == "${want_delta}" ]]; then
    pass "[h3/${name}] HTTP ${code}, origin +${delta}"
  else
    fail "[h3/${name}] HTTP ${code} (want ${want}), origin +${delta} (want +${want_delta})"
    echo "${H3_LAST_OUT}" | sed 's/^/    /'
  fi
}

run_cookie_h12() {
  local proto="$1"
  echo "==> PROTO=${proto} Cookie crumbs (TCP Envoy :${ENVOY_PORT})"
  expect_h12 "${proto}" "benign-crumbs" 200 1 \
    -H 'cookie: session=ok' -H 'cookie: theme=dark' "${BASE}/"
  expect_h12 "${proto}" "attack-2nd-crumb" 403 0 \
    -H 'cookie: session=ok' -H "cookie: ${XSS}" "${BASE}/"
  expect_h12 "${proto}" "attack-1st-crumb" 403 0 \
    -H "cookie: ${XSS}" -H 'cookie: session=ok' "${BASE}/"
  expect_h12 "${proto}" "joined-xss" 403 0 \
    -H "cookie: session=ok; ${XSS}" "${BASE}/"
}

run_cookie_h3() {
  echo "==> PROTO=h3 Cookie crumbs (QUIC Envoy :${H3_PORT}, lab only)"
  expect_h3 "benign-crumbs" 200 1 \
    --path / -H 'cookie: session=ok' -H 'cookie: theme=dark'
  expect_h3 "attack-2nd-crumb" 403 0 \
    --path / -H 'cookie: session=ok' -H "cookie: ${XSS}"
  expect_h3 "attack-1st-crumb" 403 0 \
    --path / -H "cookie: ${XSS}" -H 'cookie: session=ok'
  expect_h3 "joined-xss" 403 0 \
    --path / -H "cookie: session=ok; ${XSS}"
  # Envoy H3 drops empty cookie field lines; remaining benign crumb → 200.
  expect_h3 "empty-crumb-dropped" 200 1 \
    --path / -H 'cookie: session=ok' -H 'cookie:'
}

echo "==> cookie-protocols Envoy $(envoy --version 2>&1 | grep -o '1\.[0-9]*\.[0-9]*' | head -1) protos=[${PROTOS}]"
echo "    locks multi-Cookie / crumb CRS; not product H3 WAF support"

for PROTO in ${PROTOS}; do
  case "${PROTO}" in
    h1 | h2) run_cookie_h12 "${PROTO}" ;;
    h3) run_cookie_h3 ;;
  esac
done

if [[ "${H3_STARTED}" -eq 1 ]]; then
  if [[ "${H3_PROBE_KEEP:-0}" == "1" ]]; then
    echo "==> H3 Envoy still up (UDP :${H3_PORT})"
  else
    h3_stop_envoy
    echo "==> H3 Envoy stopped"
  fi
fi

if [[ "${FAIL}" -ne 0 ]]; then
  echo "COOKIE-PROTOCOLS FAILED checks_failed=${FAIL} pass=${PASS}"
  exit 1
fi
if [[ "${PASS}" -lt "${MIN_COOKIE_PROTOCOLS}" ]]; then
  # When running a subset of protos, lower the floor proportionally.
  local_min="${MIN_COOKIE_PROTOCOLS}"
  case "${PROTOS}" in
    "h1" | "h2") local_min=4 ;;
    "h3") local_min=5 ;;
    "h1 h2" | "h2 h1") local_min=8 ;;
    "h1 h3" | "h3 h1" | "h2 h3" | "h3 h2") local_min=9 ;;
  esac
  if [[ "${PASS}" -lt "${local_min}" ]]; then
    echo "COOKIE-PROTOCOLS FAILED pass=${PASS} < floor=${local_min} (full-run floor ${MIN_COOKIE_PROTOCOLS})"
    exit 1
  fi
fi
echo "COOKIE-PROTOCOLS PASSED checks=${PASS} (Envoy Cookie coalesce / multi-Cookie CRS; lab H3 if included)"
