//! Process-wide in-flight ModSec stream admission.
//!
//! Caps concurrent `Process` streams (one HTTP exchange each). Over-cap
//! refuses the new stream with a non-OK gRPC status so Envoy
//! (`failure_mode_allow: false`) answers 500 without contacting origin.
//! Under-cap acquires a permit held until the stream ends.

use std::sync::Arc;

use tokio::sync::{OwnedSemaphorePermit, Semaphore};

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
    pub fn try_enter(&self) -> Option<OwnedSemaphorePermit> {
        self.sem.clone().try_acquire_owned().ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn under_cap_acquires_over_cap_refuses() {
        let gate = Admission::new(1);
        let held = gate.try_enter().expect("first slot");
        assert!(gate.try_enter().is_none(), "over-cap must refuse");
        drop(held);
        assert!(gate.try_enter().is_some(), "slot freed after drop");
    }
}
