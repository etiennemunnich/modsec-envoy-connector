---
title: Testing — layers, gates, where each runs
audience: operators + contributors
date: 2026-09-27
pins: Envoy v1.39.1 · libmodsecurity v3.0.17 · CRS v4.29.0 · failure_mode_allow:false
license: see LICENSE
status: GitHub-hosted CI on x86_64 + aarch64 — Rust gate and live Envoy suites on every main push; daily stable-release watch, weekly version window, on-demand ~12-month axis matrix, monthly full CRS
---

# Testing

**One sentence:** every push to `main` runs, natively on GitHub-hosted `x86_64` and `aarch64` Ubuntu, the Rust gate (fmt, clippy, tests with libmodsecurity linked) **and** the live Envoy → connector → libmodsecurity + CRS suites (smoke, fail-closed, the HTTP/1.1 + HTTP/2 fail-mode matrix, hop-trace, go-ftw smoke); new stable Envoy / libmodsecurity / CRS releases are detected daily and tested on both architectures, the last three stables of each axis weekly, an optional ~12-month axis-at-a-time matrix on demand, and the full CRS regression monthly.

Cross-links: [how-it-works.md](./how-it-works.md) · [fail-closed.md](./fail-closed.md) · [`versions.lock.md`](../versions.lock.md) · [`versions.window.md`](../versions.window.md) · [`versions.one-year.yaml`](../versions.one-year.yaml) · [findings/one-year-stable-matrix.md](./findings/one-year-stable-matrix.md).

---

## Layer map

| Layer | Proves | Where it runs |
|-------|--------|---------------|
| **A — Pins + Rust** | pins; engine + connector unit tests; gRPC integration tests against libmodsecurity (allow, deny, redirect, BUFFERED/STREAMED-style multi-chunk body, REMOTE_ADDR from attributes, class-3 fail-closed 500 paths ≥ 8, trailers safe, `/healthz`) | `ci`: `pin-check`, `rust-quality (x86_64)`, `rust-quality (aarch64)`; `cargo test --workspace` locally |
| **B — Live smoke + fail-closed** | Envoy → connector → libmodsecurity + CRS: benign **200**, SQLi/XSS URL + body **403**, response-body **403**; kill → **500**, hang → **504** (N/A under FULL_DUPLEX), bad rules → **500**; origin untouched on every deny / failure. Body-path floor ≥ 5. | `ci` → `e2e-pin` × arch (**BUFFERED**); `ci` → `e2e-streamed` × arch (**STREAMED**, same product suites); `ci` → `e2e-buffered-partial`; `ci` → `e2e-full-duplex`; `BODY_MODE=… ./demo/scripts/up.sh` then `smoke.sh`, `fail-closed.sh` |
| **C — Fail-mode matrix (H1 + H2)** | Fail-closed classes 1–6 over HTTP/1.1 **and** HTTP/2 prior knowledge, protocol proven from the Envoy access log; split `Cookie` crumbs inspected; an attack only in the last chunk / DATA frames still **403**; class-3 gRPC floor ≥ 8; negative control (`failure_mode_allow: true`) shows the same kill / hang *does* let traffic through, so the checks can see fail-open | `ci` → `e2e-pin` + `e2e-streamed` × arch; `demo/scripts/fail-modes.sh` |
| **D — CRS regression (go-ftw)** | OWASP CRS `tests/regression` through Envoy, HTTP/1.x, judged by status code (**BUFFERED** default; **STREAMED** CI smoke; **FULL_DUPLEX_STREAMED** local full + CI smoke) | smoke: `ci` → `e2e-pin` + `e2e-streamed` + `e2e-full-duplex` × arch; full: `crs-full` × arch (monthly, **BUFFERED**); `BODY_MODE=FULL_DUPLEX_STREAMED ./demo/scripts/up.sh` then `go-ftw.sh smoke\|body\|full` |
| **E — Stable versions** | a new stable Envoy v1.x / libmodsecurity v3.0.x / CRS v4.x release, the last three stables of each axis, and (on demand) stables from the last ~12 months, pass layers B–D with the other axes at their pins (axis-at-a-time; Cartesian opt-in only) | `release-watch` (daily) → `stable-candidate` × arch → issue; `stable-window` × arch (weekly); `stable-one-year` × arch (`workflow_dispatch` only); locally `scripts/one-year-matrix.sh plan\|run`, or `scripts/ci-live-e2e.sh` with `ENVOY_VERSION` / `MODSECURITY_PIN` / `CRS_TAG`, or `scripts/probe-modsec-pin.sh`, `envoy-candidate-smoke.sh`, `crs-version-probe.sh` |
| **Trace** | one request followed across every hop by `x-request-id` (Envoy access log → connector phases → CRS matches → origin) | `ci` → `e2e-pin` + `e2e-streamed` × arch; `demo/scripts/hop-trace.sh` |
| **Trailers (SEND)** | Trailer safety with temporary trailer `SEND` Envoy config: allow+trailers **200**, body SQLi+trailers **403**, live `trailers_continue`, gRPC trailers-alone **500**. Floor ≥ 5. Trailer *values* not CRS-inspected. | `ci` → `e2e-pin` + `e2e-streamed` × arch; `demo/scripts/trailers.sh` |

