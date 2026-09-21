---
cursor:
  subagentId: "bc-9b1fcea1-bdc2-51d2-925b-6c46b3ca212d"
---

# Approach options — ModSec (libmodsecurity) + Envoy ext_proc

**Audience:** Etienne (product direction)  
**Date:** 2026-09-21  
**Mode:** Analysis only — options framed, not executed.  
**Product:** libmodsecurity + OWASP CRS via Rust Envoy `ext_proc` connector. Coraza appears only as a body-handling pattern reference ([coraza-design-lessons-for-modsec.md](./coraza-design-lessons-for-modsec.md)).

**Inputs (not rewritten):** [prod-readiness.md](./prod-readiness.md) · [preferences-fail-closed.md](./preferences-fail-closed.md) · [envoy-modsec-connex-readiness.md](./envoy-modsec-connex-readiness.md) · [aidlc-ci-parity.md](./aidlc-ci-parity.md) · [local-proof-chain.html](./local-proof-chain.html) · full CRS BUFFERED lab green `5091/0/0` @ `e81e9c6`

---

## 1. Current approach (what we actually built)

| Layer | What shipped |
|-------|----------------|
| Architecture | Envoy `ext_proc` → Rust gRPC connector → **libmodsecurity** + CRS |
| Body delivery (lab) | Envoy **BUFFERED** request + response bodies (`compose/lab/envoy.host.yaml`) |
| Engine phase ordering | Append body into ModSec transaction → on end-of-body → `process_*_body` (phase 2) before allow |
| Fail-closed | Envoy `failure_mode_allow: false` + live gate `./scripts/lab-fail-closed.sh` (15/15 PASS @ `fail-closed-20260921T063451Z`) |
| CRS fidelity | Full go-ftw **5091 / 0 / 0** on BUFFERED lab tip (`e81e9c6`) |
| CI posture | Free-tier Ubuntu gate + libmodsecurity **3.0.16** from source; AIDLC **CI-PARITY** before push ([aidlc-ci-parity.md](./aidlc-ci-parity.md)) |
| Maturity | **Lab-ready**, not prod-deployable ([prod-readiness.md](./prod-readiness.md)). STREAMED deferred. Private experiment repo; private `envoy-modsec-connex` not created yet |

**Invariant already proven on BUFFERED:** ModSec still needs a complete body (or an explicit limit policy such as Reject / ProcessPartial) before phase-2 allow. Envoy delivery mode is not an engine mode.

---

## 2. Desired outcomes (Etienne)

| Outcome | Meaning |
|---------|---------|
| **Fail-closed no matter what** | Connector down, gRPC error, panic/abort, hang/timeout, ModSec init fail, bad rules, ExtProc unreachable — traffic must not proceed as OK. Absolute; independent of BUFFERED vs STREAMED ([preferences-fail-closed.md](./preferences-fail-closed.md)). |
| **Performance with security** | Latency and memory matter, but not by cutting CRS body capability. |
| **Full CRS capability** | Body-reliant rules in scope; go-ftw fidelity is the honesty meter. |
| **Honest, not half-baked** | Prefer incomplete-but-true claims over “full WAF” theater ([preferences-no-half-baked.md](./preferences-no-half-baked.md)). |
| **Private → public path** | Eventual private [`envoy-modsec-connex`](./preferences-connex-repo.md), public later. Migration bar in [envoy-modsec-connex-readiness.md](./envoy-modsec-connex-readiness.md). No create/submit until explicit go. |

---

## 3. Options (compare; no aggressive pick)

Envoy may deliver bodies as **BUFFERED** or **STREAMED**. That is host delivery. libmodsecurity phase-2 still expects a coherent body (or a defined partial/limit policy). Coraza’s Envoy path pause → accumulate → `Process*Body` at true EOS is the **pattern** to mirror inside our connector if chunks arrive — not a product switch.

### A — Stay BUFFERED-at-Envoy + complete body before ModSec phase-2

**Shape:** Keep lab/product default: Envoy buffers the entity; connector receives full (or limit-sized) body, then `process_*_body`. If STREAMED delivery is ever enabled later, the connector still implements the accumulate/EOS pattern (Coraza-like) before phase-2 — not “decide per chunk.”

| Pros | Cons / risks |
|------|----------------|
| Matches what is already green (5091/0/0) | Host buffer pressure sits partly in Envoy |
| Simplest ops story for connex v1 / BoE `processingMode` docs | Large bodies hit Envoy buffer ceilings — must deny, not pass-through |
| Aligns with early ext_proc WAF guidance (buffered body as the reliable path) | STREAMED remains a documented roadmap item until separately proven |
| Strong fail-closed coupling: no upstream until phase-2 decision | Double-buffer risk if connector also keeps a large copy |

**Fit to desired outcomes:** Strong on security completeness, CRS fidelity, honesty (“BUFFERED proven”), connex readiness as the current proof base.

### B — Envoy STREAMED delivery; connector always reassembles before `process_*_body`

**Shape:** Configure Envoy `STREAMED` (and later EG `FullDuplexStreamed` if relevant). Connector appends every chunk; runs phase-2 only on true end-of-body / trailer-finalize / fail-closed stream error. Same ModSec semantics as A; different wire delivery.

| Pros | Cons / risks |
|------|----------------|
| Potentially smoother memory handoff for some deployments | Upstream ext_proc STREAMED / half-close / duplicate-EOS bugs are active risk surface |
| Connector owns accumulate/EOS (explicit Coraza-pattern port) | Must prove trailer / non-EOS end still forces finalize — miss = fail-open class |
| Keeps full CRS body capability if reassembly is correct | Extra proof burden: go-ftw + fail-closed must be re-run on STREAMED |
| | Latency profile changes (more gRPC messages); harder to claim “same as BUFFERED lab” until measured |

