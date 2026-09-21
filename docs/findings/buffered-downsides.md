---
cursor:
  subagentId: "bc-1531b582-97b3-56f2-8299-5adcb97d5202"
---

# Downsides of BUFFERED body approaches (Envoy ext_proc × ModSec/CRS)

**Audience:** Etienne  
**Date:** 2026-09-21  
**Mode:** Analysis only — no code/lab/repo edits.  
**Lab context:** request + response `BUFFERED` via Envoy `ext_proc` → libmodsecurity + CRS ([approach-options.md](./approach-options.md), [http-grpc-websocket-scope.md](./http-grpc-websocket-scope.md)).

**Evidence legend:** **[doc]** = Envoy/ModSec primary docs or merged fix descriptions · **[issue]** = GitHub bug/enhancement report · **[anecdote]** = operator/community reports (not normative).

---

## Short list of downsides (with evidence)

| # | Downside | Why it hurts BUFFERED | Evidence |
|---|----------|----------------------|----------|
| 1 | **Whole-body RAM + hard reject at limit** | Envoy holds the entire entity in memory, then sends one `HttpBody` to ext_proc. Over the configured buffer limit → downstream error (typically **413** via `per_connection_buffer_limit_bytes` / buffer filter). | **[doc]** [BodySendMode.BUFFERED](https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/filters/http/ext_proc/v3/processing_mode.proto.html) — “If the body exceeds the configured buffer limit, then the downstream system will receive an error.” · **[issue]** [envoy#37626](https://github.com/envoyproxy/envoy/issues/37626) — no first-class `max_req_body` on ext_proc; operators stuck with non-obvious listener/buffer limits (closed stale, unshipped). |
| 2 | **413 path has been buggy (hang instead of reject)** | While waiting for header response, wrong watermark vs buffer status meant oversized BUFFERED requests could **stall until timeout** instead of local 413 (since ~v1.32; fixed). | **[issue]** [envoy#39365](https://github.com/envoyproxy/envoy/issues/39365) · **[doc/fix]** [PR #39345](https://github.com/envoyproxy/envoy/pull/39345) — BUFFERED must use `StopIterationAndBuffer` so limit triggers 413. |
| 3 | **TTFB / latency floor = full upload + one big RPC** | Upstream (and often header finalize) waits until EOS + external processor returns. Large/slow clients pay buffering time *before* ModSec phase-2, then another wait for the connector. Default `message_timeout` is **200ms** (must be raised for large BUFFERED bodies). | **[doc]** [ext_proc.proto `message_timeout`](https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/filters/http/ext_proc/v3/ext_proc.proto) · inherent to BUFFERED send-at-once. |
| 4 | **Large uploads are a first-class conflict** | Multi‑MB/GB POSTs force either huge Envoy buffers (DoS risk) or frequent 413s. Operators who need huge uploads explicitly reject BUFFERED. | **[anecdote]** [envoy#38291](https://github.com/envoyproxy/envoy/issues/38291) — “BUFFERED mode isn’t an option for us due to extremely large file uploads.” · Fastly NGWAF Envoy recipe pairs BUFFERED with an explicit buffer filter `max_request_bytes` (e.g. 1 MB) — **[doc]** [Fastly Kubernetes Envoy setup](https://www.fastly.com/documentation/guides/next-gen-waf/setup-and-configuration/kubernetes/kubernetes-envoy/). |
| 5 | **WebSocket / upgrade / streaming gRPC can silent-hang** | Anything that never sends HTTP `END_STREAM` while expecting an upgrade/stream response will wait forever if a full-body buffer sits in the path. Same class of failure as Envoy’s HTTP buffer filter. | **[issue]** [envoy#1053](https://github.com/envoyproxy/envoy/issues/1053) — mattklein: buffer filter “should not be used in streaming API scenarios.” · **[issue]** [envoyproxy/gateway#8578](https://github.com/envoyproxy/gateway/issues/8578) — `requestBuffer` + WebSocket = silent deadlock (`end_stream=false`). · **[anecdote]** Traefik ModSec middleware **skips** WebSocket entirely and still buffers all other bodies ([plugin issue #6](https://github.com/acouvreur/traefik-modsecurity-plugin/issues/6)). · Lab product stance: handshake-only WS, not frame WAF — [http-grpc-websocket-scope.md](./http-grpc-websocket-scope.md). |
| 6 | **Double buffering (Envoy + ModSec)** | Even after Envoy BUFFERED delivery, libmodsecurity with `SecRequestBodyAccess On` buffers again for phase-2. Response buffering adds memory **and** latency by design. | **[doc]** [ModSecurity Reference Manual — SecRequestBodyAccess](https://github.com/owasp-modsecurity/ModSecurity/wiki/Reference-Manual-(v3.x)) (“buffer request bodies”; required for reliable blocking) · **[doc]** `SecResponseBodyAccess` notes increased memory + response latency · **[doc]** recommended defaults `SecRequestBodyLimit 13107200` / `SecRequestBodyNoFilesLimit 131072` in [modsecurity.conf-recommended](https://github.com/owasp-modsecurity/ModSecurity/blob/master/modsecurity.conf-recommended). |
| 7 | **Content-Length mutation is stricter / operator-owned** | In `BUFFERED` + `SEND` headers, Envoy keeps `Content-Length` but the processor must set length matching the mutated body or mutation is rejected. `BUFFERED_PARTIAL` strips CL (chunked). | **[doc]** [processing_mode.proto Content-Length rules](https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/filters/http/ext_proc/v3/processing_mode.proto.html) · **[doc/fix]** [PR #29536](https://github.com/envoyproxy/envoy/pull/29536) / release notes quoted in [#38291](https://github.com/envoyproxy/envoy/issues/38291). |
| 8 | **`BUFFERED_PARTIAL` is not “CRS-safe buffering”** | Sends only up to the buffer limit; remainder is not in the one-shot body message. Partial inspection ≠ full CRS fidelity (evasion / ProcessPartial class risk). | **[doc]** BUFFERED_PARTIAL definition in [processing_mode.proto](https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/filters/http/ext_proc/v3/processing_mode.proto.html) · ModSec `SecRequestBodyLimitAction ProcessPartial` same honesty problem — **[doc]** [SecRequestBodyLimitAction](https://github.com/owasp-modsecurity/ModSecurity/wiki/Reference-Manual-(v3.x)). |

---

## BUFFERED vs BUFFERED_PARTIAL vs STREAMED (Envoy semantics)

| Mode | What Envoy does | Limit behavior | Fit for stock CRS phase-2 |
|------|-----------------|----------------|---------------------------|
| **BUFFERED** | Hold full body → one message at EOS | Over limit → **error** to downstream | Best host-side match if size capped and denied |
| **BUFFERED_PARTIAL** | Hold up to limit → one (truncated) message | Over limit → send **prefix only** | Incomplete body → not full CRS claim |
| **STREAMED** / **FULL_DUPLEX_STREAMED** | Chunks as they arrive | Watermarks; not the same whole-body 413 story | Only if **connector** re-assembles to EOS before `process_*_body` |

Primary: [processing_mode.proto](https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/filters/http/ext_proc/v3/processing_mode.proto.html), [ext_proc.proto](https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/filters/http/ext_proc/v3/ext_proc.proto).

---

## When BUFFERED is still the right **default** for CRS / ModSec

1. **Engine invariant:** ModSec phase-2 / CRS body rules need a coherent body (or an explicit Reject/ProcessPartial policy) — not per-chunk allow. Envoy BUFFERED matches that “complete entity then decide” shape ([approach-options.md](./approach-options.md) option A).
2. **ext_proc feature fit:** Header mutations together with body responses are designed for BUFFERED ([PR #15935](https://github.com/envoyproxy/envoy/pull/15935); docs: header mutations on `HttpBody` responses only in BUFFERED).
3. **Content-Length control:** BUFFERED + SEND is the mode that keeps CL under processor responsibility without the STREAMED strip/smuggling footgun (unless `allow_content_length_header` is carefully used).
4. **Proven lab claim:** Full go-ftw on BUFFERED HTTP is the honesty meter today; STREAMED is deferred until re-proven ([http-grpc-websocket-scope.md](./http-grpc-websocket-scope.md)).
5. **Industry parallel:** At least one production WAF-via-ext_proc recipe documents **BUFFERED** + explicit max body bytes (Fastly NGWAF link above) — **[doc]** pattern, not a ModSec endorsement.
6. **Fail-closed coupling:** No upstream until phase-2 (or limit reject) is operationally clearer than streaming half-states — provided limits **deny**, never pass-through ([preferences-fail-closed.md](./preferences-fail-closed.md)).

Keep BUFFERED off WebSocket/upgrade and client-/bidi-gRPC streaming routes; use headers-only (or skip body mode) with honest labels there.

---

## What STREAMED does / does **not** fix

### Does (or can) improve

- Avoids Envoy holding the **entire** body before the first ext_proc body RPC; better for very large entities at the **proxy** layer.
- Uses watermarking while waiting in non-BUFFERED paths (see source comments / #39345 discussion) instead of always taking the hard whole-body 413 path.
- Lets the connector own accumulate → EOS → `process_*_body` (Coraza-like pattern) if product chooses option B in [approach-options.md](./approach-options.md).

### Does **not** fix

| Still broken / still owed | Why |
|---------------------------|-----|
| **ModSec memory & SecRequestBody\*** | Connector (or engine) still needs a full (or policy-truncated) body for CRS; STREAMED only moves where buffering lives. |
| **CRS fidelity without reassembly** | Per-chunk inspection is incomplete; STREAMED without accumulate = capability cut. |
| **WebSocket frame inspection** | Post-upgrade frames are not HTTP bodies; STREAMED ext_proc does not create a WS WAF. |
| **gRPC streaming lifetime** | Long-lived streams still lack a single “complete request body” for phase-2. |
| **Content-Length / mutation ergonomics** | STREAMED strips CL by default; header mutations on body responses historically BUFFERED-only ([#38291](https://github.com/envoyproxy/envoy/issues/38291)). |
| **ext_proc STREAMED correctness debt** | Active issues around truncation, half-close, duplicate EOS, HTTP/1.1 upgrades — see project rollup [github-issues-envoy-modsec-crs.md](./github-issues-envoy-modsec-crs.md) (#47449, #47458, #46237, #47161, #47081). Switching mode trades BUFFERED’s limit/latency problems for a larger correctness surface. |
| **message_timeout semantics** | STREAMED may multiply per-chunk RPC timeouts; FULL_DUPLEX_STREAMED disables message timeout — different failure mode, not “no timeout risk.” **[doc]** ext_proc.proto. |

---

## Practical takeaway for this lab

- **Default BUFFERED for HTTP + CRS** remains correct: matches ModSec phase-2, keeps mutation semantics sane, matches green go-ftw proof.
- **Pay the tax:** sized `per_connection_buffer_limit_bytes` / buffer filter, aligned `SecRequestBodyLimit` (+ Reject), raised `message_timeout`, fail-closed on oversize — never silent pass.
- **Carve out** WebSocket upgrades and streaming gRPC from body BUFFERED; do not expect STREAMED alone to make those protocols CRS-complete.
- Treat **BUFFERED_PARTIAL** and ModSec **ProcessPartial** as honesty downgrades, not drop-in upgrades.

---

## Primary URLs (bookmark set)

| Topic | URL | Class |
|-------|-----|-------|
| BodySendMode defs + CL rules | https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/filters/http/ext_proc/v3/processing_mode.proto.html | doc |
| ext_proc filter + message_timeout | https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/filters/http/ext_proc/v3/ext_proc.proto | doc |
| HTTP buffer filter 413 | https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/filters/http/buffer/v3/buffer.proto | doc |
| No max body on ext_proc | https://github.com/envoyproxy/envoy/issues/37626 | issue |
| BUFFERED 413 hang bug | https://github.com/envoyproxy/envoy/issues/39365 · https://github.com/envoyproxy/envoy/pull/39345 | issue / fix |
| STREAMED CL / large upload | https://github.com/envoyproxy/envoy/issues/38291 | issue + anecdote |
| Buffer filter vs gRPC streaming | https://github.com/envoyproxy/envoy/issues/1053 | issue (design) |
| EG requestBuffer × WebSocket hang | https://github.com/envoyproxy/gateway/issues/8578 | issue |
| ModSec body buffering directives | https://github.com/owasp-modsecurity/ModSecurity/wiki/Reference-Manual-(v3.x) | doc |
| Recommended ModSec body limits | https://github.com/owasp-modsecurity/ModSecurity/blob/master/modsecurity.conf-recommended | doc |
| BUFFERED header+body mutations | https://github.com/envoyproxy/envoy/pull/15935 | doc/fix |
| WAF-via-ext_proc BUFFERED recipe | https://www.fastly.com/documentation/guides/next-gen-waf/setup-and-configuration/kubernetes/kubernetes-envoy/ | doc (vendor) |
