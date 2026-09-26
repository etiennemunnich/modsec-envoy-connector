# Demo — Envoy + ModSecurity + CRS

Local setup for **envoy-modsec-connex**: install the pinned Envoy, optionally libmodsecurity and OWASP CRS, build this repo’s connector, and wire Envoy’s `ext_proc` filter to it.

Versions used in this tree are listed in [`versions.lock.md`](../versions.lock.md) (Envoy **v1.39.1**, libmodsecurity **v3.0.16**, CRS **v4.29.0**). Confirm those tags before you install.

Architecture and outcomes: [`docs/how-it-works.md`](../docs/how-it-works.md).

## Scripts

| Script | Role |
|--------|------|
| [`scripts/install-envoy.sh`](./scripts/install-envoy.sh) | Verify / pull Envoy **v1.39.1** |
| [`scripts/install-libmodsecurity.sh`](./scripts/install-libmodsecurity.sh) | Verify libmodsecurity **v3.0.16** |
| [`scripts/install-crs.sh`](./scripts/install-crs.sh) | Clone CRS **v4.29.0** into `demo/.crs` |
| [`scripts/smoke.sh`](./scripts/smoke.sh) | Pin check + `cargo build` / `cargo test` |

---

## 1. Envoy Proxy v1.39.1

Official install guide: [Installing Envoy (v1.39.1)](https://www.envoyproxy.io/docs/envoy/v1.39.1/start/install).  
Release: [envoyproxy/envoy v1.39.1](https://github.com/envoyproxy/envoy/releases/tag/v1.39.1).

### macOS (Homebrew)

Homebrew currently bottles **1.39.1**:

```bash
brew update
brew install envoy
envoy --version
```

Expect a version string that includes `1.39.1`. If brew drifts to a newer formula, install from the Docker image or a matching release asset instead of staying on an unpinned `brew upgrade`.

### Linux

The Envoy apt repository is **not** maintained. Prefer one of:

**Docker (amd64 / arm64)**

```bash
docker pull envoyproxy/envoy:v1.39.1
docker run --rm envoyproxy/envoy:v1.39.1 --version
```

**Static binary from GitHub Releases**

Download the asset for your arch from the [v1.39.1 release](https://github.com/envoyproxy/envoy/releases/tag/v1.39.1), for example:

- `envoy-1.39.1-linux-x86_64`
- `envoy-1.39.1-linux-aarch_64`

```bash
chmod +x envoy-1.39.1-linux-x86_64
sudo mv envoy-1.39.1-linux-x86_64 /usr/local/bin/envoy
envoy --version
```

### Version check

```bash
envoy --version
# or
docker run --rm envoyproxy/envoy:v1.39.1 --version
```

Match **v1.39.1** to [`versions.lock.md`](../versions.lock.md).

---

## 2. Connector (this repo)

Rust toolchain required. From the repository root:

```bash
cargo build -p ext-proc-modsec
cargo test --workspace
```

The product binary is `ext-proc-modsec`. Contributor build notes: [`CONTRIBUTING.md`](../CONTRIBUTING.md).

A full listening connector (gRPC `ext_proc` + FFI) is still landing here. Until then, end-to-end compose proofs live in the private lab [`modsec-envoy-experiement`](https://github.com/etiennemunnich/modsec-envoy-experiement).

---

## 3. Wire Envoy → connector

Envoy must call the connector over `ext_proc` and **not** allow traffic through if that call fails. Minimal filter shape:

```yaml
http_filters:
  - name: envoy.filters.http.ext_proc
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.http.ext_proc.v3.ExternalProcessor
      grpc_service:
        envoy_grpc:
          cluster_name: modsec_ext_proc
      failure_mode_allow: false
      message_timeout: 2s
  - name: envoy.filters.http.router
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
```

Point cluster `modsec_ext_proc` at the connector’s gRPC listen address. Hop model and outcomes: [`docs/how-it-works.md`](../docs/how-it-works.md). Runnable compose until migrate: experiment lab above.

---

## 4. libmodsecurity and CRS (optional for native inspection)

Needed when you link or run against a real ModSecurity engine and rule pack.

| Component | Pin | Where to get it |
|-----------|-----|-----------------|
| libmodsecurity | **v3.0.16** | [ModSecurity releases](https://github.com/owasp-modsecurity/ModSecurity/releases/tag/v3.0.16) · macOS: `brew install modsecurity` then `pkg-config --modversion modsecurity` |
| OWASP CRS | **v4.29.0** | [coreruleset v4.29.0](https://github.com/coreruleset/coreruleset/releases/tag/v4.29.0) (optional LTS **v4.25.1**) |

Stub helpers in this tree: [`scripts/install-libmodsecurity.sh`](./scripts/install-libmodsecurity.sh), [`scripts/install-crs.sh`](./scripts/install-crs.sh). Full lab scripts remain in the experiment repo until migrate. Ubuntu/CI builds often compile **v3.0.16** from source because distro packages can lag.

Workspace crates build without a system libmodsecurity until the connector’s native engine feature is enabled.

---

## Smoke path

1. Install Envoy **v1.39.1** (`./scripts/install-envoy.sh` or manual steps above) and confirm `envoy --version`.
2. `cargo build -p ext-proc-modsec` in this repo.
3. Configure Envoy `ext_proc` as above (`failure_mode_allow: false`).
4. For ModSec + CRS end-to-end today, use the experiment lab compose; migrate those scripts here when the connector lands.

---

Copyright © 2026 Etienne Munnich. Licensed under the Apache License, Version 2.0 — see [LICENSE](../LICENSE).
