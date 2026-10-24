# Changelog

All notable changes to **modsec-envoy-connector** are recorded here.
Product tags are `vX.Y.Z` (optional pre-release suffix). Pin axes for each
release are quoted from [`versions.lock.md`](./versions.lock.md).

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- **Alpha DM in release artifacts:** `release.yml` builds `libmodsec_dm.so` (SDK @ `ENVOY_PIN`) into `ext-proc-modsec-<ver>-linux-<arch>.tar.gz` `lib/` and the GHCR image `/usr/local/lib/` (ENTRYPOINT remains ext_proc). RUNPATH `$ORIGIN` so the module finds sibling `libmodsecurity`. Operator load path: [Deploy — Alpha dynamic module from release artifacts](./docs/deploy.md#alpha-dynamic-module-from-release-artifacts). Early testing only; not fail-closed absolute; no separate GHCR module package. **Not** published in `v0.1.0-alpha.3` (build from tip `main` until the next tag).

### Fixed

- Docs honesty: README / deploy / lock D-row no longer claim `v0.1.0-alpha.3` ships `libmodsec_dm.so` or still list the alpha.2 OCI digest.

## [v0.1.0-alpha.3] — 2026-10-22

Early-test pre-release. Pins unchanged from `v0.1.0-alpha.2`: Envoy `v1.39.4`,
libmodsecurity `v3.0.17`, CRS `v4.30.0` (see [`versions.lock.md`](./versions.lock.md)).
No dynamic-modules product path in this cut (store-only research; not shipped).

### Added

- Demo **lab HTTP/3 suite** (not product support, not PR CI): [`demo/envoy/envoy-h3.yaml`](./demo/envoy/envoy-h3.yaml) +
  [`h3-probe.sh`](./demo/scripts/h3-probe.sh) / [`h3-lib.sh`](./demo/scripts/h3-lib.sh) / [`h3get.py`](./demo/scripts/h3get.py).
  PASS floor ≥ 14 (hop/fail-closed + Cookie crumbs). Demo-only.
- Demo **Cookie protocols** suite: [`cookie-protocols.sh`](./demo/scripts/cookie-protocols.sh) locks multi-`Cookie`
  / crumb CRS on H1 + H2 + lab H3 (≥13 PASS). `fail-modes.sh --class cookie` expanded (1st crumb + joined XSS).
- Docs: [CRS and Envoy limits](./docs/crs-and-envoy-limits.md) — operator guide to what Envoy
  forwards to ModSecurity (and how to aim custom SecRules), linked from the README and
  [how-it-works](./docs/how-it-works.md) “What is not inspected.”

### Docs

- Soften [CRS and Envoy limits](./docs/crs-and-envoy-limits.md): operator framing around what Envoy forwards / ModSec sees; drop “security weaker than nginx” headlines; probe status codes as illustrative only; nginx comparisons demoted to a short appendix. Matching one-liners in README, getting-started, how-it-works, and deploy.
- Alpha security reports go through **GitHub Issues** ([SECURITY.md](./SECURITY.md)); no private-advisory requirement or SLA while early-testing. Issue chooser contact link matches that (no “report privately / never in a public issue” wording).
- Supported container install is **GHCR** (`ghcr.io/…/modsec-envoy-connector:<tag>`, pin by digest in `versions.lock.md`); tarball and source remain alternatives. Local `packaging/Dockerfile` build is advanced/dev only. Images publish on release tags only (no PR/`latest` churn); stale cleanup via `scripts/ghcr-delete-stale.sh`.
- Deploy: GHCR auth is tied to **package** visibility (may stay private after the GitHub repo is public); Release tarballs on a public repo download without login.
- Agent standards: drop stale “repository is private on GitHub Pro” minutes language; keep CI discipline for a public repo.
- Docs scrub: no local machine / Agent Store / `file://` paths in shipped docs (ripgrep clean). Soften `install-crs.sh` “before production use” comment to early-testing honesty; AGENTS Never bans battle-tested / production-ready / enterprise-grade hype.

### Changed

- Dependabot: `tokio` 1.53.2 → 1.53.3 (#24); demo `golang.org/x/net` 0.60.0 → 0.61.0 (#23).
- Crate version `0.1.0-alpha.3` (product tag `v0.1.0-alpha.3`).

## [v0.1.0-alpha.2] — 2026-10-17

Early-test pre-release. Envoy pin is `v1.39.4` (was `v1.39.3` at `v0.1.0-alpha.1`); libmodsecurity and CRS pins are unchanged.

### Security

- **Fail-open on unreadable ext_proc messages (affects v0.1.0-alpha.1).**
  When the connector could not read an inbound message, for example a
  BUFFERED body larger than tonic's 4 MiB decode limit, it ended the stream
  with gRPC **OK**. Envoy treats an OK close as "processing done" and
  forwarded the request to origin uninspected, so a large SQLi body reached
  origin. A read error now aborts the stream with `INTERNAL`, and Envoy
  answers **500**. If Envoy half-closes while a FULL_DUPLEX body is still
  held unanswered, the stream also aborts instead of ending OK.
- **Bodies that end in trailers skipped inspection (affects v0.1.0-alpha.1).**
  With trailer mode `SKIP`, Envoy sends a body that trailers follow with
  `end_of_stream=false` and never sends the trailers; with HEADERS then
  trailers and no DATA it sends no body message at all. The connector waited
  for `end_of_stream`, so request phase 2 never ran and an HTTP/2 SQLi body
  or query reached origin (BUFFERED, STREAMED, BUFFERED_PARTIAL; NONE for the
  query). The connector now takes each direction's body mode from
  `protocol_config` (a stream without it fails closed), ends the body phase
  per mode (any body message for BUFFERED / BUFFERED_PARTIAL, the headers for
  NONE, `end_of_stream` or trailers for STREAMED / FULL_DUPLEX), and answers
  **500** when response headers arrive before the request body phase ran.
  Shipped configs with a body mode now set trailer modes `SEND`.

### Fixed

- FULL_DUPLEX: a request or response with headers and trailers but no body
  gets only a trailers answer. Before, an empty `StreamedBodyResponse` was
  sent, which Envoy rejects as spurious (500).
- Rules files that load but define **0** rules make the connector refuse to
  start. An empty ruleset would have allowed every request.
- `/healthz` probes no longer count in `ext_proc_*` metrics and log their
  phases at DEBUG instead of INFO.
- Header values reach ModSecurity as the raw bytes Envoy forwards. A lossy
  UTF-8 conversion turned non-UTF-8 bytes into U+FFFD, so a rule matching
  such a byte could not fire while the origin received it.
- A read error or idle stream after the final verdict ends the stream OK
  instead of counting as a stream error; before the verdict it still aborts.

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
- `--stream-idle-timeout` (300 s), `--duplex-idle-timeout` (30 s) and
  `--duplex-total-timeout` (300 s): Envoy silent before the verdict, or a
  FULL_DUPLEX stream past its deadlines → ImmediateResponse **504**.
- `--max-concurrent-streams` (1024), `--http2-keepalive-interval` (30 s),
  `--http2-keepalive-timeout` (10 s) on the gRPC server.
- `/healthz` reports `engine_mode=` and `rules=`, and answers **503** unless
  the rules leave `SecRuleEngine On`; `--allow-detection-only` opts out.
- Live suite `demo/scripts/h2-trailers.sh` (HTTP/2 body and trailers-only
  cells asserting origin hits) in `e2e-pin`, `e2e-streamed` and
  `e2e-full-duplex`.

### Changed

- Envoy pin `v1.39.3` → `v1.39.4` (stable-candidate green on x86_64 + aarch64; see #20)
- ModSecurity's logging phase (audit-log write on session drop) runs on the
  blocking pool, so a deny reply does not wait for the audit log.
- The gRPC listener sets `TCP_NODELAY`.
- The encode limit is the message limit plus 64 KiB of envelope room.
- Both crates declare `repository` and `readme` metadata.
- `--body-reply` is a consistency check against `protocol_config`; a stream
  that disagrees fails closed.
- The ModSecurity transaction id is generated by the connector instead of
  taken from the client-supplied `x-request-id` (still logged).
- The WARN intervention line carries only the rule id and a truncated msg;
  the full ModSecurity log line is at DEBUG.
- The metrics listener backs off on accept errors.
- Neutral names: connector info `modsec-envoy-connector/<version>`, health
  probe path `/__ext_proc_healthz`, CRS test env `MODSEC_REQUIRE_CRS` /
  `MODSEC_CRS_DIR`, test markers `TEST-LEAK-MARKER` / `DEMO-LEAK-MARKER` /
  `x-demo-grpc-probe`.
- Crate version `0.1.0-alpha.2`.
- The demo origin writes each response in one segment. With `TCP_NODELAY` the
  connector answers STREAMED response headers before a separately written
  body reaches Envoy, so the phase-4 leak cells only reset the stream; the
  docs now state that STREAMED response limit.

### Docs

- One page per topic under `docs/`: [getting started](./docs/getting-started.md),
  [deploy beside your own Envoy](./docs/deploy.md) (rules entry file, full
  Envoy config, body-mode table, `docker run` and tarball examples),
  [body modes](./docs/body-modes.md), [how it works](./docs/how-it-works.md),
  [fail-closed](./docs/fail-closed.md), [troubleshooting](./docs/troubleshooting.md)
  and [testing](./docs/testing.md). `docs/modes/` (the Docsify site) and
  `docs/ash.md` are removed; their content moved into those pages.
- Corrected claims: STREAMED and NONE behaviour, FULL_DUPLEX_STREAMED timeouts
  (Envoy has no `message_timeout` there; the connector's duplex deadlines
  answer 504), full-CRS coverage (local go-ftw runs only), the vendored Envoy
  API version in `NOTICE` (v1.39.1).
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
- The `release` workflow requires the tag to equal `v` plus the crate version,
  pre-release suffix included (`v0.1.0-alpha.2` needs crate `0.1.0-alpha.2`).
- Release tarballs load their bundled `lib/libmodsecurity.so` without
  `LD_LIBRARY_PATH` (RUNPATH `$ORIGIN/../lib`).
- Dependabot also watches `tools/protogen`, `.github/actions/*` and
  `demo/grpc-echo`.

### Demo and install scripts

- Installers accept only the versions in `versions.lock.md` (libmodsecurity,
  CRS, Envoy on macOS, go-ftw 2.6.0) and fail on any other.
- Scripts find a `~/.local` libmodsecurity themselves; `up.sh` starts BUFFERED
  unless `BODY_MODE` is set; `hop-trace.sh` defaults to `/`; `DEMO_PORT_BASE`
  moves every port, including `down.sh` and the bad-rules drills in
  `fail-closed.sh` / `fail-modes.sh`.
- Suites print SKIP for cells that do not apply to the body mode (never PASS)
  and must reach a minimum PASS count.
- `demo/grpc-echo` uses `golang.org/x/net` v0.60.0.
- Removed unused lab scripts and the `versions.window.md` snapshot.

### Known issues

Still open after this release; details in
[deploy.md](./docs/deploy.md#known-issues).

- STREAMED response bodies: Envoy forwards the response headers as soon as
  the connector answers them, so a phase-4 deny on a later body chunk resets
  the client stream instead of answering 403. The origin's bytes already sent
  are not recalled. Use BUFFERED for the response when phase-4 blocking must
  answer 403.
- Trailer values are never passed to ModSecurity; trailers only end the body
  phase. Trailer mode `SKIP` is not fail-closed: Envoy forwards the request
  to origin before the body phase finishes. Body-mode configs must set
  trailer modes `SEND` (shipped configs already do). The `none`, `grpc` and
  `ws-headers` configs keep `SKIP`.
- BUFFERED_PARTIAL inspects only the body prefix up to Envoy's buffer limit;
  it is not CRS-complete body inspection. NONE never sends bodies.
- HTTP/3 and WebSocket frames are not inspected.
- `v0.1.0-alpha.1` has both Security defects listed above. Do not use it.

## [v0.1.0-alpha.1] — 2026-10-12

First **alpha** for early testing / UAT. Not a production release.

**Do not use:** this release fails open on an unreadable ext_proc message
(a body over 4 MiB reaches origin uninspected) and skips inspection of bodies
that end in trailers. Both are fixed in `v0.1.0-alpha.2`; see its Security
section.

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
- The Security defects fixed in `v0.1.0-alpha.2` apply.

**Install / prove:** [Getting started](https://github.com/etiennemunnich/modsec-envoy-connector/blob/v0.1.0-alpha.1/docs/modes/getting-started.md) →
[UAT checklist](https://github.com/etiennemunnich/modsec-envoy-connector/blob/v0.1.0-alpha.1/docs/modes/uat.md). Local: `up.sh` → `smoke.sh` →
`fail-closed.sh`. Hosted: `ci-ok` on both arches for the tag commit on `main`.

[Unreleased]: https://github.com/etiennemunnich/modsec-envoy-connector/compare/v0.1.0-alpha.3...HEAD
[v0.1.0-alpha.3]: https://github.com/etiennemunnich/modsec-envoy-connector/compare/v0.1.0-alpha.2...v0.1.0-alpha.3
[v0.1.0-alpha.2]: https://github.com/etiennemunnich/modsec-envoy-connector/compare/v0.1.0-alpha.1...v0.1.0-alpha.2
[v0.1.0-alpha.1]: https://github.com/etiennemunnich/modsec-envoy-connector/releases/tag/v0.1.0-alpha.1
