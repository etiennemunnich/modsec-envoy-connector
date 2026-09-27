---
title: Fail-closed model — ModSec × Envoy ext_proc
audience: operators + contributors
date: 2026-09-27
pins: Envoy v1.39.1 · libmodsecurity v3.0.16 · failure_mode_allow:false · message_timeout 2s
license: see LICENSE
status: Product contract — live drills in demo/scripts/fail-closed.sh
---

# Fail-closed

**One sentence:** If ModSecurity cannot produce a trustworthy allow/deny decision, the request **must not** reach upstream. That is a different class from a **rule deny (403)**. Envoy alone cannot cover every class.

Cross-links: [how-it-works.md](./how-it-works.md) · [testing.md](./testing.md) · pins in [`versions.lock.md`](../versions.lock.md).

---

## Six classes (do not conflate)

| # | Class | Who enforces | Default | Client |
|---|-------|--------------|---------|--------|
| **1** | Connector process / gRPC stream fail | **Envoy** (`failure_mode_allow: false`) | Fail closed | **500** |
| **2** | Rules / engine init at boot | **Connector** — refuse listen / exit; healthz not 200 | Refuse service | Envoy **500** |
| **3** | Per-request ModSec / FFI `Err` | **Connector** — `ImmediateResponse` **500** | Fail closed | **500** |
| **4** | Rule intervention (deny) | Connector maps intervention | Policy deny (not “failure”) | **403** typical |
| **5** | Timeout / hang | **Envoy** `message_timeout` (lab **2s**) | Fail closed | **504** |
| **6** | Audit / partial CRS write | Connector telemetry | Best-effort; do **not** open traffic | Unchanged from 1–5 |

**Deny ≠ fail:** **403** means the WAF decided; **500** / **504** means the WAF could not decide.

**Never:** `failure_mode_allow: true` on enforcement; Continue after engine error (“connector-lie fail-open”).

---

## Who owns what

```text
Envoy ext_proc (failure_mode_allow:false)
  Owns: stream establish / gRPC fail → 500
        message_timeout hang → 504
  Cannot see: “ModSec Err but connector said Continue”

Rust connector
  Owns: boot Rules, per-request msc_* Result→500, intervention→403
  Must never: Continue after engine error

libmodsecurity (in-process FFI)
  Owns: SecLang eval + intervention
```

---

## Honest status

| Class | Proven by | How |
|-------|-----------|-----|
| **1** connector killed | live drill | `demo/scripts/fail-closed.sh` — SIGKILL → Envoy **500**; origin hit count unchanged |
| **2** bad rules at boot | live drill + unit test | connector exits non-zero, nothing listens, Envoy **500**; `invalid_seclang_is_rejected`, `rules_are_required` |
| **3** per-request engine error / protocol violation | gRPC integration tests | body-before-headers, duplicate headers, missing `:status`, empty message → `ImmediateResponse` **500** (`crates/ext-proc-modsec/tests/grpc.rs`) |
| **4** rule deny | live smoke + tests | `demo/scripts/smoke.sh` — SQLi/XSS (URL + body) → **403**, response-body rule → **403** |
| **5** connector hung | live drill | SIGSTOP → Envoy **504** after `message_timeout` 2s; origin unchanged |
| **6** audit | — | best-effort by design; not drilled |

Class 3 has no live injection hook: a real libmodsecurity transaction error cannot be forced from outside, so it is covered by the in-process gRPC tests that exercise the same code path (`fail_closed` → 500).

Drop interventions (status 0) are mapped to a gRPC stream abort, which Envoy fails closed as **500**; an `ImmediateResponse` with status 0 would be sent by Envoy v1.39 as **200**. See [how-it-works.md](./how-it-works.md#decisions--what-the-client-sees).
