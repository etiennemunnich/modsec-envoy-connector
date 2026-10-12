#!/usr/bin/env bash
# Offline tests for the CI helper scripts (run by ci.yml pin-check). No network,
# no GitHub token: ci-report.sh reads fixture jobs, ci-changes.sh and
# check-workflows.sh run against throwaway repos.
#
#   ./scripts/test-ci-scripts.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fails=0
check() { # check <name> <want> <got>
  if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fails=$((fails + 1)); fi
}

# --- ci-report.sh verdicts -------------------------------------------------
jobs() { # jobs <conclusion...> -> fixture path
  local f="${TMP}/jobs-$*.json" c
  f="${f// /_}"
  { echo '{"jobs":[{"name":"report","conclusion":null,"status":"in_progress","labels":[]}'
    for c in "$@"; do
      echo ",{\"name\":\"e2e (${c})\",\"conclusion\":\"${c}\",\"labels\":[\"ubuntu-24.04\"],\"started_at\":null,\"completed_at\":null}"
    done
    echo ']}'
  } >"${f}"
  echo "${f}"
}
verdict() { CI_REPORT_JOBS_JSON="$1" "${ROOT}/scripts/ci-report.sh" --verdict-only "${@:2}" | tail -1; }

check "ci-report: all success"            pass "$(verdict "$(jobs success success)")"
check "ci-report: one failure"            fail "$(verdict "$(jobs success failure)")"
check "ci-report: one cancelled"          fail "$(verdict "$(jobs success cancelled)")"
check "ci-report: only skipped"           fail "$(verdict "$(jobs skipped skipped)")"
check "ci-report: skipped + success"      fail "$(verdict "$(jobs success skipped)")"
check "ci-report: skipped allowed"        pass "$(verdict "$(jobs success skipped)" --allow-skipped)"
check "ci-report: only skipped, allowed"  fail "$(verdict "$(jobs skipped)" --allow-skipped)"
check "ci-report: no jobs besides report" fail "$(verdict "$(jobs)")"

# --- ci-changes.sh docs-only detection ------------------------------------
repo="${TMP}/repo"
mkdir -p "${repo}/scripts" "${repo}/docs" "${repo}/src"
cp "${ROOT}/scripts/ci-changes.sh" "${repo}/scripts/"
(
  cd "${repo}"
  git init -q && git config user.email t@t && git config user.name t
  echo a >README.md && echo a >docs/x.md && echo a >src/lib.rs && echo a >versions.lock.md
  git add -A && git commit -qm base
)
docs_only() { # docs_only <files to touch...>
  local base f
  base="$(git -C "${repo}" rev-parse HEAD)"
  for f in "$@"; do echo "$RANDOM" >>"${repo}/${f}"; done
  git -C "${repo}" commit -qam change
  BASE="${base}" HEAD="$(git -C "${repo}" rev-parse HEAD)" "${repo}/scripts/ci-changes.sh" | tail -1 | cut -d' ' -f1
}
check "ci-changes: docs/ + README"        docs_only=true "$(docs_only docs/x.md README.md)"
check "ci-changes: code"                  docs_only=false "$(docs_only src/lib.rs)"
check "ci-changes: versions.lock.md"      docs_only=false "$(docs_only versions.lock.md docs/x.md)"
check "ci-changes: no base"               docs_only=false "$(BASE='' "${repo}/scripts/ci-changes.sh" | tail -1 | cut -d' ' -f1)"
check "ci-changes: all-zero base"         docs_only=false "$(BASE=0000000000000000000000000000000000000000 "${repo}/scripts/ci-changes.sh" | tail -1 | cut -d' ' -f1)"

# --- check-workflows.sh rejects each rule ---------------------------------
wf() { # wf <yaml line> -> exit code of check-workflows.sh on a one-job workflow
  local d="${TMP}/wf-${RANDOM}"
  mkdir -p "${d}/.github/workflows" "${d}/.github/actions/x" "${d}/scripts"
  cp "${ROOT}/scripts/check-workflows.sh" "${d}/scripts/"
  echo 'runs: { using: composite, steps: [] }' >"${d}/.github/actions/x/action.yml"
  printf 'on: push\njobs:\n  j:\n    runs-on: ubuntu-24.04\n    steps:\n%s\n' "$1" >"${d}/.github/workflows/w.yml"
  "${d}/scripts/check-workflows.sh" >/dev/null 2>&1 && echo 0 || echo 1
}
good='      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false'
check "check-workflows: SHA pin + no creds" 0 "$(wf "${good}")"
check "check-workflows: tag ref"            1 "$(wf '      - uses: actions/checkout@v4')"
check "check-workflows: branch ref"         1 "$(wf '      - uses: dtolnay/rust-toolchain@stable')"
check "check-workflows: SHA, no comment"    1 "$(wf '      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1')"
check "check-workflows: ubuntu-latest"      1 "$(wf "${good}
    runs-on: ubuntu-latest")"
