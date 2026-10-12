# Fail-closed

If ModSecurity cannot produce a trustworthy allow/deny decision, the request **must not** reach upstream. That is a different class from a **rule deny (403)**. Envoy alone cannot cover every class.

Cross-links: [how-it-works.md](./how-it-works.md) · [testing.md](./testing.md) · pins in [`versions.lock.md`](../versions.lock.md).

---

## Six classes (do not conflate)

| # | Class | Who enforces | Default | Client |
|---|-------|--------------|---------|--------|
| **1** | Connector process / gRPC stream fail (incl. the connector aborting a stream it cannot read) | **Envoy** (`failure_mode_allow: false`) | Fail closed | **500** |
| **2** | Rules / engine init at boot (incl. a ruleset with 0 rules) | **Connector**: refuse listen / exit; healthz not 200 | Refuse service | Envoy **500** |
| **3** | Per-request ModSec / FFI `Err` | **Connector**: `ImmediateResponse` **500** | Fail closed | **500** |
| **4** | Rule intervention (deny) | Connector maps intervention | Policy deny (not “failure”) | **403** typical |
| **5** | Stall past `message_timeout` | **Envoy** `message_timeout` (lab **2s**) | Fail closed | **504** |
| **6** | Audit / partial CRS write | Connector telemetry | Best-effort; do **not** open traffic | Unchanged from 1–5 |

**Deny ≠ fail:** **403** means the WAF decided; **500** / **504** means the WAF could not decide.

