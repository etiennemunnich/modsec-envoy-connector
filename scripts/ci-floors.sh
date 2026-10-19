#!/usr/bin/env bash
# Per-suite floors for scripts/ci-live-e2e.sh. Source, do not execute.
# scripts/test-ci-scripts.sh sources this same file, so the tests exercise the
# real floors rather than copies.
#
# A suite passes only if it exits 0 AND its summary line reports at least the
# floor of passing checks. SKIP lines never count. Every MIN_* can be
# overridden from the environment.
#
# Measured at the pins (2026-10-12): fail-modes 59 PASS (53 under
# FULL_DUPLEX_STREAMED, whose three hang cells per protocol are SKIP); 2 fewer
# when the engine refuses to boot with an unwritable audit log (class 6 then
# records 3 checks per protocol, not 4). fail-closed 13 PASS (11 under
# FULL_DUPLEX_STREAMED: the hang drill and its restore are SKIP). go-ftw demo
# 8, CRS body ids 118, CRS full 5231.

if [[ "${BODY_MODE:-BUFFERED}" == "FULL_DUPLEX_STREAMED" ]]; then
  MIN_FAIL_MODES="${MIN_FAIL_MODES:-51}"
  MIN_FAIL_CLOSED="${MIN_FAIL_CLOSED:-11}"
else
  MIN_FAIL_MODES="${MIN_FAIL_MODES:-57}"
  MIN_FAIL_CLOSED="${MIN_FAIL_CLOSED:-13}"
fi
MIN_FTW_DEMO="${MIN_FTW_DEMO:-8}"
MIN_FTW_BODY_PIN="${MIN_FTW_BODY_PIN:-100}"
MIN_FTW_BODY_ABS="${MIN_FTW_BODY_ABS:-50}"
MIN_FTW_FULL="${MIN_FTW_FULL:-5000}"
MIN_SMOKE_BODY="${MIN_SMOKE_BODY:-5}"
MIN_SMOKE_HEADER="${MIN_SMOKE_HEADER:-5}"
MIN_TRAILERS="${MIN_TRAILERS:-5}"
# h2-trailers: 4 cells; NONE skips the body cell (bodies are not inspected).
if [[ "${BODY_MODE:-BUFFERED}" == "NONE" ]]; then
  MIN_H2_TRAILERS="${MIN_H2_TRAILERS:-3}"
else
  MIN_H2_TRAILERS="${MIN_H2_TRAILERS:-4}"
fi
# hop-trace CI cell: status, Envoy log, connector phases, origin untouched.
MIN_HOP_TRACE="${MIN_HOP_TRACE:-4}"
MIN_GRPC_HOP="${MIN_GRPC_HOP:-6}"
MIN_WS_FRAMES="${MIN_WS_FRAMES:-6}"
MIN_PARTIAL_HONESTY="${MIN_PARTIAL_HONESTY:-3}"
MIN_BUFFERED_OVERSIZE="${MIN_BUFFERED_OVERSIZE:-4}"
MIN_CONNECT_ASSERT="${MIN_CONNECT_ASSERT:-1}"
# h3-probe: lab-only QUIC suite (demo script; not on every PR).
# 9 hop/fail-closed + 5 Cookie crumb cells.
MIN_H3_CHECKS="${MIN_H3_CHECKS:-14}"
# cookie-protocols: H1+H2 (4 each) + H3 (5 incl. empty crumb) = 13.
MIN_COOKIE_PROTOCOLS="${MIN_COOKIE_PROTOCOLS:-13}"
# MIN_FTW_BODY: set by ci-live-e2e.sh from the installed CRS tag (version-aware);
# floor() falls back to MIN_FTW_BODY_PIN.

# Suite summary lines for the report table. Must match mid-line suffixes
# (e.g. "SMOKE PASSED body_mode=BUFFERED body_checks=6"), not only EOL PASSED.
# shellcheck disable=SC2034 # read by ci-live-e2e.sh and test-ci-scripts.sh
SUMMARY_RE='summary: PASS=|^(demo tests|CRS body ids|CRS full):|\bPASSED\b|\bFAILED\b|HOP-TRACE|TRAILERS|PARTIAL-HONESTY|BUFFERED-OVERSIZE|CONNECT-ASSERT|H3 PROBE|COOKIE-PROTOCOLS'

# ftw_success <log> <line prefix> — go-ftw success= count on that summary line (0 if absent).
ftw_success() {
  local n
  n="$(grep -E "^$2: +success=[0-9]+" "$1" | tail -1 | sed -E 's/.*success=([0-9]+).*/\1/' || true)"
  echo "${n:-0}"
}

# marker_count <log> <PASSED marker> <key> <min> — the marker line must exist
# and carry key=N with N >= min.
marker_count() {
  local n
  grep -qE "\\b$2\\b" "$1" || { echo "missing $2"; return 1; }
  n="$(grep -E "\\b$2\\b" "$1" | grep -Eo "$3=[0-9]+" | tail -1 | cut -d= -f2 || true)"
  [[ "${n:-0}" -ge "$4" ]] || { echo "$3=${n:-0} < $4"; return 1; }
}

