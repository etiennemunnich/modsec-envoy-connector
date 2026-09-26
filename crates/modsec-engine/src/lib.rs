//! Safe façade over libmodsecurity (scaffold).
//!
//! When the connector migrates from the experiment lab, keep all `unsafe` /
//! FFI inside this crate. `ext-proc-modsec` must not call raw `msc_*`.
//!
//! Fail-closed rule: engine / FFI `Err` maps to [`Decision::FailClosed`] —
//! never a silent allow / Continue upstream.

#![deny(unsafe_code)]

use thiserror::Error;

/// Errors from engine init or per-request processing.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum EngineError {
    /// Rules / engine could not be built trustworthily at boot.
    #[error("modsecurity init failed: {0}")]
    Init(String),
    /// Per-request `msc_*` / phase failure — must not Continue.
    #[error("modsecurity processing failed: {0}")]
    Processing(String),
}

/// Product decision after a ModSec phase (maps to ImmediateResponse / Continue).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Decision {
    Allow,
    Deny {
        status: u16,
    },
    Redirect {
        status: u16,
        location: String,
    },
    /// Engine status 0 / drop — path semantics still Envoy-limited.
    Drop,
    /// Untrustworthy path — ImmediateResponse 500, never Continue.
    FailClosed,
}

impl Decision {
    /// Map engine failure to fail-closed. Body mode does not change this.
    pub fn from_engine_err(_err: &EngineError) -> Self {
        Self::FailClosed
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn processing_err_is_fail_closed() {
        let err = EngineError::Processing("boom".into());
        assert_eq!(Decision::from_engine_err(&err), Decision::FailClosed);
    }

    #[test]
    fn init_err_is_fail_closed() {
        let err = EngineError::Init("bad rules".into());
        assert_eq!(Decision::from_engine_err(&err), Decision::FailClosed);
    }
}