check "check-workflows: always()"           1 "$(wf "${good}
    if: always()")"
check "check-workflows: checkout keeps creds" 1 "$(wf '      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - run: true')"
check "check-workflows: checkout, last step"  1 "$(wf '      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          fetch-depth: 0')"

# Cron presence for product schedule workflows (skip when files absent — covered above).
cron_neg() {
  local d="${TMP}/cron-neg" rc
  mkdir -p "${d}/.github/workflows" "${d}/.github/actions/x" "${d}/scripts"
  cp "${ROOT}/scripts/check-workflows.sh" "${d}/scripts/"
  echo 'runs: { using: composite, steps: [] }' >"${d}/.github/actions/x/action.yml"
  # Minimal valid job so other rules pass; omit schedule cron on purpose.
  cat >"${d}/.github/workflows/stable-window.yml" <<'YAML'
on:
  workflow_dispatch:
jobs:
  j:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
YAML
  cat >"${d}/.github/workflows/crs-full.yml" <<'YAML'
on:
  schedule:
    - cron: "41 3 7 * *"
  workflow_dispatch:
jobs:
  j:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
YAML
  "${d}/scripts/check-workflows.sh" >/dev/null 2>&1 && rc=0 || rc=1
  echo "${rc}"
}
check "check-workflows: stable-window missing schedule cron (neg)" 1 "$(cron_neg)"

