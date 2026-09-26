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
| **PR thin** | GitHub Actions | `rust-quality` + `pin-check` (see `.github/workflows/ci.yml`) |
| **Mac / dispatch** | Lab or self-hosted | Full CRS go-ftw, fail-mode / fail-closed live proofs, H2 custom suite, version-matrix cells |
| **CRS** | go-ftw | **H1** rule fidelity — never full ~5k on free-tier PR |
| **Fail-mode / H2** | Custom scripts | `lab-fail-closed.sh` absolute; `lab-fail-modes.sh` + protocol delivery — not go-ftw |

Do not claim Mac-only proofs from cloud CI.

## Docs

On **substantive** architecture / fail-mode / protocol / CI / pin changes: update **`README.md`** (and product how-it-works when this repo owns it). Prefer honesty over completeness theater.

## License

Apache-2.0 — `Copyright (c) 2026 Etienne Munnich`. See `LICENSE` and `CONTRIBUTING.md` (DCO; no CLA).

## Git

After a **validated** moderate slice: `git commit` + `git push` on the working tip branch. No force-push to shared branches unless Etienne asks. No secrets in commits.

## Crate layout

- `crates/ext-proc-modsec` — tonic ExternalProcessor binary (product name).
- `crates/modsec-engine` — safe façade over libmodsecurity; keep `unsafe` / FFI here only.

Runnable lab history may still live in `modsec-envoy-experiement` until migrate completes — port product surface deliberately; do not dump experiment history wholesale.
