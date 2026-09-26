//! Envoy ExternalProcessor → libmodsecurity connector (scaffold).
//!
//! Full tonic/FFI implementation remains in the experiment lab until a
//! deliberate migrate. This binary proves the workspace links and exits
//! non-zero so nobody mistakes it for a listening WAF.

#![deny(unsafe_code)]

use modsec_engine::Decision;

fn main() {
    // Keep fail-closed Decision in the link graph before migrate.
    let _guard = Decision::FailClosed;
    eprintln!(
        "ext-proc-modsec 0.1.0 scaffold — connector not migrated yet.\n\
         See AGENTS.md and CONTRIBUTING.md; runnable proofs live in modsec-envoy-experiement."
    );
    std::process::exit(1);
}
