# Agent standards — modsec-envoy-connector

Mandatory for coding agents working in this repo. Keep it short; deep tables live in `docs/` and lab notes outside this tree.

## Product

- **Shape:** Rust Envoy `ext_proc` gRPC sidecar → in-process C API → **libmodsecurity** (+ optional OWASP CRS). Not Coraza-as-product; not a Rust Envoy dynamic module.
- **Fail-closed is absolute:** connector down, gRPC error, panic/abort, hang/timeout, ModSec init/rules fail, ExtProc unreachable, or per-request ModSec `Err` → traffic must **not** reach origin as OK. Body mode (BUFFERED/STREAMED) does **not** relax this.
- **Hops:** Client → Envoy → (side-call) connector; **Envoy alone** forwards to origin after `Continue`. Connector / libmodsecurity never dial origin.

## Pins (source of truth)

Read **`versions.lock.md`** before bumping anything. Four axes + product tag:

| Axis | Field | Do not invent |
|------|-------|---------------|
| Envoy | `ENVOY_PIN` | tip flags / unlisted builds |
| libmodsecurity | `MODSECURITY_PIN` | random distro package as “the pin” |
| CRS | `CRS_TAG` (+ optional LTS) | issue labels as versions |
| Connector | git SHA / OCI digest | — |
| Product | git tag `vX.Y.Z` | — |

Versioning = **git tags + Releases + this lockfile**, not GitHub issue labels.

## Never

- Set `failure_mode_allow: true` on enforcement paths.
- Treat **BUFFERED_PARTIAL** as “CRS-complete” body inspection.
- Never claim **HTTP/3** or **WebSocket-frame** CRS without a proven QUIC / frame inspector path. WebSocket **handshake** hop-trace (`--proto ws`) documents Envoy upgrade rejection only — not CRS on upgrade headers or frames.
- Return **`Continue`** after ModSec / FFI `Err` (that is connector-lie fail-open → map to ImmediateResponse **500**).
- Invent Envoy / ModSec / CRS tip flags or pins not in `versions.lock.md`.
- Market go-ftw green as “H2 WAF proven” (go-ftw is **HTTP/1.x CRS fidelity** only).

## Testing expectations

| Gate | Where | What |
|------|-------|------|
| **Push / PR** | GitHub Actions `ci`, x86_64 + aarch64 | `pin-check`, `rust-quality`, `msrv`, `supply-chain`, `protos`; product e2e `e2e-pin` (BUFFERED) + `e2e-streamed` + `e2e-full-duplex` on `main` pushes, PRs and dispatches; `ci-ok` is the single verdict. Lab modes (PARTIAL / NONE / asymm) are weekly via `e2e-lab`. |
| **Stable versions** | `release-watch` (daily) → `stable-candidate`; `stable-window` (weekly); `e2e-lab` (weekly); `crs-full` (monthly) | new / last-3 stables per axis, both arches; lab body modes weekly; results as issues (see `docs/testing.md`) |
| **Live demo** | Mac / Linux host | `demo/scripts/`: `smoke.sh`, `fail-closed.sh`, `fail-modes.sh` (H1 + H2), `go-ftw.sh`, `hop-trace.sh`, `perf.sh` (latency floors); `scripts/ci-live-e2e.sh` runs a CI cell locally |
| **CRS** | go-ftw | **H1** rule fidelity only |
| **Fail-closed** | `demo/scripts/fail-closed.sh` | absolute gate: kill → 500, hang → 504, bad rules → 500, origin untouched |

GitHub-hosted runners only — never add a self-hosted or Mac runner. Do not claim Mac-only proofs from cloud CI.

## CI rules

1. **A proof cites a run only after reading it.** For each run URL, record `event`, `conclusion` and `headSha` from `gh run view <id> --json event,conclusion,headSha`. Never label a `workflow_dispatch` run as "scheduled"; a schedule is proven only by a run with `event=schedule`.
2. **Every new or changed check ships with a negative control.** Break it on a `cursor/ci-negctl-*` branch, run `gh workflow run ci.yml --ref <branch>` (branch pushes run no CI), link the red run, then link the green run on `main`. A check that never went red is unproven.
3. **No vacuous passes.** No `|| true`, `continue-on-error` or soft asserts on assertion paths. Guards use `var="$(cmd)"`, never `echo "$(cmd)"`. Suites assert a minimum count (PASS ≥ N, tests selected > 0), not only "no failures". Never call functions as `cond && fn` under `set -e`.
4. **Pin runners and toolchains; never float.** `ubuntu-24.04` / `ubuntu-24.04-arm` together, never `ubuntu-latest`. Rust comes from `rust-toolchain.toml`. Actions are pinned by full commit SHA with a `# vX.Y.Z` comment. No third-party actions in jobs with write scopes. (`scripts/check-workflows.sh` enforces the mechanical parts.)
5. **Cache keys include everything that changes the output:** OS id + version, arch, upstream tag, the hash of the build script, the toolchain file.
6. **Report jobs use `if: ${{ !cancelled() }}`, never `always()`.** A cancelled run must not file a failure issue.
7. **`main` runs are never cancelled.** `cancel-in-progress: false` is not enough: a concurrency group always cancels its *pending* run when a newer one queues. Give each main run its own group (`ci-main-<run_id>`) and cancel only on other refs.
8. **Watchers** propose the latest stable *and* the top patch on the pinned line, warn on release lines the pattern does not cover, dedupe only on a recorded result (never on "issue exists"), create tracking state only after the dispatch succeeded, and report their own failures.
9. **Releases are gated.** The tag commit must be on `main` and the required `ci` checks green for that SHA before anything is pushed to GHCR or released.
10. **Workflow comments and docs match the triggers.** When you change `on:` or `if:`, update the workflow's header comment and `docs/testing.md` in the same commit.