# --- ci-live-e2e floors: the real floor() and SUMMARY_RE from ci-floors.sh ---
# floor_ok <body_mode> <suite> <log line...> -> 0 when the floor holds, 1 when not.
floor_ok() {
  local mode="$1" suite="$2" log="${TMP}/floor-${RANDOM}.log"
  shift 2
  printf '%s\n' "$@" >"${log}"
  (
    unset "${!MIN_@}"
    BODY_MODE="${mode}"
    # shellcheck source=ci-floors.sh
    source "${ROOT}/scripts/ci-floors.sh"
    floor "${suite}" "${log}" >/dev/null
  ) && echo 0 || echo 1
}
summary_hits() { # summary_hits <line> -> how many SUMMARY_RE matches
  (
    # shellcheck source=ci-floors.sh
    source "${ROOT}/scripts/ci-floors.sh"
    printf '%s\n' "$1" | grep -cE "${SUMMARY_RE}" || true
  )
}
check "floor: smoke BUFFERED body_checks=6"            0 "$(floor_ok BUFFERED smoke 'SMOKE PASSED body_mode=BUFFERED body_checks=6')"
check "floor: smoke STREAMED body_checks=7"            0 "$(floor_ok STREAMED smoke 'SMOKE PASSED body_mode=STREAMED body_checks=7')"
check "floor: smoke NONE header_checks=5"              0 "$(floor_ok NONE smoke 'SMOKE PASSED body_mode=NONE body_checks=0 header_checks=5')"
check "floor: smoke NONE header_checks=4 (neg)"        1 "$(floor_ok NONE smoke 'SMOKE PASSED body_mode=NONE body_checks=0 header_checks=4')"
check "floor: smoke body_checks=4 (neg)"               1 "$(floor_ok BUFFERED smoke 'SMOKE PASSED body_mode=BUFFERED body_checks=4')"
check "floor: smoke FAILED (neg)"                      1 "$(floor_ok BUFFERED smoke 'SMOKE FAILED body_mode=BUFFERED')"
check "floor: smoke count without PASSED (neg)"        1 "$(floor_ok BUFFERED smoke 'body_checks=99')"
check "floor: fail-closed 13"                          0 "$(floor_ok BUFFERED fail-closed 'FAIL-CLOSED DRILLS PASSED checks=13 skipped=0')"
check "floor: fail-closed 12 (neg)"                    1 "$(floor_ok BUFFERED fail-closed 'FAIL-CLOSED DRILLS PASSED checks=12 skipped=0')"
check "floor: fail-closed FULL_DUPLEX 11"              0 "$(floor_ok FULL_DUPLEX_STREAMED fail-closed 'FAIL-CLOSED DRILLS PASSED checks=11 skipped=1')"
check "floor: fail-closed FULL_DUPLEX 10 (neg)"        1 "$(floor_ok FULL_DUPLEX_STREAMED fail-closed 'FAIL-CLOSED DRILLS PASSED checks=10 skipped=1')"
check "floor: fail-closed old line, no count (neg)"    1 "$(floor_ok BUFFERED fail-closed 'FAIL-CLOSED DRILLS PASSED')"
check "floor: fail-closed count on another line (neg)" 1 "$(floor_ok BUFFERED fail-closed 'checks=99' 'FAIL-CLOSED DRILLS PASSED')"
check "floor: fail-modes 59"                           0 "$(floor_ok BUFFERED fail-modes 'summary: PASS=59 FAIL=0 SKIP=0' 'FAIL-MODES PASSED')"
check "floor: fail-modes 56 (neg)"                     1 "$(floor_ok BUFFERED fail-modes 'summary: PASS=56 FAIL=0 SKIP=0' 'FAIL-MODES PASSED')"
check "floor: fail-modes FULL_DUPLEX 53 + 6 SKIP"      0 "$(floor_ok FULL_DUPLEX_STREAMED fail-modes 'summary: PASS=53 FAIL=0 SKIP=6' 'FAIL-MODES PASSED')"
check "floor: fail-modes FULL_DUPLEX 50 (neg)"         1 "$(floor_ok FULL_DUPLEX_STREAMED fail-modes 'summary: PASS=50 FAIL=0 SKIP=6' 'FAIL-MODES PASSED')"
check "floor: fail-modes without PASSED (neg)"         1 "$(floor_ok BUFFERED fail-modes 'summary: PASS=59 FAIL=1 SKIP=0' 'FAIL-MODES FAILED')"
check "floor: hop-trace OK 4"                          0 "$(floor_ok BUFFERED hop-trace 'HOP-TRACE OK checks=4')"
check "floor: hop-trace OK 3 (neg)"                    1 "$(floor_ok BUFFERED hop-trace 'HOP-TRACE OK checks=3')"
check "floor: hop-trace OK, no count (neg)"            1 "$(floor_ok BUFFERED hop-trace 'HOP-TRACE OK')"
check "floor: hop-trace FAILED (neg)"                  1 "$(floor_ok BUFFERED hop-trace 'HOP-TRACE FAILED')"
check "floor: trailers 6"                              0 "$(floor_ok BUFFERED trailers 'TRAILERS PASSED body_mode=BUFFERED trailer_checks=6 skipped=0')"
check "floor: trailers 4 (neg)"                        1 "$(floor_ok BUFFERED trailers 'TRAILERS PASSED body_mode=BUFFERED trailer_checks=4 skipped=1')"
check "floor: trailers FAILED (neg)"                   1 "$(floor_ok BUFFERED trailers 'TRAILERS FAILED body_mode=BUFFERED PASS=0')"
check "floor: trailers count without PASSED (neg)"     1 "$(floor_ok BUFFERED trailers 'trailer_checks=99')"
check "floor: hop-trace-grpc 13"                       0 "$(floor_ok BUFFERED hop-trace-grpc 'HOP-TRACE-GRPC PASSED checks=13 (headers/path only — not protobuf CRS)')"
check "floor: hop-trace-grpc FAILED (neg)"             1 "$(floor_ok BUFFERED hop-trace-grpc 'HOP-TRACE-GRPC FAILED (9 passed)')"
check "floor: hop-trace-ws-frames 9"                   0 "$(floor_ok BUFFERED hop-trace-ws-frames 'HOP-TRACE-WS-FRAMES PASSED checks=9 (handshake ModSec yes; frame CRS no)')"
check "floor: hop-trace-ws-frames 5 (neg)"             1 "$(floor_ok BUFFERED hop-trace-ws-frames 'HOP-TRACE-WS-FRAMES PASSED checks=5')"
check "floor: partial-honesty 3"                       0 "$(floor_ok BUFFERED_PARTIAL partial-honesty 'PARTIAL-HONESTY PASSED body_mode=BUFFERED_PARTIAL checks=3 soft_limit_bytes=1048576')"
check "floor: partial-honesty 2 (neg)"                 1 "$(floor_ok BUFFERED_PARTIAL partial-honesty 'PARTIAL-HONESTY PASSED body_mode=BUFFERED_PARTIAL checks=2')"
check "floor: buffered-oversize 4"                     0 "$(floor_ok BUFFERED buffered-oversize 'BUFFERED-OVERSIZE PASSED body_mode=BUFFERED checks=4')"
check "floor: buffered-oversize 3 (neg)"               1 "$(floor_ok BUFFERED buffered-oversize 'BUFFERED-OVERSIZE PASSED body_mode=BUFFERED checks=3')"
check "floor: connect-assert 1"                        0 "$(floor_ok BUFFERED connect-assert 'CONNECT-ASSERT PASSED body_mode=BUFFERED checks=1')"
check "floor: connect-assert 0 (neg)"                  1 "$(floor_ok BUFFERED connect-assert 'CONNECT-ASSERT PASSED body_mode=BUFFERED checks=0')"
check "floor: go-ftw-smoke 8 + 118"                    0 "$(floor_ok BUFFERED go-ftw-smoke 'demo tests: success=8 failed=0' 'CRS body ids: success=118 failed=0')"
check "floor: go-ftw-smoke body 99 (neg)"              1 "$(floor_ok BUFFERED go-ftw-smoke 'demo tests: success=8 failed=0' 'CRS body ids: success=99 failed=0')"
check "floor: go-ftw-smoke no demo line (neg)"         1 "$(floor_ok BUFFERED go-ftw-smoke 'CRS body ids: success=118 failed=0')"
check "floor: go-ftw-full 5231"                        0 "$(floor_ok BUFFERED go-ftw-full 'CRS full: success=5231 failed=0')"
check "floor: go-ftw-full 4999 (neg)"                  1 "$(floor_ok BUFFERED go-ftw-full 'CRS full: success=4999 failed=0')"
check "floor: unknown suite has no floor (neg)"        1 "$(floor_ok BUFFERED no-such-suite 'NO-SUCH PASSED checks=99')"
check "summary: SMOKE PASSED with body_mode suffix"    1 "$(summary_hits 'SMOKE PASSED body_mode=BUFFERED body_checks=6')"
check "summary: TRAILERS PASSED"                       1 "$(summary_hits 'TRAILERS PASSED body_mode=BUFFERED trailer_checks=6 skipped=0')"
check "summary: HOP-TRACE-GRPC PASSED"                 1 "$(summary_hits 'HOP-TRACE-GRPC PASSED checks=13')"
check "summary: PARTIAL-HONESTY PASSED"                1 "$(summary_hits 'PARTIAL-HONESTY PASSED checks=3')"
check "summary: fail-modes summary line"               1 "$(summary_hits 'summary: PASS=59 FAIL=0 SKIP=0')"
check "summary: plain PASS line is not a summary"      0 "$(summary_hits '  PASS [baseline] 200')"
# ci-live-e2e.sh must use these floors, and refuse an empty suite list.
grep -q 'source "${ROOT}/scripts/ci-floors.sh"' "${ROOT}/scripts/ci-live-e2e.sh" && ok=0 || ok=1
check "e2e: ci-live-e2e.sh sources ci-floors.sh" 0 "${ok}"
grep -qE '^floor\(\)' "${ROOT}/scripts/ci-live-e2e.sh" && ok=1 || ok=0
check "e2e: no private floor() copy in ci-live-e2e.sh" 0 "${ok}"
out="$(SUITES=' ' "${ROOT}/scripts/ci-live-e2e.sh" 2>&1 || true)"
[[ "${out}" == *"SUITES is empty"* ]] && ok=0 || ok=1
check "e2e: empty SUITES refused before anything starts" 0 "${ok}"

