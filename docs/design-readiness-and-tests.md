---
title: Design readiness + further testing (connex prep snapshot)
audience: Etienne
date: 2026-09-21
status: Historical prep snapshot. Current product truth is how-it-works / testing / fail-closed.
license: see LICENSE (Apache-2.0)
---

# Design readiness + further testing (connex prep)

**Date:** 2026-09-21 (snapshot)  
**Audience:** Etienne  
**Status:** Prep notes from before the private connex tree landed live CI and honesty suites. Several checklist items below are **done or superseded** on tip (STREAMED thin smoke + fail-closed in CI; hop-trace in `e2e-pin`; gRPC/WS honesty scripts; Apache-2.0 license). Treat this file as history, not the live claim surface.

**Current product truth:** [how-it-works.md](./how-it-works.md) · [testing.md](./testing.md) · [fail-closed.md](./fail-closed.md) · [`versions.lock.md`](../versions.lock.md) · [`demo/README.md`](../demo/README.md)

**Inputs (findings):** [modsec-only-retest-hops.md](./findings/modsec-only-retest-hops.md) · [grpc-websocket-assumption-test.md](./findings/grpc-websocket-assumption-test.md) · [http-grpc-websocket-scope.md](./findings/http-grpc-websocket-scope.md) · [buffered-downsides.md](./findings/buffered-downsides.md) · [coraza-envoy-issues.md](./findings/coraza-envoy-issues.md) · [approach-options.md](./findings/approach-options.md) · preferences-* (lab notes outside this tree; readiness memo was never checked in)  
**Lab:** `modsec-envoy-experiement` (reference). **Product repo:** private `envoy-modsec-connex`.  
**Coraza:** reference only. **Fail-closed:** absolute.

BoE pages reviewed (no catalog submit):
- https://builtonenvoy.io/docs/writing-rust-extensions/
- https://builtonenvoy.io/docs/running-local-extensions/
- https://builtonenvoy.io/docs/extension-types/
- https://builtonenvoy.io/docs/packaging-prod/
- https://builtonenvoy.io/docs/security-considerations/

---

## 1. Design readiness (snapshot verdict)

### **PARTIAL** (as of 2026-09-21)

| Ready (keep) | Not ready (honest gap then) |
|--------------|-----------------------------|
| Architecture shape: Envoy `ext_proc` → Rust → **libmodsecurity** → origin | Not production-deployable (ops / body limits not productized) |
| HTTP **BUFFERED** full CRS fidelity proven historically (`5091/0/0`) | Then-current focus window could defer CRS as fidelity bar ([modsec-only-no-crs.md](./findings/modsec-only-no-crs.md)) |
| Fail-closed live on HTTP lab path | Fail-closed expansion to gRPC/WS handshake (later covered by demo suites) |
| Protocol honesty: HTTP proven; gRPC/WS limits confirmed live | Multi-protocol product sentence + route-mode defaults still open decisions |
| BUFFERED default for CRS/SecLang body rules is the right *default* | BUFFERED downsides (RAM, TTFB, WS hang, large uploads) documented but not mitigated in product config |
| Ext_proc out-of-process matches BoE security guidance better than in-process DM for a WAF | BoE catalog packaging / `boe run` / OCI artifacts not built |

**One-liner (then):** Design is sound for a **lab-proven HTTP BUFFERED ModSec connector** with honest protocol limits; it is **not** ready to claim multi-protocol full WAF or BoE catalog production.

**Tip today (see testing.md):** STREAMED has thin live smoke + fail-closed on both arches; full CRS / go-ftw stay on BUFFERED. Do not read the 2026-09-21 "STREAMED deferred" line as current product truth.

---

## 2. Further testing still needed (checklist as written 2026-09-21)

Items marked **(done on tip)** are covered by `demo/scripts/` and hosted `ci` / honesty suites; keep the original wording for audit trail.

