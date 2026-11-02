# Fail-closed (dynamic module) — weaker / different model

**Status:** early beta dual option. Early testing only. Not production-ready. **Not** fail-closed absolute (see table below).

This page covers the **in-process** `modsec-dm` path (`DEPLOY=dm`). It is **not** the same absolute fail-closed story as [`fail-closed.md`](./fail-closed.md) (ext_proc). Do **not** cite `demo/scripts/fail-closed.sh` as DM proof. Elect **one** hop — do not stack both ModSec filters on one chain.

## What DM can enforce

| Class | DM behavior | Drill |
|-------|-------------|-------|
| Missing / unloadable `.so` | Envoy rejects config or does not serve OK-to-origin | `fail-closed-dm.sh` |
| Bad / zero rules at filter init | `FilterConfig::new` → `None` → config reject | `fail-closed-dm.sh` |
| `SecRuleEngine` DetectionOnly / Off | Filter load → `None` unless JSON `allow_detection_only: true` (parity with ext_proc `/healthz` + `--allow-detection-only`) | unit test |
| Per-request `EngineError` | Local **500** via `send_response`; never Continue (default build) | unit test + inject |
| Rule deny | Local **403** (typical) | `smoke-dm.sh` |
| Drop intervention (status 0) | Local **403** `"dropped"` today (ext_proc maps Drop → stream abort → Envoy **500**) | unit / settle path |
| Rust panic | `CatchUnwind` → local **500** | SDK wrapper (Rust only) |
| FULL_DUPLEX config | **Rejected** (UNSUPPORTED) | `fail-closed-dm.sh` |

## What DM cannot claim (ext_proc absolute)

| Capability | Why |
|------------|-----|
| Kill sidecar → **500** | No sidecar |
| Hang → **504** via `message_timeout` | No gRPC message timeout on the filter |
| `failure_mode_allow: true` negctl | No first-class fail-open flip |
| Process isolation from libmodsecurity SIGSEGV | Same address space as Envoy |
| CatchUnwind = ModSec containment | C++ UB still kills/stalls Envoy |

Hung FFI on a worker is an **Envoy availability** risk (route/stream idle timeouts may fire with an observed status that is **not** necessarily 504). Document observed status; do not rename it as mapped absolute class 5.

## Forbidden: `module.remote`

Remote fetch failure **omits** the filter → requests pass **unfiltered** (fail-open). Enforcement configs must use local `name` / search path only. Negative control: `demo/scripts/fail-closed-dm-negctl.sh`.

## Elect one hop

Do not put both `envoy.filters.http.ext_proc` (ModSec connector) and `envoy.filters.http.dynamic_modules` (ModSec DM) on the same filter chain.
