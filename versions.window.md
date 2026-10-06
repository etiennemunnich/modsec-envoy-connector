# Version window — envoy-modsec-connex

Candidate versions to probe before bumping a pin. The pins themselves live in [`versions.lock.md`](./versions.lock.md); this file only lists what the probes cover.

| Axis | Pin | Window (checked 2026-09-27 against upstream tags) |
|------|-----|----------------------------------------------------|
| Envoy | `v1.39.1` | `v1.39.1`, `v1.38.4`, `v1.37.6` |
| libmodsecurity | `v3.0.17` | `v3.0.17`, `v3.0.16`, `v3.0.15` |
| CRS | `v4.30.0` | `v4.30.0`, `v4.29.0`, `v4.28.0` |

## Probes

CI computes the window from upstream releases (`scripts/stable-releases.sh window <axis>`) and tests it weekly on x86_64 + aarch64 (`stable-window`); new stables newer than the pin are tested as they appear (`release-watch` → `stable-candidate`). See [docs/testing.md](./docs/testing.md#hosted-ci). The table above is the last manual check.

| Axis | Local | What it proves |
|------|-------|----------------|
| libmodsecurity | `MODSECURITY_PIN=v3.0.15 ./scripts/probe-modsec-pin.sh` (Linux) | The connector builds, passes clippy and every test against exactly that engine tag. |
| Envoy | `ENVOY_VERSION=v1.38.4 ./scripts/envoy-candidate-smoke.sh` | That Envoy runs the demo config, and smoke, fail-closed and the H1/H2 fail-mode suite pass. |
| CRS | `CRS_TAG=v4.28.0 ./scripts/crs-version-probe.sh` | That CRS loads in the pinned engine; smoke and go-ftw pass (`FTW_MODE=full` for the whole regression tree). |

Any axis, locally: `ENVOY_VERSION=… MODSECURITY_PIN=… CRS_TAG=… ./scripts/ci-live-e2e.sh` (what CI runs per cell). After a green `stable-candidate`, bump `versions.lock.md` on `main`.

## ~12-month lookback (on demand)

For stables published in the last year (not just depth 3), see [`versions.one-year.yaml`](./versions.one-year.yaml) and:

```bash
./scripts/one-year-matrix.sh list
./scripts/one-year-matrix.sh plan --strategy axis          # default; never silent Cartesian
./scripts/one-year-matrix.sh plan --strategy diagonal
gh workflow run stable-one-year.yml -f strategy=axis -f dry_run=true
```

Axis-at-a-time is the default (~19 cells today). Full Cartesian is opt-in (`--confirm-cartesian` / `confirm_cartesian=yes`) and expensive. Details: [docs/testing.md](./docs/testing.md#hosted-ci), [findings/one-year-stable-matrix.md](./docs/findings/one-year-stable-matrix.md).
