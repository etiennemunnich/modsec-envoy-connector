# Troubleshooting

## What a status code means

| Client sees | Usual cause | Origin contacted? | Check |
|-------------|-------------|-------------------|-------|
| **403** | a ModSecurity or CRS rule denied the request or response | no, for a request-side deny | rule id in the connector log and the ModSecurity audit log |
| **500** | fail-closed: connector down, stream error, rules failed to load, engine or protocol error, body modes that disagree with `--body-reply`, a request whose body phase never ended (trailer mode `SKIP`), a FULL_DUPLEX body over `--max-held-body-bytes` | no | `curl -sf http://127.0.0.1:18082/healthz`; is the connector process running; connector log |
| **500** on large bodies only | a message from Envoy over `--max-grpc-message-bytes` (4 MiB): the connector logs `ext_proc stream read error` with `code=OutOfRange` and `hint="message larger than --max-grpc-message-bytes"` | no | raise `--max-grpc-message-bytes` above Envoy's `per_connection_buffer_limit_bytes` plus the headers, or lower that buffer limit |
| **504** | connector did not answer within Envoy's `message_timeout` (demo: 2 s) | no | connector stuck or overloaded. Does not happen under FULL_DUPLEX_STREAMED, which has no `message_timeout` |
| **504**, `details=modsec_stream_timeout` | the connector gave up waiting for Envoy: no message for `--stream-idle-timeout` (300 s) before the verdict, or under FULL_DUPLEX_STREAMED a held body idle for `--duplex-idle-timeout` (30 s) or a stream past `--duplex-total-timeout` (300 s) | no | a slow or stalled client body; raise the timeouts if such uploads are legitimate |
| **503** | usually not the connector: the origin cluster, or Envoy overload | maybe | Envoy admin `/clusters`, origin health |
| **503** from `/healthz` | the rules leave `SecRuleEngine` at `DetectionOnly` or `Off` (the answer's `engine_mode=` line says which), or the connector failed its self-probe | — | set `SecRuleEngine On`, or start with `--allow-detection-only` if detection-only is intended |
| **413** | the body is over Envoy's buffer limit (BUFFERED, default 1 MiB) or ModSecurity's body limit (demo `engine.conf`: 128 KiB for bodies without files) | no | raise `per_connection_buffer_limit_bytes` or `SecRequestBodyNoFilesLimit` / `SecRequestBodyLimit` |
| **400** on a POST | `engine.conf` rule 200002: the body did not parse, for example malformed JSON | no | the audit log names the parse error |
| **400** on odd URLs | Envoy rejected the request itself, for example a `#fragment` | no | Envoy access log `details=` |

**403 means the WAF decided; 500 and 504 mean it could not.** Details: [fail-closed.md](./fail-closed.md).

## Install and startup

| Symptom | Fix |
|---------|-----|
| `install-envoy.sh`: `WARN: installed Envoy does not match` | Linux: the script installs the pinned Envoy into `~/.local/bin`; put that first on `PATH` (`export PATH="$HOME/.local/bin:$PATH"`). macOS: Homebrew has moved past the pin; run the Linux path in a VM or container |
| `install-libmodsecurity.sh` on macOS: version is not the pin | Homebrew has moved past the pin; same as above |
| `up.sh`: `envoy not on PATH` | `export PATH="$HOME/.local/bin:$PATH"` (Linux) |
| `up.sh`: `libmodsecurity not found by pkg-config` | run `./demo/scripts/install-libmodsecurity.sh`; if you installed elsewhere, set `MODSECURITY_PREFIX` to that prefix |
| `cargo build` outside the demo: `pkg-config` cannot find `modsecurity` | `export PKG_CONFIG_PATH=$HOME/.local/lib/pkgconfig LD_LIBRARY_PATH=$HOME/.local/lib` (Linux) |
| `error while loading shared libraries: libmodsecurity.so.3` | the same `LD_LIBRARY_PATH`; for a release tarball, keep `bin/` and `lib/` side by side, as the binary finds `lib/` through its RUNPATH ([deploy.md](./deploy.md#release-tarball)) |
| `up.sh` refuses to start: a port is in use | `./demo/scripts/down.sh`, or `DEMO_PORT_BASE=18380 ./demo/scripts/up.sh` |
| connector exits at startup: `ModSecurity rules failed to load` | a rules file is missing or does not parse, or the files define 0 rules; `--modsec-rules` does not expand globs, so use one entry file with `Include` lines ([deploy.md](./deploy.md#2-write-the-rules-entry-file)) |
| `go-ftw.sh`: go-ftw not found | `./demo/scripts/install-go-ftw.sh` (installs into `~/.local/bin`), or set `FTW_BIN` |

## Body modes

| Symptom | Likely cause |
|---------|--------------|
| a body attack reaches the origin with **200** | `BODY_MODE=NONE`; BUFFERED_PARTIAL with the attack past the buffer limit; or the connector is `v0.1.0-alpha.1` ([deploy.md](./deploy.md#known-issues)) |
| requests whose body ends in trailers get **500** | trailer mode `SKIP` with a body mode other than NONE; set both trailer modes to `SEND` ([body-modes.md](./body-modes.md#where-the-body-phase-ends)) |
| every request **500**, the connector logs `Envoy body modes request=… response=… need --body-reply …` | `--body-reply` does not match Envoy's body modes: `streamed` when a direction is FULL_DUPLEX_STREAMED, `common` otherwise |
| a later script runs in the wrong body mode | the scripts use the mode `up.sh` saved in `demo/.run/body_mode`; run `up.sh` again with the `BODY_MODE` you want |
| a response-body rule fires but the client got a reset stream, or part of the body, instead of a 403 | under STREAMED, Envoy sends the response headers and chunks before the response-body rules run ([body-modes.md](./body-modes.md#streamed)) |

## Logs

- Demo: `demo/.run/envoy.log` (access log with `rid=` and `details=`), `demo/.run/connector.log`, `demo/.run/origin.log`, ModSecurity audit log `demo/.run/modsec-audit.log`.
- More detail from the connector and the engine: `RUST_LOG=debug,modsecurity=debug ./demo/scripts/up.sh`, or set `RUST_LOG` for your own connector process.
- One request across every hop: `./demo/scripts/hop-trace.sh <path>`, which writes `demo/.run/hop-trace/<request id>.txt`.
