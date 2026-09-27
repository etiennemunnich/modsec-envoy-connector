---
title: Testing — layers, gates, where each runs
audience: operators + contributors
date: 2026-09-27
pins: Envoy v1.39.1 · libmodsecurity v3.0.16 · CRS v4.29.0 · failure_mode_allow:false
license: see LICENSE
status: GitHub-hosted CI on x86_64 + aarch64 — Rust gate and live Envoy suites on every main push; daily stable-release watch, weekly version window, monthly full CRS
---

# Testing

**One sentence:** every push to `main` runs, natively on GitHub-hosted `x86_64` and `aarch64` Ubuntu, the Rust gate (fmt, clippy, tests with libmodsecurity linked) **and** the live Envoy → connector → libmodsecurity + CRS suites (smoke, fail-closed, the HTTP/1.1 + HTTP/2 fail-mode matrix, hop-trace, go-ftw smoke); new stable Envoy / libmodsecurity / CRS releases are detected daily and tested on both architectures, the last three stables of each axis weekly, and the full CRS regression monthly.

Cross-links: [how-it-works.md](./how-it-works.md) · [fail-closed.md](./fail-closed.md) · [`versions.lock.md`](../versions.lock.md) · [`versions.window.md`](../versions.window.md).

---

## Layer map

| Layer | Proves | Where it runs |
|-------|--------|---------------|
| **A — Pins + Rust** | pins; engine + connector unit tests; gRPC integration tests against libmodsecurity (allow, deny, redirect, request/response body, REMOTE_ADDR from attributes, fail-closed 500 paths, `/healthz`) | `ci`: `pin-check`, `rust-quality (x86_64)`, `rust-quality (aarch64)`; `cargo test --workspace` locally |
| **B — Live smoke + fail-closed** | Envoy → connector → libmodsecurity + CRS: benign **200**, SQLi/XSS URL + body **403**, response-body **403**; kill → **500**, hang → **504**, bad rules → **500**; origin untouched on every deny / failure | `ci` → `e2e-pin` × arch; `demo/scripts/smoke.sh`, `fail-closed.sh` |
| **C — Fail-mode matrix (H1 + H2)** | Fail-closed classes 1–6 over HTTP/1.1 **and** HTTP/2 prior knowledge, protocol proven from the Envoy access log; split `Cookie` crumbs inspected; an attack only in the last chunk / DATA frames still **403**; negative control (`failure_mode_allow: true`) shows the same kill / hang *does* let traffic through, so the checks can see fail-open | `ci` → `e2e-pin` × arch; `demo/scripts/fail-modes.sh` |
| **D — CRS regression (go-ftw)** | OWASP CRS `tests/regression` through Envoy, HTTP/1.x, judged by status code | smoke: `ci` → `e2e-pin` × arch; full: `crs-full` × arch (monthly); `demo/scripts/go-ftw.sh smoke\|body\|full` |
| **E — Stable versions** | a new stable Envoy v1.x / libmodsecurity v3.0.x / CRS v4.x release, and the last three stables of each axis, pass layers B–D with the other axes at their pins | `release-watch` (daily) → `stable-candidate` × arch → issue; `stable-window` × arch (weekly); locally `scripts/ci-live-e2e.sh` with `ENVOY_VERSION` / `MODSECURITY_PIN` / `CRS_TAG`, or `scripts/probe-modsec-pin.sh`, `envoy-candidate-smoke.sh`, `crs-version-probe.sh` |
| **Trace** | one request followed across every hop by `x-request-id` (Envoy access log → connector phases → CRS matches → origin) | `ci` → `e2e-pin` × arch; `demo/scripts/hop-trace.sh` |

