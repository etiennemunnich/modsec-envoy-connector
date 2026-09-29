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

# --- ci-live-e2e smoke summary + floor (body_mode suffix regression) --------
# Keep SUMMARY_RE / smoke floor rules in sync with scripts/ci-live-e2e.sh.
SUMMARY_RE='summary: PASS=|^(demo tests|CRS body ids|CRS full):|\bPASSED\b|\bFAILED\b|HOP-TRACE|TRAILERS'
smoke_floor() { # smoke_floor <log> -> 0/1 (mirrors ci-live-e2e.sh floor smoke)
  local n
  grep -qE '\bSMOKE PASSED\b' "$1" || { echo "missing SMOKE PASSED"; return 1; }
  n="$(grep -Eo 'body_checks=[0-9]+' "$1" | tail -1 | cut -d= -f2 || true)"
  [[ "${n:-0}" -ge 5 ]] || { echo "body_checks=${n:-0} < 5"; return 1; }
  return 0
}
trailers_floor() { # mirrors ci-live-e2e.sh floor trailers
  local n
  grep -qE '\bTRAILERS PASSED\b' "$1" || { echo "missing TRAILERS PASSED"; return 1; }
  n="$(grep -Eo 'trailer_checks=[0-9]+' "$1" | tail -1 | cut -d= -f2 || true)"
  [[ "${n:-0}" -ge 5 ]] || { echo "trailer_checks=${n:-0} < 5"; return 1; }
  return 0
}
printf '%s\n' 'SMOKE PASSED body_mode=BUFFERED body_checks=6' >"${TMP}/smoke-ok.log"
printf '%s\n' 'SMOKE PASSED body_mode=STREAMED body_checks=7' >"${TMP}/smoke-streamed.log"
printf '%s\n' 'SMOKE FAILED body_mode=BUFFERED' >"${TMP}/smoke-failed.log"
printf '%s\n' 'body_checks=99' >"${TMP}/smoke-fake.log" # floor number without PASSED
printf '%s\n' 'TRAILERS PASSED body_mode=BUFFERED trailer_checks=5' >"${TMP}/trailers-ok.log"
printf '%s\n' 'TRAILERS FAILED body_mode=BUFFERED PASS=0' >"${TMP}/trailers-failed.log"
printf '%s\n' 'trailer_checks=99' >"${TMP}/trailers-fake.log"
check "e2e summary: PASSED with body_mode (BUFFERED)" 1 \
  "$(grep -cE "${SUMMARY_RE}" "${TMP}/smoke-ok.log")"
check "e2e summary: PASSED with body_mode (STREAMED)" 1 \
  "$(grep -cE "${SUMMARY_RE}" "${TMP}/smoke-streamed.log")"
check "e2e summary: TRAILERS PASSED matches SUMMARY_RE" 1 \
  "$(grep -cE "${SUMMARY_RE}" "${TMP}/trailers-ok.log")"
check "e2e summary: old PASSED\$ misses body_mode suffix" 0 \
  "$(grep -cE 'PASSED$' "${TMP}/smoke-ok.log" || true)"
smoke_floor "${TMP}/smoke-ok.log" >/dev/null && ok=0 || ok=1
check "e2e floor: real SMOKE PASSED + body_checks passes" 0 "${ok}"
smoke_floor "${TMP}/smoke-streamed.log" >/dev/null && ok=0 || ok=1
check "e2e floor: STREAMED SMOKE PASSED passes" 0 "${ok}"
smoke_floor "${TMP}/smoke-failed.log" >/dev/null && ok=0 || ok=1
check "e2e floor: SMOKE FAILED fails (negative)" 1 "${ok}"
smoke_floor "${TMP}/smoke-fake.log" >/dev/null && ok=0 || ok=1
check "e2e floor: fake body_checks without PASSED fails (negative)" 1 "${ok}"
trailers_floor "${TMP}/trailers-ok.log" >/dev/null && ok=0 || ok=1
check "e2e floor: real TRAILERS PASSED passes" 0 "${ok}"
trailers_floor "${TMP}/trailers-failed.log" >/dev/null && ok=0 || ok=1
check "e2e floor: TRAILERS FAILED fails (negative)" 1 "${ok}"
trailers_floor "${TMP}/trailers-fake.log" >/dev/null && ok=0 || ok=1
check "e2e floor: fake trailer_checks without PASSED fails (negative)" 1 "${ok}"

