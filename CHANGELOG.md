# Changelog

All notable changes to **modsec-envoy-connector** are recorded here.
Product tags are `vX.Y.Z` (optional pre-release suffix). Pin axes for each
release are quoted from [`versions.lock.md`](./versions.lock.md).

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- Envoy pin `v1.39.3` → `v1.39.4` (stable-candidate green on x86_64 + aarch64; see #20)

## [v0.1.0-alpha.1] — 2026-10-12

First **alpha** for early testing / UAT. Not a production release.

**Pins:** Envoy `v1.39.3`, libmodsecurity `v3.0.17`, CRS `v4.30.0`
(see `versions.lock.md` at this tag).

### Added

- Early-tester / UAT path: [`docs/modes/uat.md`](./docs/modes/uat.md)
- This changelog as the release-notes source for GitHub Releases

### Changed

- Docs and demo entry points aligned for 0.1 alpha early testing
- Consumer-facing product name consistency (`modsec-envoy-connector`)

**Install / prove:** [Getting started](./docs/modes/getting-started.md) →
[UAT checklist](./docs/modes/uat.md). Local: `up.sh` → `smoke.sh` →
`fail-closed.sh`. Hosted: `ci-ok` on both arches for the tag commit on `main`.

[Unreleased]: https://github.com/etiennemunnich/modsec-envoy-connector/compare/v0.1.0-alpha.1...HEAD
[v0.1.0-alpha.1]: https://github.com/etiennemunnich/modsec-envoy-connector/releases/tag/v0.1.0-alpha.1
