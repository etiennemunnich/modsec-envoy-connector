---
cursor:
  subagentId: "bc-e514583b-de64-59b7-8863-d8524b7c8c5c"
---

# ModSec-only retest — hop evidence (no CRS)

**Date:** 2026-09-21  
**Repo:** `modsec-envoy-experiement` (local lab)  
**Prior CRS assumption test:** [grpc-websocket-assumption-test.md](./grpc-websocket-assumption-test.md)  
**Scope memo:** [modsec-only-no-crs.md](./modsec-only-no-crs.md)

Fail-closed absolute. No connex push. CRS lab files restored after probes.

---

## ModSec-only config (exact)

Reversible profile (does **not** rewrite CRS trees):

| File | Role |
|------|------|
| `experiments/lab/modsec-only/engine.conf` | `SecRuleEngine On`, body access On, `SecAuditEngine On`, JSON audit → `experiments/lab/logs/modsec-only-audit.log` |
| `experiments/lab/modsec-only/stub-rules.conf` | Stub SecLang only: `990001` URI deny `/__modsec_probe_deny`, `990002` body deny `__modsec_probe_body_deny__` |
| `experiments/lab/modsec-only/includes.conf` | Include root for `--modsec-rules` |

Toggle:

```bash
./scripts/lab-modsec-only.sh only   # ModSec-only (CRS skipped)
./scripts/lab-modsec-only.sh crs    # restore CRS includes
./scripts/lab-modsec-only.sh status
```

After this retest: **CRS restored** (`lab-modsec-only.sh crs`). Fail-closed spot-check: connector kill → HTTP **500**; restore → **200**. CRS SQLi POST again **403**.

---

## Hop-trace script (reusable)

```bash
# request → Envoy → ModSec → CRS(or skipped) → origin
./scripts/hop-trace.sh --label http-get --proto http --path / \
  --expect-status 200 --expect-origin yes --expect-modsec body

./scripts/hop-trace.sh --label ws-stock --proto ws --path / \
  --expect-status 403 --expect-modsec none

./scripts/hop-trace.sh --label grpc-unary --proto grpc \
  --grpc-method echo.Echo/Unary --grpc-data '{"text":"hi"}' \
  --expect-grpc-ok yes --expect-modsec body
```

Artifacts land in `experiments/lab/logs/hop-trace/<ts>-<label>/` (or `$HOP_OUT_DIR`): client result, Envoy access (`rid=`), connector phase lines, ModSec audit (`unique_id` = `x-request-id`), CRS alerts **or** `crs-status=skipped`, origin inference. **Exit non-zero** if a claimed hop cannot be evidenced.

---

## Results table (ModSec-only)

Evidence paths under Context: `internal/modsec-only-retest/hops/<ts>-<label>/`.

| Protocol / case | Result | ModSec assessed | CRS hop | Hop evidence dir |
|-----------------|--------|-----------------|---------|------------------|
| HTTP GET | **PASS** 200 | **body** (hdr+body allow) | skipped | `…/20260921T074119Z-http-get` |
| HTTP probe deny URI | **PASS** 403 | **headers** (990001) | skipped | `…/20260921T074234Z-http-probe-deny` (+ suite twin) |
| HTTP probe body deny | **PASS** 403 | **body** (990002) | skipped | `…/20260921T074125Z-http-body-deny` |
| HTTP SQLi POST (CRS-bait) | **PASS** 200 | **body** allow | skipped | `…/20260921T074128Z-http-sqli-nocrs` |
| WS stock (no upgrade) | **PASS** 403 | **none** (before ext_proc) | skipped | `…/20260921T074324Z-ws-stock` |
| WS BUFFERED + upgrade | **HANG** status 0 / `flags=DC` | **headers** only (stuck pre-body EOS) | skipped | `…/20260921T074137Z-ws-buffered` |
| WS headers-only + upgrade | **PASS** 101 | **headers** (handshake only) | skipped | `…/20260921T074150Z-ws-headers` |
| gRPC unary BUFFERED | **PASS** OK | **body** (HTTP-phase on framed POST) | skipped | `…/20260921T074154Z-grpc-unary-buffered` |
| gRPC server-stream BUFFERED | **PASS** OK | **body** | skipped | `…/20260921T074157Z-grpc-stream-buffered` |
| gRPC unary headers-only | **PASS** OK | **headers** | skipped | `…/20260921T074202Z-grpc-unary-headers` |

Join key: Envoy `rid=` = connector `request_id` = ModSec audit `transaction.unique_id`.

---

## Verdict vs prior CRS assumption test

**Prior CRS test:** HTTP BUFFERED proven; WS hang on BUFFERED / stock reject / headers-only handshake; gRPC unary+stream **accidental CRS 403** (not protobuf WAF).  

**This ModSec-only retest (log-evidenced):** same HTTP+WS engine limits; **gRPC now passes** because CRS anomaly rules are absent — ModSec still only does **HTTP-phase header/body** inspection on gRPC-shaped requests, **not** a gRPC/protobuf WAF. CRS hop correctly reported as **skipped**.

---

## Restore

- Connector: CRS includes (`./scripts/lab-modsec-only.sh crs`) — confirmed.  
- Envoy: stock `compose/lab/envoy.host.yaml` — confirmed.  
- Experimental WS/gRPC Envoy YAML remains under `/tmp/modsec-proto-test/` only (not committed).
