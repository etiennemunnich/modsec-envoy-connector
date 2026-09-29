# Finding: ~12-month stable version matrix

**Date:** 2026-09-29  
**Scope:** envoy-modsec-connex — discover and test stable Envoy v1.x / libmodsecurity v3.0.x / CRS v4.x tags from the last ~year, including combinations, without Mac-as-runner CI.

## What landed

| Piece | Role |
|-------|------|
| [`versions.one-year.yaml`](../../versions.one-year.yaml) | Policy: `days`, ModSec floor, collapse mode, strategies, suite profiles |
| [`scripts/stable-releases.sh`](../../scripts/stable-releases.sh) `since` / `since-window` | Stables with `published_at` in the lookback (never `releases/latest`) |
| [`scripts/one-year-matrix.sh`](../../scripts/one-year-matrix.sh) | `list` · `plan` (axis / diagonal / cartesian) · `run` one cell by profile |
| [`stable-one-year.yml`](../../.github/workflows/stable-one-year.yml) | `workflow_dispatch` only; empty matrix fails; Cartesian needs `confirm_cartesian=yes` |

## Combination policy (honest)

- **Default:** axis-at-a-time (pin two, vary one) + pins cell — ~19 cells × 2 arches ≈ **90–130** warm job-minutes.
- **Optional:** sparse diagonal (~7 cells).
- **Opt-in only:** full Cartesian (~176 cells / **~800+** min) — never scheduled.
- Do **not** claim full-year Cartesian green unless that strategy was actually run.

## Operator

```bash
./scripts/one-year-matrix.sh plan --strategy axis
./scripts/one-year-matrix.sh run --profile smoke --crs v4.28.0
gh workflow run stable-one-year.yml -f strategy=axis -f profile=full-cell -f days=365
gh workflow run stable-one-year.yml -f strategy=axis -f dry_run=true
```

Older Envoy on macOS: Homebrew usually only bottles the tip; there is no Darwin release asset for prior stables — use hosted Linux for Envoy-axis cells. CRS / ModSec overrides work locally when Envoy matches the pin.

Project plan (Context store): `docs/stable-versions-one-year-plan.md`. Sample proof: Project store `internal/connex-one-year-matrix/proof.md`.