**Never:** `failure_mode_allow: true` on enforcement; Continue after engine error (“connector-lie fail-open”); ending the gRPC stream with status **OK** while Envoy still waits for a verdict. Envoy v1.39 treats an OK close as "processing complete" and forwards what it holds, so an OK close is a Continue. v0.1.0-alpha.1 did exactly that when a message failed to decode (e.g. a body above tonic's 4 MiB limit), which let such a request reach origin uninspected. The connector now aborts with gRPC `INTERNAL` instead.

---

## Who owns what

```text
Envoy ext_proc (failure_mode_allow:false)
  Owns: stream establish / gRPC fail → 500
        stall past message_timeout → 504
  Cannot see: “ModSec Err but connector said Continue”

Rust connector
  Owns: boot Rules, per-request msc_* Result→500, intervention→403
  Must never: Continue after engine error

libmodsecurity (in-process FFI)
  Owns: SecLang eval + intervention
```

---

## Status by class

| Class | Proven by | How |
|-------|-----------|-----|
| **1** connector killed | live drill, H1 + H2 | `fail-closed.sh`, `fail-modes.sh`: SIGKILL → Envoy **500** for GET, POST and attack requests; origin hit count unchanged; `failure_mode_allowed` stays 0 |
| **1** connector aborts the stream | gRPC tests | message above `--max-grpc-message-bytes` → gRPC `INTERNAL`, never OK (`oversize_message_aborts_stream_never_ok`, `oversize_message_never_ok_in_full_duplex`; negative control `raised_message_limit_inspects_large_body` → 403); Envoy half-close with a FULL_DUPLEX body held → `INTERNAL` (`half_close_with_held_body_aborts_stream`); panic → stream reset (`panic_resets_stream_never_ok`); status-0 drop → `ABORTED` (`drop_intervention_aborts_stream`) |
| **2** bad rules at boot | live drill + unit test | invalid SecLang or a missing `Include` → connector exits non-zero, nothing listens, healthz down, Envoy **500**; `invalid_seclang_is_rejected`, `rules_are_required`; empty or directives-only rules files (0 rules) are refused the same way (`zero_rule_rulesets_are_rejected`) |
| **3** per-request engine error / protocol violation | gRPC integration tests only (see below) | Mid-exchange `EngineError` after the session is open (test-only fail-inject; phase-order Err; NUL in header) and protocol violations → `ImmediateResponse` **500**, details `modsec_fail_closed`. Floor ≥ **8** tests matching `fails_closed` / `fail_closed` in `crates/ext-proc-modsec/tests/grpc.rs`. Negative control: same request without inject Continues. |
| **4** rule deny | live, H1 + H2 + tests | `smoke.sh` (BUFFERED + STREAMED), `fail-modes.sh`: SQLi/XSS (URL + body) → **403**, response-body rule → **403**, attack only in the last chunk / DATA frames → **403** |
| **5** connector hung | live drill, H1 + H2 | SIGSTOP → Envoy **504** after `message_timeout` 2s; origin unchanged |
| **6** audit | live drill, H1 + H2 | `SecAuditLog` on an unwritable path: libmodsecurity v3.0.16 still loads; attack **403** with origin untouched, benign **200** |

### Why class 3 has no live Envoy drill

A well-behaved Envoy `ext_proc` client only sends ordered headers/body/trailers for a real HTTP exchange. It cannot force libmodsecurity's `msc_*` Transaction API to return a failure code mid-stream: there is no request shape that makes a healthy engine return `Err` after a session is open while still looking like valid HTTP. Protocol-violation cases (body before headers, empty oneof, …) are also not produced by Envoy in normal operation.

So class 3 is proven **only** by gRPC integration tests that drive the same `Exchange::fail_closed` path the product binary uses:

| Case | How Err is forced | Client |
|------|-------------------|--------|
| Injected mid-body failure | `modsec-engine` feature `fail-inject` (dev-dependency only; **off** in `cargo build -p ext-proc-modsec`) arms one Transaction step to return `EngineError` after headers Continue | **500** |
| Same request, inject not armed | Negative control | Continue |
| Append after body finished / response body before response headers / duplicate response headers / NUL in header | Real `EngineError` from the façade (phase-order / `CString`) | **500** |
| Body before headers, empty oneof, invalid `:status`, trailers with no session, … | Connector protocol guards → same `fail_closed` | **500** |
| FULL_DUPLEX body above `--max-held-body-bytes` (`full_duplex_held_body_cap_fails_closed`) | Connector bound on held memory → same `fail_closed` | **500** |

`fail-modes.sh` runs those gRPC tests as its class-3 step and asserts the floor. Do not invent a fake live “engine Err” drill through Envoy.

**Negative control:** `fail-modes.sh` temporarily restarts Envoy with `failure_mode_allow: true` and repeats the kill and stall→504 drills. Traffic then reaches the origin (**200**) and `failure_mode_allowed` rises, which shows the drills would catch a fail-open configuration. The product config is restored and re-checked (**500**) before the suite continues.

---

## Envoy's own local replies (not a failure class)

Envoy can reject a request itself before the request phase reaches ext_proc. For example a URI with a `#fragment` (400 `path_normalization_failed`) or `OPTIONS *` (404 `absolute_path_rejected`). ext_proc then sees only the response headers of that local reply, on a stream with no request headers. The origin was never contacted and never can be, so the request is already closed.

| Stream state when response headers arrive | Connector answer | Client |
|-------------------------------------------|------------------|--------|
| No request on the stream, `:status` 4xx/5xx | Continue (headers and the local reply's body; not inspected) | Envoy's status, e.g. **400** |
| No request on the stream, any other status (1xx–3xx, missing, invalid) | `ImmediateResponse` **500** | **500** |
| After such a pass-through: request headers/body or a second response headers | `ImmediateResponse` **500** | **500** |

This relies on `request_header_mode: SEND`: Envoy never sends a request to the origin without first sending its headers to ext_proc, so a 2xx/3xx on a stream with no request cannot be trusted and stays fail-closed. gRPC tests: `envoy_local_reply_without_request_passes_through`, `response_without_request_below_400_fails_closed`, `local_reply_does_not_open_the_request_path`. Metric: `ext_proc_local_reply_passthrough_total`.

Drop interventions (status 0) are mapped to a gRPC stream abort, which Envoy fails closed as **500**; an `ImmediateResponse` with status 0 would be sent by Envoy v1.39 as **200**. See [how-it-works.md](./how-it-works.md#decisions--what-the-client-sees).
