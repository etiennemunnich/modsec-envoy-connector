---
title: Fail-closed model — ModSec × Envoy ext_proc
audience: operators + contributors
date: 2026-09-26
pins: Envoy v1.39.1 · libmodsecurity v3.0.16 · failure_mode_allow:false · message_timeout 2s
license: see LICENSE
status: Product contract — live proofs remain on experiment tip / Mac lab
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

Live class-**1** kill→500 and class-**4** deny→403 are proven in the **experiment** lab (Mac / tip), not by this connex scaffold alone. Class-**3** inject and some soft classes still have thinner drills. Absolute gate on experiment tip: `./scripts/lab-fail-closed.sh`.

**This repo has not migrated the lab.** Until Phase 2-B (explicit migrate), treat experiment tip as authoritative for runnable fail-closed proofs. See [testing.md](./testing.md).
