//! Process-wide in-flight ModSec stream admission.
//!
//! Caps concurrent `Process` streams (one HTTP exchange each). Over-cap
//! refuses the new stream with a non-OK gRPC status so Envoy
//! (`failure_mode_allow: false`) answers 500 without contacting origin.
//! Under-cap acquires a permit held until the stream ends.

use std::sync::Arc;

use tokio::sync::{OwnedSemaphorePermit, Semaphore, TryAcquireError};

/// Default process-wide in-flight ModSec stream cap.
pub const DEFAULT_MAX_IN_FLIGHT: u32 = 1024;

/// Process-wide admission gate (shared via [`Arc`]).
#[derive(Debug, Clone)]
pub struct Admission {
    limit: u32,
    sem: Arc<Semaphore>,
}

impl Admission {
    pub fn new(limit: u32) -> Self {
        assert!(limit > 0, "admission limit must be > 0");
        Self {
            limit,
            sem: Arc::new(Semaphore::new(limit as usize)),
        }
    }

    pub fn limit(&self) -> u32 {
        self.limit
    }

    /// Non-blocking: refuse immediately when at capacity (fail-closed).
    pub fn try_enter(&self) -> Result<OwnedSemaphorePermit, ()> {
        match self.sem.clone().try_acquire_owned() {
            Ok(p) => Ok(p),
            Err(TryAcquireError::NoPermits) => Err(()),
            Err(TryAcquireError::Closed) => Err(()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn under_cap_acquires_over_cap_refuses() {
        let gate = Admission::new(1);
        let held = gate.try_enter().expect("first slot");
        assert!(gate.try_enter().is_err(), "over-cap must refuse");
        drop(held);
        assert!(gate.try_enter().is_ok(), "slot freed after drop");
    }
}
