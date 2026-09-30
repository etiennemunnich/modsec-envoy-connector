# Findings index

Design notes and measured tradeoffs that sit behind the product docs. Live proofs stay in `docs/testing.md` and the demo suites.

| Doc | One-line |
|-----|----------|
| [design-readiness-and-tests.md](../design-readiness-and-tests.md) | Readiness snapshot; test gaps; integration tests |
| [approach-options.md](./approach-options.md) | BUFFERED vs STREAMED vs headers-only options for libmodsecurity |
| [buffered-downsides.md](./buffered-downsides.md) | RAM, TTFB, WS hang, large-upload tradeoffs of BUFFERED |
| [http-grpc-websocket-scope.md](./http-grpc-websocket-scope.md) | Multi-protocol product surface and limits |
| [grpc-websocket-assumption-test.md](./grpc-websocket-assumption-test.md) | Live CRS-on assumption test (HTTP ok; WS hang; gRPC accidental HTTP) |
| [modsec-only-retest-hops.md](./modsec-only-retest-hops.md) | ModSec-only hop-trace retest (CRS skipped) |
| [modsec-only-no-crs.md](./modsec-only-no-crs.md) | Engine+connector focus without CRS |
| [coraza-envoy-issues.md](./coraza-envoy-issues.md) | Coraza Envoy issues as **reference only** |
| [ghcr-stale-tags.md](./ghcr-stale-tags.md) | GHCR stale-tag cleanup notes |
| [one-year-stable-matrix.md](./one-year-stable-matrix.md) | ~12-month stable Envoy×ModSec×CRS matrix (axis default; Cartesian opt-in) |

**Invariants:** fail-closed on protected paths; Coraza is reference only; this tree is a PoC, not a production ops package.