# Thin presence hook for gRPC hop-trace artifacts (no live Envoy).
[[ -x "${ROOT}/demo/scripts/hop-trace-grpc.sh" ]] && ok=0 || ok=1
check "demo: hop-trace-grpc.sh executable" 0 "${ok}"
[[ -f "${ROOT}/demo/envoy/envoy-grpc.yaml" ]] && ok=0 || ok=1
check "demo: envoy-grpc.yaml present" 0 "${ok}"
[[ -f "${ROOT}/demo/grpc-echo/echo.proto" ]] && ok=0 || ok=1
check "demo: grpc-echo proto present" 0 "${ok}"
[[ -f "${ROOT}/demo/rules/demo-grpc.conf" ]] && ok=0 || ok=1
check "demo: demo-grpc.conf present" 0 "${ok}"
grep -q 'failure_mode_allow: false' "${ROOT}/demo/envoy/envoy-grpc.yaml" && ok=0 || ok=1
check "demo: envoy-grpc fail-closed" 0 "${ok}"
grep -q 'request_body_mode: NONE' "${ROOT}/demo/envoy/envoy-grpc.yaml" && ok=0 || ok=1
check "demo: envoy-grpc headers-only bodies" 0 "${ok}"

# Stock HTTP NONE BodySendMode (Envoy default; headers-only product cell).
[[ -f "${ROOT}/demo/envoy/envoy-none.yaml" ]] && ok=0 || ok=1
check "demo: envoy-none.yaml present" 0 "${ok}"
grep -q 'request_body_mode: NONE' "${ROOT}/demo/envoy/envoy-none.yaml" && ok=0 || ok=1
check "demo: envoy-none bodies NONE" 0 "${ok}"
grep -q 'response_body_mode: NONE' "${ROOT}/demo/envoy/envoy-none.yaml" && ok=0 || ok=1
check "demo: envoy-none response bodies NONE" 0 "${ok}"
grep -q 'failure_mode_allow: false' "${ROOT}/demo/envoy/envoy-none.yaml" && ok=0 || ok=1
check "demo: envoy-none fail-closed" 0 "${ok}"
grep -q 'e2e-none' "${ROOT}/.github/workflows/e2e-lab.yml" && ok=0 || ok=1
check "e2e-lab: e2e-none job present" 0 "${ok}"
grep -q 'e2e-buffered-partial' "${ROOT}/.github/workflows/e2e-lab.yml" && ok=0 || ok=1
check "e2e-lab: e2e-buffered-partial job present" 0 "${ok}"
grep -q 'e2e-asymm-req-buf-resp-str' "${ROOT}/.github/workflows/e2e-lab.yml" && ok=0 || ok=1
check "e2e-lab: asymm lab jobs present" 0 "${ok}"
# Product PR cells stay on ci; lab modes must not return to every-PR ci.yml.
grep -qE '^[[:space:]]*e2e-none:' "${ROOT}/.github/workflows/ci.yml" && ok=1 || ok=0
check "ci: e2e-none not on every-PR path" 0 "${ok}"
grep -qE '^[[:space:]]*e2e-buffered-partial:' "${ROOT}/.github/workflows/ci.yml" && ok=1 || ok=0
check "ci: e2e-buffered-partial not on every-PR path" 0 "${ok}"
grep -q 'e2e-full-duplex' "${ROOT}/.github/workflows/ci.yml" && ok=0 || ok=1
check "ci: e2e-full-duplex product cell present" 0 "${ok}"
grep -q 'body_mode: \[BUFFERED, STREAMED, FULL_DUPLEX_STREAMED\]' "${ROOT}/.github/workflows/crs-full.yml" && ok=0 || ok=1
check "crs-full: Envoy full-CRS body_mode matrix" 0 "${ok}"
# ASH commit pin: lock and workflow agree; no movable @vX.Y.Z tag install.
ash_lock="$(grep -E '^ASH_PIN=' "${ROOT}/versions.lock.md" | head -1 | cut -d= -f2 || true)"
ash_wf="$(grep -Eo 'automated-security-helper\.git@[0-9a-f]{40}' "${ROOT}/.github/workflows/ash.yml" | head -1 | grep -Eo '[0-9a-f]{40}$' || true)"
[[ -n "$ash_lock" && "$ash_lock" == "$ash_wf" ]] && ok=0 || ok=1
check "ash: ASH_PIN matches ash.yml commit pin" 0 "${ok}"
grep -qE 'automated-security-helper\.git@v[0-9]' "${ROOT}/.github/workflows/ash.yml" && ok=1 || ok=0
check "ash: no movable tag install" 0 "${ok}"

