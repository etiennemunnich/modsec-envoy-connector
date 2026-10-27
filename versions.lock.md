# Pinned versions — modsec-envoy-connector

Source of truth for Envoy, libmodsecurity, CRS, and related tools used by this tree.
Product releases use git tags `vX.Y.Z` (+ optional pre-release suffix) and Release
notes that quote these axes ([`CHANGELOG.md`](./CHANGELOG.md)), **not** GitHub issue
labels as versions.

| Axis | Field | Pin | Notes |
|------|-------|-----|-------|
| **E. Envoy** | `ENVOY_PIN` | `v1.39.6` | Fleet / lab ExtProc host |
| **E′. DM SDK** | `DYNAMIC_MODULES_SDK_REV` | `v1.39.6` (= `ENVOY_PIN` tag) | `envoy-proxy-dynamic-modules-rust-sdk` git tag; rebuild `.so` on every Envoy bump. Artifact: `lib/libmodsec_dm.so` inside `ext-proc-modsec-<ver>-linux-<arch>.tar.gz` and the GHCR image `/usr/local/lib/` (same package as ext_proc; no separate module image). First published tag: `v0.1.0-alpha.4` (#36 packaging). Per-arch module sha256 recorded in the D-row. Forbid tip examples `.so`. |
| **A. Engine / ABI** | `MODSECURITY_PIN` | `v3.0.17` | libmodsecurity latest stable v3 |
| **B. CRS pack** | `CRS_TAG` | `v4.30.0` | Optional LTS: `v4.25.2` |
| **D. Connector** | git SHA / OCI | `80f61931e59dc9a19286cb107d3412ee812fe012` / `ghcr.io/etiennemunnich/modsec-envoy-connector@sha256:c6a781f5d3c98015f6166a6fe0786d73aae5d704e1c81f4a55cba2c2d063ae33` | Last published image: `v0.1.0-alpha.4`, [release run 40083369885](https://github.com/etiennemunnich/modsec-envoy-connector/actions/runs/40083369885). Multi-arch index digest for that tag ([deploy.md](./docs/deploy.md)). Install tag: `:v0.1.0-alpha.4` (no `latest`). Module sha256 (tarball `lib/libmodsec_dm.so`): x86_64 `e51302aad09bb43ca17a62f5943353aec4c61d1b5cdbb80ab54e48a1cbbf2d02`, aarch64 `37d085435cfe6fadff70515d7686410a66239451e027ec78468d29be61ff018b`. |
| **P. Product** | git tag | `v0.1.0-alpha.4` | Early-test pre-release; the crates carry the same version (`0.1.0-alpha.4`). First tag with published `libmodsec_dm.so`. Do not use `v0.1.0-alpha.1` ([`CHANGELOG.md`](./CHANGELOG.md)). |
| **T. go-ftw** | `GO_FTW_PIN` | `v2.6.0` | CRS regression runner; `demo/scripts/install-go-ftw.sh` (local and CI) |
| **S. ASH** | `ASH_PIN` | `af1206aff596f1288ad066828058b3011de2a998` | awslabs/automated-security-helper v3.7.1 tip (commit, not tag) |

### Consumers

- **Install / demo scripts** read `ENVOY_PIN`, `MODSECURITY_PIN`, `CRS_TAG` (and optional `CRS_LTS_TAG`).
- **Crate version** in `crates/*/Cargo.toml` is `0.1.0-alpha.4`. The release workflow accepts only the tag `v` + that version, pre-release included ([`scripts/release-version.sh`](./scripts/release-version.sh)).
- **Alpha:** early-tester checklist in [docs/getting-started.md](./docs/getting-started.md#early-tester-checklist). Do not treat an alpha tag as production-supported.

## Machine-readable pins

```
ENVOY_PIN=v1.39.6
DYNAMIC_MODULES_SDK_REV=v1.39.6
MODSECURITY_PIN=v3.0.17
CRS_TAG=v4.30.0
CRS_LTS_TAG=v4.25.2
PRODUCT_VERSION=v0.1.0-alpha.4
ASH_PIN=af1206aff596f1288ad066828058b3011de2a998
GO_FTW_PIN=v2.6.0
```

## Upstream references

- Envoy: https://github.com/envoyproxy/envoy/releases/tag/v1.39.6
- ModSecurity: https://github.com/owasp-modsecurity/ModSecurity/releases/tag/v3.0.17
- CRS: https://github.com/coreruleset/coreruleset/releases/tag/v4.30.0
- ASH: https://github.com/awslabs/automated-security-helper/commit/af1206aff596f1288ad066828058b3011de2a998 (tag `v3.7.1`)

Re-check GitHub Releases before bumps. Bump `ASH_PIN` by editing this file and the `pip install …@<sha>` line in `.github/workflows/ash.yml` together (`pin-check` asserts they match).
