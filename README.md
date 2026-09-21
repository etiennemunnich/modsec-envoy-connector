# envoy-modsec-connex

Private connector project: **Envoy `ext_proc` → Rust → libmodsecurity** (optional OWASP CRS).

**Author:** Etienne Munnich  
**License:** [MIT-0](./LICENSE) (MIT No Attribution)  
**Status:** Docs-first scaffold. **Not production.** **Not** submitted to the Built on Envoy catalog.

Experiment / live lab (reference): private [`modsec-envoy-experiement`](https://github.com/etiennemunnich/modsec-envoy-experiement) — keep using that for runnable proofs until migration is complete.

---

## Purpose

Ship an ownable Envoy External Processing connector that drives **ModSecurity v3 (libmodsecurity)** for request/response inspection, with:

- **Fail-closed** as an absolute invariant (`failure_mode_allow: false` / equivalent).
- Honest protocol claims (HTTP proven; gRPC / WebSocket limited).
- A future path toward Built on Envoy `type: ext_proc` packaging — checklist only until Etienne says submit.

Coraza is **reference only** (body/EOS lessons). The engine is libmodsecurity.

---

## Current status (2026-09-21)

| Area | Status |
|------|--------|
| HTTP BUFFERED ext_proc → ModSec | **Proven** in the experiment lab (headers + bodies; CRS go-ftw historically green on BUFFERED) |
| Fail-closed (HTTP lab) | **Proven** live (`lab-fail-closed` 15/15 PASS in experiment) |
| CRS | **Deferred option** for engine focus — ModSec-only stub SecLang profile exists in lab; full CRS remains available when toggled |
| gRPC | **Not** a protobuf WAF. Lab: HTTP-phase header/body on gRPC-shaped traffic; with CRS, accidental anomaly denies; without CRS, unary/stream can pass ModSec HTTP phases — still not gRPC-aware |
| WebSocket | Stock lab rejects upgrades; BUFFERED + upgrade **hangs**; headers-only unlocks handshake-only — **not** frame CRS |
| STREAMED bodies | Deferred |
| This repo | README + license + findings docs + BoE draft manifest placeholder |

Details: [`docs/design-readiness-and-tests.md`](./docs/design-readiness-and-tests.md), [`docs/findings/`](./docs/findings/).

---

## Design notes (summary)

1. **Default product surface:** HTTP with Envoy **BUFFERED** bodies so libmodsecurity phase-2 sees a coherent body (or an explicit limit reject — never silent pass).
2. **Fail-closed absolute:** connector down, hang, panic, ModSec init/rules fail, ExtProc unreachable → traffic must not proceed as OK. Independent of BUFFERED vs STREAMED.
3. **Multi-protocol honesty:** prefer per-route `processing_mode` — full BUFFERED for HTTP; headers-only for gRPC and WS handshake; never market frame/protobuf CRS without a separate engine.
4. **BUFFERED tradeoffs:** RAM, TTFB, large-upload 413/hangs, WS upgrade deadlock risk — see findings; keep BUFFERED off upgrade/streaming routes.
5. **BoE:** use `ext_proc` (out-of-process), not Rust dynamic modules, for WAF isolation. See [`docs/boe/`](./docs/boe/).

---

## Hop-trace testing

Integration proofs should evidence the chain:

**request → Envoy → ModSec → CRS** (or `CRS skipped` when ModSec-only).

Join key: Envoy `rid=` / `x-request-id` = connector `request_id` = ModSec audit `unique_id`.

In the experiment lab today:

```bash
./scripts/hop-trace.sh --label http-get --proto http --path / \
  --expect-status 200 --expect-origin yes --expect-modsec body
./scripts/lab-modsec-only.sh only   # or crs
./scripts/lab-fail-closed.sh
```

Planned connex integration tests are listed in [`docs/design-readiness-and-tests.md`](./docs/design-readiness-and-tests.md) §3.

---

## Built on Envoy alignment

| Item | Status |
|------|--------|
| Extension type `ext_proc` | Target; draft [`docs/boe/manifest.yaml`](./docs/boe/manifest.yaml) |
| Local `boe run` / OCI catalog packaging | **Not ready** |
| Security (out-of-process isolation, fail-closed, body bounds) | Partially documented; expand before any catalog claim |
| Catalog / BoE PR | **Do not submit** until explicitly requested |

Reviewed docs: writing Rust extensions, running local extensions, extension types, packaging for prod, security considerations (https://builtonenvoy.io/docs/).

---

## Repository layout

```
LICENSE / NOTICE     MIT-0 + third-party honesty
README.md            This file
docs/                Findings + design readiness + BoE notes
crates/              Placeholder for future Rust ext_proc connector (not ported yet)
```

Runnable connector code remains in the experiment repo until a deliberate, clean migration.

---

## Not production

Do not deploy this repository as a WAF product. No SLA, no catalog badge, no “full multi-protocol CRS” claim. Use the experiment lab for proofs; use this repo for the product name, license, and distilled documentation.
