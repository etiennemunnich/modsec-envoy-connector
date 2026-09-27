//! Link the system libmodsecurity (>= 3.0.13) found by the `pkg-config` tool.
//!
//! `MODSECURITY_LIB_DIR` skips pkg-config and links `-lmodsecurity` from that
//! directory (no version check).

use std::env;
use std::process::Command;

const MIN_VERSION: &str = "3.0.13";

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    for var in [
        "MODSECURITY_LIB_DIR",
        "PKG_CONFIG",
        "PKG_CONFIG_PATH",
        "PKG_CONFIG_LIBDIR",
        "PKG_CONFIG_SYSROOT_DIR",
    ] {
        println!("cargo:rerun-if-env-changed={var}");
    }

    if let Ok(dir) = env::var("MODSECURITY_LIB_DIR") {
        println!("cargo:rustc-link-search=native={dir}");
        println!("cargo:rustc-link-lib=modsecurity");
        return;
    }

    let tool = env::var("PKG_CONFIG").unwrap_or_else(|_| "pkg-config".into());
    let version = pkg_config(&tool, &["--modversion", "modsecurity"]).unwrap_or_else(|e| {
        panic!("libmodsecurity not found via {tool}: {e}. Install it or set PKG_CONFIG_PATH / MODSECURITY_LIB_DIR.")
    });
    if pkg_config(&tool, &["--atleast-version", MIN_VERSION, "modsecurity"]).is_err() {
        panic!(
            "libmodsecurity {} found, need >= {MIN_VERSION}",
            version.trim()
        );
    }
    let libs = pkg_config(&tool, &["--libs", "modsecurity"]).unwrap_or_else(|e| panic!("{e}"));
    for flag in libs.split_whitespace() {
        if let Some(dir) = flag.strip_prefix("-L") {
            println!("cargo:rustc-link-search=native={dir}");
        } else if let Some(lib) = flag.strip_prefix("-l") {
            println!("cargo:rustc-link-lib={lib}");
        }
    }
}

fn pkg_config(tool: &str, args: &[&str]) -> Result<String, String> {
    let out = Command::new(tool)
        .args(args)
        .output()
        .map_err(|e| format!("run {tool}: {e}"))?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_owned());
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}
