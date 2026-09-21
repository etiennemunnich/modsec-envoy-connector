---
cursor:
  subagentId: "bc-dee43e7f-f3fc-5550-b158-8d7d484ca0f8"
---

# Protocol scope — HTTP + gRPC + WebSocket (Envoy → ModSec → origin)

**Audience:** Etienne (product direction)  
**Date:** 2026-09-21  
**Mode:** Analysis only — no implementation, no lab runs, no repo edits.  
**Product:** libmodsecurity + OWASP CRS via Rust Envoy `ext_proc` connector. Path: **Envoy → ModSec (libmodsecurity) → origin**.  
**Coraza:** reference-only where cited ([coraza-design-lessons-for-modsec.md](./coraza-design-lessons-for-modsec.md)).

**Inputs (not rewritten):** [approach-options.md](./approach-options.md) · [coraza-design-lessons-for-modsec.md](./coraza-design-lessons-for-modsec.md) · [preferences-fail-closed.md](./preferences-fail-closed.md) · [prod-readiness.md](./prod-readiness.md) · [preferences-protocol-scope.md](./preferences-protocol-scope.md)

**Invariant (absolute):** Fail-closed must hold on whatever capability is *claimed* for a route — connector down, gRPC error, panic, hang/timeout, ModSec init/rules fail, ExtProc unreachable. Body/protocol mode does not relax this ([preferences-fail-closed.md](./preferences-fail-closed.md)).

---

## 1. HTTP — baseline (what we already have)

| Layer | Status |
|-------|--------|
| Architecture | Envoy `ext_proc` → Rust connector → **libmodsecurity** + CRS → origin |
| Body delivery | Envoy **BUFFERED** request + response bodies (lab `compose/lab/envoy.host.yaml`) |
| Engine ordering | Append body → end-of-body → `process_*_body` (phase 2) before allow |
| CRS fidelity | Full go-ftw **5091 / 0 / 0** on BUFFERED tip (`e81e9c6`) |
| Fail-closed | `failure_mode_allow: false` + live `./scripts/lab-fail-closed.sh` (15/15 PASS) |
| Maturity | **Lab-ready**, not prod-deployable ([prod-readiness.md](./prod-readiness.md)). STREAMED deferred |

**Honest claim today:** “Full CRS on BUFFERED HTTP ext_proc” — proven. This remains the **product baseline** and the honesty meter for any multi-protocol story.

**Not claimed:** STREAMED HTTP delivery; gRPC payload CRS; WebSocket frame inspection.

From [approach-options.md](./approach-options.md): options A (BUFFERED) / B (STREAMED reassembly) are still open for HTTP body *delivery*; neither changes the ModSec phase-2 complete-body invariant. Headers-only as a silent default remains rejected for HTTP product claims.

---

## 2. gRPC — how it looks on Envoy, what ModSec can do

### 2.1 Wire shape on Envoy

gRPC over Envoy is **HTTP/2** (or HTTP/3) with:

- Path = `/package.Service/Method`
- Headers include `content-type: application/grpc` (and often `:authority`, `grpc-timeout`, encoding)
- Body = length-prefixed **protobuf** (or other codec) frames, not form/JSON that CRS assumes

Envoy terminates/proxies that as an HTTP request on the HTTP connection manager. `ext_proc` still sees **HTTP phases** (request/response headers, bodies, trailers) — not a native “gRPC WAF API.”

### 2.2 What ModSec / CRS can and cannot do

| Surface | Realistic ModSec value |
|---------|------------------------|
| **Request/response headers** | Useful: method/path, content-type, auth-ish headers, size/encoding anomalies, some protocol-abuse rules. Phase 1 / header CRS still apply. |
| **Protobuf body as bytes** | Weak for stock CRS: rules expect HTTP parameter/XML/JSON/multipart semantics. Raw binary rarely matches body-reliant CRS without custom rules or a protobuf-aware preprocessor (out of current product scope). |
| **“Scan each gRPC DATA frame alone”** | Unsafe / incomplete — same split-body problem as HTTP streaming ([coraza-design-lessons-for-modsec.md](./coraza-design-lessons-for-modsec.md): accumulate → EOS → `Process*Body`). |

**Streaming EOS problem (critical):** Unary RPCs have a clear request end; **client-/bidi-streaming** may not present a single “complete request body” before the stream lives a long time. Waiting for full reassembly before phase-2 can mean:

- unbounded buffering, or
- never reaching a phase-2 decision while messages keep flowing

That collides with fail-closed *and* with CRS complete-body semantics. Coraza’s trailer/EOS lesson still applies for HTTP/2 ends that omit a clean `end_of_stream` on the last body chunk — but gRPC streaming adds a longer-lived duplex shape on top.

### 2.3 Envoy config levers (conceptual)

