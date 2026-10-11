# GHCR stale package versions

**Date:** 2026-09-29  
**Status:** cleanup script shipped; delete still needs packages scopes on the operator's `gh` token  
**Not merge-blocking** for connector work.

## What remains

GitHub Release + git tag `v0.1.0-rc.1` are **already deleted** (API 404). Accidental / stale **GHCR** container versions may still exist under the **predecessor** package name:

`ghcr.io/etiennemunnich/envoy-modsec-connex`

New releases from this repository publish `ghcr.io/etiennemunnich/modsec-envoy-connector` (`GITHUB_REPOSITORY` in the release workflow). The cleanup script defaults still target the old package where the stale tags live.

Allowlisted targets (hard-coded in the script — nothing else is deleted):

| Tag / version name pattern | Why |
|----------------------------|-----|
| `v0.1.0-rc.1` | Accidental CI-proof pre-release image |
| tags starting `sha-770ab01` | Stale dispatch image from early release path |

Package UI (signed-in):  
https://github.com/users/etiennemunnich/packages/container/envoy-modsec-connex/versions

## Script (preferred)

Use the repo script — do **not** paste ad-hoc `gh api` delete loops:

```bash
# Default = dry-run: list allowlisted stale ids + tags only (exit 0 if none)
./scripts/ghcr-delete-stale.sh

# Optional read-only dump of every package version (debug; never deletes)
./scripts/ghcr-delete-stale.sh --all-versions

# Delete only allowlisted version ids (prints each id before DELETE)
./scripts/ghcr-delete-stale.sh --delete
```

Overrides: `OWNER=… PACKAGE=…` (defaults `etiennemunnich` / `envoy-modsec-connex`).

The script uses `gh api` + the logged-in user. It stores no secrets and does **not** widen auth.

## Scopes (human must refresh once)

Mac `gh` token historically had only `gist`, `read:org`, `repo`, `workflow`. Listing or deleting package versions needs **`read:packages`** (+ **`delete:packages`** for `--delete`):

```text
GET /users/etiennemunnich/packages/container/envoy-modsec-connex/versions
→ 403  You need at least read:packages scope to get a package's versions.
```

On 403 the script prints this exact refresh command and exits non-zero:

```bash
gh auth refresh -h github.com -s read:packages,delete:packages,gist,read:org,repo,workflow
```

Then re-run `./scripts/ghcr-delete-stale.sh` (dry-run) and, when the list looks right, `./scripts/ghcr-delete-stale.sh --delete`. Re-list to confirm those tags are gone. No connector code change is required.

## Issue

Tracking (predecessor repo): [#9](https://github.com/etiennemunnich/envoy-modsec-connex/issues/9) — **GHCR: delete stale v0.1.0-rc.1 and sha-770ab01-* versions** on package `envoy-modsec-connex`. New releases on this repo publish `ghcr.io/etiennemunnich/modsec-envoy-connector`.
