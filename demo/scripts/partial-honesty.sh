#!/usr/bin/env bash
# BUFFERED_PARTIAL honesty probes under real CRS.
# Requires BODY_MODE=BUFFERED_PARTIAL demo up
# (envoy-buffered-partial.yaml with per_connection_buffer_limit_bytes: 1048576).
#
# Envoy's listener per_connection_buffer_limit_bytes is a soft limit. On Envoy
# v1.39.1 with BUFFERED_PARTIAL, bodies just over 1 MiB are still fully delivered
# to ext_proc; once the body is large enough (~2 MiB here) Envoy stops sending
# request_body to the connector (headers-only then Continue) — trailing body
# CRS can miss. That is the ProcessPartial honesty class.
#
# Cells:
#   - SQLi inside a small prefix → 403, origin untouched
#   - trailing SQLi after a 2 MiB pad → origin hit and not CRS-deny (200 on Mac;
#     Linux GH runners sometimes 503 after Continue while still reaching origin)
#   - benign 2 MiB body → origin hit and not CRS-deny
#
# Not a full-CRS claim. Floor: all three cells must match.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

FAIL=0
pass() { echo "  PASS $*"; }
fail() { echo "  FAIL $*"; FAIL=1; }

# Oversize PARTIAL miss / pass-through: origin must see the request and CRS must
# not deny (403). Client status may be 200 or 503 (Envoy post-Continue noise on
# oversized PARTIAL bodies on some Linux runners) — still not a CRS deny.
partial_oversize_ok() {
  local code="$1" delta="$2"
  [[ "$delta" == "1" && "$code" != "403" && "$code" != "000" ]]
}

[[ "${BODY_MODE}" == "BUFFERED_PARTIAL" ]] \
  || { echo "partial-honesty requires BODY_MODE=BUFFERED_PARTIAL (got '${BODY_MODE}')" >&2; exit 2; }
grep -q 'per_connection_buffer_limit_bytes: 1048576' "${ENVOY_CFG}" \
  || { echo "${ENVOY_CFG} must set 1 MiB per_connection_buffer_limit_bytes" >&2; exit 2; }
grep -q 'engine-partial-overlay.conf' "${RULES_FILE}" 2>/dev/null \
  || { echo "demo rules missing engine-partial-overlay.conf — restart with BODY_MODE=BUFFERED_PARTIAL" >&2; exit 2; }

wait_http "${BASE}/" 50 || { echo "demo not up at ${BASE}" >&2; exit 2; }

WORKDIR="${RUN}/partial-honesty"
mkdir -p "${WORKDIR}"
PAD_2MIB=$((2 * 1024 * 1024))
python3 - "${WORKDIR}" "${PAD_2MIB}" <<'PY'
import sys
from pathlib import Path
out, pad_n = Path(sys.argv[1]), int(sys.argv[2])
(out / "inprefix.bin").write_bytes(b"pad=" + b"A" * 200 + b"&a=1'%20OR%201%3D1--")
(out / "trailing.bin").write_bytes(b"pad=" + b"A" * pad_n + b"&a=1'%20OR%201%3D1--")
(out / "benign.bin").write_bytes(b"hello=world&pad=" + b"B" * pad_n)
PY

echo "==> BUFFERED_PARTIAL honesty (CRS; listener soft limit 1 MiB; miss pad ${PAD_2MIB} bytes)"

post_file() {
  local file="$1"
  http_code -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-binary "@${file}" --max-time 60 "${BASE}/login"
}

# In-prefix SQLi (well under the soft limit) — must deny.
before="$(origin_hits)"
code="$(post_file "${WORKDIR}/inprefix.bin")"
sleep 0.2
delta=$(( $(origin_hits) - before ))
if [[ "$code" == "403" && "$delta" == "0" ]]; then
  pass "[in-prefix-sqli] HTTP 403 origin +0"
else
  fail "[in-prefix-sqli] HTTP $code origin +$delta (want 403 / +0)"
fi

# Trailing SQLi after 2 MiB pad — expected PARTIAL miss (origin hit, not 403).
before="$(origin_hits)"
code="$(post_file "${WORKDIR}/trailing.bin")"
sleep 0.3
delta=$(( $(origin_hits) - before ))
if partial_oversize_ok "$code" "$delta"; then
  pass "[trailing-sqli-past-2MiB] HTTP ${code} origin +${delta} (PARTIAL miss; soft limit 1 MiB)"
else
  fail "[trailing-sqli-past-2MiB] HTTP $code origin +$delta (want origin +1 and not 403)"
fi

# Benign oversize — must reach origin without CRS deny.
before="$(origin_hits)"
code="$(post_file "${WORKDIR}/benign.bin")"
sleep 0.3
delta=$(( $(origin_hits) - before ))
if partial_oversize_ok "$code" "$delta"; then
  pass "[benign-2MiB] HTTP ${code} origin +${delta}"
else
  fail "[benign-2MiB] HTTP $code origin +$delta (want origin +1 and not 403)"
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo "PARTIAL-HONESTY FAILED body_mode=${BODY_MODE}"
  exit 1
fi
echo "PARTIAL-HONESTY PASSED body_mode=${BODY_MODE} checks=3 soft_limit_bytes=1048576 miss_pad_bytes=${PAD_2MIB}"
