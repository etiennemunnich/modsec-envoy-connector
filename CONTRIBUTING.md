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
4. Bring the branch up to date with `main`, then **squash-merge**.

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

- **Product:** git tag `vX.Y.Z` (+ optional pre-release suffix) and a GitHub Release.
- **Pins:** Envoy / libmodsecurity / CRS / connector in `versions.lock.md`, not issue labels.
- Optional triage labels (`pin:envoy`, `fail-closed`, …) are fine for filtering only.

## Releases

1. In a PR to `main`: set `version` in every `crates/*/Cargo.toml` to the tag without the `v`, pre-release included (`0.1.0-alpha.4` for `v0.1.0-alpha.4`), and refresh `Cargo.lock` (`cargo update -w`); give the version's heading in [`CHANGELOG.md`](./CHANGELOG.md) its date; set `PRODUCT_VERSION` in `versions.lock.md` to the tag. The release workflow refuses a tag that is not exactly `v` + the crate version ([`scripts/release-version.sh`](./scripts/release-version.sh)).
2. Check that the commit has a successful `ci` run with every required check green. A merge that took the tested-tree skip does not: run `gh workflow run ci.yml --ref main` and wait for it first. `scripts/release-gate.sh` refuses the tag otherwise.
3. Run the local early-tester checklist ([docs/getting-started.md](./docs/getting-started.md#early-tester-checklist)) on that commit.
4. Tag it: `git tag -a v0.1.0-alpha.4 <sha> && git push origin v0.1.0-alpha.4`.
5. The `release` workflow builds the Linux tarballs and the multi-arch GHCR image and creates the GitHub Release (pre-release for suffixed tags) with the pins and artifact notes. Paste the CHANGELOG section into the Release body.
6. After the release, record the commit and image digest in the connector row of `versions.lock.md`.

A manual dispatch of `release` builds and tests the artifacts but publishes nothing. Do not market an alpha as production-ready.

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
