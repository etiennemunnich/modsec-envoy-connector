#!/usr/bin/env bash
# Regenerate crates/ext-proc-modsec/src/pb/ from the vendored proto/ tree.
# Only this script needs protoc; normal builds use the committed output.
#
#   ./scripts/gen-protos.sh           regenerate in place
#   ./scripts/gen-protos.sh --check   fail if the committed code is stale
#
# proto/ is the import closure of envoy/service/ext_proc/v3/external_processor.proto:
#   envoy/**                  envoyproxy/envoy  api/ @ v1.39.1 (b579d07d3ad7ee11d32b105e91a5a39ad24718d7)
#   xds/**, udpa/**           cncf/xds @ 8bfbf64dc13ee1a570be4fbdcfccbdd8532463f0
#   validate/validate.proto   bufbuild/protoc-gen-validate v1.3.3
#   google/protobuf/*.proto   protocolbuffers/protobuf well-known types
# (xds + PGV revisions are the ones Envoy v1.39.1 pins in api/bazel/repository_locations.bzl.)
# On an Envoy bump: refresh proto/ from the new tag, then rerun this script.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v "${PROTOC:-protoc}" >/dev/null || { echo "protoc not found (set PROTOC)" >&2; exit 2; }
cargo run -q --manifest-path tools/protogen/Cargo.toml

if [[ "${1:-}" == "--check" ]]; then
  if [[ -n "$(git status --porcelain -- crates/ext-proc-modsec/src/pb)" ]]; then
    git status --short -- crates/ext-proc-modsec/src/pb >&2
    echo "generated ext_proc code is stale — run ./scripts/gen-protos.sh and commit" >&2
    exit 1
  fi
  echo "OK: crates/ext-proc-modsec/src/pb matches proto/"
fi