# Thin presence hook for WS frame-bound artifacts.
[[ -x "${ROOT}/demo/scripts/hop-trace-ws-frames.sh" ]] && ok=0 || ok=1
check "demo: hop-trace-ws-frames.sh executable" 0 "${ok}"
[[ -x "${ROOT}/demo/scripts/ws-echo.py" ]] && ok=0 || ok=1
check "demo: ws-echo.py executable" 0 "${ok}"
[[ -f "${ROOT}/demo/envoy/envoy-ws-headers.yaml" ]] && ok=0 || ok=1
check "demo: envoy-ws-headers.yaml present" 0 "${ok}"
[[ -f "${ROOT}/demo/envoy/envoy-ws-buffered.yaml" ]] && ok=0 || ok=1
check "demo: envoy-ws-buffered.yaml present" 0 "${ok}"
grep -q 'upgrade_type: websocket' "${ROOT}/demo/envoy/envoy-ws-headers.yaml" && ok=0 || ok=1
check "demo: envoy-ws-headers upgrade_configs" 0 "${ok}"
grep -q 'request_body_mode: NONE' "${ROOT}/demo/envoy/envoy-ws-headers.yaml" && ok=0 || ok=1
check "demo: envoy-ws-headers bodies NONE" 0 "${ok}"
grep -q 'request_body_mode: BUFFERED' "${ROOT}/demo/envoy/envoy-ws-buffered.yaml" && ok=0 || ok=1
check "demo: envoy-ws-buffered hang config" 0 "${ok}"
[[ -f "${ROOT}/demo/rules/demo-ws.conf" ]] && ok=0 || ok=1
check "demo: demo-ws.conf present" 0 "${ok}"

