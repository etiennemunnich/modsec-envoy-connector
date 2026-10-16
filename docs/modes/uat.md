# Early testing / UAT (0.1 alpha)

Short path for someone who clones the repo and needs to **install, exercise, and
sign off** before a `v0.1.0-alpha.*` tag. Not a production hardening guide.

Pins: Envoy **v1.39.4**, libmodsecurity **v3.0.17**, CRS **v4.30.0**
([`versions.lock.md`](../../versions.lock.md)). Status and release notes:
[`CHANGELOG.md`](../../CHANGELOG.md).

## Clone → install → smoke

Follow [Getting started](./getting-started.md) (pin-safe install scripts, not a
naked `brew install envoy modsecurity`).

```bash
git clone https://github.com/etiennemunnich/modsec-envoy-connector.git
cd modsec-envoy-connector
./demo/scripts/install-envoy.sh && export PATH=$HOME/.local/bin:$PATH
./demo/scripts/install-libmodsecurity.sh
./demo/scripts/install-crs.sh
./demo/scripts/up.sh
./demo/scripts/smoke.sh
./demo/scripts/fail-closed.sh
./demo/scripts/down.sh
```

| Step | Pass means |
|------|------------|
| `smoke.sh` | Benign **200**; SQLi/XSS URL + body **403**; response leak **403**; origin untouched on deny |
| `fail-closed.sh` | Kill → **500**; stall → **504** (N/A under `FULL_DUPLEX_STREAMED`); bad rules → **500**; origin untouched |
| Health | `curl -sf http://127.0.0.1:18082/healthz` and `…:18089/ready` succeed while up |

Optional deeper UAT (same demo stack):

```bash
./demo/scripts/fail-modes.sh                 # H1 + H2 failure matrix
./demo/scripts/install-go-ftw.sh && ./demo/scripts/go-ftw.sh smoke
./demo/scripts/hop-trace.sh
BODY_MODE=STREAMED ./demo/scripts/up.sh && ./demo/scripts/smoke.sh && ./demo/scripts/fail-closed.sh
```

Script table and ports: [`demo/README.md`](../../demo/README.md). Body modes:
[comparison](./README.md#mode-comparison). Decode status codes:
[Troubleshooting](./troubleshooting.md).

## UAT sign-off checklist

- [ ] Pin-safe install completed; `envoy --version` / libmodsecurity / CRS match `versions.lock.md`
- [ ] Default BUFFERED: `smoke.sh` and `fail-closed.sh` green
- [ ] At least one of: `fail-modes.sh`, `go-ftw.sh smoke`, or STREAMED smoke+fail-closed
- [ ] No `failure_mode_allow: true` on enforcement configs you tested
- [ ] Issues filed with pin versions, OS/arch, and suite output (not “it broke”)

## What alpha does **not** claim

- Production mesh hardening or SLA
- HTTP/3 or WebSocket-**frame** CRS (handshake hop-traces only)
- go-ftw green as “H2 WAF proven” (go-ftw is HTTP/1.x fidelity)
- BUFFERED_PARTIAL as full CRS body inspection

## After local UAT — cutting the alpha tag

Contributors: see [CONTRIBUTING — Releases](../../CONTRIBUTING.md#releases).
In short: land on `main` with **`ci-ok` green on both arches**, set
`PRODUCT_VERSION` in `versions.lock.md`, tag `v0.1.0-alpha.N` (crate version
stays `0.1.0`; the release workflow compares the `vX.Y.Z` prefix), mark the
GitHub Release as **pre-release**, and paste the CHANGELOG section.
