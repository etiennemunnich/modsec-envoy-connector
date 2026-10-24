# Security Policy

## Supported Versions

Security fixes land on the latest release of **modsec-envoy-connector** and on `main`.
While the project is in **0.1 alpha**, treat tags as early-testing artifacts: fixes prefer `main` tip; see [`CHANGELOG.md`](./CHANGELOG.md).

| Version | Supported |
| ------- | --------- |
| Latest release | :white_check_mark: |
| `main` tip | :white_check_mark: (pre-release / development) |
| `v0.1.0-alpha.4` and later alphas | :white_check_mark: (early testing only; not production) |
| `v0.1.0-alpha.3` | :white_check_mark: (early testing only; not production; no `libmodsec_dm.so` in artifacts) |
| `v0.1.0-alpha.2` | :white_check_mark: (early testing only; not production) |
| `v0.1.0-alpha.1` | :x: forwards some requests uninspected; see [`CHANGELOG.md`](./CHANGELOG.md) |
| Older releases | :x: unless a release notes line says otherwise |

Pinned Envoy / libmodsecurity / CRS versions for a given release are listed in that release and in `versions.lock.md`. Report against the pins you actually ran.

## Security posture

**Status:** product documentation of intended fail-closed behavior — not a production hardening checklist for your whole mesh. This is early testing, not a production support channel.

### Fail-closed

For any route that claims protection:

- ExtProc unreachable, connector crash/kill, gRPC error, a message the connector cannot read, ModSec init or rules load failure (including a ruleset with 0 rules) → **deny** (500 from Envoy or the connector). `/healthz` stays 503 unless the rules leave `SecRuleEngine On`.
- A hung connector → **504** after `message_timeout`, except under `FULL_DUPLEX_STREAMED`, where Envoy applies no `message_timeout` and the request waits for another Envoy timeout ([fail-closed.md](./docs/fail-closed.md#full_duplex_streamed-and-a-hung-connector)). Envoy going silent past the connector's own stream and duplex deadlines → **504** from the connector.
- Never redefine a failing mode as "out of scope."
- The body mode does **not** relax this. Open defects that break it in specific configurations are listed in [deploy.md](./docs/deploy.md#known-issues).

Live drills: `demo/scripts/fail-closed.sh` (kill → 500, hang → 504 outside FULL_DUPLEX_STREAMED, bad rules → 500, origin untouched).

### Why `ext_proc` is the stronger default

Built on Envoy [security considerations](https://builtonenvoy.io/docs/security-considerations/) stress that Rust/Go **dynamic modules** share Envoy's process, memory, and worker threads. A WAF that links libmodsecurity is a **poor fit** for an edge “hardened” story: mid-life libmodsecurity faults can take or stall the proxy.

`ext_proc` runs **out of process**: Envoy stays up if the connector dies (and with `failure_mode_allow: false`, traffic fails closed). That is the **fail-closed absolute** path documented in [`docs/fail-closed.md`](./docs/fail-closed.md).

### Alpha dynamic module (optional elect)

An in-process DM path (`crates/modsec-dm`) exists for alpha / lab / trusted-mesh experiments. It is **early testing only**, uses a **weaker fail-closed model** ([`docs/fail-closed-dm.md`](./docs/fail-closed-dm.md)), forbids `module.remote` for enforcement, and does **not** claim CatchUnwind contains C++ faults. Elect **one** hop; do not stack both ModSec filters. The Envoy HTTP dynamic-modules filter is documented as **not hardened** (trusted downstream and upstream) at the product pin.

### Bounds

- Keep the connector's `--max-grpc-message-bytes` (default 4 MiB) above Envoy's body buffer limit plus the headers. A larger message fails closed (**500**); over Envoy's own limit, BUFFERED rejects with **413**. Under FULL_DUPLEX_STREAMED a body over `--max-held-body-bytes` fails closed.
- Set ExtProc `message_timeout` for your largest body, and set route / stream timeouts on FULL_DUPLEX_STREAMED routes.
- Do not enable BUFFERED body modes on WebSocket upgrade routes.

The full configuration, with what breaks when a field is left out: [deploy.md](./docs/deploy.md).

## Reporting a Vulnerability

During **0.1 alpha**, report security problems (bypass of an intended block, crash that leads to fail-open, remote code execution, secret exposure, or similar) by **opening a GitHub Issue**. Prefer the [bug template](https://github.com/etiennemunnich/modsec-envoy-connector/issues/new?template=bug.md) and say clearly that it is a security report. This is early testing: there is no private-advisory requirement and no response SLA.

**[Open an issue](https://github.com/etiennemunnich/modsec-envoy-connector/issues/new/choose)**

### What to include

1. Connector version (git tag or commit) and the Envoy / libmodsecurity / CRS pins you ran.
2. Body mode (`BUFFERED`, `STREAMED`, `BUFFERED_PARTIAL`, `FULL_DUPLEX_STREAMED`, headers-only, etc.).
3. Steps to reproduce, expected vs actual allow/deny/fail-closed outcome.
4. Impact (bypass, availability, information disclosure, etc.).
5. Whether you want credit in release notes if a fix ships.

Upstream **CRS rule gaps / false negatives** that are not connector bugs belong in [coreruleset/coreruleset](https://github.com/coreruleset/coreruleset) (see their [SECURITY.md](https://github.com/coreruleset/coreruleset/blob/main/SECURITY.md)). Upstream **libmodsecurity** engine issues belong with [OWASP ModSecurity](https://github.com/owasp-modsecurity/ModSecurity) (contact path: `modsecurity@owasp.org` per their README). Report here when the defect is in this connector's ExtProc / FFI / fail-closed path.

— Etienne Munnich, maintainer