# --- one-year matrix policy + cartesian guard (offline) --------------------
[[ -x "${ROOT}/scripts/one-year-matrix.sh" ]] && ok=0 || ok=1
check "one-year: one-year-matrix.sh executable" 0 "${ok}"
[[ -f "${ROOT}/versions.one-year.yaml" ]] && ok=0 || ok=1
check "one-year: versions.one-year.yaml present" 0 "${ok}"
[[ -f "${ROOT}/.github/workflows/stable-one-year.yml" ]] && ok=0 || ok=1
check "one-year: stable-one-year.yml present" 0 "${ok}"
grep -q 'workflow_dispatch:' "${ROOT}/.github/workflows/stable-one-year.yml" && ok=0 || ok=1
check "one-year: stable-one-year is dispatchable" 0 "${ok}"
grep -qE '^[[:space:]]*schedule:' "${ROOT}/.github/workflows/stable-one-year.yml" && ok=1 || ok=0
check "one-year: stable-one-year has no schedule cron" 0 "${ok}"
# Cartesian without --confirm-cartesian must refuse (no network needed).
"${ROOT}/scripts/one-year-matrix.sh" plan --strategy cartesian >/dev/null 2>&1 && ok=1 || ok=0
check "one-year: cartesian without confirm refused" 0 "${ok}"
# Unknown profile must fail before e2e (no network).
out="$("${ROOT}/scripts/one-year-matrix.sh" run --profile nosuch 2>&1 || true)"
echo "${out}" | grep -q "unknown profile" && ok=0 || ok=1
check "one-year: unknown profile refused" 0 "${ok}"


# --- go-ftw body staging + version-aware CRS body floor (offline) ----------
grep -q 'stage_body_tests' "${ROOT}/demo/scripts/go-ftw.sh" && ok=0 || ok=1
check "go-ftw: stages BODY_INCLUDE rule YAML for smoke/body" 0 "${ok}"
grep -q 'MIN_FTW_BODY_PIN' "${ROOT}/scripts/ci-floors.sh" && ok=0 || ok=1
check "e2e: version-aware CRS body floor (MIN_FTW_BODY_PIN)" 0 "${ok}"
ci_ftw="$(sed -n 's/^  GO_FTW_VERSION: "\(.*\)"$/\1/p' "${ROOT}/.github/workflows/live-e2e.yml")"
local_ftw="$(sed -n 's/^GO_FTW_VERSION="${GO_FTW_VERSION:-\(.*\)}"$/\1/p' "${ROOT}/demo/scripts/install-go-ftw.sh")"
check "go-ftw: install-go-ftw.sh pins the CI version (${ci_ftw:-none})" "${ci_ftw:-missing}" "${local_ftw:-unset}"
grep -q 'count_ftw_body_tests' "${ROOT}/scripts/ci-live-e2e.sh" && ok=0 || ok=1
check "e2e: counts BODY_INCLUDE tests for older CRS floors" 0 "${ok}"
grep -q 'ftw_body_floor_pin' "${ROOT}/versions.one-year.yaml" && ok=0 || ok=1
check "one-year: documents ftw_body_floor_pin policy" 0 "${ok}"
grep -q 'status: \[400\]' "${ROOT}/demo/scripts/go-ftw.sh" && ok=0 || ok=1
check "go-ftw: documents CRS v4.23.0 status:[400] parse poison" 0 "${ok}"

