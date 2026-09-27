# Agent standards — envoy-modsec-connex

Mandatory for coding agents working in this repo. Keep it short; deep tables live in `docs/` and the experiment lab.

## Product

- **Shape:** Rust Envoy `ext_proc` gRPC sidecar → FFI → **libmodsecurity** (+ optional OWASP CRS). Not Coraza-as-product; not a Rust Envoy dynamic module.
- **Fail-closed is absolute** — connector down, gRPC error, panic/abort, hang/timeout, ModSec init/rules fail, ExtProc unreachable, or per-request ModSec `Err` → traffic must **not** reach origin as OK. Body mode (BUFFERED/STREAMED) does **not** relax this.
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
- Claim **HTTP/3** or **WebSocket-frame** CRS without a proven QUIC / frame inspector path.
- Return **`Continue`** after ModSec / FFI `Err` (that is connector-lie fail-open → map to ImmediateResponse **500**).
- Invent Envoy / ModSec / CRS tip flags or pins not in `versions.lock.md`.
- Market go-ftw green as “H2 WAF proven” (go-ftw is **HTTP/1.x CRS fidelity** only).

## Testing expectations

| Gate | Where | What |
|------|-------|------|
| **Push / PR** | GitHub Actions `ci`, x86_64 + aarch64 | `pin-check` + `rust-quality`; on `main` also `e2e-pin` (live smoke, fail-closed, fail-modes H1+H2, hop-trace, go-ftw smoke) |
| **Stable versions** | `release-watch` (daily) → `stable-candidate`; `stable-window` (weekly); `crs-full` (monthly) | new / last-3 stables per axis, both arches; results as issues (see `docs/testing.md`) |
| **Live demo** | Mac / Linux host | `demo/scripts/`: `smoke.sh`, `fail-closed.sh`, `fail-modes.sh` (H1 + H2), `go-ftw.sh`, `hop-trace.sh`; `scripts/ci-live-e2e.sh` runs a CI cell locally |
| **CRS** | go-ftw | **H1** rule fidelity only |
| **Fail-closed** | `demo/scripts/fail-closed.sh` | absolute gate: kill → 500, hang → 504, bad rules → 500, origin untouched |

GitHub-hosted runners only — never add a self-hosted or Mac runner. Do not claim Mac-only proofs from cloud CI.

## Docs

On **substantive** architecture / fail-mode / protocol / CI / pin changes: update **`README.md`** (and product how-it-works when this repo owns it). Prefer honesty over completeness theater.

## License

Apache-2.0 — `Copyright (c) 2026 Etienne Munnich`. See `LICENSE` and `CONTRIBUTING.md` (DCO; no CLA).

## Git

After a **validated** moderate slice: `git commit` + `git push` on the working tip branch. No force-push to shared branches unless Etienne asks. No secrets in commits.

## Crate layout

- `crates/ext-proc-modsec` — tonic ExternalProcessor binary (product name).
- `crates/modsec-engine` — safe façade over libmodsecurity; own `msc_*` FFI (`src/ffi.rs`); keep `unsafe` / FFI here only.
- `proto/` → `crates/ext-proc-modsec/src/pb/` — vendored Envoy ext_proc proto closure and its committed generated code; never hand-edit `pb/`, rerun `scripts/gen-protos.sh`.
- No new crates without a reason in the commit; the runtime set is tokio, tokio-stream, tonic (server + codegen), prost, tonic-prost, tracing.

Live demo + suites: `demo/scripts/` (`up.sh`, `smoke.sh`, `fail-closed.sh`, `fail-modes.sh`, `go-ftw.sh`, `hop-trace.sh`); go-ftw config and measured Envoy overrides in `demo/ftw/`. Version probes: `scripts/probe-modsec-pin.sh`, `scripts/envoy-candidate-smoke.sh`, `scripts/crs-version-probe.sh`. Anything else from `modsec-envoy-experiement` (perf harness, WebSocket / gRPC hop tracing) — port deliberately; do not dump experiment history wholesale.
