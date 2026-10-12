# Changelog

All notable changes to **modsec-envoy-connector** are recorded here.
Product tags are `vX.Y.Z` (optional pre-release suffix). Pin axes for each
release are quoted from [`versions.lock.md`](./versions.lock.md).

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Security

- **Fail-open on unreadable ext_proc messages (affects v0.1.0-alpha.1).**
  When the connector could not read an inbound message, for example a
  BUFFERED body larger than tonic's 4 MiB decode limit, it ended the stream
  with gRPC **OK**. Envoy treats an OK close as "processing done" and
  forwarded the request to origin uninspected, so a large SQLi body reached
  origin. A read error now aborts the stream with `INTERNAL`, and Envoy
  answers **500**. If Envoy half-closes while a FULL_DUPLEX body is still
  held unanswered, the stream also aborts instead of ending OK.

### Fixed

- FULL_DUPLEX: a request or response with headers and trailers but no body
  gets only a trailers answer. Before, an empty `StreamedBodyResponse` was
  sent, which Envoy rejects as spurious (500).
- Rules files that load but define **0** rules make the connector refuse to
  start. An empty ruleset would have allowed every request.
- `/healthz` probes no longer count in `ext_proc_*` metrics and log their
  phases at DEBUG instead of INFO.

### Added

- `--max-grpc-message-bytes` / `EXT_PROC_MAX_GRPC_MESSAGE_BYTES` (default
  4 MiB): the largest ext_proc message read. Larger → stream abort → 500.
- `--max-held-body-bytes` / `EXT_PROC_MAX_HELD_BODY_BYTES` (default = the
  message limit): the FULL_DUPLEX held-body cap per direction. Over the cap →
  ImmediateResponse 500, nothing released.
- gRPC tests for read errors and oversize messages, half-close with a held
  body, panic → reset, status-0 drop → abort, observability mode, response
  trailers, FULL_DUPLEX replies and the held cap, and probe isolation.
- CI `rust-quality` installs the pinned CRS and sets `MODSEC_REQUIRE_CRS=1`,
  so the engine CRS test fails instead of skipping when CRS is missing.

### Changed

- ModSecurity's logging phase (audit-log write on session drop) runs on the
  blocking pool, so a deny reply does not wait for the audit log.
- The gRPC listener sets `TCP_NODELAY`.
- The encode limit is the message limit plus 64 KiB of envelope room.
- `demo/scripts/down.sh` and the bad-rules drills in `fail-closed.sh` /
  `fail-modes.sh` honour `DEMO_PORT_BASE` instead of the stock ports.
- Both crates declare `repository` and `readme` metadata.

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