# --- Envoy checksums.txt.asc layout (bare name vs /tmp path) ---------------
# shellcheck source=envoy-checksum.sh
source "${ROOT}/scripts/envoy-checksum.sh"
cat >"${TMP}/sums-bare.asc" <<'EOF'
-----BEGIN PGP SIGNED MESSAGE-----
Hash: SHA512
aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  debs.tar.gz
d2f1a9f4f19b7fc064e75b4e52d191754c49a4de1ae2145462c0c7e19a860e1b  envoy-1.39.2-linux-x86_64
8f77e9b08456e4f28689e76441b422436c031895ff00aeda5561bd4d4372c997  envoy-contrib-1.39.2-linux-x86_64
b3d0e9213289f4456413bec2a5b8ed8896765185ab9642da4b2b9b58cc46409c  envoy-1.39.2-linux-aarch_64
EOF
cat >"${TMP}/sums-path.asc" <<'EOF'
-----BEGIN PGP SIGNED MESSAGE-----
Hash: SHA512
002c6e1c69ed0fa0ea381887247cadadfaec9481375fa8d8d2b1731eeabf40b8  /tmp/tmpdauyk7w6/bin/envoy-1.39.1-linux-x86_64
3405ced6147ab5ab9a25491a6c8110bb5e5f958d2936225918576f4b6f380354  /tmp/tmpdauyk7w6/bin/envoy-contrib-1.39.1-linux-x86_64
EOF
check "envoy checksum: bare filename (v1.39.2 layout)" \
  d2f1a9f4f19b7fc064e75b4e52d191754c49a4de1ae2145462c0c7e19a860e1b \
  "$(envoy_checksum_sha256 "${TMP}/sums-bare.asc" envoy-1.39.2-linux-x86_64)"
check "envoy checksum: aarch64 bare filename" \
  b3d0e9213289f4456413bec2a5b8ed8896765185ab9642da4b2b9b58cc46409c \
  "$(envoy_checksum_sha256 "${TMP}/sums-bare.asc" envoy-1.39.2-linux-aarch_64)"
check "envoy checksum: /tmp path suffix (v1.39.1 layout)" \
  002c6e1c69ed0fa0ea381887247cadadfaec9481375fa8d8d2b1731eeabf40b8 \
  "$(envoy_checksum_sha256 "${TMP}/sums-path.asc" envoy-1.39.1-linux-x86_64)"
check "envoy checksum: contrib asset stays distinct" \
  8f77e9b08456e4f28689e76441b422436c031895ff00aeda5561bd4d4372c997 \
  "$(envoy_checksum_sha256 "${TMP}/sums-bare.asc" envoy-contrib-1.39.2-linux-x86_64)"
check "envoy checksum: missing asset" "" \
  "$(envoy_checksum_sha256 "${TMP}/sums-bare.asc" envoy-9.9.9-linux-x86_64)"
grep -q 'envoy_checksum_sha256' "${ROOT}/demo/scripts/install-envoy.sh" && ok=0 || ok=1
check "install-envoy: uses envoy_checksum_sha256" 0 "${ok}"
# The pre-fix matcher required a slash before the asset name, so current
# patch releases (bare filenames) produced an empty digest and a fast fail.
old_envoy_checksum() {
  awk -v a="/$2" '$2 ~ a"$" { print $1; exit }' "$1"
}
check "envoy checksum: old slash matcher misses bare names" "" \
  "$(old_envoy_checksum "${TMP}/sums-bare.asc" envoy-1.39.2-linux-x86_64)"
check "envoy checksum: old slash matcher still hits /tmp paths" \
  002c6e1c69ed0fa0ea381887247cadadfaec9481375fa8d8d2b1731eeabf40b8 \
  "$(old_envoy_checksum "${TMP}/sums-path.asc" envoy-1.39.1-linux-x86_64)"

# --- ci-tested-tree.sh: a main push may skip only a tree a same-repo PR passed
T1=1111111111111111111111111111111111111111
T2=2222222222222222222222222222222222222222
cat >"${TMP}/runs.json" <<JSON
{"workflow_runs":[
 {"html_url":"https://x/fork","head_repository":{"full_name":"someone/fork"},"head_commit":{"tree_id":"${T2}"}},
 {"html_url":"https://x/ours","head_repository":{"full_name":"o/r"},"head_commit":{"tree_id":"${T1}"}}]}
