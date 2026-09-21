# Coraza Envoy approaches — GitHub issues (reference-only)

**Audience:** Etienne  
**Date:** 2026-09-21  
**Mode:** Analysis only — no code, no repo, no connex.  
**Product stays:** libmodsecurity (+ CRS) via Rust Envoy `ext_proc`.  
**Coraza:** design / threat-model reference only — steal connector failure modes, not the engine.

Related Context (do not duplicate):
- Body pattern / EOS semantics: [coraza-design-lessons-for-modsec.md](./coraza-design-lessons-for-modsec.md)
- BUFFERED delivery downsides (Envoy/ext_proc): [buffered-downsides.md](./buffered-downsides.md)
- Prior-art table: [github-issues-envoy-modsec-crs.md](./github-issues-envoy-modsec-crs.md) §5
- Protocol scope: [http-grpc-websocket-scope.md](./http-grpc-websocket-scope.md)

Sources scanned (public GitHub + [coraza.io/connectors](https://coraza.io/connectors/)):
| Approach | Repo / surface | Role |
|----------|----------------|------|
| Proxy-Wasm (Envoy/Istio/APISIX) | [corazawaf/coraza-proxy-wasm](https://github.com/corazawaf/coraza-proxy-wasm) | Primary prior art — richest issue history |
| Core engine | [corazawaf/coraza](https://github.com/corazawaf/coraza) | Engine semantics / ModSec divergence |
| Envoy contrib Go filter | [united-security-providers/coraza-envoy-go-filter](https://github.com/united-security-providers/coraza-envoy-go-filter) | In-process Go HTTP filter (contrib) |
| Envoy Go dynamic module | [tetratelabs/built-on-envoy](https://github.com/tetratelabs/built-on-envoy) `coraza-waf` ([docs](https://builtonenvoy.io/extensions/coraza-waf/)) | Official “Envoy (core)” connector on coraza.io |
| Community extproc | [rikatz/coraza-envoy-extproc](https://github.com/rikatz/coraza-envoy-extproc) | Thin community sample; **no thematic WAF issues** (deps/CI only) — skip |

---

## Top issues by theme

### 1. Body buffering / EOS / trailers

| Issue | State | Why it matters |
|-------|-------|----------------|
| [proxy-wasm#289](https://github.com/corazawaf/coraza-proxy-wasm/issues/289) — HTTP/2 trailers bypass request body scan | **CLOSED** (fix [#306](https://github.com/corazawaf/coraza-proxy-wasm/pull/306)) | Classic: `end_of_stream` stays **false** when trailers follow; phase-2 never ran → **fail-open bypass**. |
| [proxy-wasm#320](https://github.com/corazawaf/coraza-proxy-wasm/issues/320) — nil panic in `OnHttpResponseTrailers` (HTTP/2 / gRPC) | **OPEN** | Trailers callbacks still fire when WAF context was never initialized (common on gRPC `grpc-status` trailers) → **crash**, not clean deny. |
| [proxy-wasm#97](https://github.com/corazawaf/coraza-proxy-wasm/issues/97) — Avoid double buffering (Envoy pause buffer + Coraza buffer) | **OPEN** | Pause-until-inspect copies body twice; Envoy default ~1 MiB → `413 Payload Too Large`. |
| [proxy-wasm#68](https://github.com/corazawaf/coraza-proxy-wasm/issues/68) / [coraza#497](https://github.com/corazawaf/coraza/issues/497) — Only buffer when inspecting | **CLOSED** | Unnecessary full-body buffer kills streaming and burns CPU/memory when `Sec*BodyAccess` is Off. |
| [proxy-wasm#158](https://github.com/corazawaf/coraza-proxy-wasm/issues/158) — Trust `Content-Length` for body limit? | **OPEN** | Early reject vs wait-for-chunks: limit policy must be explicit (Reject / ProcessPartial), never silent pass. |
| [proxy-wasm#26](https://github.com/corazawaf/coraza-proxy-wasm/issues/26) — Response-body intervention not enforced | **OPEN** (design thread) | Phase-4 detect without enforce = leak; status may stay 200 with altered/empty body — hard UX. |
| [proxy-wasm#280](https://github.com/corazawaf/coraza-proxy-wasm/issues/280) — segfault on large response (`response_payload_too_large`) | **OPEN** | Oversized response path + MIME skip rules still hit host/plugin crash. |
| [proxy-wasm#309](https://github.com/corazawaf/coraza-proxy-wasm/issues/309) — APISIX cannot intercept request body | **OPEN** | Host/proxy must actually deliver body to the WAF; config “On” ≠ body arrives. |
| [USP go-filter#129](https://github.com/united-security-providers/coraza-envoy-go-filter/issues/129) — Large JS response → HTTP 500 | **CLOSED** | Contrib Go filter uses **StopAndBuffer** for HTTP; Envoy `per_connection_buffer_limit_bytes` (~1 MiB default) bites. Maintainers note WebSockets are **not** buffered. |

**Takeaway:** “Last body chunk” ≠ “safe to skip phase-2.” Trailers, half-close, and host buffer ceilings are first-class failure modes. Deeper BUFFERED latency/memory tradeoffs for *our* ext_proc path live in [buffered-downsides.md](./buffered-downsides.md) — this section is Coraza evidence only.

---

### 2. Memory / TinyGo / Wasm limits

| Issue | State | Why it matters |
|-------|-------|----------------|
| [proxy-wasm#290](https://github.com/corazawaf/coraza-proxy-wasm/issues/290) — Proxy-Wasm Go SDK / TinyGo future | **OPEN** | tetratelabs SDK archived; TinyGo GC fundamentals called out — project exploring migration ([#313](https://github.com/corazawaf/coraza-proxy-wasm/pull/313)). |
| [proxy-wasm#219](https://github.com/corazawaf/coraza-proxy-wasm/issues/219) — OOM / panic on response body | **OPEN** | `GC Warning: Out of Memory! Heap size: 830 MiB` → VM panic / unreachable. |
| [proxy-wasm#191](https://github.com/corazawaf/coraza-proxy-wasm/issues/191), [#249](https://github.com/corazawaf/coraza-proxy-wasm/issues/249) — Memory grows under load / leak | closed / **OPEN** | Working set climbs with CRS Wasm; does not reclaim cleanly. |
| [proxy-wasm#234](https://github.com/corazawaf/coraza-proxy-wasm/issues/234) — GC failed to expand heap | **CLOSED** | Heap expansion failures under Wasm. |
| [proxy-wasm#291](https://github.com/corazawaf/coraza-proxy-wasm/issues/291) — `memoryLimit reached while writing` (~1 MB uploads) | **OPEN** | Engine/host memory ceiling mid-body → 500 / broken upstream. |
| [proxy-wasm#155](https://github.com/corazawaf/coraza-proxy-wasm/issues/155) — ~100 MB initial heap | **CLOSED** | Wasm heap sizing is a first-class ops knob. |
| [BOE#391](https://github.com/tetratelabs/built-on-envoy/pull/391) — call `WAF.Close()` on destroy | **OPEN** PR | Go dynamic module: live reload / per-route WAF without `Close()` → regex memoization leak (Coraza ≥3.5). |

**Takeaway:** In-process Wasm/Go shares the Envoy process memory budget. Out-of-process `ext_proc` + libmodsecurity isolates OOM from the data plane — a product argument for our shape, not for adopting Coraza.

---

### 3. WebSocket / gRPC / streaming

| Issue | State | Why it matters |
|-------|-------|----------------|
| [proxy-wasm#320](https://github.com/corazawaf/coraza-proxy-wasm/issues/320) | **OPEN** | gRPC = HTTP/2 trailers always; uninitialized WAF ctx → panic on trailers path. |
| USP [#129](https://github.com/united-security-providers/coraza-envoy-go-filter/issues/129) comments | — | Maintainers: **buffer whole HTTP body**; **do not buffer WebSockets**. |
| [coraza#497](https://github.com/corazawaf/coraza/issues/497) / [proxy-wasm#68](https://github.com/corazawaf/coraza-proxy-wasm/issues/68) | **CLOSED** | Full buffer breaks stream-like workloads. |
| [BOE coraza-waf docs](https://builtonenvoy.io/extensions/coraza-waf/) `mode` | — | `REQUEST_ONLY` / `FULL` / deprecated `RESPONSE_ONLY`; body access still needs SecLang (`SecResponseBodyAccess`). CRS expects request-phase init. |

**No strong “WebSocket frame WAF” success story** in Coraza Envoy issues — scope honesty matches [http-grpc-websocket-scope.md](./http-grpc-websocket-scope.md): do not claim frame-level CRS without a design.

---

### 4. Fail-open / fail-closed / timeouts / process health

| Issue | State | Why it matters |
|-------|-------|----------------|
| [#289](https://github.com/corazawaf/coraza-proxy-wasm/issues/289) class | **CLOSED** | Missing finalize path = **silent allow** (worst class). |
| [proxy-wasm#171](https://github.com/corazawaf/coraza-proxy-wasm/issues/171) — deny still reaches app | **CLOSED** | Client saw 403 but upstream still got the request until multiphase evaluation ([#194](https://github.com/corazawaf/coraza-proxy-wasm/pull/194)). **Deny must stop the chain**, not only local-reply. |
| [proxy-wasm#278](https://github.com/corazawaf/coraza-proxy-wasm/issues/278) — Wasm makes Envoy admin unresponsive | **OPEN** | In-VM work starves `/ready` → k8s kills “healthy” pods. Failure isolation argument for ext_proc. |
| [proxy-wasm#320](https://github.com/corazawaf/coraza-proxy-wasm/issues/320) | **OPEN** | Panic in trailers ≠ fail-closed HTTP response. |
| [BOE#324](https://github.com/tetratelabs/built-on-envoy/issues/324) — `RESPONSE_ONLY` unexpectedly fails requests | **OPEN** | Wrong mode / skipped request-phase init breaks CRS assumptions. |

Envoy-side `failure_mode_allow` / ext_proc timeouts are **our** knobs (see [preferences-fail-closed.md](./preferences-fail-closed.md)); Coraza issues mostly show in-process crash/bypass, not clean timeout policy.

---

### 5. Envoy version / ABI / host skew

| Issue | State | Why it matters |
|-------|-------|----------------|
| [proxy-wasm#308](https://github.com/corazawaf/coraza-proxy-wasm/issues/308) — 0.5.0 / 0.3.0 fail on Istio 1.26.1 | **OPEN** | Wasm binary ↔ Istio/Envoy host coupling. |
| [proxy-wasm#313](https://github.com/corazawaf/coraza-proxy-wasm/pull/313) — migrate TinyGo → Go Wasm | **OPEN** WIP | Depends on [proxy-wasm-cpp-host#433](https://github.com/proxy-wasm/proxy-wasm-cpp-host/pull/433) landing in Envoy/Istio — ABI/host churn. |
| USP go-filter continuous Envoy bumps | e.g. [#145](https://github.com/united-security-providers/coraza-envoy-go-filter/pull/145), [#134](https://github.com/united-security-providers/coraza-envoy-go-filter/pull/134) | Contrib filter tracks Envoy contrib images closely. |
| [built-on-envoy releases](https://github.com/tetratelabs/built-on-envoy/releases) | — | Composer Go modules require **Envoy ≥ 1.38** for newer dynamic-module APIs — version floor is real. |

**Takeaway:** In-process filters pay ABI tax. gRPC `ext_proc` to a sidecar/process we control decouples ModSec from Envoy Wasm/Go-plugin ABI — keep that advantage.

---

### 6. Performance

| Issue | State | Why it matters |
|-------|-------|----------------|
| [proxy-wasm#262](https://github.com/corazawaf/coraza-proxy-wasm/issues/262) — CRS ≈ 5× hit | **OPEN** | Single custom rule OK; full CRS expensive. |
| [proxy-wasm#316](https://github.com/corazawaf/coraza-proxy-wasm/issues/316) — ~10× drop with rules (APISIX) | **OPEN** | Flamegraphs / rule count (~669) dominate; not “Wasm tax” alone. |
| [proxy-wasm#225](https://github.com/corazawaf/coraza-proxy-wasm/issues/225) — how to measure p90/p99 vs Envoy-Go | **OPEN** | Operators want Wasm vs Go-filter comparison — no consensus numbers in-thread. |
| [#313](https://github.com/corazawaf/coraza-proxy-wasm/pull/313) notes | — | Go Wasm FTW ~2× slower than TinyGo in author’s PoC; binary larger. |

CRS cost is engine + rule volume; expect similar order-of-magnitude on libmodsecurity. Measure our connector separately — do not inherit Coraza’s Wasm numbers as ModSec SLOs.

---

### 7. Engine fidelity (why product stays ModSec)

| Issue | State | Note |
|-------|-------|------|
| [coraza#1685](https://github.com/corazawaf/coraza/issues/1685) — `REQUEST_BODY` empty after JSON/XML processor vs libmodsecurity | **OPEN** | Explicit divergence from ModSec v3 — reinforces **do not switch engines** for CRS fidelity. |

---

## Lessons for ModSec `ext_proc` connector

1. **Accumulate → true end → `process_*_body` → then continue/deny.** Never treat “last chunk” alone as EOS when trailers or stream errors can follow ([#289](https://github.com/corazawaf/coraza-proxy-wasm/issues/289)).
2. **Trailers / gRPC paths must be nil-safe and finalize-or-fail-closed** — panics and skipped phase-2 are both wrong ([#320](https://github.com/corazawaf/coraza-proxy-wasm/issues/320)).
3. **Deny must stop upstream**, not only return a client error ([#171](https://github.com/corazawaf/coraza-proxy-wasm/issues/171)).
4. **Single coherent body budget** — Envoy buffer limits + ModSec `Sec*BodyLimit` + action (Reject/ProcessPartial) must agree; oversized paths must deny or partial-process by policy, not 500/segfault ([#97](https://github.com/corazawaf/coraza-proxy-wasm/issues/97), USP [#129](https://github.com/united-security-providers/coraza-envoy-go-filter/issues/129), [#280](https://github.com/corazawaf/coraza-proxy-wasm/issues/280)).
5. **Buffer only when body access is On** — streaming/WebSocket upgrades should not inherit HTTP full-buffer ([#68](https://github.com/corazawaf/coraza-proxy-wasm/issues/68), USP comments).
6. **Out-of-process is a reliability feature** — Wasm OOM / admin freeze ([#219](https://github.com/corazawaf/coraza-proxy-wasm/issues/219), [#278](https://github.com/corazawaf/coraza-proxy-wasm/issues/278)) argue for ext_proc + `failure_mode_allow: false`, not for Coraza.
7. **Expect CRS latency cost**; pin SLOs with our lab, not Coraza Wasm anecdotes ([#262](https://github.com/corazawaf/coraza-proxy-wasm/issues/262), [#316](https://github.com/corazawaf/coraza-proxy-wasm/issues/316)).
8. **Steal the pattern, not the product** — [coraza#1685](https://github.com/corazawaf/coraza/issues/1685) and Etienne preference: libmodsecurity remains the engine.

---

## What we did *not* find

- Community [coraza-envoy-extproc](https://github.com/rikatz/coraza-envoy-extproc): no filed body/EOS/fail-mode issues — not a learning source beyond “ext_proc + Coraza is experimented with.”
- No Coraza Envoy issue that overturns fail-closed or recommends silent headers-only as a product default.
