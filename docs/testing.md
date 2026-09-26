---
title: Testing — layers, gates, where lab lives
audience: operators + contributors
date: 2026-09-26
pins: Envoy v1.39.1 · libmodsecurity v3.0.16 · CRS v4.29.0 · failure_mode_allow:false
license: see LICENSE
status: Connex CI thin; full lab/fail-mode still on experiment tip
---

# Testing

**One sentence:** Connex keeps **PR CI thin** (pins + Rust quality). Fail-closed, protocol, and CRS go-ftw gates remain on the **experiment** lab until an explicit migrate.

Cross-links: [how-it-works.md](./how-it-works.md) · [fail-closed.md](./fail-closed.md) · [`versions.lock.md`](../versions.lock.md).

---

## Layer map

| Layer | Proves | On connex today? | Where it runs |
|-------|--------|------------------|---------------|
| **A — Pins + Rust** | `versions.lock.md` axes; workspace builds | **Yes** — thin CI (`pin-check`, `rust-quality`) | GitHub Actions on this repo |
| **B — Fail-mode** | Kill→**500**, deny→**403**, hang→**504** | **Pointer only** | Experiment tip scripts (`lab-fail-closed.sh`, `lab-fail-modes.sh`) + Mac |
| **C — CRS go-ftw** | CRS packs over HTTP/1.x | **Pointer only** | Experiment tip / Mac (`run-go-ftw.sh`) |
| **D — Version matrix** | Sliding ModSec / CRS / Envoy windows | **Not landed here** | Experiment dispatch workflows (when tip-merged) |

Do **not** gate connex PR merge on Mac-only hang/SIGSTOP, full CRS, or Envoy e2e.

---

## Absolute fail-closed gate (experiment)

On the experiment tip (not yet copied into connex):

```bash
./scripts/lab-up.sh
./scripts/lab-fail-closed.sh   # class-1 kill → 5xx; restore → 200
```

Broader suite (when landed on tip): `./scripts/lab-fail-modes.sh` — classes **1/4/5** hard; FO toggle opt-in; class **3** SKIP unless inject enabled.

Product model for those classes: [fail-closed.md](./fail-closed.md).

---

## Honest boundaries

- **Lab not migrated.** Compose, hop-trace, CRS, and fail-mode scripts still live in [`modsec-envoy-experiement`](https://github.com/etiennemunnich/modsec-envoy-experiement). Connex README / docs **point**; they do not claim in-repo lab PASS.
- **Scaffold ≠ product connector.** Thin CI green means pins + crates compile — not “WAF proven on connex.”
- **No wiki.** In-repo `docs/` + README index only.
- **Pins:** quote [`versions.lock.md`](../versions.lock.md) — do not invent tip flags.
