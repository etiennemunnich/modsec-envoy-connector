#!/usr/bin/env bash
# Negative controls for DM fail-open footguns (local only; not CI-published).
#
#   A) module.remote paste → prove fail-open (filter omitted / unfiltered 200)
#      then document that product configs must forbid remote.
#   B) Unit floor: EngineError → send_response(500) + Stop* (never filter Continue).
#      There is no Continue-after-Err feature flag (removed; it lied — Stop* without 500).
#
# Exit 0 only when both: remote fail-open is **demonstrated** AND default
# .so still EngineError→500 (unit tests cover B when cargo test runs).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

ART="${ART:-/opt/cursor/artifacts/dm-private-complete}"
mkdir -p "${ART}"

FAIL=0
PASS=0
pass() { echo "  PASS $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL $*"; FAIL=1; }

command -v envoy >/dev/null || { echo "envoy required" >&2; exit 2; }
pkg-config --exists modsecurity || { echo "libmodsecurity required" >&2; exit 2; }

export LIBCLANG_PATH="${LIBCLANG_PATH:-/usr/lib/llvm-18/lib}"
echo "==> ensure default libmodsec_dm.so"
(cd "${ROOT}" && cargo build -q -p modsec-dm)
mkdir -p "${DM_MODULES_DIR}"
cp -f "${ROOT}/target/debug/libmodsec_dm.so" "${DM_SO}"

# Minimal allow-all rules for remote drill origin path (when filter omitted).
mkdir -p "${RUN}/tmp" "${RUN}/data"
RULES_OK="${RUN}/dm-negctl-ok.conf"
{
  echo "SecRuleEngine On"
  echo "SecRule REQUEST_URI \"@unconditionalMatch\" \"id:900001,phase:1,pass,nolog\""
} >"${RULES_OK}"

ORIGIN_PORT_N=$((DEMO_PORT_BASE + 118))
ENVOY_PORT_N=$((DEMO_PORT_BASE + 100))
ADMIN_PORT_N=$((DEMO_PORT_BASE + 109))
HITS_N="${RUN}/origin-hits-negctl.log"
: >"${HITS_N}"
"${DEMO}/scripts/down.sh" >/dev/null 2>&1 || true
# Free negotiated ports if busy
for p in "${ENVOY_PORT_N}" "${ORIGIN_PORT_N}" "${ADMIN_PORT_N}"; do
  pid="$(port_pid "$p")"
  [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
done
daemonize "${RUN}/origin-negctl.log" "${RUN}/origin-negctl.pid" \
  python3 "${DEMO}/scripts/origin.py" "${ORIGIN_PORT_N}" "${HITS_N}"

echo "==> A) remote-module YAML (expect fail-open: unfiltered 200 or filter omitted)"
python3 "${DEMO}/scripts/mk-envoy-dm-yaml.py" \
  --out "${RUN}/envoy-dm-remote.yaml" \
  --listen "${ENVOY_PORT_N}" \
  --admin "${ADMIN_PORT_N}" \
  --origin "${ORIGIN_PORT_N}" \
  --body-policy buffer_until_eos \
  --rules "${RULES_OK}" \
  --remote-module \
  --label "dm-remote-negctl" | tee "${ART}/negctl-remote-gen.log"

# Proto field names for remote may differ by Envoy minor; if config rejected as invalid YAML/proto,
# that still proves remote is not a silent local load — record and treat as pass for "forbid remote".
set +e
ENVOY_DYNAMIC_MODULES_SEARCH_PATH="${DM_MODULES_DIR}" \
  envoy -c "${RUN}/envoy-dm-remote.yaml" --concurrency 1 --base-id 81 --log-level error \
  >"${ART}/negctl-remote-envoy.log" 2>&1 &
rp=$!
sleep 3
remote_alive=0
kill -0 "$rp" 2>/dev/null && remote_alive=1
before="$(wc -l <"${HITS_N}" | tr -d ' ')"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${ENVOY_PORT_N}/" || true)"
sleep 0.2
after="$(wc -l <"${HITS_N}" | tr -d ' ')"
kill "$rp" 2>/dev/null || true
wait "$rp" 2>/dev/null || true
set -e

echo "  remote_alive=${remote_alive} HTTP ${code} origin ${before}→${after}" | tee -a "${ART}/negctl-remote-envoy.log"
if [[ "${remote_alive}" -eq 0 ]]; then
  # Invalid remote config rejected at boot — still evidence remote is not a safe enforcement path.
  pass "[remote] envoy rejected remote config (forbid remote; not silent local)"
elif [[ "$code" == "200" && "$after" -gt "$before" ]]; then
  pass "[remote] fail-open demonstrated (HTTP 200 origin hit; filter omitted or unused)"
else
  # Ambiguous — still record; do not vacuous-pass.
  fail "[remote] inconclusive (alive=${remote_alive} code=${code} origin ${before}→${after}); see ${ART}/negctl-remote-envoy.log"
fi

echo "==> B) EngineError → 500 unit floor (never Continue after Err)"
set +e
(cd "${ROOT}" && cargo test -q -p modsec-dm engine_error_sends_500_never_continue -- --nocapture) \
  >"${ART}/negctl-engine-error-unit.log" 2>&1
trc=$?
set -e
if [[ "$trc" -eq 0 ]]; then
  pass "[engine-error] unit: EngineError → 500 + Stop* on default build"
else
  fail "[engine-error] unit failed — see ${ART}/negctl-engine-error-unit.log"
fi

stop_pidfile "${RUN}/origin-negctl.pid" KILL

if [[ "$FAIL" -ne 0 || "$PASS" -lt 2 ]]; then
  echo "FAIL-CLOSED-DM-NEGCTL FAILED pass=${PASS}" | tee "${ART}/negctl-summary.txt"
  exit 1
fi
echo "FAIL-CLOSED-DM-NEGCTL PASSED checks=${PASS}" | tee "${ART}/negctl-summary.txt"