grpc_floor() { # mirrors ci-live-e2e.sh floor hop-trace-grpc
  local n
  grep -qE '\bHOP-TRACE-GRPC PASSED\b' "$1" || { echo "missing HOP-TRACE-GRPC PASSED"; return 1; }
  n="$(grep -Eo 'checks=[0-9]+' "$1" | tail -1 | cut -d= -f2 || true)"
  [[ "${n:-0}" -ge 6 ]] || { echo "checks=${n:-0} < 6"; return 1; }
  return 0
}
printf '%s\n' 'HOP-TRACE-GRPC PASSED checks=13 (headers/path only — not protobuf CRS)' >"${TMP}/grpc-ok.log"
printf '%s\n' 'HOP-TRACE-GRPC FAILED (9 passed)' >"${TMP}/grpc-failed.log"
printf '%s\n' 'checks=99' >"${TMP}/grpc-fake.log"
check "e2e summary: HOP-TRACE-GRPC PASSED matches SUMMARY_RE" 1 \
  "$(grep -cE "${SUMMARY_RE}" "${TMP}/grpc-ok.log")"
grpc_floor "${TMP}/grpc-ok.log" >/dev/null && ok=0 || ok=1
check "e2e floor: real HOP-TRACE-GRPC PASSED passes" 0 "${ok}"
grpc_floor "${TMP}/grpc-failed.log" >/dev/null && ok=0 || ok=1
check "e2e floor: HOP-TRACE-GRPC FAILED fails (negative)" 1 "${ok}"
grpc_floor "${TMP}/grpc-fake.log" >/dev/null && ok=0 || ok=1
check "e2e floor: fake checks without PASSED fails (negative)" 1 "${ok}"

# Thin presence hook for gRPC hop-trace artifacts (no live Envoy).
[[ -x "${ROOT}/demo/scripts/hop-trace-grpc.sh" ]] && ok=0 || ok=1
check "demo: hop-trace-grpc.sh executable" 0 "${ok}"
[[ -f "${ROOT}/demo/envoy/envoy-grpc.yaml" ]] && ok=0 || ok=1
check "demo: envoy-grpc.yaml present" 0 "${ok}"
[[ -f "${ROOT}/demo/grpc-echo/echo.proto" ]] && ok=0 || ok=1
check "demo: grpc-echo proto present" 0 "${ok}"
[[ -f "${ROOT}/demo/rules/connex-grpc-demo.conf" ]] && ok=0 || ok=1
check "demo: connex-grpc-demo.conf present" 0 "${ok}"
grep -q 'failure_mode_allow: false' "${ROOT}/demo/envoy/envoy-grpc.yaml" && ok=0 || ok=1
check "demo: envoy-grpc fail-closed" 0 "${ok}"
grep -q 'request_body_mode: NONE' "${ROOT}/demo/envoy/envoy-grpc.yaml" && ok=0 || ok=1
check "demo: envoy-grpc headers-only bodies" 0 "${ok}"

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
[[ -f "${ROOT}/demo/rules/connex-ws-demo.conf" ]] && ok=0 || ok=1
check "demo: connex-ws-demo.conf present" 0 "${ok}"

ws_floor() {
  local n
  grep -qE '\bHOP-TRACE-WS-FRAMES PASSED\b' "$1" || { echo "missing HOP-TRACE-WS-FRAMES PASSED"; return 1; }
  n="$(grep -Eo 'checks=[0-9]+' "$1" | tail -1 | cut -d= -f2 || true)"
  [[ "${n:-0}" -ge 6 ]] || { echo "checks=${n:-0} < 6"; return 1; }
  return 0
}
printf '%s\n' 'HOP-TRACE-WS-FRAMES PASSED checks=9 (handshake ModSec yes; frame CRS no)' >"${TMP}/wsf-ok.log"
printf '%s\n' 'HOP-TRACE-WS-FRAMES FAILED (8 passed)' >"${TMP}/wsf-failed.log"
check "e2e summary: HOP-TRACE-WS-FRAMES PASSED matches SUMMARY_RE" 1 \
  "$(grep -cE "${SUMMARY_RE}" "${TMP}/wsf-ok.log")"
ws_floor "${TMP}/wsf-ok.log" >/dev/null && ok=0 || ok=1
check "e2e floor: real HOP-TRACE-WS-FRAMES PASSED passes" 0 "${ok}"
ws_floor "${TMP}/wsf-failed.log" >/dev/null && ok=0 || ok=1
check "e2e floor: HOP-TRACE-WS-FRAMES FAILED fails (negative)" 1 "${ok}"

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

[[ "${fails}" -eq 0 ]] || { echo "test-ci-scripts: ${fails} failed" >&2; exit 1; }
echo "test-ci-scripts OK"
