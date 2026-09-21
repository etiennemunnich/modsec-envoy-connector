---
cursor:
  subagentId: "bc-f7eb1369-1d29-571d-a152-31c7c61f23be"
---

# ModSecurity only — CRS deferred

**Audience:** Etienne (product direction)  
**Date:** 2026-09-21  
**Mode:** Analysis only — no experiment-repo edits, no CRS reload / lab mutation.  
**Preference:** [preferences-modsec-only.md](./preferences-modsec-only.md)

**Inputs (not rewritten):** [grpc-websocket-assumption-test.md](./grpc-websocket-assumption-test.md) · [http-grpc-websocket-scope.md](./http-grpc-websocket-scope.md) · [approach-options.md](./approach-options.md) · [preferences-fail-closed.md](./preferences-fail-closed.md)

---

## 1. What “ModSec only” means for this connector

**Product stack (unchanged shape):** Envoy `ext_proc` → Rust connector → **libmodsecurity** → origin.

| Still present | Deferred / not the fidelity bar |
|---------------|----------------------------------|
| libmodsecurity **engine** | Stock **OWASP CRS** packs as the honesty meter |
| **SecLang** rules language (custom / minimal rules still load) | Full CRS tree + go-ftw as ship gate |
| Connector FFI, transaction lifecycle, phase ordering | “Full CRS on BUFFERED HTTP” as the connex public sentence |

**ModSec only** means: focus on the **engine + connector** (init, transaction, header/body phases, deny/allow, fail-closed). Stock CRS packs are **not loaded** (or not treated as the product bar) for the time being. SecLang remains — operators can load custom or minimal rules; they are not “no rules forever.”

This is **not** “drop ModSecurity” and **not** “headers-only by default for HTTP.” It is a temporary fidelity-bar change: engine correctness and connector honesty first; CRS returns when Etienne says so ([preferences-modsec-only.md](./preferences-modsec-only.md)).

---

## 2. What stays the same

| Invariant | Why unchanged |
|-----------|----------------|
| **HTTP ext_proc path** | Architecture stays Envoy → Rust gRPC connector → libmodsecurity. Delivery and phase story from [approach-options.md](./approach-options.md) still apply. |
| **Fail-closed absolute** | Connector down, gRPC error, panic, hang/timeout, ModSec init/rules fail, ExtProc unreachable → traffic must not proceed as OK. Independent of CRS presence ([preferences-fail-closed.md](./preferences-fail-closed.md)). Live gate `./scripts/lab-fail-closed.sh` remains the bar for whatever is *claimed*. |
| **BUFFERED body semantics for rules that need bodies** | libmodsecurity phase-2 still expects a coherent body (or an explicit limit policy) before allow. Envoy BUFFERED (or connector accumulate-to-EOS) is still required for body-reliant **SecLang**, whether CRS or custom. Headers-only remains a named non-default / protocol-specific mode — not a silent HTTP product default. |
| **Honesty over theater** | Claims must match what rules and body modes actually do. Removing CRS does not license a “full WAF” README. |

---

## 3. What changes

| Was (CRS-on lab) | Now (ModSec-only window) |
|------------------|--------------------------|
| go-ftw **5091 / 0 / 0** as fidelity bar | **Paused** — not the ship / honesty meter until CRS returns |
| Stock CRS anomaly / protocol rules blocking some traffic | Without CRS packs loaded, those denies **do not fire** unless replaced by custom rules |
| Accidental gRPC **403** on BUFFERED / headers-only (CRS anomaly score on gRPC-shaped HTTP — see live assumption test) | **May vanish** once CRS is unloaded — gRPC can **pass** until custom/header rules exist. **Note:** that outcome is inferred from prior CRS-on probes; a **live ModSec-only retest is required later** before stating it as proven. |
| Product surface = “full CRS on BUFFERED HTTP” | Product surface = **engine + connector + whatever minimal/custom SecLang** you choose to load |

**Do not** treat “gRPC now works” as true without retest — prior FAIL was CRS-driven accidental HTTP deny, not proven protobuf support ([grpc-websocket-assumption-test.md](./grpc-websocket-assumption-test.md)).

---

## 4. HTTP / gRPC / WebSocket under ModSec-only (clearer honesty)

Deferred CRS does **not** invent new protocol capabilities. It clarifies what we can honestly claim while the engine is the focus.

| Protocol | With CRS (prior evidence) | ModSec-only (expected honesty) |
|----------|---------------------------|--------------------------------|
| **HTTP** | BUFFERED path proven; body CRS + fail-closed green | Still the **primary** surface. Engine + custom/minimal rules on BUFFERED (or accumulate-to-EOS). Body-needing rules still need complete body before phase-2. No CRS ≠ no body inspection. |
| **gRPC** | Accidental HTTP CRS **403** (unary + streaming); not protobuf-aware WAF | Without CRS, traffic **may pass** until custom rules exist — **retest later**. Honest claim stays: HTTP-phase inspection only; **not** “gRPC WAF” or protobuf CRS. Headers-only vs unary opaque-body still open ([http-grpc-websocket-scope.md](./http-grpc-websocket-scope.md)). |
| **WebSocket** | Stock lab rejects upgrade; BUFFERED + upgrade **hangs**; headers-only handshake works, frames never ModSec | **Unchanged engine limit:** BUFFERED body mode can still hang the upgrade. Post-upgrade frames remain **out of ModSec**. ModSec-only does not fix WS; it only removes CRS from the handshake story. |

**One-line honesty:** ModSec-only = engine/connector fidelity first; protocol limits (WS hang on BUFFERED, gRPC not protobuf-aware) remain; CRS absence may change *pass/deny* outcomes but not the architecture truth.

---

## 5. Open decisions for Etienne

1. **When does CRS return?** Soft pause until engine/connex naming is frozen, or hard gate (e.g. after fail-closed + minimal-rules smoke + private connex scaffold)?
2. **Minimal ruleset for smoke:** What SecLang pack replaces CRS for CI/lab honesty — empty allow-all (engine wiring only), a tiny deny-probe rule (SQLi string / path), or a named “lab profile” that must never be the public default?
3. **Connex naming / claim sentence:** Is private `envoy-modsec-connex` marketed as “libmodsecurity via Envoy ext_proc” (CRS later), or hold create/submit until CRS is back on the fidelity bar ([preferences-connex-repo.md](./preferences-connex-repo.md))?
4. **gRPC live retest timing:** Run ModSec-only (no CRS) probes before deciding headers-only default, or decide product mode first and retest against that claim?
5. **Fail-closed gate while CRS paused:** Keep today’s HTTP `lab-fail-closed.sh` as sufficient for ModSec-only claims, or require a minimal-rules deny + ExtProc-down proof before any connex language?

---

## Scope of this write

- **Created:** `/cursor/stores/bc-cd276624-32a5-4521-b433-4a550531888f/docs/modsec-only-no-crs.md` only.
- **No** experiment-repo product changes, CRS reload experiments, lab mutations, pushes, PRs, or `envoy-modsec-connex` create/submit.
- **Confirmed:** `/workspace` remains empty of product code (seeded git only); zero filesystem changes outside this Context doc.
