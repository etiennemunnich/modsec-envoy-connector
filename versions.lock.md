# Pinned versions - envoy-modsec-connex

Source of truth for Envoy, libmodsecurity, CRS, and related tools used by this tree.
Product releases use git tags `vX.Y.Z` + Release notes that quote these axes, **not** GitHub issue labels as versions.

| Axis | Field | Pin | Notes |
|------|-------|-----|-------|
| **E. Envoy** | `ENVOY_PIN` | `v1.39.1` | Fleet / lab ExtProc host |
| **A. Engine / ABI** | `MODSECURITY_PIN` | `v3.0.17` | libmodsecurity latest stable v3 |
| **B. CRS pack** | `CRS_TAG` | `v4.29.0` | Optional LTS: `v4.25.1` |
| **D. Connector** | git SHA / OCI | *(tip SHA)* | Fill at release / image publish |
| **P. Product** | git tag | `v0.1.0` | Semver from here |

## Machine-readable pins

```
ENVOY_PIN=v1.39.1
MODSECURITY_PIN=v3.0.17
CRS_TAG=v4.29.0
CRS_LTS_TAG=v4.25.1
PRODUCT_VERSION=v0.1.0
```

## Upstream references

- Envoy: https://github.com/envoyproxy/envoy/releases/tag/v1.39.1
- ModSecurity: https://github.com/owasp-modsecurity/ModSecurity/releases/tag/v3.0.17
- CRS: https://github.com/coreruleset/coreruleset/releases/tag/v4.29.0

Re-check GitHub Releases before bumps.
