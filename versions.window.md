# Version window — envoy-modsec-connex

Candidate versions to probe before bumping a pin. The pins themselves live in [`versions.lock.md`](./versions.lock.md); this file only lists what the probes cover.

| Axis | Pin | Window (checked 2026-09-27 against upstream tags) |
|------|-----|----------------------------------------------------|
| Envoy | `v1.39.1` | `v1.39.1`, `v1.38.4`, `v1.37.6` |
| libmodsecurity | `v3.0.16` | `v3.0.16`, `v3.0.15`, `v3.0.14` |
| CRS | `v4.29.0` | `v4.29.0`, `v4.28.0`, `v4.27.0` |

## Probes

| Axis | Local | What it proves |
|------|-------|----------------|
| libmodsecurity | `MODSECURITY_PIN=v3.0.15 ./scripts/probe-modsec-pin.sh` (Linux) | The connector builds, passes clippy and every test against exactly that engine tag. |
| Envoy | `ENVOY_VERSION=v1.38.4 ./scripts/envoy-candidate-smoke.sh` | That Envoy runs the demo config, and smoke, fail-closed and the H1/H2 fail-mode suite pass. |
| CRS | `CRS_TAG=v4.28.0 ./scripts/crs-version-probe.sh` | That CRS loads in the pinned engine; smoke and go-ftw pass (`FTW_MODE=full` for the whole regression tree). |

Update the window when a new stable lands, run the matching probe, then bump `versions.lock.md`.