1. **Hop-trace CI gate** **(done on tip)**  -  `hop-trace.sh` in `e2e-pin`.
2. **Fail-closed × protocol** **(done on tip for H1+H2 HTTP; WS/gRPC handshake drills exist)**  -  see `fail-modes.sh`, `hop-trace-ws*.sh`, `hop-trace-grpc.sh`.
3. **BUFFERED limit behavior**  -  oversized body → deny/413 (not hang/timeout); assert ModSec + Envoy limits agree. *(still open)*
4. **CRS reload / ModSec-only toggle**  -  switch ModSec-only vs CRS without breaking fail-closed. *(ops polish; `DEMO_CRS=0` exists)*
5. **gRPC honesty suite** **(done on tip)**  -  `hop-trace-grpc.sh`; not protobuf CRS.
6. **WebSocket honesty suite** **(done on tip)**  -  `hop-trace-ws.sh` / `hop-trace-ws-frames.sh`.
7. **STREAMED** **(thin live on tip; full CRS still BUFFERED)**  -  smoke + fail-closed via `BODY_MODE=STREAMED` / `e2e-streamed`.
8. **Client IP / connection attrs** **(done on tip)**  -  Envoy `request_attributes` → `process_connection`.
9. **Soak / memory**  -  double-buffer Envoy+ModSec under sustained BUFFERED load. *(still open)*
10. **Ubuntu CI-parity** **(done on tip)**  -  hosted x86_64 + aarch64.

---

## 3. Integration tests to build (snapshot)

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
| IT-G2 | gRPC unary CRS-on | Expect accidental HTTP CRS deny **or** tuned headers-only route  -  assert honesty label |
| IT-G3 | gRPC stream BUFFERED | Same honesty as unary (HTTP-phase); no “stream CRS” |
| IT-LIM1 | Body over buffer limit | Downstream error/deny; never silent allow |
| IT-BOE1 | Draft `manifest.yaml` `type: ext_proc` loads documented ports/modes | Docs/schema validate; **not** catalog publish |

Harness entrypoints today: `demo/scripts/hop-trace.sh`, `demo/scripts/fail-closed.sh`, `demo/scripts/fail-modes.sh` (lab scripts named in the original note are outside this tree).

---

## 4. BoE gap checklist (five pages)

Target product type: **`ext_proc`** (out-of-process gRPC), **not** Rust/Go dynamic module.

| Area | BoE expectation (from docs) | Our status | Gap |
|------|-----------------------------|------------|-----|
| **Extension type** ([extension-types](https://builtonenvoy.io/docs/extension-types/)) | `type: ext_proc` with `extProc.grpcPort`, `failureModeAllow`, `processingMode` | Lab **is** ext_proc; draft manifest in `docs/boe/` | Need published `manifest.yaml`; BUFFERED + `failureModeAllow: false` |
| **Writing Rust** ([writing-rust-extensions](https://builtonenvoy.io/docs/writing-rust-extensions/)) | Guide is **Rust dynamic modules** (`cdylib`, HTTP filter traits) | Product is **ext_proc binary**, not DM | Do **not** follow DM template for the WAF; keep Rust as standalone gRPC server. Optional DM only if future non-WAF filter |
| **Local run** ([running-local-extensions](https://builtonenvoy.io/docs/running-local-extensions/)) | `boe create` / `boe run --local` for go/rust DM | Demo uses host Envoy scripts | No `boe run` path yet; document demo scripts as interim |
| **Packaging prod** ([packaging-prod](https://builtonenvoy.io/docs/packaging-prod/)) | Focused on **Dynamic Module** OCI `.so` + custom Envoy image | N/A for in-process DM; ext_proc needs container + Envoy config cluster | OCI image path exists via `release` workflow; EG attachment docs still open |
| **Security** ([security-considerations](https://builtonenvoy.io/docs/security-considerations/)) | DM in-process = crash/memory/permissions shared; fail open/closed deliberate; bound buffers; no blocking on worker threads | Ext_proc **isolates** crash from Envoy (good for WAF); fail-closed proven on HTTP; body bounds partial | Document isolation advantage; bound BUFFERED sizes; timeouts; never block Envoy workers (already OOP) |

### Catalog submit readiness

**Not ready.** Missing: BoE-shaped layout + validated `manifest.yaml`, `boe`-class local run or equivalent example, EG/Gateway examples, coverage culture for upstream, and Etienne explicit go. **Do not open a BoE PR.**

### License note

Connex is **Apache License 2.0** (see `LICENSE` / `NOTICE`). BoE tree is also Apache-2.0. If catalog contribution is ever pursued, confirm attribution and any dual-license needs before submit (separate decision).

---

## 5. Design notes summary (for connex README)

- **Claim today:** HTTP BUFFERED (default) ext_proc → libmodsecurity; STREAMED thin-proven; fail-closed absolute; CRS optional at the pin.
- **Do not claim:** Full CRS on STREAMED; gRPC/protobuf WAF; WebSocket frame CRS; HTTP/3.
- **gRPC/WS:** headers/handshake-only with honest labels; BUFFERED on upgrade hangs (lab-confirmed).
- **Coraza:** EOS/trailer/bypass lessons only  -  engine remains libmodsecurity.
