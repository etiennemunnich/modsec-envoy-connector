# GHCR stale package versions — cleanup blocked

**Date:** 2026-09-29  
**Status:** blocked on token scopes (`read:packages` + `delete:packages`)  
**Not merge-blocking** for connector work.

## What remains

GitHub Release + git tag `v0.1.0-rc.1` are **already deleted** (API 404). Accidental / stale **GHCR** container versions may still exist under:

`ghcr.io/etiennemunnich/envoy-modsec-connex`

Targets to remove when scopes allow:

| Tag / version name pattern | Why |
|----------------------------|-----|
| `v0.1.0-rc.1` | Accidental CI-proof pre-release image |
| `sha-770ab01-*` (any arch / digest tags from head `770ab01`) | Stale dispatch image from early release path |

Package UI (signed-in):  
https://github.com/users/etiennemunnich/packages/container/envoy-modsec-connex/versions

## Why agents cannot delete today

Mac `gh` token scopes (2026-09-29): `gist`, `read:org`, `repo`, `workflow` only.

```text
GET /users/etiennemunnich/packages/container/envoy-modsec-connex/versions
→ 403  You need at least read:packages scope to get a package's versions.
```

## Exact commands for Etienne

Re-auth (or add a PAT) with **`read:packages`** and **`delete:packages`**, then:

```bash
# List versions (confirm names / ids)
gh api \
  "/users/etiennemunnich/packages/container/envoy-modsec-connex/versions?per_page=100" \
  --jq '.[] | {id, name: .name, tags: .metadata.container.tags, updated: .updated_at}'

# Delete by version id (repeat per stale version)
# Replace VERSION_ID with each matching id from the list above.
gh api -X DELETE \
  "/users/etiennemunnich/packages/container/envoy-modsec-connex/versions/VERSION_ID"

# Optional: filter locally for the known stale tags
gh api \
  "/users/etiennemunnich/packages/container/envoy-modsec-connex/versions?per_page=100" \
  --jq '.[] | select(
    (.metadata.container.tags // []) as $t
    | ($t | index("v0.1.0-rc.1") != null)
      or (any($t[]; startswith("sha-770ab01")))
  ) | .id' \
  | while read -r id; do
      echo "deleting version id=$id"
      gh api -X DELETE \
        "/users/etiennemunnich/packages/container/envoy-modsec-connex/versions/$id"
    done
```

After delete, re-list and confirm those tags are gone. No connector code change is required.

## Issue

Tracking: open/keep a repo issue titled **"GHCR: delete stale v0.1.0-rc.1 and sha-770ab01-* versions"** with a link to this note if one is not already open.
