---
cursor:
  subagentId: "bc-d3aa7497-a57d-5dec-bf2d-3fc584e07b60"
---

# Design readiness + further testing (connex prep)

**Date:** 2026-09-21  
**Audience:** Etienne  
**Inputs:** [modsec-only-retest-hops.md](./modsec-only-retest-hops.md) · [grpc-websocket-assumption-test.md](./grpc-websocket-assumption-test.md) · [http-grpc-websocket-scope.md](./http-grpc-websocket-scope.md) · [buffered-downsides.md](./buffered-downsides.md) · [coraza-envoy-issues.md](./coraza-envoy-issues.md) · [approach-options.md](./approach-options.md) · [envoy-modsec-connex-readiness.md](./envoy-modsec-connex-readiness.md) · preferences-*  
**Lab:** `modsec-envoy-experiement` (reference). **Product repo:** private `envoy-modsec-connex` (prep).  
**Coraza:** reference only. **Fail-closed:** absolute.

BoE pages reviewed (no catalog submit):
- https://builtonenvoy.io/docs/writing-rust-extensions/
- https://builtonenvoy.io/docs/running-local-extensions/
- https://builtonenvoy.io/docs/extension-types/
- https://builtonenvoy.io/docs/packaging-prod/
- https://builtonenvoy.io/docs/security-considerations/

---

## 1. Design readiness — honest verdict

### **PARTIAL**

| Ready (keep) | Not ready (honest gap) |
|--------------|------------------------|
| Architecture shape: Envoy `ext_proc` → Rust → **libmodsecurity** → origin | Not production-deployable (STREAMED deferred; body limits/ops not productized) |
| HTTP **BUFFERED** full CRS fidelity proven historically (`5091/0/0`) | Current focus window may defer CRS as fidelity bar ([modsec-only-no-crs.md](./modsec-only-no-crs.md)) |
| Fail-closed live **15/15 PASS** on HTTP lab path | Fail-closed not yet expanded to gRPC/WS handshake-deny cases |
| Protocol honesty: HTTP proven; gRPC/WS limits confirmed live | Multi-protocol product sentence + route-mode defaults still open decisions |
| BUFFERED default for CRS/SecLang body rules is the right *default* | BUFFERED downsides (RAM, TTFB, WS hang, large uploads) documented but not mitigated in product config |
| Ext_proc out-of-process matches BoE security guidance better than in-process DM for a WAF | BoE catalog packaging / `boe run` / OCI artifacts not built |

**One-liner:** Design is sound for a **lab-proven HTTP BUFFERED ModSec connector** with honest protocol limits; it is **not** ready to claim multi-protocol full WAF or BoE catalog production.

---

## 2. Further testing still needed

1. **Hop-trace CI gate** — automate `hop-trace.sh` for HTTP allow/deny (URI + body stubs) with join-key evidence; fail if any hop lacks logs.
2. **Fail-closed × protocol** — ExtProc down / hang during gRPC unary and WS handshake must deny (no 101 / no OK RPC); extend beyond HTTP-only `lab-fail-closed.sh`.
3. **BUFFERED limit behavior** — oversized body → deny/413 (not hang/timeout); assert ModSec + Envoy limits agree.
4. **CRS reload / ModSec-only toggle** — switch `lab-modsec-only.sh only|crs` without breaking fail-closed; document CRS-bait SQLi 200 (no CRS) vs 403 (CRS).
5. **gRPC honesty suite** — unary/stream with CRS on vs off; prove “HTTP-phase only,” never protobuf WAF.
6. **WebSocket honesty suite** — stock reject; BUFFERED+upgrade hang; headers-only 101; assert no frame inspection claim.
7. **STREAMED (deferred)** — if ever claimed: reassembly → EOS → `process_*_body`, trailer/non-EOS finalize, go-ftw + fail-closed re-proof (Coraza EOS lessons).
8. **Client IP / connection attrs** — replace hardcoded `127.0.0.1` fidelity gap before any “production CRS” claim.
9. **Soak / memory** — double-buffer Envoy+ModSec under sustained BUFFERED load; leak/OOM watch.
10. **Ubuntu CI-parity** on connex tree before any push that claims quality (Mac-green ≠ gate).

---

## 3. Integration tests to build

Prefer scripted hop-trace: **request → Envoy → ModSec → CRS** (or `crs-status=skipped`).

