# Contributing

Short guide for humans and agents. Standards for agents: **[AGENTS.md](./AGENTS.md)**. Pins: **[versions.lock.md](./versions.lock.md)**.

## Setup

1. Rust **1.88+** (MSRV in crate `Cargo.toml`; CI uses `stable`).
2. libmodsecurity **v3.0.16** discoverable via `pkg-config modsecurity` (`./demo/scripts/install-libmodsecurity.sh`: Homebrew on macOS, source build on Ubuntu).
   The `pkg-config` tool must be on `PATH` (or set `MODSECURITY_LIB_DIR` to the directory holding `libmodsecurity`).
3. For the live Envoy demo and fail-closed drills, follow [`demo/README.md`](./demo/README.md).
4. `protoc` is only needed to regenerate the committed ext_proc code after refreshing `proto/`: `./scripts/gen-protos.sh` (`--check` to verify).

Dependencies are deliberately few: `tokio`, `tokio-stream`, `tonic` (server + codegen only), `prost`, `tonic-prost`, `tracing`. Justify any new crate in the commit message.

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
./scripts/check-pins.sh
./scripts/check-workflows.sh     # when you touch .github/
./scripts/test-ci-scripts.sh     # when you touch scripts/ci-*.sh
```

CI builds with the toolchain in `rust-toolchain.toml`; rustup picks it up locally too.

## Pull requests

- Branch from `main` (or the documented tip). Prefer `cursor/<short-name>-…` for agent work.
- Keep PRs focused. Use the PR template checklist.
- Update `README.md` / `versions.lock.md` when behavior or pins change.
- Do not set `failure_mode_allow: true` on enforcement configs in the PR.

### PR checklist (summary)

- [ ] Fail-closed preserved (no enforcement fail-open; no `Continue` after ModSec Err)
- [ ] Pins in `versions.lock.md` still accurate (or bumped deliberately)
- [ ] `ci-ok` green (or explained)
- [ ] Mac / dispatch proofs noted if the change needs them (CRS full, fail-mode, H2)

## Test matrix

All CI runs on GitHub-hosted runners, natively on `ubuntu-24.04` (x86_64) and `ubuntu-24.04-arm` (aarch64). Details and measured minutes: [docs/testing.md](./docs/testing.md#hosted-ci).

| Layer | CI | Local |
|-------|----|-------|
| `pin-check` (pins, workflow rules, CI-script tests) | every push / PR | `./scripts/check-pins.sh`, `check-workflows.sh`, `test-ci-scripts.sh` |
| `rust-quality` (fmt, clippy, tests incl. gRPC against libmodsecurity, build) | every non-docs push / PR, × arch | same cargo commands |
| `msrv`, `supply-chain` (cargo-deny), `protos` | every non-docs push / PR | `cargo deny check`, `./scripts/gen-protos.sh --check` |
| Live smoke, fail-closed, fail-modes H1+H2, hop-trace, go-ftw smoke | `e2e-pin` × arch on `main` pushes, PRs and dispatches | `./scripts/ci-live-e2e.sh` or the `demo/scripts/` suites |
| New stable Envoy / libmodsecurity / CRS | `release-watch` (daily) → `stable-candidate` × arch → issue | `ENVOY_VERSION=… ./scripts/ci-live-e2e.sh` |
| Last 3 stables per axis | `stable-window` × arch (weekly) | same, per cell |
| Full CRS go-ftw | `crs-full` × arch (monthly) | `./demo/scripts/go-ftw.sh full` |
| Release artifacts | `release` on a tag that is on `main` with green `ci` (dispatch pushes an image, no Release) | — |

## Versioning

- **Product:** git tag `vX.Y.Z` (+ GitHub Release listing pin axes).
- **Pins:** Envoy / ModSec / CRS / connector in `versions.lock.md` — **not** issue labels as versions.
- Optional triage labels (`pin:envoy`, `fail-closed`, …) are fine for PR filtering only.

## License

Copyright (c) 2026 Etienne Munnich. This project is licensed under the
**Apache License, Version 2.0** — see [LICENSE](./LICENSE) (add full Apache-2.0
text in Phase 0 if missing). Optional `NOTICE` may list the same copyright.

**Why not MIT-0:** CRS, ModSecurity, ModSecurity-nginx, and Envoy are all
Apache-2.0. Matching Apache-2 keeps ecosystem friction low and retains
attribution; copyright stays with Etienne either way. MIT is a fine
permissive alternative; MIT-0 (zero attribution) is rarely wise for a named
product. Full comparison: Project store
`docs/connex-license-and-contribute.md`.

## Developer Certificate of Origin (DCO)

By contributing, you certify each commit under the
[Developer Certificate of Origin](https://developercertificate.org/) (DCO) v1.1.
Sign off commits:

```bash
git commit -s -m "your message"
```

No CLA. Keep PRs focused; see the checklist above and [AGENTS.md](./AGENTS.md).
(CRS prefers GPG-signed commits and has no DCO; DCO is the lightweight
origin cert for this independent connector.)
