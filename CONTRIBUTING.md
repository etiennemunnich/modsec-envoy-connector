# Contributing

Short guide for contributors. Coding-agent rules: **[AGENTS.md](./AGENTS.md)**. Pins: **[versions.lock.md](./versions.lock.md)**. CI and test detail: **[docs/testing.md](./docs/testing.md)**.

## Setup

1. Rust from [`rust-toolchain.toml`](./rust-toolchain.toml) (rustup picks it up). The crates' `rust-version` (1.88) is checked by the `msrv` job.
2. libmodsecurity at `MODSECURITY_PIN`, found through `pkg-config modsecurity`: `./demo/scripts/install-libmodsecurity.sh` (Homebrew on macOS, source build into `~/.local` on Ubuntu). Without `pkg-config`, set `MODSECURITY_LIB_DIR` to the directory holding `libmodsecurity`.
3. For the live demo and the fail-closed drills, follow [docs/getting-started.md](./docs/getting-started.md).
4. `protoc` is needed only to regenerate the committed ext_proc code after refreshing `proto/`: `./scripts/gen-protos.sh` (`--check` to verify).

Dependencies are deliberately few: `tokio`, `tokio-stream`, `tonic` (server + codegen only), `prost`, `tonic-prost`, `tracing`. Justify any new crate in the commit message.

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
./scripts/check-pins.sh
./scripts/check-workflows.sh     # when you touch .github/
./scripts/test-ci-scripts.sh     # when you touch scripts/
```

## Code map

| Path | Role |
|------|------|
| `crates/modsec-engine/` | The only crate with `unsafe`. Declares the libmodsecurity v3 `msc_*` API (`src/ffi.rs`); `Engine` loads rules at boot; `InspectionSession` is one transaction and maps interventions to a `Decision`. |
| `crates/ext-proc-modsec/src/processor.rs` | `ModSecProcessor` (tonic). One `Exchange` per gRPC stream; turns each `ProcessingRequest` into Continue, a terminal reply or an abort. |
| `crates/ext-proc-modsec/src/responses.rs` | Builds Continue and `ImmediateResponse`; validates statuses. |
| `crates/ext-proc-modsec/src/connection_meta.rs` | Reads Envoy `request_attributes` for `process_connection` and the URI protocol. |
| `crates/ext-proc-modsec/src/config.rs` | Flags and environment variables. |
| `crates/ext-proc-modsec/src/metrics.rs`, `metrics_server.rs` | Prometheus counters and histograms; `GET /metrics`, `GET /healthz`. |
| `crates/ext-proc-modsec/src/pb/` | Committed prost/tonic code for `envoy.service.ext_proc.v3`, generated from the Envoy v1.39.1 API in `proto/`. Never hand-edit; rerun `scripts/gen-protos.sh`. |
| `demo/` | Demo Envoy configs, rules and the live suites. |
| `scripts/` | CI helpers, pin checks and the release gate. |

## Pull requests

**Do not push product, docs, or CI changes straight to `main`.** Use pull requests.

1. Branch from current `main`: `cursor/<short-name>` (automation branches may append a short suffix).
2. Keep the PR focused; one concern per PR when possible so CI can be judged in isolation.
3. Open the PR, then wait for **`ci-ok` green on both architectures** for the PR head SHA.
4. Bring the branch up to date with `main`, then **squash-merge**. Clear extra squash commit messages so no `[skip ci]` line copies onto `main`.
5. Delete the head branch after merge (`git push origin --delete <branch>`). This repository does not auto-delete merged branches. Close superseded PRs; they do not merge.

- Use the [PR template](./.github/PULL_REQUEST_TEMPLATE.md) checklist.
- Never put a workflow-skip token in a commit message, PR title or PR body: the squash commit on `main` would get no `ci` run and could not be released. `pin-check` fails such a PR. The only skips are the automatic ones described in [docs/testing.md](./docs/testing.md#when-ci-skips-the-heavy-jobs).
- Update `README.md` only for product-facing behaviour. Contributor and agent detail lives here, in `AGENTS.md` and in `docs/`.
- Update `versions.lock.md` when pins change.
- Do not set `failure_mode_allow: true` on enforcement configs.

## Test matrix

All CI runs on GitHub-hosted runners, natively on `ubuntu-24.04` (x86_64) and `ubuntu-24.04-arm` (aarch64). Triggers and floors: [docs/testing.md](./docs/testing.md#workflows).

| Layer | CI | Local |
|-------|----|-------|
| `pin-check` (pins, workflow rules, CI-script tests, shellcheck, skip tokens) | every push to `main`, PR and dispatch | `./scripts/check-pins.sh`, `check-workflows.sh`, `test-ci-scripts.sh` |
| `rust-quality` (fmt, clippy, tests incl. gRPC against libmodsecurity, build) | same, × arch, unless skipped | the cargo commands above |
| `msrv`, `supply-chain` (cargo-deny), `protos` | same, unless skipped | `cargo deny check`, `./scripts/gen-protos.sh --check` |
| Live smoke, fail-closed, fail-modes H1+H2, trailers, HTTP/2 trailers, hop-trace, go-ftw smoke | `e2e-pin` (BUFFERED), `e2e-streamed`, `e2e-full-duplex` × arch, unless skipped | `./scripts/ci-live-e2e.sh` or the `demo/scripts/` suites |
| BUFFERED_PARTIAL, NONE, asymmetric modes | `e2e-lab` × arch (weekly) | `BODY_MODE=… ./demo/scripts/up.sh` |
| New stable Envoy / libmodsecurity / CRS | `release-watch` (daily) → `stable-candidate` × arch → issue | `ENVOY_VERSION=… ./scripts/ci-live-e2e.sh` |
| Last 3 stables per axis | `stable-window` × arch (weekly) | same, per cell |
| Full CRS go-ftw | `crs-full` × arch (monthly) | `./demo/scripts/go-ftw.sh full` |
| Release artifacts | `release` on a tag on `main` whose commit passed `ci` | — |

Supported container installs pull release tags from GHCR ([docs/deploy.md](./docs/deploy.md)); images are published only by `release` on tags (not on PRs). GHCR cleanup is an owner task: `./scripts/ghcr-delete-stale.sh` (dry-run by default).

## Versioning

- **Product:** git tag `vX.Y.Z` (+ optional pre-release suffix) and a GitHub Release. **Etienne names every such tag** — including `-alpha.N`, `-beta.N`, `-rc.N`. Agents and contributors do not pick the next string.
- **Pins:** Envoy / libmodsecurity / CRS / connector in `versions.lock.md`, not issue labels.
- Optional triage labels (`pin:envoy`, `fail-closed`, …) are fine for filtering only.

## Releases

SOP for making a version *ready* and then cutting it. Mechanical checks: [docs/testing.md — Releases](./docs/testing.md#releases). Agent short form: [AGENTS.md — Pins](./AGENTS.md#pins-source-of-truth).

**Etienne names the tag.** Do not bump crate `version` / `PRODUCT_VERSION`, do not `git tag` / `git push origin v*`, do not `gh release create`, and do not dispatch `release.yml` on a tag, unless he named that exact tag and said to push it. Never retag, move, or reuse a version string.

### Ready (before he names a tag)

Land product work on `main` through squash-merged PRs. Do not invent a CHANGELOG version heading yet — keep new work under `[Unreleased]`.

1. **One concern per PR.** Do not open a swarm of overlapping product PRs. Superseded PRs **close**; they do not merge.
2. **Negative controls** (`cursor/ci-negctl-*`): dispatch `ci.yml` on the branch (branch pushes run no CI), link the red run, then **close** the PR. Never merge. Never leave it open.
3. **Squash-merge** only with `ci-ok` green on both arches. Clear extra squash commit messages so no `[skip ci]` line copies onto `main`.
4. **Delete the head branch** after merge (`git push origin --delete <branch>`). This repository does not auto-delete merged branches.
5. **Do not point testers at an unpublished SHA as “the release”.** The last published tag is what GHCR and the tarballs are. If they need unreleased `main` fixes, say that explicitly (clone `main` / wait for the named tag).
6. Record whether `main`'s latest `ci` run skipped heavy jobs (`ci-tested-tree`). A skipped run **cannot** be used to tag.

### Cut (only after Etienne names the exact tag)

Example: he says `v0.1.0-beta.2`. Then, and only then:

1. **Version PR** to `main`: every `crates/*/Cargo.toml` `version` = the tag without `v` (so `0.1.0-beta.2`); `cargo update -w`; move `[Unreleased]` under that heading in [`CHANGELOG.md`](./CHANGELOG.md) with today's date; set `PRODUCT_VERSION` in `versions.lock.md`; update README / getting-started / deploy “current pre-release” to that tag. `./scripts/release-version.sh <tag>` must pass.
2. Wait for **`ci-ok` both arches**. Squash-merge; extra squash messages empty.
3. If that merge SHA's `ci` skipped rust-quality / e2e / …: `gh workflow run ci.yml --ref main`. Wait until `gh run view <id> --json event,conclusion,headSha` is `conclusion=success` and `headSha` is the merge SHA. [`scripts/release-gate.sh`](./scripts/release-gate.sh) requires the 15 named checks **green, not skipped**.
4. Run the early-tester checklist ([docs/getting-started.md](./docs/getting-started.md#early-tester-checklist)) on that commit.
5. **Stop** unless he also said to push the tag. Then: `git tag -a <tag> <sha> && git push origin <tag>`.
6. The `release` workflow builds the Linux tarballs and the multi-arch GHCR image and creates the GitHub Release (pre-release for suffixed tags). Paste the CHANGELOG section into the Release body.
7. **Follow-up PR:** connector D-row in `versions.lock.md` — git SHA, OCI digest, per-arch `libmodsec_dm.so` sha256 from that release run.
8. **GHCR visibility** is an owner click, independent of repo public. Anonymous `docker pull` stays `401` until he makes the package public.

A manual dispatch of `release` (no tag) is a build-only dry run: artifacts as run uploads, nothing published. Do not market a pre-release as production-ready.

## License

Copyright (c) 2026 Etienne Munnich. Licensed under the **Apache License, Version 2.0**. See [LICENSE](./LICENSE) and [NOTICE](./NOTICE).

## Developer Certificate of Origin (DCO)

By contributing, you certify each commit under the
[Developer Certificate of Origin](https://developercertificate.org/) (DCO) v1.1.
Sign off commits:

```bash
git commit -s -m "your message"
```

No CLA.