JSON
tested() { GITHUB_OUTPUT='' GITHUB_REPOSITORY=o/r CI_TESTED_RUNS_JSON="${TMP}/runs.json" "$@" "${ROOT}/scripts/ci-tested-tree.sh" | cut -d" " -f1; }
check "tested-tree: same tree, same repo" tested=true "$(tested env TREE=${T1})"
check "tested-tree: a fork's run does not count" tested=false "$(tested env TREE=${T2})"
check "tested-tree: unknown tree" tested=false "$(tested env TREE=3333333333333333333333333333333333333333)"
check "tested-tree: no tree id" tested=false "$(tested env TREE=)"
check "tested-tree: not a tree id" tested=false "$(tested env TREE='x\" or 1')"
check "tested-tree: a re-run runs everything" tested=false "$(tested env TREE=${T1} GITHUB_RUN_ATTEMPT=2)"
printf "not json" >"${TMP}/bad.json"
check "tested-tree: unreadable list" tested=false "$(GITHUB_OUTPUT='' GITHUB_REPOSITORY=o/r CI_TESTED_RUNS_JSON="${TMP}/bad.json" TREE=${T1} "${ROOT}/scripts/ci-tested-tree.sh" | cut -d" " -f1)"

# --- demo port remap (placeholders, not chained sed) -----------------------
# shellcheck source=remap-demo-ports.sh
source "${ROOT}/scripts/remap-demo-ports.sh"
port_count() { grep -c "port_value: $1" "$2" || true; }
cat >"${TMP}/stock-ports.yaml" <<'EOF'
admin: { port_value: 18089 }
listener: { port_value: 18080 }
connector: { port_value: 18081 }
origin: { port_value: 18098 }
EOF
# The pre-fix pipeline. DEMO_PORT_BASE=18081 makes the new listener 18081,
# which the next expression then rewrites to the connector port 18082.
sed \
  -e 's/port_value: 18089/port_value: 18090/g' \
  -e 's/port_value: 18080/port_value: 18081/g' \
  -e 's/port_value: 18081/port_value: 18082/g' \
  -e 's/port_value: 18098/port_value: 18099/g' \
  "${TMP}/stock-ports.yaml" >"${TMP}/chained.yaml"
check "port remap: chained sed collapses 18080→18081→18082" \
  2 "$(port_count 18082 "${TMP}/chained.yaml")"
check "port remap: chained sed leaves no listener 18081" \
  0 "$(port_count 18081 "${TMP}/chained.yaml")"
remap_stock_ports "${TMP}/stock-ports.yaml" "${TMP}/remap-18081.yaml" \
  18090 18081 18082 18099
check "port remap: listener stays 18081" \
  1 "$(port_count 18081 "${TMP}/remap-18081.yaml")"
check "port remap: connector stays 18082" \
  1 "$(port_count 18082 "${TMP}/remap-18081.yaml")"
remap_stock_ports "${TMP}/stock-ports.yaml" "${TMP}/remap-18380.yaml" \
  18389 18380 18381 18398
check "port remap: base 18380 listener" 1 "$(port_count 18380 "${TMP}/remap-18380.yaml")"
check "port remap: base 18380 connector" 1 "$(port_count 18381 "${TMP}/remap-18380.yaml")"
check "port remap: base 18380 admin" 1 "$(port_count 18389 "${TMP}/remap-18380.yaml")"
check "port remap: base 18380 origin" 1 "$(port_count 18398 "${TMP}/remap-18380.yaml")"
lib_cfg="$(
  export DEMO_PORT_BASE=18081 BODY_MODE=BUFFERED
  source "${ROOT}/demo/scripts/lib.sh"
  printf '%s' "${ENVOY_CFG}"
)"
check "port remap: lib.sh DEMO_PORT_BASE=18081 listener 18081" \
  1 "$(port_count 18081 "${lib_cfg}")"
check "port remap: lib.sh DEMO_PORT_BASE=18081 connector 18082" \
  1 "$(port_count 18082 "${lib_cfg}")"
check "port remap: lib.sh DEMO_PORT_BASE=18081 admin 18090" \
  1 "$(port_count 18090 "${lib_cfg}")"
check "port remap: lib.sh DEMO_PORT_BASE=18081 origin 18099" \
  1 "$(port_count 18099 "${lib_cfg}")"
rm -f "${lib_cfg}"
for f in demo/scripts/lib.sh demo/scripts/trailers.sh; do
  grep -q 'remap_stock_ports' "${ROOT}/${f}" && ok=0 || ok=1
  check "port remap: ${f} calls remap_stock_ports" 0 "${ok}"
done


[[ "${fails}" -eq 0 ]] || { echo "test-ci-scripts: ${fails} failed" >&2; exit 1; }
echo "test-ci-scripts OK"
