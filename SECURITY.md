# Security posture

**Status:** documentation only, not a production hardening guide.

## Fail-closed

For any route that claims protection:

- ExtProc unreachable, connector crash/kill, hang/timeout, gRPC error, ModSec init or rules load failure → **deny** (typically 5xx / local reply).
- Never redefine a failing mode as "out of scope."
- Body delivery mode (BUFFERED vs STREAMED) does **not** relax this.

Live drills: `demo/scripts/fail-closed.sh` (kill → 500, hang → 504, bad rules → 500, origin untouched).

## Why `ext_proc` (not in-process dynamic module)

Built on Envoy [security considerations](https://builtonenvoy.io/docs/security-considerations/) stress that Rust/Go **dynamic modules** share Envoy's process, memory, and worker threads. A WAF that links libmodsecurity is a poor fit for that model.

`ext_proc` runs **out of process**: Envoy stays up if the connector dies (and with `failureModeAllow: false`, traffic fails closed). That matches this project's product shape.

## Bounds

- Cap BUFFERED body sizes; over-limit must **reject**, not hang or pass.
- Set ExtProc `message_timeout` appropriate to max body size.
- Do not enable BUFFERED body modes on WebSocket upgrade routes.

## Reporting

Private repository. Security reports: contact the author (Etienne Munnich) via the GitHub account that owns this repo.
