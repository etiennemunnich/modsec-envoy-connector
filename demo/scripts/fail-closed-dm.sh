#!/usr/bin/env bash
# Fail-closed drills for DEPLOY=dm — **weaker / different model** than fail-closed.sh.
#
# What this proves (DM floors):
#   1. Missing libmodsec_dm.so → Envoy does not serve OK traffic (config/load fail)
#   2. Bad / zero rules at filter config → Envoy reject / no origin OK
#   3. Baseline allow after restore
#
# What this does **NOT** claim (ext_proc absolute — do not cite as DM proof):
#   - kill connector → 500
#   - hang → 504 via message_timeout
#   - failure_mode_allow: true negctl
#
# Requires a prior successful DEPLOY=dm up (module built). Restarts Envoy itself.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

if [[ "${DEPLOY}" != "dm" ]]; then
  echo "fail-closed-dm.sh requires DEPLOY=dm" >&2
  exit 2
fi

FAIL=0
PASS=0
pass() { echo "  PASS $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL $*"; FAIL=1; }

wait_http "${BASE}/" 50 || { echo "demo not up — run DEPLOY=dm ./demo/scripts/up.sh" >&2; exit 2; }

echo "==> baseline (DM)"
code="$(http_code "${BASE}/")"
if [[ "$code" == "200" ]]; then pass "[baseline] 200"; else fail "[baseline] $code"; exit 1; fi

restore_dm() {
  stop_pidfile "${RUN}/envoy.pid" KILL
  python3 "${DEMO}/scripts/mk-envoy-dm-yaml.py" \
    --out "${ENVOY_CFG}" \
    --listen "${ENVOY_PORT}" \
    --admin "${ENVOY_ADMIN_PORT}" \
    --origin "${ORIGIN_PORT}" \
    --body-policy "${DM_BODY_POLICY}" \
    --soft-limit "${DM_PARTIAL_SOFT_LIMIT}" \
    --rules "${RULES_FILE}" \
    --label "dm-restore" >/dev/null
  daemonize "${RUN}/envoy.log" "${RUN}/envoy.pid" \
    env ENVOY_DYNAMIC_MODULES_SEARCH_PATH="${DM_MODULES_DIR}" \
    envoy -c "${ENVOY_CFG}" --concurrency 2 --log-level warn --file-flush-interval-msec 200
  wait_http "http://127.0.0.1:${ENVOY_ADMIN_PORT}/ready" 100
}

echo "==> 1. missing module .so (move aside; Envoy must not leave origin unprotected as 200)"
stop_pidfile "${RUN}/envoy.pid" KILL
mv "${DM_SO}" "${DM_SO}.bak"
: >"${RUN}/envoy-missing-so.log"
set +e
ENVOY_DYNAMIC_MODULES_SEARCH_PATH="${DM_MODULES_DIR}" \
  envoy -c "${ENVOY_CFG}" --concurrency 1 --base-id 71 --log-level error \
  >"${RUN}/envoy-missing-so.log" 2>&1 &
miss_pid=$!
sleep 2
if kill -0 "${miss_pid}" 2>/dev/null; then
  before="$(origin_hits)"
  code="$(http_code "${BASE}/" || true)"
  sleep 0.1
  after="$(origin_hits)"
  kill "${miss_pid}" 2>/dev/null || true
  wait "${miss_pid}" 2>/dev/null || true
  # Fail-closed at config time preferred; if Envoy somehow listens without filter, origin hit is fail.
  if [[ "$code" != "200" ]] || [[ "$after" == "$before" ]]; then
    pass "[missing-so] no OK-to-origin (HTTP ${code}, origin ${before}→${after})"
  else
    fail "[missing-so] HTTP 200 and origin advanced (fail-open)"
  fi
else
  pass "[missing-so] envoy exited (config/load reject)"
fi
set -e
mv "${DM_SO}.bak" "${DM_SO}"
if restore_dm; then pass "[restore] after missing-so"; else fail "[restore] after missing-so"; fi

