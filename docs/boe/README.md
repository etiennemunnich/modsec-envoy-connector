# Built on Envoy: alignment notes (internal archive)

> **Archive.** Catalog prep only. **Do not submit** to Built on Envoy until Etienne asks.
> Product docs: [docs/modes](../modes/README.md).


**Do not submit to the Built on Envoy catalog from this repository until Etienne explicitly asks.**

## Product type

Use **`type: ext_proc`**, not Rust/Go dynamic modules.

| BoE doc | Relevance |
|---------|-----------|
| [Extension types](https://builtonenvoy.io/docs/extension-types/) | Defines `ext_proc` + `extProc` block (`grpcPort`, `failureModeAllow`, `processingMode`) |
| [Writing Rust extensions](https://builtonenvoy.io/docs/writing-rust-extensions/) | Describes **in-process** Rust dynamic modules, **not** this WAF's runtime model |
| [Running local extensions](https://builtonenvoy.io/docs/running-local-extensions/) | `boe create` / `boe run --local` today centered on go/rust DM templates |
| [Packaging for prod](https://builtonenvoy.io/docs/packaging-prod/) | OCI `.so` Dynamic Modules; connector will need a **binary/container** packaging story instead |
| [Security considerations](https://builtonenvoy.io/docs/security-considerations/) | In-process risks reinforce choosing out-of-process `ext_proc` for libmodsecurity |

Draft manifest: [`manifest.yaml`](./manifest.yaml).

## Gap summary

See [`../design-readiness-and-tests.md`](../design-readiness-and-tests.md) §4. Catalog status: **not ready**.
