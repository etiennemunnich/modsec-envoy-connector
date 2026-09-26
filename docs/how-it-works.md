---
title: How it works — ModSec × Envoy × Rust ext_proc
audience: operators + contributors
date: 2026-09-26
pins: Envoy v1.39.1 · libmodsecurity v3.0.16 · CRS v4.29.0 · failure_mode_allow:false · message_timeout 2s
product: Rust ext_proc → FFI → libmodsecurity
license: see LICENSE
status: Distilled product brief — lab proofs still live in the experiment repo
---

# How it works

**Elevator:** Envoy cannot talk to ModSecurity alone, so a small Rust process sits beside it. Only three network hops exist on the data path. The connector / libmodsecurity **never** dial origin — they only answer Envoy’s ext_proc side-call. Good traffic → **Continue** → Envoy forwards; rule deny → local **403**; connector death/hang → Envoy fails **closed** (**500** / **504**). Engine errors must become ImmediateResponse **500**, never silent Continue.

**License:** Copyright (c) 2026 Etienne Munnich. See [LICENSE](../LICENSE) (and [NOTICE](../NOTICE) when present). See [CONTRIBUTING.md](../CONTRIBUTING.md).

**Pins** (from [`versions.lock.md`](../versions.lock.md)): Envoy **v1.39.1** · libmodsecurity **v3.0.16** · CRS **v4.29.0** · product **v0.1.0** (pre-migrate).

**Lab home:** Runnable compose / scripts / CRS go-ftw / fail-closed gates still live in private [`modsec-envoy-experiement`](https://github.com/etiennemunnich/modsec-envoy-experiement) tip branches. This repo is the **product home** (standards + skeleton + distilled docs) — **not** a claim that the lab has migrated here.

---

## Hop table

| Hop | From → To | Protocol | Opens to origin? |
|-----|-----------|----------|------------------|
| 1 | Client → **Envoy** | HTTP | No — client hits the proxy |
| 2 | **Envoy ↔ Rust connector** | ext_proc gRPC bidi | **No** — side-call only |
| *(same process)* | Rust → **libmodsecurity** | In-process **FFI** (`msc_*`) | **No** — not a network service |
| 3 | **Envoy → origin** | HTTP | **Yes — Envoy only**, and **only after** connector **Continue** |

Never: connector / libmodsecurity / CRS open a TCP/HTTP connection to origin webservices.

---

## Outcomes

| Case | What happens | Client typically sees |
|------|--------------|------------------------|
| Allow | Connector **Continue** → Envoy routes | Upstream (e.g. **200**) |
| Policy deny | Disruptive intervention → `ImmediateResponse` | **403** (typical) |
| Connector down / gRPC fail | Envoy `failure_mode_allow: false` | **500** |
| Hang past `message_timeout` (lab **2s**) | Envoy local reply | **504** |
| Engine / FFI `Err` | Connector must map to `ImmediateResponse` **500** | **500** — never Continue |

Product locks: `failure_mode_allow: false` on enforcement; never `observability_mode` for blocking; never Continue after ModSec/FFI error.

Deeper model: [fail-closed.md](./fail-closed.md). How we test: [testing.md](./testing.md).