**Fit:** Same security *goal* as A if implemented correctly; weaker *today* because unproven. Not a shortcut around fail-closed.

### C — Headers-only / partial body (capability cut)

**Shape:** SKIP bodies, or inspect headers + truncated/partial bodies without a defined ModSec limit policy, and still claim “CRS WAF.”

| Pros | Cons / risks |
|------|----------------|
| Lower latency / memory | Cuts CRS body-phase capability — fails go-ftw honesty |
| Easier demos | Explicitly against Etienne prefs (performance *with* security; no half-baked “full”) |
| | Temptation to redefine failures as “out of scope” — rejected by product bar |

**Fit:** Against desired outcomes unless reframed as an **explicit non-product mode** (e.g. “headers-only lab profile”) that never ships as the default connex claim. Listed for completeness, not as a recommended product path.

### D — Other architectures (briefly; why already weak)

| Architecture | Why set aside earlier |
|--------------|----------------------|
| **Wasm filter + libmodsecurity** | [envoy#17463](https://github.com/envoyproxy/envoy/issues/17463): static deps, WASI holes, C++ exceptions, header/body pause ABI. Community energy moved to Coraza Wasm, not ModSec Wasm. In-process freeze risk argues *for* out-of-process ext_proc, not for Wasm+ModSec. |
| **Native Envoy filter (ModSecurity-envoy lineage)** | [vmware-archive/ModSecurity-envoy](https://github.com/vmware-archive/ModSecurity-envoy) archived; never merged upstream. Envoy Gateway rejected bundling (recompiles Envoy). High maintenance, low upstream appetite. |
| **Switch engine to Coraza** | Competitive/design reference only. Product is libmodsecurity + CRS fidelity on ModSec. Stealing accumulate/EOS is fine; re-platforming is not. |

Maintainer signal ([envoy#16081](https://github.com/envoyproxy/envoy/issues/16081)): WAF via **ext_proc** is an intended use case — strengthens staying on the current product shape.

---

## 4. Outcomes matrix

Ratings are relative judgments for Etienne’s decision framing — not a scored RFP. **Proven** = evidenced on current tip; **Potential** = achievable if implemented and re-proven.

| Dimension | A BUFFERED + phase-2 at complete body | B STREAMED + connector reassembly | C Headers-only / partial | D Wasm / native filter |
|-----------|----------------------------------------|-----------------------------------|--------------------------|-------------------------|
| **Security completeness** | Strong (proven) | Strong *if* EOS/trailer finalize correct (potential) | Weak — body CRS cut | Wasm/native historically incomplete or abandoned for ModSec |
| **Fail-closed strength** | Strong (live 15/15 + config) | Same *requirement*; needs STREAMED-specific failure modes proven | Easy to look “green” while open on body path — honesty risk | In-process Wasm can freeze Envoy; native couples crash domain |
| **Latency / memory** | Envoy-side buffer cost; fewer gRPC body msgs | More msgs; connector buffer cost; profile unknown until measured | Best raw latency — by dropping work | Wasm/native: different cost model; ModSec-in-Wasm historically hostile |
| **CRS / go-ftw fidelity** | **5091/0/0 proven** | Must re-prove; same target if reassembly faithful | Fails body-reliant fidelity | Not a maintained ModSec+Envoy CRS path |
| **Connex / public readiness** | Best current base (document BUFFERED + `failureModeAllow: false`) | Roadmap after A-class proof; do not claim until green | Blocks honest public claim of “full CRS” | Wrong product shape for connex (ext_proc identity) |
| **Ops complexity** | Lowest of full-CRS options | Higher (STREAMED edge cases, EG duplex modes) | Lowest ops, highest product debt | Highest (toolchain / Envoy rebuild / upstream rejection) |

---

## 5. Open decisions for Etienne (questions only)

No implementation plan below — only choices that need an explicit human call.

1. **Default body mode for private connex v1?** Stay BUFFERED-at-Envoy (A) as the supported claim, with STREAMED (B) as a later proven mode — or require B before calling the connector “complete”?
2. **What is the honest public sentence?** e.g. “Full CRS on BUFFERED ext_proc” vs waiting until STREAMED is green before any public-facing language?
3. **Partial-body policy:** When `SecRequestBodyLimit` trips, is the connex default **Reject** (fail-closed lean) or **ProcessPartial** (ModSec-compatible but must be documented as capability-bound)? Never silent skip?
4. **Double-buffer tolerance:** Accept Envoy BUFFERED + connector copy for clarity, or invest early in STREAMED reassembly to shift buffering into the connector only?
5. **Fail-closed gate expansion:** Before STREAMED is advertised, must `lab-fail-closed.sh` gain STREAMED-specific modes (half-close, trailer-only end, message timeout mid-body), or is today’s gate enough for BUFFERED-only claims?
6. **Connex migrate timing vs body roadmap:** Freeze/migrate the BUFFERED lab tip first ([envoy-modsec-connex-readiness.md](./envoy-modsec-connex-readiness.md)), or hold migration until a STREAMED proof exists?
7. **Headers-only profile:** Banned entirely from the product surface, or allowed as a clearly named non-default debug/lab profile that must never be the README default?
8. **Performance bar:** What p50/p99 and body-size envelope define “performance with security” so agents do not invent headers-only shortcuts?

---

## Scope of this write

- **Created:** this file only under Project Context `docs/`.
- **No** experiment-repo edits, lab runs that mutate, pushes, PRs, or `envoy-modsec-connex` create/submit.
- **Zero filesystem changes outside** `/cursor/stores/bc-cd276624-32a5-4521-b433-4a550531888f/docs/approach-options.md`.