All of it runs on GitHub-hosted runners (`ubuntu-latest`, `ubuntu-24.04-arm`), natively per architecture — no self-hosted or Mac runner, no QEMU, no cross-compiling. See [Hosted CI](#hosted-ci).

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

Hosted Linux on both architectures: see [Hosted CI](#measured-2026-09-27-private-repo-2-vcpu-runners). Local run on macOS (arm64), Envoy v1.39.1, libmodsecurity v3.0.16, CRS v4.29.0, go-ftw v2.6.0, 2026-09-27:

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

## Hosted CI

GitHub-hosted runners only: `ubuntu-latest` (x86_64) and `ubuntu-24.04-arm` (aarch64), each building and testing natively. `ubuntu-slim` runs the release watcher.

| Workflow | Trigger | What runs (× x86_64, aarch64) | Reports |
|----------|---------|-------------------------------|---------|
| `ci` | push to `main` / `cursor/**`, PR, dispatch; doc-only changes skipped, `versions.lock.md` always runs | `pin-check`; `rust-quality` (fmt, clippy, tests, build); on `main`: `e2e-pin` = live smoke, fail-closed, fail-modes H1+H2, hop-trace, go-ftw smoke at the pins | check status |
| `release-watch` | daily 05:17 UTC, dispatch (`force=<axis>:<tag>`, `dry_run`) | lists stable releases (Envoy `v1.x.y`, libmodsecurity `v3.0.x`, CRS `v4.x.y` — filtered from the release list, never `releases/latest`); a tag newer than the pin gets an issue and a `stable-candidate` dispatch | issue `stable-candidate: <axis> <tag>` |
| `stable-candidate` | dispatch (from `release-watch` or by hand) | that axis at the candidate, the others at their pins; same live suites as `e2e-pin` | comment on the issue: per-arch result, measured minutes, bump lines |
| `stable-window` | weekly (Mon 04:23 UTC), dispatch (`depth`) | pins + the last 3 stables of each axis, one axis moved per cell (7 cells); live suites | issue `stable-window: failing cells` on failure, closed when green |
| `crs-full` | monthly (7th, 03:41 UTC), dispatch | full CRS go-ftw at the pins | issue `crs-full: go-ftw failing` on failure, closed when green |
| `release` | tag `vX.Y.Z`; dispatch = dry run under `sha-<short>` | release build per arch → `ext-proc-modsec-<ver>-linux-{x86_64,aarch64}.tar.gz` (+ `.sha256`; bundles `libmodsecurity.so`), per-arch image, multi-arch `ghcr.io/<owner>/envoy-modsec-connex:<ver>`, GitHub Release (tag only) | Release page |

Candidates never bump anything: after a green `stable-candidate`, a human or agent edits `versions.lock.md` (plus `scripts/check-pins.sh` and `ci.yml` env) on `main`, and `ci` re-runs as the gate.

### Measured (2026-09-27, private repo, 2-vCPU runners)

| Run | x86_64 | aarch64 | Result |
|-----|--------|---------|--------|
| `ci`, warm caches | rust-quality 52s · e2e-pin 95s | rust-quality 61s · e2e-pin 80s | green; 8 job-minutes |
| `ci`, cold aarch64 (libmodsecurity built from source) | rust-quality 91s · e2e-pin 122s | rust-quality 407s · e2e-pin 446s | green; 21 job-minutes |
| `release-watch` | — | — | 10–12s on `ubuntu-slim`; 1 job-minute |
| `stable-candidate envoy v1.38.4` (forced proof via `release-watch`) | 87s | 405s (cold) | both green, fail-modes 59/59; 10 job-minutes |
| `crs-full` | 333s (go-ftw 259s) | 302s (go-ftw 247s) | **5091/5091** on both; 13 job-minutes |
| `stable-window depth=2` (4 cells) | 91–109s per cell | 90–100s per cell; 411s for libmodsecurity v3.0.15 (cold) | 8/8 green; 23 job-minutes |
| `release` dispatch | 99s | 111s | tarballs + multi-arch manifest (`linux/amd64`, `linux/arm64`); 5 job-minutes |

"Job-minutes" rounds each job up to a whole minute, as Actions billing does. The run-timing API reports 0 billable ms for these runs, so the numbers come from job start/end times. At these rates a month of 30 `main` pushes, the daily watcher, one weekly 7-cell window, one monthly full CRS run and a release is roughly 450 job-minutes, well inside the 2,000 free private minutes. A cold libmodsecurity build (new tag or evicted cache) adds about 5 minutes on aarch64.

---

## Honest boundaries

- **go-ftw is HTTP/1.x only** and judges by status code. A green run says nothing about HTTP/2; the H2 evidence is `fail-modes.sh --proto h2`.
- **Class 3** (per-request engine error) cannot be injected through a well-behaved Envoy; `fail-modes.sh` runs the gRPC integration tests for it (real libmodsecurity, no Envoy).
- **Class 6:** with `SecAuditLog` pointing at an unwritable path, libmodsecurity v3.0.16 still loads the rules; the suite proves decisions are unchanged (attack **403**, origin untouched; benign **200**).
- **HTTP/3 and WebSocket frames** are not tested and not supported.
- **Not ported from the experiment lab:** the perf harness, and hop-trace for WebSocket / gRPC origins (the demo origin is plain HTTP).
- **CI runs the live suites on `main` only.** `cursor/**` pushes and PRs get pin-check + rust-quality; a PR is proven live only after it lands (or by dispatching `ci`).
- **The release tag path is proven by dispatch, not by a real tag:** the dispatch run builds and pushes the same tarballs and multi-arch image; only the final `gh release create` step is tag-only.
- **Tarballs are not static:** they bundle `libmodsecurity.so` but need Ubuntu 24.04's pcre2, libxml2, yajl, curl, GeoIP and LMDB runtime libraries (the image has them).
- **Pins:** quote [`versions.lock.md`](../versions.lock.md) — do not invent tip flags.