# floor <suite> <log> — prints a reason and returns 1 when the suite ran fewer
# checks than its floor. An unknown suite has no floor and fails.
floor() {
  local n
  case "$1" in
    smoke)
      grep -qE '\bSMOKE PASSED\b' "$2" || { echo "missing SMOKE PASSED"; return 1; }
      if grep -qE 'header_checks=[0-9]+' "$2"; then
        # NONE (headers-only): floor on header denials; body_checks may be 0.
        n="$(grep -Eo 'header_checks=[0-9]+' "$2" | tail -1 | cut -d= -f2 || true)"
        [[ "${n:-0}" -ge "${MIN_SMOKE_HEADER}" ]] || { echo "header_checks=${n:-0} < ${MIN_SMOKE_HEADER}"; return 1; }
      else
        n="$(grep -Eo 'body_checks=[0-9]+' "$2" | tail -1 | cut -d= -f2 || true)"
        [[ "${n:-0}" -ge "${MIN_SMOKE_BODY}" ]] || { echo "body_checks=${n:-0} < ${MIN_SMOKE_BODY}"; return 1; }
      fi
      ;;
    fail-closed) marker_count "$2" 'FAIL-CLOSED DRILLS PASSED' checks "${MIN_FAIL_CLOSED}" || return 1 ;;
    fail-modes)
      grep -qE '\bFAIL-MODES PASSED\b' "$2" || { echo "missing FAIL-MODES PASSED"; return 1; }
      n="$(grep -Eo 'summary: PASS=[0-9]+' "$2" | tail -1 | cut -d= -f2 || true)"
      [[ "${n:-0}" -ge "${MIN_FAIL_MODES}" ]] || { echo "PASS=${n:-0} < ${MIN_FAIL_MODES}"; return 1; }
      ;;
    hop-trace) marker_count "$2" 'HOP-TRACE OK' checks "${MIN_HOP_TRACE}" || return 1 ;;
    trailers) marker_count "$2" 'TRAILERS PASSED' trailer_checks "${MIN_TRAILERS}" || return 1 ;;
    h2-trailers) marker_count "$2" 'H2 TRAILERS PASSED' checks "${MIN_H2_TRAILERS}" || return 1 ;;
    hop-trace-grpc) marker_count "$2" 'HOP-TRACE-GRPC PASSED' checks "${MIN_GRPC_HOP}" || return 1 ;;
    hop-trace-ws-frames) marker_count "$2" 'HOP-TRACE-WS-FRAMES PASSED' checks "${MIN_WS_FRAMES}" || return 1 ;;
    partial-honesty) marker_count "$2" 'PARTIAL-HONESTY PASSED' checks "${MIN_PARTIAL_HONESTY}" || return 1 ;;
    buffered-oversize) marker_count "$2" 'BUFFERED-OVERSIZE PASSED' checks "${MIN_BUFFERED_OVERSIZE}" || return 1 ;;
    connect-assert) marker_count "$2" 'CONNECT-ASSERT PASSED' checks "${MIN_CONNECT_ASSERT}" || return 1 ;;
    h3-probe) marker_count "$2" 'H3 PROBE PASSED' checks "${MIN_H3_CHECKS}" || return 1 ;;
    cookie-protocols) marker_count "$2" 'COOKIE-PROTOCOLS PASSED' checks "${MIN_COOKIE_PROTOCOLS}" || return 1 ;;
    go-ftw-smoke)
      n="$(ftw_success "$2" 'demo tests')"
      [[ "${n}" -ge "${MIN_FTW_DEMO}" ]] || { echo "demo tests success=${n} < ${MIN_FTW_DEMO}"; return 1; }
      n="$(ftw_success "$2" 'CRS body ids')"
      [[ "${n}" -ge "${MIN_FTW_BODY:-${MIN_FTW_BODY_PIN}}" ]] || { echo "CRS body ids success=${n} < ${MIN_FTW_BODY:-${MIN_FTW_BODY_PIN}}"; return 1; }
      ;;
    go-ftw-body)
      n="$(ftw_success "$2" 'CRS body ids')"
      [[ "${n}" -ge "${MIN_FTW_BODY:-${MIN_FTW_BODY_PIN}}" ]] || { echo "CRS body ids success=${n} < ${MIN_FTW_BODY:-${MIN_FTW_BODY_PIN}}"; return 1; }
      ;;
    go-ftw-full)
      n="$(ftw_success "$2" 'CRS full')"
      [[ "${n}" -ge "${MIN_FTW_FULL}" ]] || { echo "CRS full success=${n} < ${MIN_FTW_FULL}"; return 1; }
      ;;
    *) echo "no floor defined for suite '$1'"; return 1 ;;
  esac
  return 0
}
