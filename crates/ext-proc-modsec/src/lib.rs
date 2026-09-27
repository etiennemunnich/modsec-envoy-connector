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
pub mod metrics;
pub mod metrics_server;
pub mod processor;
pub mod responses;

pub use processor::ModSecProcessor;