## GitHub Actions minutes

This repository is private on GitHub Pro: 3,000 minutes a month across all private repositories. At the quota, CI stops until the 1st.

- **`ci` runs on pushes to `main`, pull requests and dispatches.** A branch push runs nothing: open the PR, or `gh workflow run ci.yml --ref <branch>`.
- **The only skips are automatic** (`ci-ok` still reports): a docs-only change whose base commit has a green `ci` run (`scripts/ci-changes.sh`), and a merge whose tree a same-repo PR run already passed (`scripts/ci-tested-tree.sh`). Bring the branch up to date with `main` before merging, or `main` re-runs everything.
- **Never use workflow-skip tokens** in a commit message, PR title or PR body. A squash merge copies them onto `main`, that commit gets no `ci` run, and it cannot be released. `pin-check` fails a PR that carries one (`scripts/ci-skip-tokens.sh`).
- **When minutes run out, stop and tell Etienne.** Do not skip, shrink or disable checks to save minutes.
- **PR e2e is the three product body modes** (BUFFERED / STREAMED / FULL_DUPLEX × both arches). PARTIAL, NONE, and asymmetric labs run on `e2e-lab` (weekly + dispatch).
- **`ash` runs on security-relevant PRs, weekly on main tip, and dispatch** — not every main push and not docs-only PRs. Install is commit-pinned (`ASH_PIN` in `versions.lock.md`).
- **Timeouts sit a few times above measured runs.** Warm, every `ci` job finished under 2.1 minutes in 60 runs; a cold libmodsecurity build (any change to its install script) took up to 9.8 minutes (run 38241457904). Limits: e2e 15, rust-quality 15, msrv 20, crs-full 25. Never the 360-minute default; `check-workflows.sh` requires `timeout-minutes` on every job.
- **Few, full jobs.** Each job is billed as at least a whole minute, so a one-step job costs a minute; fold small checks into a job that already runs.

## Docs

On **substantive** architecture / fail-mode / protocol / CI / pin changes: update **`README.md`** (and product how-it-works when this repo owns it). Prefer honesty over completeness theater. Release-facing notes go in **`CHANGELOG.md`**; the early-tester path is **`docs/getting-started.md`**, the bring-your-own-Envoy guide **`docs/deploy.md`**, CI detail **`docs/testing.md`**. One page per topic; do not add parallel copies.

## License

Apache-2.0 — `Copyright (c) 2026 Etienne Munnich`. See `LICENSE` and `CONTRIBUTING.md` (DCO; no CLA).

## Git / PR workflow

**Remaining work lands via pull requests — not direct pushes to `main`.**

1. Branch from current `main`: `cursor/<short-name>` (agents may use `cursor/<short-name>-…`).
2. Commit + push the branch; open a PR against `main`.
3. Wait for **`ci-ok` green on both arches** (x86_64 + aarch64) for that PR head SHA.
4. **Squash-merge** only after the checklist below is satisfied.
5. Do **not** push commits straight to `main` for product/docs/CI work unless Etienne explicitly overrides for an emergency.

After a **validated** moderate slice on the feature branch: `git commit` + `git push` (to the branch). No force-push to shared branches unless Etienne asks. No secrets in commits.

### Test plan checklist (every PR)

Copy into the PR body (or tick the PR template). Skip rows that truly do not apply and say why.

- [ ] Fail-closed absolute: no `failure_mode_allow: true` on enforcement; no `Continue` after ModSec/FFI `Err`
- [ ] Pins: `versions.lock.md` still accurate (or bumped deliberately in this PR)
- [ ] Local: `cargo fmt` / `clippy -D warnings` / `cargo test --workspace --locked` (or docs-only and noted)
- [ ] Workflows touched → `./scripts/check-workflows.sh`; CI scripts touched → `./scripts/test-ci-scripts.sh`
- [ ] Live suites if behavior / demo / body-mode / fail-mode changed: smoke + fail-closed (and fail-modes / hop-trace / go-ftw as relevant); note Mac or `workflow_dispatch` run URL with `event`, `conclusion`, `headSha`
- [ ] No workflow-skip token in the PR title, body or any commit message
- [ ] `ci-ok` green on the PR (both arches) before squash-merge
- [ ] README stays product-only; agent/CI detail goes in `AGENTS.md` / `CONTRIBUTING.md` / `docs/`
- [ ] Claims cite real runs (see CI rule 1) — never invent green

## Crate layout

- `crates/ext-proc-modsec` — tonic ExternalProcessor binary (product name).
- `crates/modsec-engine` — safe façade over libmodsecurity; own `msc_*` FFI (`src/ffi.rs`); keep `unsafe` / FFI here only.
- `proto/` → `crates/ext-proc-modsec/src/pb/` — vendored Envoy ext_proc proto closure and its committed generated code; never hand-edit `pb/`, rerun `scripts/gen-protos.sh`.
- No new crates without a reason in the commit; the runtime set is tokio, tokio-stream, tonic (server + codegen), prost, tonic-prost, tracing.

Live demo + suites: `demo/scripts/` (`up.sh`, `smoke.sh`, `fail-closed.sh`, `fail-modes.sh`, `go-ftw.sh`, `hop-trace.sh`, `perf.sh`); go-ftw config and measured Envoy overrides in `demo/ftw/`. Version probes: `ENVOY_VERSION=… MODSECURITY_PIN=… CRS_TAG=… ./scripts/ci-live-e2e.sh`, `scripts/probe-modsec-pin.sh`. Ops cleanup: `scripts/ghcr-delete-stale.sh` (default dry-run; `--delete` allowlisted GHCR versions only; do not paste ad-hoc delete loops).
