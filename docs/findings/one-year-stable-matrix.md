# Finding: ~12-month stable version matrix

**Date:** 2026-09-29  
**Scope:** modsec-envoy-connector — discover and test stable Envoy v1.x / libmodsecurity v3.0.x / CRS v4.x tags from the last ~year, including combinations, without Mac-as-runner CI.

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


## CRS axis cells (issue #18)

| Tag | Symptom | Root cause | Fix |
|-----|---------|------------|-----|
| **v4.23.0** | go-ftw CRS body: empty JSON (`Expecting value…`); demo/smoke/FC/fail-modes OK | go-ftw 2.6 parses **all** YAML under `--dir` before `--include`. That tag’s `920640.yaml` ships `status: [400]`; go-ftw rejects `!!seq`→int and writes no summary. Fixed in CRS ≥ v4.24.1. | `go-ftw.sh` smoke/body **stages** only BODY_INCLUDE rule YAML into a temp dir — no tag exclusion. |
| **v4.19.0** | suite green (`success=92`) but floor `92 < 100` | That tag has exactly **92** BODY_INCLUDE tests (later tags ≥ 103; pins ~118). | Version-aware floor: pin bar stays 100; when available ∈ [50, 100), floor = available. |

Policy and scripts above are the in-repo source of truth (no separate plan file in this tree).
