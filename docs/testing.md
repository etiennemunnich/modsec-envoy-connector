# Testing

What each test proves, where it runs, and how to run it yourself. Pins are in [`versions.lock.md`](../versions.lock.md); the failure model is in [fail-closed.md](./fail-closed.md).

Every pull request, push to `main` and dispatch of `ci` runs, natively on GitHub-hosted `ubuntu-24.04` (x86_64) and `ubuntu-24.04-arm` (aarch64), the Rust checks **and** the live Envoy → connector → libmodsecurity + CRS suites in the three product body modes (BUFFERED, STREAMED, FULL_DUPLEX_STREAMED). The limited body modes, the full CRS regression and other upstream versions run on schedules. There is no self-hosted or Mac runner, no QEMU and no cross-compiling.

## What is proven

| Layer | Proves | Runs in |
|-------|--------|---------|
| Rust | engine and connector unit tests; gRPC tests against the real libmodsecurity: allow, deny, redirect, multi-chunk bodies, `REMOTE_ADDR` from Envoy attributes, engine-error → 500 (class 3, ≥ 8 tests), body modes from `protocol_config`, trailers ending the body phase, `/healthz` (503 unless the engine is On; probes kept out of the metrics); the stream never ends gRPC OK without a verdict (oversize or unreadable message, half-close with a held body, panic, status-0 drop); the FULL_DUPLEX reply path and held-body cap; the idle and duplex deadlines → 504; 0-rule rulesets refused; the engine CRS test, which CI makes mandatory (`MODSEC_REQUIRE_CRS=1`) | `rust-quality` × arch; `cargo test --workspace` |
| Smoke | benign **200**; URL, request-body and response-body attacks **403**; CONNECT **403**; origin not contacted on a deny | `smoke.sh` |
| Fail-closed | connector killed → **500**; connector hung → **504** (not under FULL_DUPLEX_STREAMED, see [fail-closed.md](./fail-closed.md#full_duplex_streamed-and-a-hung-connector)); bad rules → **500**; origin not contacted | `fail-closed.sh` |
| Fail-mode matrix | failure classes 1–6 over HTTP/1.1 **and** HTTP/2 (protocol read from the Envoy access log); split `Cookie` headers; an attack only in the last body chunk; a negative control with `failure_mode_allow: true` that shows the same kill and hang *do* reach the origin, so the checks can see a fail-open | `fail-modes.sh` |
| Hop trace | one request followed by `x-request-id` through the Envoy access log, connector phases, CRS matches and the origin | `hop-trace.sh` |
| Trailers | HTTP/1.1 with trailers enabled in Envoy: allow + trailers **200**, body SQLi + trailers **403**, Envoy delivers trailers to the connector, trailers without a session **500** (gRPC test). Trailer *values* are not inspected | `trailers.sh` |
| HTTP/2 trailers | through the stock config: SQLi body + trailers, and a SQLi query with trailers but no body, **403** with the origin untouched; benign body + trailers and benign trailers-only **200**, origin +1 | `h2-trailers.sh` |
| CRS (go-ftw) | OWASP CRS `tests/regression` through Envoy, judged by status code, **HTTP/1.x only** | `go-ftw.sh smoke` on every PR; `go-ftw.sh full` monthly |
| Upstream versions | new stable Envoy v1.x / libmodsecurity v3.0.x / CRS v4.x releases and the last three stables of each axis pass the live suites, one axis moved off its pin at a time | `release-watch`, `stable-candidate`, `stable-window` |

Each live suite must also reach a minimum count of passing checks, not only exit 0, so a suite that silently runs fewer checks fails. SKIP lines never count. The floors are in [`scripts/ci-floors.sh`](../scripts/ci-floors.sh): smoke body checks ≥ 5, fail-closed ≥ 13 (≥ 11 under FULL_DUPLEX_STREAMED), fail-modes ≥ 57 (≥ 51), go-ftw demo tests ≥ 8, CRS body tests ≥ 100 at the pin, CRS full ≥ 5000, trailers ≥ 5, HTTP/2 trailers ≥ 4 (≥ 3 under NONE, which skips the body cell). After every go-ftw run the same connector process must still be serving `/metrics` with no new `ext_proc_stream_errors_total`. Each cell asserts the architecture it ran on.

## Body-mode coverage

| Body mode | Product suites | go-ftw smoke | go-ftw full | Notes |
|-----------|----------------|--------------|-------------|-------|
| BUFFERED | every PR (`e2e-pin`) | every PR | monthly (`crs-full`) | product default |
| STREAMED | every PR (`e2e-streamed`) | every PR | monthly | phase-2 and phase-4 rules still decide at end of stream |
| FULL_DUPLEX_STREAMED | every PR (`e2e-full-duplex`) | every PR | monthly | hang → 504 does not apply |
| BUFFERED_PARTIAL | weekly (`e2e-lab`) | under the limit only | not run | bytes past the limit are not inspected; never a full-CRS claim |
| NONE | weekly, headers and fail-closed only | n/a | n/a | body attacks reach the origin |
| asymmetric (request BUFFERED / response STREAMED and the reverse) | weekly | weekly | not run | lab only |

go-ftw full regression: 5231/5231 in BUFFERED, STREAMED and FULL_DUPLEX_STREAMED in a local x86_64 Linux run at the current pins on 2026-10-12. `crs-full` has not yet run in this repository; it is scheduled monthly. go-ftw is HTTP/1.x and judges status codes only; the HTTP/2 evidence is `fail-modes.sh --proto h2`.

## Run it locally

Install and bring the demo up first ([getting-started.md](./getting-started.md)). Transcripts land in `demo/.run/`.

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked

./demo/scripts/up.sh                  # BUFFERED; BODY_MODE=STREAMED|FULL_DUPLEX_STREAMED|NONE|BUFFERED_PARTIAL ./demo/scripts/up.sh
./demo/scripts/smoke.sh
./demo/scripts/fail-closed.sh
./demo/scripts/fail-modes.sh          # H1 and H2
./demo/scripts/hop-trace.sh           # traces GET /; for a deny add: --expect-status 403 --expect-origin no '/search?q=1%27%20UNION%20SELECT%201--'
./demo/scripts/trailers.sh
./demo/scripts/h2-trailers.sh         # HTTP/2 bodies that end in trailers
./demo/scripts/install-go-ftw.sh      # go-ftw at GO_FTW_PIN, into ~/.local/bin
./demo/scripts/go-ftw.sh smoke        # or: body | full
./demo/scripts/perf.sh                # latency samples, not an SLO
./demo/scripts/down.sh
```

Other scripts: `partial-honesty.sh` (BUFFERED_PARTIAL: an in-prefix SQLi is **403**, a SQLi past the limit can reach the origin), `buffered-oversize.sh`, `connect-assert.sh`, `hop-trace-ws.sh` and `hop-trace-ws-frames.sh` (WebSocket handshake and frame bounds; frames are not CRS-inspected), `hop-trace-grpc.sh` (gRPC headers and metadata; needs `go` and `grpcurl`; protobuf bodies are not CRS-inspected), `cookie-protocols.sh` (multi-`Cookie` / crumb CRS on **H1 + H2 + lab H3**; Envoy `; ` coalesce before ModSec), `h3-probe.sh` (**lab HTTP/3 only**: QUIC + aioquic; hop/fail-closed + Cookie crumbs; NONE body honesty; **not** product H3 WAF / not on every PR — demo-only).

To run one CI cell exactly as CI does, including the floors, or to try another upstream version:

```bash
BODY_MODE=STREAMED SUITES="smoke fail-closed fail-modes hop-trace go-ftw-smoke trailers connect-assert" \
  ./scripts/ci-live-e2e.sh
ENVOY_VERSION=v1.38.4 SUITES="smoke fail-closed" ./scripts/ci-live-e2e.sh   # that Envoy must be on PATH
CRS_TAG=v4.25.2 SUITES="smoke go-ftw-smoke" ./scripts/ci-live-e2e.sh        # fetched into demo/.crs-v4.25.2
```

CI-side checks, offline: `./scripts/check-pins.sh`, `./scripts/check-workflows.sh`, `./scripts/test-ci-scripts.sh`.

## Workflows

| Workflow | Trigger | What runs (× x86_64, aarch64) | Reports |
|----------|---------|-------------------------------|---------|
| `ci` | pull requests, pushes to `main`, dispatch. Branch pushes run nothing; runs on `main` are never cancelled | `pin-check` (pins, workflow rules, shellcheck, CI-script tests, the skip decision, and on PRs the CI-skip-token guard); `rust-quality` × arch (fmt, clippy, test, build, all `--locked`; installs the CRS pin and sets `MODSEC_REQUIRE_CRS=1`, so the engine CRS test fails rather than skips); `msrv`; `supply-chain` (cargo-deny); `protos` (`gen-protos.sh --check`); `e2e-pin` (BUFFERED), `e2e-streamed`, `e2e-full-duplex` × arch; `ci-ok`, the single verdict | check status |
| `e2e-lab` | weekly (Mon 05:47 UTC), dispatch | BUFFERED_PARTIAL, NONE and the two asymmetric body modes | issue `e2e-lab: failing cells` |
| `crs-full` | monthly (7th, 03:41 UTC), dispatch | `go-ftw.sh full` in BUFFERED, STREAMED, FULL_DUPLEX_STREAMED | issue `crs-full: go-ftw failing` |
| `release-watch` | daily 05:17 UTC, dispatch | lists stable releases of each axis; the latest stable **and** the top patch of the pinned line, when newer than the pin, each get a `stable-candidate` dispatch; newer release lines the patterns do not cover are flagged; a tag is retested until its issue records a result | issue `stable-candidate: <axis> <tag>`; its own failures: `release-watch: failing` |
| `stable-candidate` | dispatch (by `release-watch` or by hand) | that axis at the candidate, the others at their pins: smoke, fail-closed, fail-modes, hop-trace, go-ftw smoke | comment on the candidate issue |
| `stable-window` | weekly (Mon 04:23 UTC), dispatch | the last 3 stables of each axis, plus the CRS LTS when outside that window, one axis moved per cell; libmodsecurity below v3.0.13 is skipped | issue `stable-window: failing cells` |
| `stable-one-year` | dispatch only | stables from the last ~12 months, one axis at a time by default ([`versions.one-year.yaml`](../versions.one-year.yaml), [`scripts/one-year-matrix.sh`](../scripts/one-year-matrix.sh)); a Cartesian product needs `confirm_cartesian=yes` | issue `stable-one-year: failing cells` |
| `ash` | PRs touching workflows, ASH config, Rust, scripts, demo, tools, packaging or dependencies; weekly (Mon 03:11 UTC); dispatch | [ASH](#security-scan-ash), report-only | artifact `ash-results`; on `main`, issue `ash: failing` |
| `release` | tag `v*` (any `vX.Y.Z-<suffix>` is a pre-release); dispatch | see [Releases](#releases) | Release page |

Issues are closed again when the workflow goes green. Report jobs run unless the run was cancelled.

### When `ci` skips the heavy jobs

`ci-ok` always reports. The heavy jobs are skipped in exactly two cases:

- **Docs only.** Every changed file is under `docs/` or ends in `.md` (except `versions.lock.md`), **and** the base commit itself has a successful `ci` run ([`scripts/ci-changes.sh`](../scripts/ci-changes.sh)). A docs change on top of an untested commit runs everything.
- **Tree already tested.** A push to `main` whose git tree is exactly the merge tree that a successful same-repository pull-request run tested. On a PR, `ci-ok` uploads the artifact `tested-tree-<tree>` after every job passed; [`scripts/ci-tested-tree.sh`](../scripts/ci-tested-tree.sh) looks it up. Bring a branch up to date with `main` before merging, or `main` re-runs everything.

There are no other skips. On pull requests `pin-check` fails if the PR title, the PR body or any commit message carries a token that makes GitHub skip workflows ([`scripts/ci-skip-tokens.sh`](../scripts/ci-skip-tokens.sh)), because a squash merge would copy it onto `main` and that commit would get no `ci` run at all.

### Releases

On a tag, `gate` first runs [`scripts/release-version.sh`](../scripts/release-version.sh): the tag must equal `v` + the version of every crate, pre-release included (`v0.1.0-alpha.2` needs `0.1.0-alpha.2`). Then [`scripts/release-gate.sh`](../scripts/release-gate.sh): the tag commit must be on `main`, and a successful `ci` run for exactly that commit, from this repository, must have these 13 checks green from GitHub Actions in its own check suite: `ci-ok`, `pin-check`, `rust-quality` × 2, `msrv`, `supply-chain`, `protos`, and `e2e-pin`, `e2e-streamed`, `e2e-full-duplex` × 2. A same-named check from another app or workflow does not count. A `main` commit whose heavy jobs were skipped has no such run: dispatch `ci` on `main` for it before tagging.

Then each architecture builds `ext-proc-modsec-<ver>-linux-<arch>.tar.gz` (+ `.sha256`). The tarball bundles `lib/libmodsecurity.so*`, and the binary finds it through RUNPATH `$ORIGIN/../lib`; the job fails if the RUNPATH is missing or `ldd` resolves libmodsecurity anywhere else. Per-arch images are built, tested and pushed by digest; the multi-arch tag `ghcr.io/<owner>/modsec-envoy-connector:<ver>` is made from both digests, then the GitHub Release is created. Build provenance is attested once the repository is public.

A dispatch of `release` is a build-only dry run from any ref: it builds and tests the tarballs and images and uploads the tarballs as run artifacts. It pushes nothing to GHCR, creates no tag and no Release.

### Schedule proof

A schedule is proven only by a run with `event=schedule` (read with `gh run view <id> --json event,conclusion,headSha`); a dispatch proves the same job graph but not the cron.

| Workflow | Cron (UTC) | Last `event=schedule` run in this repository |
|----------|------------|-----------------------------------------------|
| `stable-window` | `23 4 * * 1` | [38247631117](https://github.com/etiennemunnich/modsec-envoy-connector/actions/runs/38247631117): success, `b7751c4c61ee61dbffea807319db3f7ce45f492f` |
| `release-watch` | `17 5 * * *` | — |
| `e2e-lab` | `47 5 * * 1` | — |
| `ash` | `11 3 * * 1` | — |
| `crs-full` | `41 3 7 * *` | — |

Candidates never bump anything. After a green `stable-candidate`, edit `versions.lock.md` and the offline fallback in that axis's install script (which `pin-check` compares) in a pull request; `ci` is the gate.

## Security scan (ASH)

`ash` runs [AWS Automated Security Helper](https://github.com/awslabs/automated-security-helper) v3.7.1 in local mode, installed at the commit `ASH_PIN` in `versions.lock.md` (not the tag). Config: [`.ash/.ash.yaml`](../.ash/.ash.yaml), severity threshold `MEDIUM`. It is report-only (`fail_on_findings: false`): findings go to the `ash-results` artifact. Local mode runs the scanners ASH installs itself (Bandit, Checkov, Semgrep, detect-secrets, npm-audit); Grype, Syft, cfn-nag, cdk-nag and OpenGrep run only if already on `PATH`.

Locally (Python 3.10+, [uv](https://docs.astral.sh/uv/)):

```bash
uvx git+https://github.com/awslabs/automated-security-helper.git@af1206aff596f1288ad066828058b3011de2a998 --mode local
```

Reports go to `.ash/ash_output/` (ignored by git).

## Limits

- **go-ftw is HTTP/1.x only.** A green go-ftw run says nothing about HTTP/2.
- **Class 3** (an engine error in the middle of a request) cannot be injected through a well-behaved Envoy; the gRPC tests cover it ([fail-closed.md](./fail-closed.md#why-class-3-has-no-live-envoy-drill)).
- **Class 6:** with `SecAuditLog` pointing at an unwritable path, the pinned libmodsecurity still loads the rules; the suite proves decisions are unchanged.
- **Not inspected (product):** WebSocket frames, gRPC message bodies and trailer values. HTTP/3 has a **lab demo suite** (`h3-probe.sh` / `cookie-protocols.sh` + `envoy-h3.yaml`): measured hop + Cookie crumb CRS on the pinned Envoy; demo-only (not PR/`e2e-lab` CI). Not a product body mode and not a CRS H3 claim. Envoy H2/H3 reconstitutes multi-`Cookie` field lines with `"; "` before `ext_proc` (locked by those scripts). Trailers only end a STREAMED / FULL_DUPLEX body phase; every shipped config with a body mode sets trailer mode `SEND`. `BodySendMode.GRPC` is not implemented in the pinned Envoy.
- **STREAMED responses:** a phase-4 deny on a body that reaches Envoy after the response headers resets the client stream instead of answering 403 ([body-modes.md](./body-modes.md#streamed)). The demo origin writes each response in one segment, so the suites' response-body cells see 403.
- **Tarballs are not static:** they need Ubuntu 24.04's pcre2, libxml2, yajl, curl, GeoIP and LMDB runtime libraries ([deploy.md](./deploy.md#release-tarball)).