All of it runs on GitHub-hosted runners (`ubuntu-24.04`, `ubuntu-24.04-arm`), natively per architecture — no self-hosted or Mac runner, no QEMU, no cross-compiling. See [Hosted CI](#hosted-ci).

---

## Local gates

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace

./demo/scripts/up.sh                  # Envoy + connector + CRS + origin (BUFFERED)
./demo/scripts/smoke.sh               # allow / deny / body / response path (body floor ≥ 5)
./demo/scripts/fail-closed.sh         # kill → 500, hang → 504, bad rules → 500
./demo/scripts/fail-modes.sh          # classes 1–6 + controls, H1 and H2 (class-3 gRPC floor ≥ 8)
BODY_MODE=STREAMED ./demo/scripts/up.sh && ./demo/scripts/smoke.sh && ./demo/scripts/fail-closed.sh
BODY_MODE=FULL_DUPLEX_STREAMED ./demo/scripts/up.sh && ./demo/scripts/smoke.sh && ./demo/scripts/fail-closed.sh
BODY_MODE=FULL_DUPLEX_STREAMED ./demo/scripts/go-ftw.sh smoke   # after up; hang→504 N/A under duplex
./demo/scripts/go-ftw.sh smoke        # demo tests + body-heavy CRS SQLi/XSS tests (BUFFERED default)
./demo/scripts/go-ftw.sh full         # whole CRS regression tree
./demo/scripts/hop-trace.sh --expect-status 403 --expect-origin no '/search?q=1%27%20UNION%20SELECT%201--'
./demo/scripts/perf.sh                # latency samples; floors so empty runs fail
./demo/scripts/down.sh
```

go-ftw: `./demo/scripts/install-go-ftw.sh`. Results and transcripts land in `demo/.run/` (`go-ftw/`, `fail-modes/`, `hop-trace/`).

---

## Latest measured results

Hosted Linux on both architectures: see [Hosted CI](#measured-2026-09-27-private-repo-2-vcpu-runners). Local run on macOS (arm64), Envoy v1.39.1, libmodsecurity v3.0.16, CRS v4.29.0, go-ftw v2.6.0, 2026-09-27:

| Suite | Result |
|-------|--------|
| `cargo test --workspace` | 65 passed, 0 failed (class-3 gRPC fail-closed filter: 12) |
| `smoke.sh` | passed |
| `fail-closed.sh` | passed |
| `fail-modes.sh` (H1 + H2) | 59 passed, 0 failed |
| `go-ftw.sh smoke` | demo tests 8/8; CRS body-heavy tests 118/118 |
| `go-ftw.sh full` | **5091 passed, 0 failed** of 5091 (42 of the passes are judged through `demo/ftw/envoy-overrides.yaml`) |

`920100-8` and `920610-2` send a URI with a `#fragment`, which Envoy rejects itself with a local **400** before the request phase. The connector passes Envoy's local reply through (see [fail-closed.md](./fail-closed.md#envoys-own-local-replies-not-a-failure-class)), so the client gets the 400 CRS expects.

The overrides file records measured Envoy platform differences, like CRS's own `nginx-overrides.yaml`: 36 tests where Envoy's HTTP/1 codec drops a malformed request (client sees an empty reply, envoy#29440) and 6 where CRS's expected status was written for Apache's parser (the outcome here is still a 403 block, or matches CRS's nginx override). Each of the 42 entries was re-measured by removing it and running its test alone: all 42 still fail without their override.

---

## Hosted CI

GitHub-hosted runners only: `ubuntu-24.04` (x86_64) and `ubuntu-24.04-arm` (aarch64), each building and testing natively. Both are pinned to the same Ubuntu release (never `ubuntu-latest`), and the libmodsecurity and cargo caches are keyed on the OS release, so a move to a newer Ubuntu is one deliberate change for both architectures. `ubuntu-slim` runs the release watcher.

| Workflow | Trigger | What runs (× x86_64, aarch64) | Reports |
|----------|---------|-------------------------------|---------|
| `ci` | every push to `main` / `cursor/**`, PR, dispatch; runs on `main` are never cancelled | `pin-check` (pins + install-script fallbacks, workflow rules, CI-script tests); `rust-quality` × arch (fmt, clippy, tests, build, all `--locked`, Rust from `rust-toolchain.toml`); `msrv` (`cargo check` at `rust-version`); `supply-chain` (cargo-deny: RustSec, licenses, sources); `protos` (`gen-protos.sh --check`, protoc 25.3); `e2e-pin` × arch = **BUFFERED** product suites (smoke, fail-closed, fail-modes H1+H2, hop-trace, go-ftw smoke, trailers); `e2e-streamed` × arch = same suites under **STREAMED**; `e2e-buffered-partial` × arch = PARTIAL honesty cell; all on `main` pushes, PRs and dispatches, not `cursor/**` pushes; `ci-ok` = one verdict over all of them. Docs-only changes (`docs/**`, `*.md` except `versions.lock.md`) skip the heavy jobs and still get a `ci-ok` | check status |
| `release-watch` | daily 05:17 UTC, dispatch (`force=<axis>:<tag>`, `dry_run`) | lists stable releases (Envoy `v1.x.y`, libmodsecurity `v3.0.x`, CRS `v4.x.y` — all pages of the release list, never `releases/latest`); the latest stable **and** the top patch of the pinned minor line, when newer than the pin, each get a `stable-candidate` dispatch (the issue is opened after the dispatch succeeds); newer tags outside those patterns are flagged "new line — not tracked"; a tag is retested until its issue has a ✅ result (or 3 ❌) | issue `stable-candidate: <axis> <tag>`; its own failures: issue `release-watch: failing` |
| `stable-candidate` | dispatch (from `release-watch` or by hand) | that axis at the candidate, the others at their pins; same live suites as `e2e-pin` | comment on the issue: per-arch result, measured minutes, bump lines |
| `stable-window` | weekly (Mon 04:23 UTC), dispatch (`depth`) | pins + the last 3 stables of each axis + the CRS LTS (`CRS_LTS_TAG`) when outside that window, one axis moved per cell (8 cells); libmodsecurity below v3.0.13 is skipped; live suites | issue `stable-window: failing cells` on failure, closed when green |
| `stable-one-year` | **dispatch only** (`strategy`, `days`, `profile`, `dry_run`, `confirm_cartesian`) — no cron | ~12-month stables (`published_at`, never `releases/latest`): default **axis** (~19 cells × 2 arches, ~90–130 warm job-min); optional **diagonal**; **cartesian** only with `confirm_cartesian=yes` (~176 cells / ~800+ min — never schedule). Profiles: `smoke` … `full-cell`. Empty matrix fails. | issue `stable-one-year: failing cells` on failure, closed when green; dry_run prints the plan only |
| `crs-full` | monthly (7th, 03:41 UTC), dispatch | full CRS go-ftw at the pins | issue `crs-full: go-ftw failing` on failure, closed when green |
| `release` | tag `vX.Y.Z` (`vX.Y.Z-rc.N` = pre-release); dispatch | tags only: `gate` = the tag commit is on `main` and has green `ci-ok`, `pin-check`, `rust-quality` × arch, `msrv`, `e2e-pin` × arch. Then release build per arch → `ext-proc-modsec-<ver>-linux-{x86_64,aarch64}.tar.gz` (+ `.sha256`; bundles `libmodsecurity.so`), per-arch image pushed by digest, multi-arch `ghcr.io/<owner>/envoy-modsec-connex:<ver>` from both digests, GitHub Release (tag only); build provenance attested once the repo is public. A dispatch skips the gate and the Release but **does push** the image, tagged `sha-<short>` | Release page |

### Schedule proof (cron configured + last proven run)

A schedule is proven only by a run with `event=schedule` (`gh run view <id> --json event,conclusion,headSha`). `workflow_dispatch` proves the same job graph before the cron fires; it is **not** a schedule proof. `scripts/check-workflows.sh` asserts both workflows keep their cron + `workflow_dispatch`.

| Workflow | Cron (UTC) | Last proven run | `event` | `conclusion` | `headSha` |
|----------|------------|-----------------|---------|--------------|-----------|
| `stable-window` | `23 4 * * 1` (Mon) | [36413020845](https://github.com/etiennemunnich/envoy-modsec-connex/actions/runs/36413020845) | **schedule** | success | `3249f96909991437afb2f4effb5de564a0307c13` |
| `crs-full` | `41 3 7 * *` (7th) | [36363409290](https://github.com/etiennemunnich/envoy-modsec-connex/actions/runs/36363409290) (path via dispatch; **no `event=schedule` yet** — next window ~7th of month) | workflow_dispatch | success | `bab5dc79c3ef75be63bd5ad1e7c63ec91a916d7c` |

Candidates never bump anything: after a green `stable-candidate`, a human or agent edits `versions.lock.md` (plus the offline fallback in that axis's install script, which `pin-check` compares) on `main`, and `ci` re-runs as the gate.

Every live suite must also reach a floor of passing checks, not just exit 0: smoke body-path checks ≥ 5, fail-modes ≥ 57 (class-3 gRPC ≥ 8), go-ftw demo tests ≥ 8, CRS body ids ≥ **100 at the pin** (version-aware for older CRS tags that ship fewer BODY_INCLUDE tests — e.g. v4.19.0 has 92; empty selection still fails), CRS full ≥ 5000 (`scripts/ci-live-e2e.sh`), go-ftw smoke/body stages only the BODY_INCLUDE rule YAML so a one-tag CRS parse poison (v4.23.0 `920640.yaml` `status: [400]` vs go-ftw 2.6) cannot empty the JSON summary. and each go-ftw run must end with the same connector process serving `/metrics` and no new `ext_proc_stream_errors_total`. Each cell asserts it ran on the expected architecture. Report jobs run unless the run was cancelled, and a run whose jobs were all skipped counts as a failure.

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
- **Class 3** (per-request engine error mid-exchange) cannot be injected through a well-behaved Envoy; see [fail-closed.md](./fail-closed.md#why-class-3-has-no-live-envoy-drill). Covered by gRPC tests (real `EngineError` + test-only `fail-inject` feature off in the product binary), floor ≥ 8; `fail-modes.sh` runs them.
- **STREAMED** matches BUFFERED on hosted product suites (smoke, fail-closed, fail-modes, hop-trace, go-ftw smoke, trailers). Full CRS (`go-ftw-full` / `crs-full`) stays BUFFERED for Actions cost; local tip still has STREAMED full CRS parity. Phase-2/4 rules still decide at EOS.
- **Trailers** values are not CRS-inspected. Product demo keeps trailer mode `SKIP`. With `SEND`, unfinished body is finalized when trailers mark EOS; trailers alone / no session → **500** (gRPC). Live: `demo/scripts/trailers.sh` (floor ≥ 5); gated in `e2e-pin` + `e2e-streamed`.
- **Class 6:** with `SecAuditLog` pointing at an unwritable path, libmodsecurity v3.0.16 still loads the rules; the suite proves decisions are unchanged (attack **403**, origin untouched; benign **200**).
- **HTTP/3 and WebSocket frames** are not CRS-inspected and not claimed as a WAF surface. Handshake hop-trace: `demo/scripts/hop-trace-ws.sh`. Frame bound suite: `demo/scripts/hop-trace-ws-frames.sh` (floor ≥ 6) — stock `upgrade_failed`; headers-only 101 + handshake ModSec; frames echo without CRS; fail-closed on handshake; BUFFERED+upgrade hang.
- **gRPC hop-trace** (headers/path/metadata): `demo/scripts/hop-trace-grpc.sh` (floor ≥ 6). Needs `go` + `grpcurl`. Switches to `envoy-grpc.yaml` (body `NONE`) and `demo/grpc-echo` :18090, then restores stock HTTP demo. **Not** protobuf CRS. Optional via `SUITES=… hop-trace-grpc` in `ci-live-e2e.sh` (not default hosted e2e).
- Perf latency samples: `demo/scripts/perf.sh` (floors; not an SLO).
- **Live suites run on `main` pushes, PRs and dispatches**, not on `cursor/**` pushes (those get the Rust, supply-chain and protos gates; dispatch `ci` on the branch for the live suites).
- **The release tag path has run once, as the pre-release `v0.1.0-rc.1`** (gate → both arch builds → multi-arch image → GitHub pre-release with both tarballs); no final `v0.1.0` has been cut. The **GitHub Release + git tag were deleted**; GHCR image tags (`v0.1.0-rc.1`, `sha-770ab01-*`) may remain until someone with `read:packages` + `delete:packages` runs the commands in [findings/ghcr-stale-tags.md](./findings/ghcr-stale-tags.md).
- **Build provenance is not attested yet:** GitHub artifact attestations need a public repo on this plan, so those steps are skipped while the repo is private.
- **`main` has no branch protection or ruleset:** both need GitHub Pro or a public repo. `ci-ok` is the check to require once they are available.
- **Tarballs are not static:** they bundle `libmodsecurity.so` but need Ubuntu 24.04's pcre2, libxml2, yajl, curl, GeoIP and LMDB runtime libraries (the image has them).
- **Pins:** quote [`versions.lock.md`](../versions.lock.md) — do not invent tip flags.
