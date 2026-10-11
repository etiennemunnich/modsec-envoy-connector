## Summary

<!-- What this PR changes and why. One concern per PR when possible. -->

## Test plan

- [ ] Fail-closed preserved (`failure_mode_allow: false` on enforcement; no `Continue` after ModSec/FFI Err)
- [ ] Pins reviewed (`versions.lock.md` — Envoy / ModSec / CRS / connector) or deliberately bumped here
- [ ] Local: `cargo fmt` / `clippy -D warnings` / `cargo test --workspace --locked` **or** docs-only (noted)
- [ ] Workflows / CI scripts touched → `./scripts/check-workflows.sh` / `./scripts/test-ci-scripts.sh`
- [ ] Live suites if behavior / demo / fail-mode changed — note Mac path or Actions URL (`event`, `conclusion`, `headSha`)
- [ ] **`ci-ok` green on both arches** for this PR head before squash-merge
- [ ] README stays product-only; agent/CI detail in `AGENTS.md` / `CONTRIBUTING.md` / `docs/`
- [ ] User-facing or release-facing doc change → `CHANGELOG.md` `[Unreleased]` updated when substantive

## Merge

Squash-merge only after the checklist above. Do not push straight to `main`.
