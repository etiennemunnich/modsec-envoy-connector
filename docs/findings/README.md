# Findings index

Distilled from Project Context research (2026-09-21). Evidence and hop artifacts remain in the experiment lab / Context store; these files are the durable product narrative.

| Doc | One-line |
|-----|----------|
| [design-readiness-and-tests.md](../design-readiness-and-tests.md) | PARTIAL readiness; test gaps; integration tests; BoE checklist |
| [approach-options.md](./approach-options.md) | BUFFERED vs STREAMED vs headers-only options for libmodsecurity |
| [buffered-downsides.md](./buffered-downsides.md) | RAM, TTFB, WS hang, large-upload tradeoffs of BUFFERED |
| [http-grpc-websocket-scope.md](./http-grpc-websocket-scope.md) | Honest multi-protocol product surface |
| [grpc-websocket-assumption-test.md](./grpc-websocket-assumption-test.md) | Live CRS-on assumption test (HTTP ok; WS hang; gRPC accidental HTTP) |
| [modsec-only-retest-hops.md](./modsec-only-retest-hops.md) | ModSec-only hop-trace retest (CRS skipped) |
| [modsec-only-no-crs.md](./modsec-only-no-crs.md) | CRS deferred; engine+connector focus |
| [coraza-envoy-issues.md](./coraza-envoy-issues.md) | Coraza Envoy issues as **reference only** |

**Invariants:** fail-closed absolute; Coraza = reference; not production.
