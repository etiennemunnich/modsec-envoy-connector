//! Regenerates `crates/ext-proc-modsec/src/pb/` from the vendored `proto/`
//! tree (Envoy ext_proc v3 and its import closure).
//!
//! Files that only declare custom options (validate, udpa/xds/envoy
//! annotations, descriptor.proto) are dropped before codegen: prost ignores
//! extensions, so they would only add unused types.

use std::path::{Path, PathBuf};
use std::process::Command;

use prost::Message;
use prost_types::FileDescriptorSet;

const ENTRY: &str = "envoy/service/ext_proc/v3/external_processor.proto";

const OPTION_ONLY: &[&str] = &[
    "google/protobuf/descriptor.proto",
    "validate/",
    "udpa/annotations/",
    "xds/annotations/",
    "envoy/annotations/",
];

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let repo = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let proto = repo.join("proto").canonicalize()?;
    let out = repo.join("crates/ext-proc-modsec/src/pb");

    let fds = descriptor_set(&proto)?;
    let mut fds = FileDescriptorSet::decode(fds.as_slice())?;
    fds.file
        .retain(|f| !OPTION_ONLY.iter().any(|p| f.name().starts_with(p)));
    let kept: Vec<&str> = fds.file.iter().map(|f| f.name()).collect();
    eprintln!("generating {} files: {}", kept.len(), kept.join(" "));

    if out.exists() {
        std::fs::remove_dir_all(&out)?;
    }
    std::fs::create_dir_all(&out)?;

    tonic_prost_build::configure()
        .build_server(true)
        .build_client(true)
        .build_transport(false)
        .compile_well_known_types(true)
        .include_file("mod.rs")
        .out_dir(&out)
        .compile_fds(fds)?;
    Ok(())
}

fn descriptor_set(proto: &Path) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    let protoc = std::env::var("PROTOC").unwrap_or_else(|_| "protoc".into());
    let tmp = std::env::temp_dir().join(format!("connex-protogen-{}.fds", std::process::id()));
    let status = Command::new(&protoc)
        .current_dir(proto)
        .arg("-I")
        .arg(proto)
        .arg("--include_imports")
        .arg("--include_source_info")
        .arg(format!("--descriptor_set_out={}", tmp.display()))
        .arg(ENTRY)
        .status()
        .map_err(|e| format!("run {protoc}: {e}"))?;
    if !status.success() {
        return Err(format!("{protoc} failed: {status}").into());
    }
    let bytes = std::fs::read(&tmp)?;
    let _ = std::fs::remove_file(&tmp);
    Ok(bytes)
}
