# Contributing

Short guide for humans and agents. Standards for agents: **[AGENTS.md](./AGENTS.md)**. Pins: **[versions.lock.md](./versions.lock.md)**.

## Setup

1. Rust **1.88+** (MSRV in crate `Cargo.toml`; CI uses `stable`).
2. libmodsecurity **v3.0.16** discoverable via `pkg-config modsecurity` (`./demo/scripts/install-libmodsecurity.sh`: Homebrew on macOS, source build on Ubuntu).
3. For the live Envoy demo and fail-closed drills, follow [`demo/README.md`](./demo/README.md).

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
./scripts/check-pins.sh
```

## Pull requests

- Branch from `main` (or the documented tip). Prefer `cursor/<short-name>-…` for agent work.
- Keep PRs focused. Use the PR template checklist.
- Update `README.md` / `versions.lock.md` when behavior or pins change.
- Do not set `failure_mode_allow: true` on enforcement configs in the PR.

### PR checklist (summary)

- [ ] Fail-closed preserved (no enforcement fail-open; no `Continue` after ModSec Err)
- [ ] Pins in `versions.lock.md` still accurate (or bumped deliberately)
- [ ] `pin-check` + `rust-quality` green (or explained)
- [ ] Mac / dispatch proofs noted if the change needs them (CRS full, fail-mode, H2)

## Test matrix

| Layer | CI (PR) | Local / Mac |
|-------|---------|-------------|
| `pin-check` | **Yes** | `./scripts/check-pins.sh` |
| `rust-quality` (fmt, clippy, test, build) | **Yes** | same cargo commands |
| libmodsecurity-linked build + gRPC integration tests | **Yes** (source-built v3.0.16, cached) | `cargo test --workspace` |
| go-ftw CRS (H1) | **No** full suite on free-tier PR | Mac lab / dispatch |
| Fail-closed / live demo | **No** live drills on PR | `demo/scripts/smoke.sh` / `demo/scripts/fail-closed.sh` |
| H2 protocol delivery | **No** | Custom lab scripts |
| Version-matrix cells | Dispatch / self-hosted when present | Mac |

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
