//! Connector metrics in Prometheus text exposition format.
//!
//! Hot path is atomics only; scrape renders a snapshot string.

use std::fmt::Write as _;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

/// Latency bucket upper bounds in **seconds** (Prometheus base unit), + `+Inf`.
const LATENCY_BOUNDS_S: [f64; 11] = [
    0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0,
];

#[derive(Debug, Default)]
struct Histogram {
    /// `buckets[i]` = observations in (bound[i-1], bound[i]]; last = +Inf.
    buckets: [AtomicU64; LATENCY_BOUNDS_S.len() + 1],
    sum_micros: AtomicU64,
    count: AtomicU64,
}

impl Histogram {
    fn observe(&self, d: Duration) {
        let secs = d.as_secs_f64();
        let micros = u64::try_from(d.as_micros()).unwrap_or(u64::MAX);
        self.sum_micros.fetch_add(micros, Ordering::Relaxed);
        self.count.fetch_add(1, Ordering::Relaxed);
        let idx = LATENCY_BOUNDS_S
            .iter()
            .position(|b| secs <= *b)
            .unwrap_or(LATENCY_BOUNDS_S.len());
        self.buckets[idx].fetch_add(1, Ordering::Relaxed);
    }

    fn render(&self, name: &str, help: &str, out: &mut String) {
        let _ = writeln!(out, "# HELP {name} {help}");
        let _ = writeln!(out, "# TYPE {name} histogram");
        let mut cumulative = 0u64;
        for (i, bound) in LATENCY_BOUNDS_S.iter().enumerate() {
            cumulative += self.buckets[i].load(Ordering::Relaxed);
            let _ = writeln!(out, "{name}_bucket{{le=\"{bound}\"}} {cumulative}");
        }
        cumulative += self.buckets[LATENCY_BOUNDS_S.len()].load(Ordering::Relaxed);
        let _ = writeln!(out, "{name}_bucket{{le=\"+Inf\"}} {cumulative}");
        let sum_s = self.sum_micros.load(Ordering::Relaxed) as f64 / 1_000_000.0;
        let _ = writeln!(out, "{name}_sum {sum_s}");
        let _ = writeln!(out, "{name}_count {}", self.count.load(Ordering::Relaxed));
    }
}

/// ModSecurity phase, as reported in logs and latency histograms.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    RequestHeaders,
    RequestBody,
    ResponseHeaders,
    ResponseBody,
}

impl Phase {
    pub fn as_str(self) -> &'static str {
        match self {
            Phase::RequestHeaders => "request_headers",
            Phase::RequestBody => "request_body",
            Phase::ResponseHeaders => "response_headers",
            Phase::ResponseBody => "response_body",
        }
    }
}

/// Process-wide connector counters. Share via `Arc`.
#[derive(Debug, Default)]
pub struct ConnectorMetrics {
    requests: AtomicU64,
    allow: AtomicU64,
    deny: AtomicU64,
    fail_closed: AtomicU64,
    stream_errors: AtomicU64,
    request_body_bytes: AtomicU64,
    response_body_bytes: AtomicU64,
    phase_request_headers: Histogram,
    phase_request_body: Histogram,
    phase_response_headers: Histogram,
    phase_response_body: Histogram,
}

impl ConnectorMetrics {
    pub fn observe_phase(&self, phase: Phase, d: Duration) {
        match phase {
            Phase::RequestHeaders => self.phase_request_headers.observe(d),
            Phase::RequestBody => self.phase_request_body.observe(d),
            Phase::ResponseHeaders => self.phase_response_headers.observe(d),
            Phase::ResponseBody => self.phase_response_body.observe(d),
        }
    }

    pub fn add_body_bytes(&self, phase: Phase, n: u64) {
        match phase {
            Phase::RequestBody => self.request_body_bytes.fetch_add(n, Ordering::Relaxed),
            Phase::ResponseBody => self.response_body_bytes.fetch_add(n, Ordering::Relaxed),
            Phase::RequestHeaders | Phase::ResponseHeaders => 0,
        };
    }

    pub fn inc_requests(&self) {
        self.requests.fetch_add(1, Ordering::Relaxed);
    }

    pub fn inc_allow(&self) {
        self.allow.fetch_add(1, Ordering::Relaxed);
    }

    pub fn inc_deny(&self) {
        self.deny.fetch_add(1, Ordering::Relaxed);
    }

    pub fn inc_fail_closed(&self) {
        self.fail_closed.fetch_add(1, Ordering::Relaxed);
    }

