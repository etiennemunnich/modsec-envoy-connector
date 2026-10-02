//! Envoy `ext_proc` → libmodsecurity connector.
//!
//! Envoy's `ext_proc` filter streams each HTTP exchange (request headers,
//! request body, response headers, response body) to [`ModSecProcessor`] over
//! gRPC. The processor feeds every phase into one ModSecurity transaction and
//! answers Continue, a rule-driven `ImmediateResponse`, or a fail-closed 500.
//! FFI lives in the `modsec-engine` crate; this crate has no `unsafe`.

#![forbid(unsafe_code)]

pub mod config;
pub mod connection_meta;
pub mod logging;
pub mod metrics;
pub mod metrics_server;
/// Envoy ext_proc v3 messages and gRPC service, generated from the vendored
/// `proto/` tree by `scripts/gen-protos.sh`. Do not edit.
#[allow(clippy::all, rustdoc::all, missing_docs)]
pub mod pb;
pub mod processor;
pub mod responses;

pub use config::{BodyReply, Config};
pub use processor::ModSecProcessor;
