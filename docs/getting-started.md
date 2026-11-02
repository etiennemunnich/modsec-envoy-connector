# Getting started

Run Envoy, the connector, libmodsecurity with OWASP CRS, and a small origin on one host; check that attacks are blocked and that failures fail closed; then tear it down. Every block below is meant to be copied as is, from the repository root.

Versions come from [`versions.lock.md`](../versions.lock.md); the install scripts check them and stop on a mismatch.

## 1. Prerequisites

**macOS** (Apple silicon or Intel): Xcode Command Line Tools (`xcode-select --install`), [Homebrew](https://brew.sh) and [rustup](https://rustup.rs). The install scripts run `brew install envoy modsecurity pkg-config` themselves, then stop if Homebrew's versions are not the pinned ones.

**Linux** (tested on Ubuntu 24.04; other Debian-based systems may work), with `sudo`: [rustup](https://rustup.rs), `git`, `curl`, `python3` and `lsof`. The libmodsecurity script installs build dependencies with `apt-get` and compiles libmodsecurity from source into `~/.local`, which takes a few minutes.

rustup picks the Rust version from `rust-toolchain.toml` on first build.

## 2. Install

```bash
git clone https://github.com/etiennemunnich/modsec-envoy-connector.git
cd modsec-envoy-connector
export PATH="$HOME/.local/bin:$PATH"          # Linux: Envoy and go-ftw are installed here
./demo/scripts/install-envoy.sh               # Linux: release binary, sha256-checked; macOS: Homebrew
./demo/scripts/install-libmodsecurity.sh      # Linux: source build into ~/.local; macOS: Homebrew
./demo/scripts/install-crs.sh                 # CRS into demo/.crs
```

The demo scripts find a libmodsecurity in `~/.local` on their own. For `cargo` outside them, `install-libmodsecurity.sh` prints the `PKG_CONFIG_PATH` and `LD_LIBRARY_PATH` to export.

## Elect one hop

This project keeps **two** early-testing options. Pick **one** ModSec hop per Envoy filter chain — do not run both on the same chain.

| Pick | How you start the demo | Smoke | Fail-closed drill |
|------|------------------------|-------|-------------------|
| **ext_proc** (default) | `./demo/scripts/up.sh` | `./demo/scripts/smoke.sh` | `./demo/scripts/fail-closed.sh` — absolute model ([fail-closed.md](./fail-closed.md)) |
| **dynamic module** | `DEPLOY=dm ./demo/scripts/up.sh` | `DEPLOY=dm ./demo/scripts/smoke-dm.sh` | `DEPLOY=dm ./demo/scripts/fail-closed-dm.sh` — weaker / different model ([fail-closed-dm.md](./fail-closed-dm.md)) |

Both paths use the same install steps and the same pinned Envoy / libmodsecurity / CRS from [`versions.lock.md`](../versions.lock.md). The module path builds `libmodsec_dm.so` against `DYNAMIC_MODULES_SDK_REV` (= `ENVOY_PIN`); rebuild or re-pull the `.so` whenever Envoy moves.

Use the **matching** fail-closed script for the hop you elected. `fail-closed.sh` is not DM proof; `fail-closed-dm.sh` is not the ext_proc absolute gate.

## 3. Start the demo

**ext_proc**

```bash
./demo/scripts/up.sh
```

**dynamic module**

```bash
DEPLOY=dm ./demo/scripts/up.sh
```

`up.sh` writes the ModSecurity rules file under `demo/.run/`, builds the elected hop, and starts the origin and Envoy in the background (plus the connector sidecar on the ext_proc path). It first stops a demo it started earlier, then refuses to start if another process holds one of its ports.

| Port | Process |
|------|---------|
| 18080 | Envoy, application traffic |
| 18081 | connector gRPC (ext_proc only) |
| 18082 | connector `/metrics` and `/healthz` (ext_proc only) |
| 18089 | Envoy admin (`/ready`) |
| 18098 | demo origin |

`DEMO_PORT_BASE=18380 ./demo/scripts/up.sh` moves every port by the same offset (Envoy on the base, the connector on base + 1, metrics + 2, Envoy admin + 9, origin + 18); use the same `DEMO_PORT_BASE` for the scripts below and change the URLs to match. Under DM there is no connector gRPC sidecar on 18081 / 18082; Envoy loads the module via `ENVOY_DYNAMIC_MODULES_SEARCH_PATH` and still serves application traffic on 18080 (or your base).

By hand (ext_proc demo):

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18080/                                           # 200
curl -s -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:18080/search?q=1'%20UNION%20SELECT%201,2--"    # 403
curl -s -o /dev/null -w '%{http_code}\n' -X POST --data 'comment=<script>alert(1)</script>' http://127.0.0.1:18080/comment   # 403
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18080/leak                                       # 403, response-body rule
curl -sf http://127.0.0.1:18082/healthz && echo connector ready
curl -s http://127.0.0.1:18082/metrics | grep -E '^ext_proc_(requests|allow|deny|fail_closed)_total'
```

## 4. Run the checks

Keep `DEPLOY=dm` for the DM checks (the scripts refuse the wrong hop).

**ext_proc**

```bash
./demo/scripts/smoke.sh
./demo/scripts/fail-closed.sh
```

**dynamic module**

```bash
DEPLOY=dm ./demo/scripts/smoke-dm.sh
DEPLOY=dm ./demo/scripts/fail-closed-dm.sh
```

| Script | Passes when |
|--------|-------------|
| `smoke.sh` | benign GET, form and JSON get **200** and reach the origin; SQLi, XSS and path traversal in the URL or body get **403** and never reach the origin (BUFFERED); response-body rule **403**; CONNECT **403** |
| `fail-closed.sh` | connector killed → **500**; connector frozen → **504** after 2 s; broken rules → **500**; origin untouched during failures; traffic **200** again after restore |
| `smoke-dm.sh` | same class of benign / deny checks for `DEPLOY=dm`; STREAMED body denies keep origin-delta honesty (`0` or `1`); NONE documents body bypass |
| `fail-closed-dm.sh` | missing `.so` → Envoy does not leave origin OK as **200**; bad / zero rules at filter init → reject / no OK-to-origin; FULL_DUPLEX config rejected; baseline allow after restore. Does **not** claim kill-sidecar **500** or hang→**504** via `message_timeout` |

Each ends with `PASSED` and a count; any `FAIL` line means it did not pass. Logs: `demo/.run/{envoy,connector,origin}.log` and the ModSecurity audit log `demo/.run/modsec-audit.log`.

Optional DM footgun drill (local): `DEPLOY=dm ./demo/scripts/fail-closed-dm-negctl.sh` shows why enforcement configs must **forbid** `module.remote` (remote fetch fail can omit the filter → unfiltered traffic).

### Protocols (H1 / H2 / lab H3)

Product-facing checks for the elected hop:

```bash
# HTTP/1.1 + HTTP/2 failure classes (ext_proc demo)
./demo/scripts/fail-modes.sh

# Hop trace example (ext_proc)
./demo/scripts/hop-trace.sh --expect-status 403 --expect-origin no '/search?q=1%27%20UNION%20SELECT%201--'

./demo/scripts/h2-trailers.sh                 # HTTP/2 bodies and queries that end in trailers
./demo/scripts/install-go-ftw.sh              # go-ftw, the CRS regression runner, into ~/.local/bin
./demo/scripts/go-ftw.sh smoke                # CRS regression tests, HTTP/1.x only
```

**Lab HTTP/3** is optional and **lab only** — not a product HTTP/3 WAF claim. Needs `pip install aioquic`:

```bash
BODY_MODE=NONE ./demo/scripts/up.sh   # or let the H3 helpers bring NONE up
./demo/scripts/h3-probe.sh            # QUIC lab hop + Cookie; demo-only
./demo/scripts/cookie-protocols.sh    # H1 + H2 + lab H3 Cookie / crumb checks
./demo/scripts/fail-modes.sh --class cookie   # H1+H2 Cookie class only
```

go-ftw remains **HTTP/1.x CRS fidelity** only. Do not read a green go-ftw run as HTTP/2 or HTTP/3 WAF proof.

What each test proves: [testing.md](./testing.md).

## 5. Other body modes

`up.sh` starts BUFFERED unless `BODY_MODE` is set. It saves the mode in `demo/.run/body_mode`, and the other scripts use the saved mode, so you do not repeat it:

```bash
BODY_MODE=STREAMED ./demo/scripts/up.sh && ./demo/scripts/smoke.sh && ./demo/scripts/fail-closed.sh
BODY_MODE=FULL_DUPLEX_STREAMED ./demo/scripts/up.sh && ./demo/scripts/smoke.sh && ./demo/scripts/fail-closed.sh
```

Under FULL_DUPLEX_STREAMED the frozen-connector check is reported as `SKIP`: Envoy does not apply `message_timeout` in that mode. **DM rejects FULL_DUPLEX** at config time — use BUFFERED or STREAMED (or NONE / partial lab modes) on the module path. NONE and BUFFERED_PARTIAL are limited modes: [body-modes.md](./body-modes.md). `DEMO_CRS=0 ./demo/scripts/up.sh` runs without CRS.

## 6. Stop

```bash
./demo/scripts/down.sh
```

Tear down with `./demo/scripts/down.sh` either way. Logs and generated rules stay in `demo/.run/` until you delete it.

## Early-tester checklist (beta dual option)

For early testers on the dual-option beta line (current tag `v0.1.0-beta.1`; pins and digests in [`versions.lock.md`](../versions.lock.md)):

- [ ] `envoy --version`, `pkg-config --modversion modsecurity` (Linux: `PKG_CONFIG_PATH=$HOME/.local/lib/pkgconfig`) and `git -C demo/.crs describe --tags` match `versions.lock.md`
- [ ] You elected **one** hop and did not stack both ModSec filters
- [ ] **ext_proc:** BUFFERED `smoke.sh` + `fail-closed.sh` pass
- [ ] **and/or DM:** `DEPLOY=dm` BUFFERED `smoke-dm.sh` + `fail-closed-dm.sh` pass (if you are exercising the module)
- [ ] at least one of: `fail-modes.sh` (H1+H2), go-ftw smoke (H1 CRS only), or STREAMED smoke + the matching fail-closed script
- [ ] beside your own Envoy ([deploy.md](./deploy.md)): benign **200**, SQLi **403**, and the fail behaviour that matches your hop (ext_proc: connector stopped → **500**, origin untouched; DM: see [fail-closed-dm.md](./fail-closed-dm.md))
- [ ] no `failure_mode_allow: true` on ext_proc enforcement; no `module.remote` on DM enforcement
- [ ] results filed with the [bug template](https://github.com/etiennemunnich/modsec-envoy-connector/issues/new?template=bug.md): versions, OS/arch, elected hop, script output

This release line is **early testing**. It does not claim product HTTP/3 WAF support (lab `h3-probe.sh` / Cookie H3 only), WebSocket-frame inspection, HTTP/2 coverage from go-ftw, full CRS under BUFFERED_PARTIAL or NONE, or fail-closed absolute for the dynamic module. Envoy may normalize some headers before ModSecurity sees them: [crs-and-envoy-limits.md](./crs-and-envoy-limits.md). Open issues: [`CHANGELOG.md`](../CHANGELOG.md).