| Lever | Effect for gRPC routes |
|-------|------------------------|
| **Route-level `processing_mode` headers-only** | Send request/response headers to ext_proc; **SKIP** bodies. Honest “header WAF” for gRPC. Avoids protobuf / streaming reassembly. |
| **Headers + BUFFERED body** | Only sane for **unary** with bounded message size and an explicit “we inspect opaque bytes / custom rules” claim — **not** “full CRS.” |
| **STREAMED / FullDuplexStreamed body** | Highest risk: EOS, trailers, half-close bugs already tracked on ExtProc ([github-issues prior art](./github-issues-envoy-modsec-crs.md)); plus gRPC streaming lifetime. Do not advertise without dedicated proof. |
| **`failure_mode_allow: false`** | Mandatory on any route that claims protection. Connector failure must deny the RPC (typically 5xx / local reply), not pass. |

### 2.4 Fail-closed implications

- If gRPC is **in product scope** with headers-only: fail-closed still applies to header processing and ExtProc availability — deny on connector fault during those phases.
- If body inspection is **on** for unary: no upstream until phase-2 (or explicit limit Reject). Buffer/timeout must **deny**, not pass-through.
- If streaming body inspection cannot complete: **do not** redefine as OK. Either refuse the mode, force headers-only with honest labeling, or fail-closed when inspection cannot finish.

### 2.5 Unary vs streaming (product honesty)

| RPC shape | Feasible ModSec posture (honest) |
|-----------|----------------------------------|
| **Unary** | Headers-only (recommended default for stock CRS). Optional opaque-body / custom-rule mode with size limits — never “full CRS” without evidence. |
| **Server-streaming** | Headers + maybe first message heuristics only with custom work; stock CRS body claim **no**. Prefer headers-only. |
| **Client- / bidi-streaming** | Headers-only for connex v1. Full-body CRS is not a credible stock-ModSec claim without a separate streaming policy product. |

---

## 3. WebSocket — handshake vs frames

### 3.1 Two different worlds

| Phase | What travels | ModSec / ext_proc reality |
|-------|--------------|---------------------------|
| **Upgrade handshake** | HTTP/1.1 `Upgrade: websocket`, `Connection: Upgrade`, `Sec-WebSocket-*`, or HTTP/2 Extended CONNECT | Still HTTP. Headers (and optional tiny body) can go through ext_proc like any other request. |
| **Post-upgrade frames** | Opaque WebSocket frames (text/binary/control) on the upgraded connection | **ModSec does not inspect these.** CRS has no meaningful “WS frame” phase. ext_proc is an **HTTP** filter path — after 101 / tunnel success, traffic is no longer normal HTTP request/response bodies. |

**Honest claim:** handshake-time header (and optional HTTP-body) inspection — **not** “WebSocket WAF” or “CRS on WS frames.”

### 3.2 Envoy upgrade path + BUFFERED risk

