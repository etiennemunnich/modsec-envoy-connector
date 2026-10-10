# BUFFERED_PARTIAL

Prefix / soft-limit class. Same honesty family as ModSecurity `SecRequestBodyLimitAction ProcessPartial`.

## What Envoy does

Buffer up to the configured limit and send a body message (full entity if under limit, prefix-class behaviour when over). With a 1 MiB soft `per_connection_buffer_limit_bytes`, bodies just over 1 MiB may still fully reach the connector; roughly **2 MiB+** can skip `request_body` (headers-only Continue). That shape was observed on Envoy v1.39.1. The runtime pin is now v1.39.3; this page does not claim a fresh measurement. Not a hard 413 like BUFFERED.

## Flow with this filter + ModSecurity / CRS

Under the soft limit, behaviour matches BUFFERED for typical CRS body sizes. Over the effective cut, trailing attacks can miss phase-2.

| Phase | Runs? | Notes |
|-------|-------|-------|
| 1 | **Yes** | |
| 2 | **Sometimes** | Runs when a body message arrives; missing over-limit body → no full phase-2 on the trailing bytes |
| 3 | **Yes** | Headers |
| 4 | **Sometimes** | Same soft-limit class on `response_body_mode: BUFFERED_PARTIAL` |

```mermaid
sequenceDiagram
  participant C as Client
  participant E as Envoy
  participant R as Connector
  participant M as libmodsecurity
  participant U as Origin

  alt body under soft limit
    C->>E: small body with SQLi
    E->>R: request_headers + request_body
    R->>M: phase 2 on full/prefix entity
    R-->>E: ImmediateResponse 403
    E-->>C: 403
  else body well over soft limit
    C->>E: 2 MiB pad + trailing SQLi
    E->>R: request_headers
    R-->>E: Continue
    Note over E,R: request_body may be skipped
    E->>U: body reaches origin
    U-->>E: 200
    E-->>C: 200 (trailing attack missed)
  end
```

```mermaid
flowchart TB
  P1[Body arrives] --> P2{Within effective soft limit?}
  P2 -->|yes| P3[Body message to connector]
  P3 --> P4[phase 2 / CRS under-limit]
  P2 -->|no / watermark skip| P5[Headers-only Continue]
  P5 --> P6[Trailing bytes unseen by ModSec]
```

## CRS response inspection (phase 3/4)

Phase 3 runs on response headers. Phase 4 runs only when a response body message is delivered (same soft-limit caveats as the request side). **Do not** treat PARTIAL as full response-body CRS fidelity.

## Config knobs

| Knob | Value |
|------|-------|
| Demo YAML | [`demo/envoy/envoy-buffered-partial.yaml`](../../demo/envoy/envoy-buffered-partial.yaml) |
| Soft limit | `per_connection_buffer_limit_bytes: 1048576` (1 MiB) |
| Selector | `BODY_MODE=BUFFERED_PARTIAL` |
| `--body-reply` | `common` |
| `message_timeout` | `2s` |
| Honesty drill | `demo/scripts/partial-honesty.sh` (in-prefix 403; 2 MiB trailing → 200) |

## When to use

Use when you explicitly want ProcessPartial-style inspection and will document the miss window.

Never claim full go-ftw / BUFFERED parity. CI refuses `go-ftw-full` under this mode. Hosted cell `e2e-buffered-partial` = smoke + fail-closed + go-ftw-smoke + honesty only.

**Coverage:** under-limit smoke/body CRS only; 2 MiB trailing bypass proven.
