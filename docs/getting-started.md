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

## 3. Start the demo

```bash
./demo/scripts/up.sh
```

`up.sh` writes the ModSecurity rules file under `demo/.run/`, builds the connector, and starts the origin, the connector and Envoy in the background. It first stops a demo it started earlier, then refuses to start if another process holds one of its ports.

| Port | Process |
|------|---------|
| 18080 | Envoy, application traffic |
| 18081 | connector gRPC |
| 18082 | connector `/metrics` and `/healthz` |
| 18089 | Envoy admin (`/ready`) |
| 18098 | demo origin |

`DEMO_PORT_BASE=18380 ./demo/scripts/up.sh` moves every port by the same offset (Envoy on the base, the connector on base + 1, metrics + 2, Envoy admin + 9, origin + 18); use the same `DEMO_PORT_BASE` for the scripts below and change the URLs to match.

By hand:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18080/                                           # 200
curl -s -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:18080/search?q=1'%20UNION%20SELECT%201,2--"    # 403
curl -s -o /dev/null -w '%{http_code}\n' -X POST --data 'comment=<script>alert(1)</script>' http://127.0.0.1:18080/comment   # 403
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18080/leak                                       # 403, response-body rule
curl -sf http://127.0.0.1:18082/healthz && echo connector ready
curl -s http://127.0.0.1:18082/metrics | grep -E '^ext_proc_(requests|allow|deny|fail_closed)_total'
```

## 4. Run the checks

```bash
./demo/scripts/smoke.sh
./demo/scripts/fail-closed.sh
```

| Script | Passes when |
|--------|-------------|
| `smoke.sh` | benign GET, form and JSON requests get **200** and reach the origin; SQLi, XSS and path traversal in the URL or the body get **403** and never reach the origin; the response-body rule gets **403**; CONNECT gets **403** |
| `fail-closed.sh` | connector killed → **500**; connector frozen → **504** after 2 s; connector restarted with broken rules → **500**; the origin receives nothing during any failure, and traffic is **200** again after restore |

Each ends with `PASSED` and a count; any `FAIL` line means it did not pass. Logs: `demo/.run/{envoy,connector,origin}.log` and the ModSecurity audit log `demo/.run/modsec-audit.log`.

More checks against the same running demo:

```bash
./demo/scripts/fail-modes.sh                  # every failure class over HTTP/1.1 and HTTP/2
./demo/scripts/h2-trailers.sh                 # HTTP/2 bodies and queries that end in trailers
./demo/scripts/install-go-ftw.sh              # go-ftw, the CRS regression runner, into ~/.local/bin
./demo/scripts/go-ftw.sh smoke                # CRS regression tests, HTTP/1.x only
./demo/scripts/hop-trace.sh --expect-status 403 --expect-origin no '/search?q=1%27%20UNION%20SELECT%201--'
```

What each test proves: [testing.md](./testing.md).

## 5. Other body modes

`up.sh` starts BUFFERED unless `BODY_MODE` is set. It saves the mode in `demo/.run/body_mode`, and the other scripts use the saved mode, so you do not repeat it:

```bash
BODY_MODE=STREAMED ./demo/scripts/up.sh && ./demo/scripts/smoke.sh && ./demo/scripts/fail-closed.sh
BODY_MODE=FULL_DUPLEX_STREAMED ./demo/scripts/up.sh && ./demo/scripts/smoke.sh && ./demo/scripts/fail-closed.sh
```

Under FULL_DUPLEX_STREAMED the frozen-connector check is reported as `SKIP`: Envoy does not apply `message_timeout` in that mode. NONE and BUFFERED_PARTIAL are limited modes: [body-modes.md](./body-modes.md). `DEMO_CRS=0 ./demo/scripts/up.sh` runs without CRS.

Optional **lab HTTP/3** (not product support; needs `pip install aioquic`):

```bash
BODY_MODE=NONE ./demo/scripts/up.sh   # or let h3-probe start NONE for you
./demo/scripts/h3-probe.sh            # QUIC :18443; ≥9 PASS; demo-only, not PR CI
```

## 6. Stop

```bash
./demo/scripts/down.sh
```

Logs and generated rules stay in `demo/.run/` until you delete it.

## Early-tester checklist

For alpha testers:

- [ ] `envoy --version`, `pkg-config --modversion modsecurity` (on Linux with `PKG_CONFIG_PATH=$HOME/.local/lib/pkgconfig`) and `git -C demo/.crs describe --tags` match `versions.lock.md` (the install scripts check this)
- [ ] BUFFERED: `smoke.sh` and `fail-closed.sh` pass
- [ ] at least one of: `fail-modes.sh`, `go-ftw.sh smoke`, or STREAMED `smoke.sh` + `fail-closed.sh`
- [ ] beside your own Envoy ([deploy.md](./deploy.md)): a benign request **200**, a SQLi **403**, connector stopped → **500**, and the origin saw nothing
- [ ] no `failure_mode_allow: true` in any config you tested
- [ ] results filed with the [bug template](https://github.com/etiennemunnich/modsec-envoy-connector/issues/new?template=bug.md): versions, OS and architecture, and the script output

This alpha does not claim production readiness, product HTTP/3 WAF support (there is only a lab `h3-probe.sh` hop), WebSocket-frame inspection, HTTP/2 coverage from go-ftw (it is HTTP/1.x only), or full CRS inspection under BUFFERED_PARTIAL or NONE. Envoy normalizes some headers (for example non-URI `Referer` and hop-by-hop `Connection`) before ModSecurity sees them; aim rules at what is still forwarded: [crs-and-envoy-limits.md](./crs-and-envoy-limits.md). Open issues: [`CHANGELOG.md`](../CHANGELOG.md).