| ID | Test | Pass criteria |
|----|------|---------------|
| IT-H1 | HTTP GET allow | Hop evidence: Envoy access + connector phases + ModSec audit allow + origin hit; join via `x-request-id`/`unique_id` |
| IT-H2 | HTTP stub URI deny (`990001`) | 403; ModSec **headers** assessed; CRS skipped or CRS path as configured |
| IT-H3 | HTTP stub body deny (`990002`) | 403; ModSec **body** assessed |
| IT-H4 | HTTP SQLi POST ModSec-only | 200 + body allow when CRS skipped; hop says CRS skipped |
| IT-H5 | HTTP SQLi POST CRS-on | 403 + CRS alert (e.g. anomaly); CRS hop evidenced |
| IT-FC1 | Connector kill mid-flight | HTTP 5xx; no origin; fail-closed artifact |
| IT-FC2 | ExtProc hang / message timeout | Deny, not pass-through |
| IT-WS1 | Stock WS (no upgrade_configs) | 403 before ModSec; ModSec hop **none** |
| IT-WS2 | WS BUFFERED + upgrade | Document hang/DC as **known fail**; must not be marketed |
| IT-WS3 | WS headers-only handshake | 101; ModSec headers only; no frame CRS claim |
| IT-G1 | gRPC unary BUFFERED ModSec-only | RPC OK; ModSec body on framed POST; not protobuf WAF |
| IT-G2 | gRPC unary CRS-on | Expect accidental HTTP CRS deny **or** tuned headers-only route — assert honesty label |
| IT-G3 | gRPC stream BUFFERED | Same honesty as unary (HTTP-phase); no “stream CRS” |
| IT-LIM1 | Body over buffer limit | Downstream error/deny; never silent allow |
| IT-BOE1 | Draft `manifest.yaml` `type: ext_proc` loads documented ports/modes | Docs/schema validate; **not** catalog publish |

Harness entrypoints (lab today): `scripts/hop-trace.sh`, `scripts/lab-modsec-only.sh`, `scripts/lab-fail-closed.sh`.

---

## 4. BoE gap checklist (five pages)

Target product type: **`ext_proc`** (out-of-process gRPC), **not** Rust/Go dynamic module.

| Area | BoE expectation (from docs) | Our status | Gap |
|------|-----------------------------|------------|-----|
| **Extension type** ([extension-types](https://builtonenvoy.io/docs/extension-types/)) | `type: ext_proc` with `extProc.grpcPort`, `failureModeAllow`, `processingMode` | Lab **is** ext_proc; draft manifest planned in connex | Need published `manifest.yaml`; BUFFERED + `failureModeAllow: false` |
| **Writing Rust** ([writing-rust-extensions](https://builtonenvoy.io/docs/writing-rust-extensions/)) | Guide is **Rust dynamic modules** (`cdylib`, HTTP filter traits) | Product is **ext_proc binary**, not DM | Do **not** follow DM template for the WAF; keep Rust as standalone gRPC server. Optional DM only if future non-WAF filter |
| **Local run** ([running-local-extensions](https://builtonenvoy.io/docs/running-local-extensions/)) | `boe create` / `boe run --local` for go/rust DM | Lab uses compose + host Envoy scripts | No `boe run` path yet; document lab scripts as interim; explore BoE ext_proc example layout later |
| **Packaging prod** ([packaging-prod](https://builtonenvoy.io/docs/packaging-prod/)) | Focused on **Dynamic Module** OCI `.so` + custom Envoy image | N/A for in-process DM; ext_proc needs container + Envoy config cluster | Need OCI image for connector binary + documented Envoy/EG attachment — not DM `.so` packaging |
| **Security** ([security-considerations](https://builtonenvoy.io/docs/security-considerations/)) | DM in-process = crash/memory/permissions shared; fail open/closed deliberate; bound buffers; no blocking on worker threads | Ext_proc **isolates** crash from Envoy (good for WAF); fail-closed proven on HTTP; body bounds partial | Document isolation advantage; bound BUFFERED sizes; timeouts; never block Envoy workers (already OOP); expand fail-closed proofs |

### Catalog submit readiness

**Not ready.** Missing: BoE-shaped layout + validated `manifest.yaml`, `boe`-class local run or equivalent example, packaging artifacts, EG/Gateway examples, coverage culture, DCO/AI policy for upstream, and Etienne explicit go. **Do not open a BoE PR.**

### License note

Connex uses **MIT-0** per preference. BoE tree is Apache-2.0 — if catalog contribution is ever pursued, confirm license compatibility / dual-license before submit (separate decision).

---

## 5. Design notes summary (for connex README)

- **Claim today:** HTTP BUFFERED ext_proc → libmodsecurity; fail-closed absolute; CRS optional/deferred fidelity bar.
- **Do not claim:** STREAMED proven; gRPC/protobuf WAF; WebSocket frame CRS.
- **gRPC/WS:** headers/handshake-only with honest labels; BUFFERED on upgrade hangs (lab-confirmed).
- **Coraza:** EOS/trailer/bypass lessons only — engine remains libmodsecurity.
- **Next product packaging:** private `envoy-modsec-connex` docs-first; experiment remains the live lab.
