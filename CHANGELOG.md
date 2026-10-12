# Changelog

All notable changes to **modsec-envoy-connector** are recorded here.
Product tags are `vX.Y.Z` (optional pre-release suffix). Pin axes for each
release are quoted from [`versions.lock.md`](./versions.lock.md).

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- Envoy pin `v1.39.3` → `v1.39.4` (stable-candidate green on x86_64 + aarch64; see #20)

### Docs

- One page per topic under `docs/`: [getting started](./docs/getting-started.md),
  [deploy beside your own Envoy](./docs/deploy.md) (rules entry file, full
  Envoy config, body-mode table, `docker run` and tarball examples),
  [body modes](./docs/body-modes.md), [how it works](./docs/how-it-works.md),
  [fail-closed](./docs/fail-closed.md), [troubleshooting](./docs/troubleshooting.md)
  and [testing](./docs/testing.md). `docs/modes/` (the Docsify site) and
  `docs/ash.md` are removed; their content moved into those pages.
- Corrected claims: STREAMED and NONE behaviour, the FULL_DUPLEX_STREAMED hang
  (no `message_timeout`), full-CRS coverage (local go-ftw runs only), the
  vendored Envoy API version in `NOTICE` (v1.39.1).
- `versions.lock.md` records the connector commit and image digest of
  `v0.1.0-alpha.1`.

### CI and releases

- `ci` skips its heavy jobs only when that is sound: a docs-only change needs a
  green `ci` run on its base commit, and a merge to `main` skips only a tree
  that a pull request run from this repository passed.
- `pin-check` fails a pull request whose title, body or commits carry a
  workflow-skip token, and runs `shellcheck` over every tracked shell script.
- `check-workflows.sh` also requires pinned runners, a timeout on every job and
  a complete `ci-ok.needs`. Lab workflows never cancel a `main` run.
- The `release` gate requires a successful `ci` run for the tag commit and
  reads each required check from that run only. A manual dispatch builds and
  tests artifacts but publishes nothing.
- Release tarballs load their bundled `lib/libmodsecurity.so` without
  `LD_LIBRARY_PATH` (RUNPATH `$ORIGIN/../lib`).
- Dependabot also watches `tools/protogen`, `.github/actions/*` and
  `demo/grpc-echo`.

### Demo and install scripts

- Installers accept only the versions in `versions.lock.md` (libmodsecurity,
  CRS, Envoy on macOS, go-ftw 2.6.0) and fail on any other.
- Scripts find a `~/.local` libmodsecurity themselves; `up.sh` starts BUFFERED
  unless `BODY_MODE` is set; `hop-trace.sh` defaults to `/`; `DEMO_PORT_BASE`
  moves every port.
- Suites print SKIP for cells that do not apply to the body mode (never PASS)
  and must reach a minimum PASS count.
- `demo/grpc-echo` uses `golang.org/x/net` v0.60.0.
- Removed unused lab scripts and the `versions.window.md` snapshot.

### Known issues

Open on `main` and in `v0.1.0-alpha.1`; details in
[deploy.md](./docs/deploy.md#known-issues).

- With trailer mode `SKIP`, a body followed by trailers is not inspected.
  Use `SEND`.
- A gRPC message over 4 MiB, or a stream read error, ends the stream without
  failing closed.
- BUFFERED_PARTIAL over the limit and NONE with a request body run the
  request-body rules only after the origin answered.
- FULL_DUPLEX_STREAMED buffers the whole body with no size limit.
- No `TCP_NODELAY` on the gRPC listener (about 40 ms per request).

## [v0.1.0-alpha.1] — 2026-10-12

First **alpha** for early testing / UAT. Not a production release.

**Pins:** Envoy `v1.39.3`, libmodsecurity `v3.0.17`, CRS `v4.30.0`
(see `versions.lock.md` at this tag).

### Added

- Envoy `ext_proc` gRPC connector running libmodsecurity in process, with
  OWASP CRS; fail-closed on connector loss, hang (outside
  FULL_DUPLEX_STREAMED), gRPC error, rules load failure and per-request
  engine errors.
- Body modes BUFFERED, STREAMED and FULL_DUPLEX_STREAMED tested on every pull
  request on x86_64 and aarch64. NONE and BUFFERED_PARTIAL are lab modes,
  not tested on pull requests.
- Linux tarballs (x86_64, aarch64) and a multi-arch image on GHCR.
- Early-tester / UAT path: [`docs/modes/uat.md`](https://github.com/etiennemunnich/modsec-envoy-connector/blob/v0.1.0-alpha.1/docs/modes/uat.md)
- This changelog as the release-notes source for GitHub Releases

### Changed

- Docs and demo entry points aligned for 0.1 alpha early testing
- Consumer-facing product name consistency (`modsec-envoy-connector`)

### Known limitations

- HTTP/1.x CRS fidelity only (go-ftw); HTTP/2 is tested by the connector's
  own suites, HTTP/3 and WebSocket frames are not inspected.
- The tarball binary needs `LD_LIBRARY_PATH` pointing at its `lib/`.
- The defects listed under Known issues in [Unreleased] apply.

**Install / prove:** [Getting started](https://github.com/etiennemunnich/modsec-envoy-connector/blob/v0.1.0-alpha.1/docs/modes/getting-started.md) →
[UAT checklist](https://github.com/etiennemunnich/modsec-envoy-connector/blob/v0.1.0-alpha.1/docs/modes/uat.md). Local: `up.sh` → `smoke.sh` →
`fail-closed.sh`. Hosted: `ci-ok` on both arches for the tag commit on `main`.

[Unreleased]: https://github.com/etiennemunnich/modsec-envoy-connector/compare/v0.1.0-alpha.1...HEAD
[v0.1.0-alpha.1]: https://github.com/etiennemunnich/modsec-envoy-connector/releases/tag/v0.1.0-alpha.1