echo "==> 2. bad rules at filter config (empty/zero rules → reject)"
stop_pidfile "${RUN}/envoy.pid" KILL
bad="${RUN}/dm-broken-rules.conf"
{
  echo "SecRuleEngine On"
  # No SecRule lines → ZeroRulesLoaded / refuse
} >"${bad}"
python3 "${DEMO}/scripts/mk-envoy-dm-yaml.py" \
  --out "${RUN}/envoy-dm-bad-rules.yaml" \
  --listen "${ENVOY_PORT}" \
  --admin "${ENVOY_ADMIN_PORT}" \
  --origin "${ORIGIN_PORT}" \
  --body-policy "${DM_BODY_POLICY}" \
  --rules "${bad}" \
  --label "dm-bad" >/dev/null
: >"${RUN}/envoy-bad-rules.log"
set +e
ENVOY_DYNAMIC_MODULES_SEARCH_PATH="${DM_MODULES_DIR}" \
  envoy -c "${RUN}/envoy-dm-bad-rules.yaml" --concurrency 1 --base-id 72 --log-level error \
  >"${RUN}/envoy-bad-rules.log" 2>&1 &
bad_pid=$!
sleep 2
if kill -0 "${bad_pid}" 2>/dev/null; then
  before="$(origin_hits)"
  code="$(http_code "${BASE}/" || true)"
  after="$(origin_hits)"
  kill "${bad_pid}" 2>/dev/null || true
  wait "${bad_pid}" 2>/dev/null || true
  if [[ "$code" != "200" ]] || [[ "$after" == "$before" ]]; then
    pass "[bad-rules] no OK-to-origin (HTTP ${code})"
  else
    fail "[bad-rules] HTTP 200 origin advanced (would allow everything)"
  fi
else
  pass "[bad-rules] envoy exited (filter config None / load fail)"
fi
set -e
if restore_dm; then pass "[restore] after bad-rules"; else fail "[restore] after bad-rules"; fi

echo "==> 3. FULL_DUPLEX config reject (UNSUPPORTED)"
python3 "${DEMO}/scripts/mk-envoy-dm-yaml.py" \
  --out "${RUN}/envoy-dm-fullduplex.yaml" \
  --listen "$((ENVOY_PORT + 50))" \
  --admin "$((ENVOY_ADMIN_PORT + 50))" \
  --origin "${ORIGIN_PORT}" \
  --body-policy full_duplex_hold \
  --rules "${RULES_FILE}" \
  --label "dm-fd" >/dev/null
: >"${RUN}/envoy-fullduplex.log"
set +e
ENVOY_DYNAMIC_MODULES_SEARCH_PATH="${DM_MODULES_DIR}" \
  envoy -c "${RUN}/envoy-dm-fullduplex.yaml" --concurrency 1 --base-id 73 --log-level error \
  >"${RUN}/envoy-fullduplex.log" 2>&1 &
fd_pid=$!
sleep 2
if kill -0 "${fd_pid}" 2>/dev/null; then
  kill "${fd_pid}" 2>/dev/null || true
  wait "${fd_pid}" 2>/dev/null || true
  if grep -qiE 'UNSUPPORTED|filter_config|modsec-dm|failed|error' "${RUN}/envoy-fullduplex.log"; then
    pass "[full-duplex] rejected/logged UNSUPPORTED"
  else
    fail "[full-duplex] envoy stayed up without clear reject log"
  fi
else
  pass "[full-duplex] envoy exited (config reject)"
fi
set -e

echo "==> note: kill→500 and hang→504 are ext_proc-only; not drilled here"

if [[ "${PASS}" -lt 5 ]]; then
  fail "[floor] PASS=${PASS} < 5"
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo "FAIL-CLOSED-DM FAILED pass=${PASS}"
  exit 1
fi
echo "FAIL-CLOSED-DM PASSED checks=${PASS} (weaker model; not fail-closed absolute)"
