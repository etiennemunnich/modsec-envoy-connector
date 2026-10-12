# Pinned versions — modsec-envoy-connector

Source of truth for Envoy, libmodsecurity, CRS, and related tools used by this tree.
Product releases use git tags `vX.Y.Z` (+ optional pre-release suffix) and Release
notes that quote these axes ([`CHANGELOG.md`](./CHANGELOG.md)), **not** GitHub issue
labels as versions.

| Axis | Field | Pin | Notes |
|------|-------|-----|-------|
| **E. Envoy** | `ENVOY_PIN` | `v1.39.4` | Fleet / lab ExtProc host |
| **A. Engine / ABI** | `MODSECURITY_PIN` | `v3.0.17` | libmodsecurity latest stable v3 |
| **B. CRS pack** | `CRS_TAG` | `v4.30.0` | Optional LTS: `v4.25.2` |
| **D. Connector** | git SHA / OCI | *(tip SHA at tag)* | Filled when `v0.1.0-alpha.1` is tagged / image published |
| **P. Product** | git tag | `v0.1.0-alpha.1` | Early-test pre-release; crate semver stays `0.1.0` until final |
| **T. go-ftw** | `GO_FTW_PIN` | `v2.6.0` | CRS regression runner; `demo/scripts/install-go-ftw.sh` (local and CI) |
| **S. ASH** | `ASH_PIN` | `af1206aff596f1288ad066828058b3011de2a998` | awslabs/automated-security-helper v3.7.1 tip (commit, not tag) |

### Consumers

- **Install / demo scripts** read `ENVOY_PIN`, `MODSECURITY_PIN`, `CRS_TAG` (and optional `CRS_LTS_TAG`).
- **Crate version** in `crates/*/Cargo.toml` is `0.1.0`. A tag like `v0.1.0-alpha.1` is valid: the release workflow compares the `vX.Y.Z` prefix to the crate version.
- **Alpha / UAT:** [docs/modes/uat.md](./docs/modes/uat.md). Do not treat an alpha tag as production-supported.

## Machine-readable pins

```
ENVOY_PIN=v1.39.4
MODSECURITY_PIN=v3.0.17
CRS_TAG=v4.30.0
CRS_LTS_TAG=v4.25.2
PRODUCT_VERSION=v0.1.0-alpha.1
ASH_PIN=af1206aff596f1288ad066828058b3011de2a998
GO_FTW_PIN=v2.6.0
```

## Upstream references

- Envoy: https://github.com/envoyproxy/envoy/releases/tag/v1.39.4
- ModSecurity: https://github.com/owasp-modsecurity/ModSecurity/releases/tag/v3.0.17
- CRS: https://github.com/coreruleset/coreruleset/releases/tag/v4.30.0
- ASH: https://github.com/awslabs/automated-security-helper/commit/af1206aff596f1288ad066828058b3011de2a998 (tag `v3.7.1`)

Re-check GitHub Releases before bumps. Bump `ASH_PIN` by editing this file and the `pip install …@<sha>` line in `.github/workflows/ash.yml` together (`pin-check` asserts they match).