- Envoy must allow the upgrade (`upgrade_configs` / HCM upgrade map) and typically treat the connection as a tunnel after success.
- **BUFFERED body modes on upgrade routes are dangerous:** waiting to buffer a “full body” before answering can **break or hang the 101 Switching Protocols** path. Prior art already flags ExtProc + HTTP/1.1 upgrade hangs with aggressive stream body modes ([envoy#47161](https://github.com/envoyproxy/envoy/issues/47161) / related in [github-issues](./github-issues-envoy-modsec-crs.md)).
- Practical default for WS routes: **headers-only** (and trailers if any) during handshake; **do not** BUFFERED-body the upgrade request as if it were a CRS POST.

### 3.3 Fail-closed during handshake

- Connector/ExtProc failure **before** upgrade completes → deny handshake (no 101). Aligns with absolute fail-closed.
- After upgrade, ModSec is **out of the frame path**. Fail-closed cannot invent frame inspection. Remaining controls are Envoy-level (route allowlist, authn at handshake, idle timeouts, max duration) — outside ModSec CRS fidelity.
- Do not claim fail-closed “covers WebSocket payloads.” Claim: fail-closed on **handshake inspection**; post-upgrade is explicitly **uninspected by ModSec**.

---

## 4. Unified architecture options (one connector product)

Goal: one ModSec ext_proc connector binary/product, honest multi-protocol surface — not three engines.

### Option U1 — Per-route `processing_mode` (likely primary shape)

| Route class | Mode | Claim |
|-------------|------|-------|
| HTTP (default) | Full headers + **BUFFERED** bodies (proven) | Full CRS |
| gRPC | Headers-only (SKIP body) | Header WAF / protocol abuse — **not** full CRS on protobuf |
| WebSocket / upgrade | Headers-only on handshake | Handshake-only — **not** frame CRS |

**Pros:** One listener possible; matches Envoy’s native per-route override story; keeps HTTP green path untouched.  
**Cons:** Mis-tagged routes (gRPC on “HTTP full body”) cause either broken upgrades/streaming or false “full CRS” marketing. Needs clear docs + route classification discipline.

### Option U2 — Separate listeners / filter chains

| Chain | Purpose |
|-------|---------|
| `:443` / HTTP API | Full BUFFERED ModSec |
| `:443` SNI or dedicated port / `application/grpc` matcher | Headers-only ModSec |
| Upgrade-enabled chain | Headers-only; upgrade_configs isolated |

**Pros:** Hard separation reduces accidental BUFFERED-on-upgrade; ops can scale/fail independently.  
**Cons:** Higher ops complexity; duplicate ExtProc clusters/config; easy to drift rules versions across chains unless disciplined.

### Option U3 — Explicit “unsupported / bypass with audit”

Allow selected routes to **skip** ExtProc entirely, with mandatory audit/metrics (“unprotected path”).

| Honesty | Security |
|---------|----------|
| **Honest** if labeled “bypass — not WAF-protected” and never sold as CRS | **Weak** — intentional hole; attackers aim here |
| Dishonest if README still says “all traffic ModSec” | Fail-closed absolute is **violated in spirit** for that traffic |

**Product stance (recommended framing for Etienne):** Prefer U1/U2 with **headers-only** over silent bypass. If bypass exists, it must be a named, audited exception — never the default for in-scope protocols. “Bypass with audit” trades security for honesty; it does **not** satisfy fail-closed for those flows.

### Hybrid (common in practice)

U1 as default product config, U2 for high-assurance isolation of upgrade/gRPC, U3 only for explicitly accepted exceptions (health checks, metrics scrape) — not for application gRPC/WS.

---

## 5. Outcomes matrix (by protocol)

Ratings assume stock CRS + libmodsecurity via ext_proc; custom protobuf/WS frame engines are out of scope.

| Dimension | HTTP (BUFFERED baseline) | gRPC (headers-only) | gRPC (body on / streaming) | WebSocket (handshake headers-only) | WebSocket (claim frame CRS) |
|-----------|--------------------------|---------------------|----------------------------|------------------------------------|-----------------------------|
| **Security honesty** | Strong — matches proven claim | Strong if labeled header-only | Weak unless custom rules + limits documented | Strong if labeled handshake-only | **False** — ModSec cannot do it |
| **CRS fidelity** | **5091/0/0 proven** | Partial (header/protocol rules only) | Poor for stock CRS on protobuf | Partial (handshake headers) | None |
| **Fail-closed** | Strong (live gate) | Strong on claimed phases | Hard — streaming EOS / buffer caps must deny | Strong on handshake; N/A post-upgrade for ModSec | N/A — claim invalid |
| **Ops complexity** | Lowest (current lab) | Medium (route modes / matchers) | High (STREAMED + streaming RPC proof) | Medium (upgrade config + headers-only) | Misleading complexity — wrong problem |

Relative to unified options:

| Dimension | U1 per-route mode | U2 separate chains | U3 bypass+audit |
|-----------|-------------------|--------------------|-----------------|
| Honesty | High if labels enforced | High if chains documented | High only if bypass never marketed as protected |
| CRS on HTTP | Preserved | Preserved | Risk of accidental bypass of HTTP |
| Fail-closed | Holds on protected routes | Holds per chain | **Does not** hold on bypassed routes |
| Ops | Medium | Higher | Low ops, high governance debt |

---

## 6. Open decisions for Etienne (questions only)

1. **Product sentence for connex v1:** Is the public claim “Full CRS on HTTP; header/handshake inspection on gRPC and WebSocket,” or must all three protocols share one capability bar before shipping?
2. **gRPC default mode:** Headers-only forever for stock CRS, or invest in unary opaque-body / custom-rule profile as a named second tier?
3. **Streaming gRPC:** Explicitly **unsupported** (fail config / refuse route), headers-only only, or require a future streaming policy before any gRPC marketing?
4. **WebSocket post-upgrade:** Accept “ModSec stops at handshake” as the permanent product truth, or keep WS out of the product name until a non-ModSec frame inspector exists?
5. **Unified shape:** Prefer U1 (per-route `processing_mode`), U2 (separate chains), or hybrid — as the connex default topology?
6. **Bypass class (U3):** Allowed for health/metrics only, allowed for app routes with audit, or banned when protocol is “in scope”?
7. **Fail-closed proof expansion:** Before claiming gRPC/WS support, must `lab-fail-closed.sh` gain handshake-deny and gRPC ExtProc-down cases, or is HTTP gate enough while docs limit the claim?
8. **Misconfiguration severity:** If a WS/gRPC route accidentally inherits HTTP BUFFERED body mode, is that a **hard config reject**, a runtime fail-closed, or a documented footgun?
9. **Relation to HTTP STREAMED roadmap ([approach-options](./approach-options.md) A vs B):** Does multi-protocol work wait on BUFFERED-only HTTP claims, or can gRPC/WS headers-only ship in parallel while HTTP STREAMED stays deferred?
10. **Connex migrate timing:** Freeze HTTP BUFFERED lab first, then add protocol matrix docs — or hold private connex create until gRPC/WS honesty labels are decided?

---

## Scope of this write

- **Created:** `/cursor/stores/bc-cd276624-32a5-4521-b433-4a550531888f/docs/http-grpc-websocket-scope.md` only.
- **No** experiment-repo edits, lab runs, pushes, PRs, or `envoy-modsec-connex` create/submit.
- **Zero filesystem changes outside** this Context docs file.