    pub fn inc_stream_errors(&self) {
        self.stream_errors.fetch_add(1, Ordering::Relaxed);
    }

    pub fn deny_total(&self) -> u64 {
        self.deny.load(Ordering::Relaxed)
    }

    pub fn fail_closed_total(&self) -> u64 {
        self.fail_closed.load(Ordering::Relaxed)
    }

    pub fn allow_total(&self) -> u64 {
        self.allow.load(Ordering::Relaxed)
    }

    /// Render Prometheus text exposition (format 0.0.4).
    pub fn render(&self) -> String {
        let mut out = String::with_capacity(4096);
        let counters: [(&str, &str, &AtomicU64); 7] = [
            (
                "ext_proc_requests_total",
                "HTTP exchanges seen (request_headers messages)",
                &self.requests,
            ),
            (
                "ext_proc_allow_total",
                "Exchanges whose request path completed with no disruptive intervention",
                &self.allow,
            ),
            (
                "ext_proc_deny_total",
                "Disruptive ModSecurity interventions (deny / redirect / drop)",
                &self.deny,
            ),
            (
                "ext_proc_fail_closed_total",
                "Fail-closed responses (engine error or protocol violation)",
                &self.fail_closed,
            ),
            (
                "ext_proc_stream_errors_total",
                "gRPC stream read errors from Envoy",
                &self.stream_errors,
            ),
            (
                "ext_proc_request_body_bytes_total",
                "Request body bytes appended to libmodsecurity",
                &self.request_body_bytes,
            ),
            (
                "ext_proc_response_body_bytes_total",
                "Response body bytes appended to libmodsecurity",
                &self.response_body_bytes,
            ),
        ];
        for (name, help, v) in counters {
            let _ = writeln!(out, "# HELP {name} {help}");
            let _ = writeln!(out, "# TYPE {name} counter");
            let _ = writeln!(out, "{name} {}", v.load(Ordering::Relaxed));
        }
        let histograms = [
            (
                &self.phase_request_headers,
                "ext_proc_phase_request_headers_seconds",
                "Wall time in the ModSecurity request-headers phase",
            ),
            (
                &self.phase_request_body,
                "ext_proc_phase_request_body_seconds",
                "Wall time in the ModSecurity request-body phase (append + process)",
            ),
            (
                &self.phase_response_headers,
                "ext_proc_phase_response_headers_seconds",
                "Wall time in the ModSecurity response-headers phase",
            ),
            (
                &self.phase_response_body,
                "ext_proc_phase_response_body_seconds",
                "Wall time in the ModSecurity response-body phase (append + process)",
            ),
        ];
        for (h, name, help) in histograms {
            h.render(name, help, &mut out);
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn histogram_buckets_are_seconds_and_cumulative() {
        let m = ConnectorMetrics::default();
        m.observe_phase(Phase::RequestHeaders, Duration::from_micros(300));
        m.observe_phase(Phase::RequestHeaders, Duration::from_millis(20));
        m.observe_phase(Phase::RequestHeaders, Duration::from_secs(3));
        let text = m.render();
        let name = "ext_proc_phase_request_headers_seconds";
        assert!(text.contains(&format!("{name}_bucket{{le=\"0.0005\"}} 1\n")));
        assert!(text.contains(&format!("{name}_bucket{{le=\"0.025\"}} 2\n")));
        assert!(text.contains(&format!("{name}_bucket{{le=\"1\"}} 2\n")));
        assert!(text.contains(&format!("{name}_bucket{{le=\"+Inf\"}} 3\n")));
        assert!(text.contains(&format!("{name}_count 3\n")));
        assert!(text.contains(&format!("{name}_sum 3.0203\n")), "{text}");
    }

    #[test]
    fn counters_render() {
        let m = ConnectorMetrics::default();
        m.inc_requests();
        m.inc_deny();
        m.inc_fail_closed();
        m.add_body_bytes(Phase::RequestBody, 10);
        m.add_body_bytes(Phase::ResponseBody, 7);
        let text = m.render();
        assert!(text.contains("ext_proc_requests_total 1\n"));
        assert!(text.contains("ext_proc_deny_total 1\n"));
        assert!(text.contains("ext_proc_fail_closed_total 1\n"));
        assert!(text.contains("ext_proc_request_body_bytes_total 10\n"));
        assert!(text.contains("ext_proc_response_body_bytes_total 7\n"));
        assert_eq!(m.deny_total(), 1);
    }
}
