---
title: Testing — layers, gates, where each runs
audience: operators + contributors
date: 2026-09-27
pins: Envoy v1.39.1 · libmodsecurity v3.0.16 · CRS v4.29.0 · failure_mode_allow:false
license: see LICENSE
status: PR CI = pins + Rust (libmodsecurity linked); live demo suites on a Mac / Linux host; version probes by manual dispatch
---

# Testing

**One sentence:** PR CI runs pins + fmt/clippy/tests with libmodsecurity linked (including in-process gRPC tests of every phase and fail-closed path); the live Envoy suites — smoke, fail-closed, the HTTP/1.1 + HTTP/2 fail-mode matrix and CRS go-ftw — run against the demo on a Mac or Linux host; version-window probes run by manual dispatch.

Cross-links: [how-it-works.md](./how-it-works.md) · [fail-closed.md](./fail-closed.md) · [`versions.lock.md`](../versions.lock.md) · [`versions.window.md`](../versions.window.md).

---

## Layer map

| Layer | Proves | Where it runs |
|-------|--------|---------------|
| **A — Pins + Rust** | pins; engine + connector unit tests; gRPC integration tests against libmodsecurity (allow, deny, redirect, request/response body, REMOTE_ADDR from attributes, fail-closed 500 paths, `/healthz`) | GitHub Actions on every push / PR (`pin-check`, `rust-quality`); `cargo test --workspace` locally |
| **B — Live smoke + fail-closed** | Envoy → connector → libmodsecurity + CRS: benign **200**, SQLi/XSS URL + body **403**, response-body **403**; kill → **500**, hang → **504**, bad rules → **500**; origin untouched on every deny / failure | `demo/scripts/smoke.sh`, `fail-closed.sh` |
| **C — Fail-mode matrix (H1 + H2)** | Fail-closed classes 1–6 over HTTP/1.1 **and** HTTP/2 prior knowledge, protocol proven from the Envoy access log; split `Cookie` crumbs inspected; an attack only in the last chunk / DATA frames still **403**; negative control (`failure_mode_allow: true`) shows the same kill / hang *does* let traffic through, so the checks can see fail-open | `demo/scripts/fail-modes.sh` |
| **D — CRS regression (go-ftw)** | OWASP CRS `tests/regression` through Envoy, HTTP/1.x, judged by status code | `demo/scripts/go-ftw.sh smoke\|body\|full` |
| **E — Version window** | connector against each libmodsecurity tag; each Envoy release running layers B + C; each CRS tag loading and passing smoke + go-ftw | `scripts/probe-modsec-pin.sh`, `scripts/envoy-candidate-smoke.sh`, `scripts/crs-version-probe.sh`; GitHub workflows `modsec-window-matrix`, `modsec-pin-probe`, `envoy-candidate-smoke`, `crs-version-probe` (manual dispatch) |
| **Trace** | one request followed across every hop by `x-request-id` (Envoy access log → connector phases → CRS matches → origin) | `demo/scripts/hop-trace.sh` |

Push / PR CI stays thin (layer A). Layers B–D need a running Envoy and are not a merge gate; layer E runs them on hosted Ubuntu when dispatched.

---

## Local gates

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace

./demo/scripts/up.sh                  # Envoy + connector + CRS + origin
./demo/scripts/smoke.sh               # allow / deny / body / response path
./demo/scripts/fail-closed.sh         # kill → 500, hang → 504, bad rules → 500
./demo/scripts/fail-modes.sh          # classes 1–6 + controls, H1 and H2
./demo/scripts/go-ftw.sh smoke        # demo tests + body-heavy CRS SQLi/XSS tests
./demo/scripts/go-ftw.sh full         # whole CRS regression tree
./demo/scripts/hop-trace.sh --expect-status 403 --expect-origin no '/search?q=1%27%20UNION%20SELECT%201--'
./demo/scripts/down.sh
```

go-ftw: `./demo/scripts/install-go-ftw.sh`. Results and transcripts land in `demo/.run/` (`go-ftw/`, `fail-modes/`, `hop-trace/`).

---

## Latest measured results

macOS (arm64), Envoy v1.39.1, libmodsecurity v3.0.16, CRS v4.29.0, go-ftw v2.6.0, 2026-09-27:

| Suite | Result |
|-------|--------|
| `cargo test --workspace` | 54 passed, 0 failed |
| `smoke.sh` | passed |
| `fail-closed.sh` | passed |
| `fail-modes.sh` (H1 + H2) | 59 passed, 0 failed |
| `go-ftw.sh smoke` | demo tests 8/8; CRS body-heavy tests 118/118 |
| `go-ftw.sh full` | **5091 passed, 0 failed** of 5091 (42 of the passes are judged through `demo/ftw/envoy-overrides.yaml`) |

`920100-8` and `920610-2` send a URI with a `#fragment`, which Envoy rejects itself with a local **400** before the request phase. The connector passes Envoy's local reply through (see [fail-closed.md](./fail-closed.md#envoys-own-local-replies-not-a-failure-class)), so the client gets the 400 CRS expects.

The overrides file records measured Envoy platform differences, like CRS's own `nginx-overrides.yaml`: 36 tests where Envoy's HTTP/1 codec drops a malformed request (client sees an empty reply, envoy#29440) and 6 where CRS's expected status was written for Apache's parser (the outcome here is still a 403 block, or matches CRS's nginx override). Each of the 42 entries was re-measured by removing it and running its test alone: all 42 still fail without their override.

---

## Honest boundaries

- **go-ftw is HTTP/1.x only** and judges by status code. A green run says nothing about HTTP/2; the H2 evidence is `fail-modes.sh --proto h2`.
- **Class 3** (per-request engine error) cannot be injected through a well-behaved Envoy; `fail-modes.sh` runs the gRPC integration tests for it (real libmodsecurity, no Envoy).
- **Class 6:** with `SecAuditLog` pointing at an unwritable path, libmodsecurity v3.0.16 still loads the rules; the suite proves decisions are unchanged (attack **403**, origin untouched; benign **200**).
- **HTTP/3 and WebSocket frames** are not tested and not supported.
- **Not ported from the experiment lab:** the perf harness, and hop-trace for WebSocket / gRPC origins (the demo origin is plain HTTP).
- **CI green ≠ live proof.** Push / PR CI does not run Envoy; the live suites (or a dispatched version probe) are the end-to-end evidence.
- **Pins:** quote [`versions.lock.md`](../versions.lock.md) — do not invent tip flags.
