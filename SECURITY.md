# Security Policy

## Supported Versions

Security fixes land on the latest release of **modsec-envoy-connector** and on `main`.
While the project is in **0.1 alpha**, treat tags as early-testing artifacts: fixes prefer `main` tip; see [`CHANGELOG.md`](./CHANGELOG.md).

| Version | Supported |
| ------- | --------- |
| Latest release | :white_check_mark: |
| `main` tip | :white_check_mark: (pre-release / development) |
| `v0.1.0-alpha.*` | :white_check_mark: (early testing only; not production) |
| Older releases | :x: unless a release notes line says otherwise |

Pinned Envoy / libmodsecurity / CRS versions for a given release are listed in that release and in `versions.lock.md`. Report against the pins you actually ran.

## Security posture

**Status:** product documentation of intended fail-closed behavior — not a production hardening checklist for your whole mesh.

### Fail-closed

For any route that claims protection:

- ExtProc unreachable, connector crash/kill, hang/timeout, gRPC error, ModSec init or rules load failure → **deny** (typically 5xx / local reply).
- Never redefine a failing mode as "out of scope."
- Body delivery mode (BUFFERED vs STREAMED) does **not** relax this.

Live drills: `demo/scripts/fail-closed.sh` (kill → 500, hang → 504, bad rules → 500, origin untouched).

### Why `ext_proc` (not an in-process dynamic module)

Built on Envoy [security considerations](https://builtonenvoy.io/docs/security-considerations/) stress that Rust/Go **dynamic modules** share Envoy's process, memory, and worker threads. A WAF that links libmodsecurity is a poor fit for that model.

`ext_proc` runs **out of process**: Envoy stays up if the connector dies (and with `failureModeAllow: false`, traffic fails closed).

### Bounds

- Cap BUFFERED body sizes; over-limit must **reject**, not hang or pass.
- Set ExtProc `message_timeout` appropriate to max body size.
- Do not enable BUFFERED body modes on WebSocket upgrade routes.

## Reporting a Vulnerability

Please **do not** open a public GitHub issue for security problems (bypass of an intended block, crash that leads to fail-open, remote code execution, secret exposure, or similar). This matches ModSecurity's practice of keeping security issues private until fixed.

### Preferred path — GitHub private vulnerability reporting

Use GitHub's private advisory form when it is available on this repository:

**[Report a vulnerability](https://github.com/etiennemunnich/modsec-envoy-connector/security/advisories/new)**

That creates a draft Security Advisory visible only to maintainers (and to you as the reporter). Prefer this over email so versions, impact, and remediation stay in one place.

### If the form is unavailable

While the repository is private, or if private vulnerability reporting is not yet enabled, contact the maintainer **Etienne Munnich** via GitHub ([@etiennemunnich](https://github.com/etiennemunnich)) and ask for a private channel or a draft advisory. Do not paste exploit details into public issues, discussions, or pull requests.

### What to include

1. Connector version (git tag or commit) and the Envoy / libmodsecurity / CRS pins you ran.
2. Body mode (`BUFFERED`, `STREAMED`, `BUFFERED_PARTIAL`, `FULL_DUPLEX_STREAMED`, headers-only, etc.).
3. Steps to reproduce, expected vs actual allow/deny/fail-closed outcome.
4. Impact (bypass, availability, information disclosure, etc.).
5. Whether you want public credit after a fix ships.

Upstream **CRS rule gaps / false negatives** that are not connector bugs belong in [coreruleset/coreruleset](https://github.com/coreruleset/coreruleset) (see their [SECURITY.md](https://github.com/coreruleset/coreruleset/blob/main/SECURITY.md)). Upstream **libmodsecurity** engine issues belong with [OWASP ModSecurity](https://github.com/owasp-modsecurity/ModSecurity) (contact path: `modsecurity@owasp.org` per their README). Report here when the defect is in this connector's ExtProc / FFI / fail-closed path.

### Response expectations

- Acknowledgement within **five business days**.
- A short status update when triage finishes (accepted / needs more info / declined with reason).
- Coordinated disclosure: we aim to ship a fix (or a clear mitigation) before any advisory is made public.
- Credit in the advisory or release notes if you ask for it (same spirit as ModSecurity's "credit will be given" note).

If in doubt, reach out privately first.

— Etienne Munnich, maintainer
