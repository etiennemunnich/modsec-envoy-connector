---
cursor:
  subagentId: "bc-8923ef71-a7d3-5f88-9320-6d61c64a12d5"
---

# Live assumption test — gRPC / WebSocket on BUFFERED ModSec lab

**Date:** 2026-09-21  
**Repo:** `modsec-envoy-experiement` (local lab only; no push)  
**Context assumption:** [http-grpc-websocket-scope.md](./http-grpc-websocket-scope.md)  
**Fail-closed:** stock lab restored after probes (`compose/lab/envoy.host.yaml` + connector + albedo). Experimental YAML lived only under `/tmp/modsec-proto-test/` and was not committed.

---

## Assumption under test

Current Envoy → Rust `ext_proc` → libmodsecurity **BUFFERED** lab is **HTTP-proven**. gRPC and WebSocket through the same path either **break** (body buffer / no EOS / failed upgrade) or get only **accidental partial HTTP** handling — **not** meaningful protocol support.

---

## Lab setup (commands run)

```bash
# Stock lab (BUFFERED request+response bodies, no WS upgrade_configs, HTTP/1.1 listener)
./scripts/lab-up.sh   # or durable host connector :18081 + envoy -c compose/lab/envoy.host.yaml :18080
# albedo echo :18088

# Helpers (tmp only)
python3 …            # WS echo :18089
./grpc_echo_real     # real gRPC Echo :18090 (grpcurl + echo.proto)

# Experimental Envoy configs (NOT in repo):
#   /tmp/modsec-proto-test/envoy-ws-buffered.yaml
#   /tmp/modsec-proto-test/envoy-ws-headers-only.yaml
#   /tmp/modsec-proto-test/envoy-grpc-buffered.yaml
#   /tmp/modsec-proto-test/envoy-grpc-headers-only.yaml

# Probes
curl … http://127.0.0.1:18080/ …
# raw WS handshake python sockets → :18080
grpcurl -plaintext -import-path /tmp/modsec-proto-test -proto echo.proto \
  -d '{"text":"hi"}' 127.0.0.1:18080 echo.Echo/{Unary,ServerStream,ClientStream}
```

---

## Results

| Case | Config | Result | What happened |
|------|--------|--------|---------------|
| **HTTP GET** | Stock BUFFERED | **PASS** | `200` (~13ms) via ModSec allow all phases |
| **HTTP POST benign** | Stock BUFFERED | **PASS** | `200` |
| **HTTP POST SQLi** | Stock BUFFERED | **PASS** | `403` CRS anomaly (949110), body path works |
| **WebSocket (stock)** | Stock BUFFERED, **no** `upgrade_configs` | **FAIL** | Envoy `403` in ~1ms; `downstream_cx_upgrades_total=0` — upgrade not enabled |
| **WebSocket (BUFFERED + upgrade)** | Experimental `upgrade_configs` + **BUFFERED** bodies → WS echo | **HANG** | Client timeout 12s, empty reply; Envoy access `status=0 flags=DC`; connector got **request_headers allow** then **never** completed body/response (stuck waiting for body/EOS on upgrade) |
| **WebSocket (headers-only contrast)** | Same upgrade + `request/response_body_mode: NONE` | **PASS (handshake only)** | `101` in ~9ms; frame echo worked; ModSec saw headers only (`response_headers status=101`). **Not** frame CRS — post-upgrade opaque |
| **gRPC unary (stock HTTP/1)** | Stock BUFFERED HTTP/1.1 listener | **FAIL (accidental HTTP)** | ModSec phase-2 **403** / grpcurl `PermissionDenied` — CRS anomaly score 11 on `/echo.Echo/Unary` (HTTP semantics on gRPC-shaped POST) |
| **gRPC unary (BUFFERED + HTTP/2)** | Experimental HTTP/2 + BUFFERED → real Echo | **FAIL (accidental HTTP)** | Same CRS **403** / grpc-status 7; body phase deny (`body_bytes=9`); never meaningful unary CRS/protobuf support |
| **gRPC server-stream** | Experimental HTTP/2 + BUFFERED | **FAIL (accidental HTTP)** | Same CRS **403** before stream |
| **gRPC client-stream** | Experimental HTTP/2 + BUFFERED | **FAIL (accidental HTTP)** | Same CRS **403** before stream |
| **gRPC headers-only contrast** | HTTP/2 + body `NONE` | **FAIL (still accidental HTTP)** | Still CRS anomaly **403** (score 11 from header/protocol rules); connector still ran phase-2 deny. Upstream Echo never reached. Confirms headers-only is **not** “gRPC support” without rule/route tuning |

**Direct baselines (bypass Envoy):** WS echo `101` OK; gRPC unary/`ServerStream` OK (`pong:hi`, three chunks).

---

## Verdict

**Assumption confirmed.**

- HTTP BUFFERED path remains the only proven product surface.
- WebSocket through BUFFERED body mode **hangs** the upgrade (no 101 / DC); stock lab **rejects** upgrades outright; headers-only unlocks handshake-only (explicitly not frame inspection).
- gRPC through the same ModSec path is **accidental HTTP CRS** (deny on anomaly score), not protobuf-aware or streaming-aware WAF — unary and streaming alike.

No repo commits; experimental YAML discarded from the lab path; stock Envoy + connector + albedo left green.
