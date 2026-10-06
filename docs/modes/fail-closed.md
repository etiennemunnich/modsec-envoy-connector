# Fail-closed

If ModSecurity cannot produce a trustworthy allow/deny decision, the request **must not** reach upstream as OK. That is a different class from a **rule deny (403)**.

Full contract and drills: [docs/fail-closed.md](https://github.com/etiennemunnich/envoy-modsec-connex/blob/main/docs/fail-closed.md).

## Deny ≠ fail

| Client status | Meaning |
|---------------|---------|
| **403** (typical) | WAF **decided**: rule deny |
| **500** | WAF / path **could not decide**: connector down, bad rules, engine error |
| **504** | Connector stalled past Envoy `message_timeout` (demo **2s**) |

Never: `failure_mode_allow: true` on an enforcement filter. Never Continue after an engine error.

## Who owns what

| Class | Who | Client |
|-------|-----|--------|
| Connector process / gRPC stream fail | **Envoy** (`failure_mode_allow: false`) | **500** |
| Rules fail to load at boot | **Connector** exits; Envoy then | **500** |
| Per-request engine / protocol error | **Connector** `ImmediateResponse` | **500** |
| Rule intervention | **Connector** maps deny | **403** typical |
| Stall past `message_timeout` | **Envoy** | **504** |

Under **FULL_DUPLEX_STREAMED**, Envoy turns `message_timeout` **off**, so the stall→504 cell is skipped. Kill → 500 and bad-rules → 500 still apply.

## Prove it locally

```bash
./demo/scripts/up.sh
./demo/scripts/fail-closed.sh     # kill → 500; stall → 504; bad rules → 500
./demo/scripts/fail-modes.sh      # classes 1-6, HTTP/1.1 + HTTP/2
```

## Related

- [How it works](./how-it-works.md)
- [Troubleshooting](./troubleshooting.md): 403 vs 503 vs fail-closed 500/504
- [Testing suite](./testing-suite.md)
