# Troubleshooting

Quick status decode. Fail-closed detail: [Fail-closed](./fail-closed.md). Path detail: [How it works](./how-it-works.md).

## 403 vs 500 vs 504 vs 503

| Client status | Usual cause | Origin hit? | What to check |
|---------------|-------------|-------------|---------------|
| **403** | CRS / demo **rule deny** | No (request path) | Connector log + ModSecurity audit log for rule id; not a failure |
| **500** | Fail-closed: connector down, stream error, bad rules, engine/protocol error | No | `failure_mode_allow` must be false; `/healthz`; connector process; rules load |
| **504** | Connector stalled past Envoy `message_timeout` (demo 2s) | No | Connector stuck / overloaded. **N/A under FULL_DUPLEX** (`message_timeout` off) |
| **503** | Usually **not** connector fail-closed: upstream / Envoy cluster / overload | Maybe | Envoy admin / upstream cluster health; do not treat as ModSec deny |

**Deny ≠ fail:** **403** means the WAF decided. **500** / **504** means it could not decide.

## CRS block vs fail-closed

| Symptom | Class |
|---------|-------|
| SQLi/XSS URL or body → **403**, origin hit count unchanged | CRS / rule deny (working as designed) |
| Response leak marker → **403** | Phase 4 rule deny |
| Connector killed → **500**, `failure_mode_allowed` stays 0 | Fail-closed class 1 |
| Invalid SecLang / missing Include at boot → connector exits, Envoy **500** | Fail-closed class 2 |
| Stall under BUFFERED/STREAMED → **504** after ~2s | Fail-closed timeout |
| Same stall under FULL_DUPLEX does **not** become 504 | Expected: timer off |

Prove locally: `./demo/scripts/smoke.sh` (denies) and `./demo/scripts/fail-closed.sh` (failures).

## Body mode surprises

| Symptom | Likely cause |
|---------|--------------|
| Body attack reaches origin with **200** | `BODY_MODE=NONE`, or PARTIAL over-limit trailing miss |
| Envoy `spurious_message` under duplex | Connector `--body-reply` still `common`; need `streamed` |
| go-ftw full claimed “hosted green” for STREAMED/DUPLEX | Matrix is **wired**; tip hosted green not yet shown (see [Testing suite](./testing-suite.md)) |

## Ports and readiness

| Check | Expect |
|-------|--------|
| `curl -sf http://127.0.0.1:18082/healthz` | 200 |
| `curl -sf http://127.0.0.1:18089/ready` | ready |
| `curl -s http://127.0.0.1:18082/metrics \| grep ext_proc_` | counters move |

Port collisions: `DEMO_PORT_BASE=18380 ./demo/scripts/up.sh`.

## Related

- [Config / pins](./config-pins.md)
- [Testing suite](./testing-suite.md)
- [Install / build](./install.md)
