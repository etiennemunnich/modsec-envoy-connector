# GRPC (`BodySendMode` enum 5): unimplemented

This is **not** “gRPC routes in the demo.” It is Envoy’s `BodySendMode.GRPC` value on the ext_proc processing-mode enum.

## Status on pinned Envoy v1.39.4

Marked `[#not-implemented-hide:]` in the committed proto, which was generated from the v1.39.1 API closure. The v1.39.4 runtime pin does not add a connector YAML, CI cell, or CRS claim for this mode.

| Surface | Connector policy |
|---------|----------------|
| Demo YAML | **None** |
| `BODY_MODE=` | **None** |
| CI cell | **None** |
| CRS claim | **None** (out of scope) |

If it were implemented, Envoy would also disable `message_timeout` (same class as `FULL_DUPLEX_STREAMED`) and would expect `StreamedBodyResponse`-style Continues.

## Not the same as demo gRPC

| Topic | What this connector ships |
|-------|-------------------|
| gRPC **routes** / protobuf bodies | Headers-only path (`envoy-grpc.yaml`, body `NONE`). Not protobuf CRS. |
| `BodySendMode.GRPC` | Unimplemented upstream (document only) |

```mermaid
flowchart LR
  A[BodySendMode.GRPC enum 5] --> B{Implemented on pinned Envoy v1.39.4?}
  B -->|no| C[Out of scope for this connector]
  C --> D[No YAML / CI / CRS claim]
  E[Demo gRPC listener] --> F[Body mode NONE]
  F --> G[Header / metadata inspection only]
```

See [NONE](./none.md) for the headers-only body mode that protocol demos actually use.
