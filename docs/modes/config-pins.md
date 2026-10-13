# Config / pins

What to pin, which demo YAML each body mode uses, and how to pick a mode. Install steps: [Install / build](./install.md).

## Version pins

Source of truth: [`versions.lock.md`](../../versions.lock.md).

| Axis | Pin (tip) | How it gets installed |
|------|-----------|------------------------|
| Envoy | **v1.39.4** | `./demo/scripts/install-envoy.sh` |
| libmodsecurity | **v3.0.17** | `./demo/scripts/install-libmodsecurity.sh` |
| OWASP CRS | **v4.30.0** | `./demo/scripts/install-crs.sh` → `demo/.crs` |

Prefer those scripts over a naked package-manager install so the pin check runs. Release image builds use the same pins (see packaging / CI release workflow).

## Body mode selector

`BODY_MODE=… ./demo/scripts/up.sh` picks the Envoy YAML and connector `--body-reply`. Written to `demo/.run/body_mode` so later scripts match.

| `BODY_MODE` | Demo YAML | `--body-reply` | When to use |
|-------------|-----------|----------------|-------------|
| `BUFFERED` (default) | [`envoy.yaml`](../../demo/envoy/envoy.yaml) | `common` | Full body before origin; strongest default CRS claim |
| `STREAMED` | [`envoy-streamed.yaml`](../../demo/envoy/envoy-streamed.yaml) | `common` | Lower Envoy whole-body buffering; early chunks may move |
| `BUFFERED_PARTIAL` | [`envoy-buffered-partial.yaml`](../../demo/envoy/envoy-buffered-partial.yaml) | `common` | Soft-limit / honesty labs; **not** full CRS |
| `NONE` | [`envoy-none.yaml`](../../demo/envoy/envoy-none.yaml) | `common` | Headers only; body CRS n/a |
| `FULL_DUPLEX_STREAMED` | [`envoy-full-duplex.yaml`](../../demo/envoy/envoy-full-duplex.yaml) | **`streamed`** | Duplex wire + Silent buffer until allow; `message_timeout` off |

Asymmetric labs (`REQ_BUFFERED_RESP_STREAMED` / `REQ_STREAMED_RESP_BUFFERED`) exist for secondary axes; see [`demo/README.md`](../../demo/README.md).

## Enforcement knobs (do not relax)

| Knob | Product value |
|------|---------------|
| `failure_mode_allow` | **`false`** |
| `message_timeout` | **`2s`** on BUFFERED / STREAMED / PARTIAL / NONE; **off** under FULL_DUPLEX |
| Trailer modes | `SKIP` default; **SEND** required for FULL_DUPLEX |
| `observability_mode` | Never for enforcement |

## How to pick a mode

1. Need a full CRS claim and request-body deny before origin → **BUFFERED**.
2. Need streamed bodies and accept early-chunk exposure risk → **STREAMED** (product suites hosted; full CRS matrix wired).
3. Need duplex Continue shape → **FULL_DUPLEX_STREAMED** (same honesty as STREAMED for hosted full CRS).
4. Soft-limit / ProcessPartial class → **BUFFERED_PARTIAL** (honesty only).
5. Headers-only path / gRPC hop-trace demos → **NONE**.

Per-mode pages: [comparison table](./README.md#mode-comparison).

## Related

- [Getting started](./getting-started.md)
- [How it works](./how-it-works.md)
- [Testing suite](./testing-suite.md)
