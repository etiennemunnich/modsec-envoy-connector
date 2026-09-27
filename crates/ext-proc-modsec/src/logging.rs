//! Minimal `tracing` subscriber: one line per event on stderr.
//!
//! Line format matches `tracing-subscriber`'s default formatter (which
//! `demo/scripts/hop-trace.sh` parses):
//! `<RFC 3339 UTC> <LEVEL> <target>: <message> key=value …`, with string
//! fields quoted. Spans are accepted but not rendered; the connector opens
//! none.
//!
//! `RUST_LOG` is a comma-separated list of `<level>` (default for every
//! target) and `<target>=<level>` (target or module-path prefix). Levels:
//! `off`, `error`, `warn`, `info`, `debug`, `trace`. Default `info`.

use std::fmt::{self, Write as _};
use std::io::Write as _;
use std::str::FromStr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use tracing::field::{Field, Visit};
use tracing::level_filters::LevelFilter;
use tracing::span::{Attributes, Id, Record};
use tracing::{Event, Metadata, Subscriber};

/// Install the stderr logger as the global subscriber, configured from
/// `RUST_LOG`.
pub fn init() {
    let spec = std::env::var("RUST_LOG").unwrap_or_default();
    let _ =
        tracing::subscriber::set_global_default(Logger::new(Filter::parse(&spec), Sink::Stderr));
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Filter {
    default: LevelFilter,
    targets: Vec<(String, LevelFilter)>,
}

impl Filter {
    /// Parse a `RUST_LOG`-style spec. Unparseable directives are ignored.
    pub fn parse(spec: &str) -> Self {
        let mut filter = Self {
            default: LevelFilter::INFO,
            targets: Vec::new(),
        };
        for directive in spec.split(',').map(str::trim).filter(|d| !d.is_empty()) {
            match directive.split_once('=') {
                Some((target, level)) => {
                    if let Ok(level) = LevelFilter::from_str(level.trim()) {
                        filter.targets.push((target.trim().to_owned(), level));
                    }
                }
                None => {
                    if let Ok(level) = LevelFilter::from_str(directive) {
                        filter.default = level;
                    }
                }
            }
        }
        // Longest (most specific) prefix first.
        filter
            .targets
            .sort_by_key(|(t, _)| std::cmp::Reverse(t.len()));
        filter
    }

    fn level_for(&self, target: &str) -> LevelFilter {
        self.targets
            .iter()
            .find(|(t, _)| {
                target == t
                    || target
                        .strip_prefix(t.as_str())
                        .is_some_and(|rest| rest.starts_with("::"))
            })
            .map_or(self.default, |(_, l)| *l)
    }

    pub fn enabled(&self, meta: &Metadata<'_>) -> bool {
        *meta.level() <= self.level_for(meta.target())
    }

    fn max_level(&self) -> LevelFilter {
        self.targets
            .iter()
            .map(|(_, l)| *l)
            .fold(self.default, std::cmp::max)
    }
}

enum Sink {
    Stderr,
    #[cfg(test)]
    Buffer(std::sync::Arc<std::sync::Mutex<String>>),
}

struct Logger {
    filter: Filter,
    sink: Sink,
    next_span: AtomicU64,
}

impl Logger {
    fn new(filter: Filter, sink: Sink) -> Self {
        Self {
            filter,
            sink,
            next_span: AtomicU64::new(1),
        }
    }
}

impl Subscriber for Logger {
    fn enabled(&self, meta: &Metadata<'_>) -> bool {
        self.filter.enabled(meta)
    }

    fn max_level_hint(&self) -> Option<LevelFilter> {
        Some(self.filter.max_level())
    }

    fn new_span(&self, _: &Attributes<'_>) -> Id {
        Id::from_u64(self.next_span.fetch_add(1, Ordering::Relaxed))
    }

    fn record(&self, _: &Id, _: &Record<'_>) {}

    fn record_follows_from(&self, _: &Id, _: &Id) {}

    fn event(&self, event: &Event<'_>) {
        let line = format_line(SystemTime::now(), event);
        match &self.sink {
            Sink::Stderr => {
                let _ = std::io::stderr().lock().write_all(line.as_bytes());
            }
            #[cfg(test)]
            Sink::Buffer(buf) => buf.lock().unwrap().push_str(&line),
        }
    }

    fn enter(&self, _: &Id) {}

    fn exit(&self, _: &Id) {}
}

#[derive(Default)]
struct Fields {
    message: String,
    rest: String,
}

impl Visit for Fields {
    fn record_debug(&mut self, field: &Field, value: &dyn fmt::Debug) {
        if field.name() == "message" {
            let _ = write!(self.message, "{value:?}");
        } else {
            let _ = write!(self.rest, " {}={value:?}", field.name());
        }
    }
}

fn format_line(now: SystemTime, event: &Event<'_>) -> String {
    let mut fields = Fields::default();
    event.record(&mut fields);
    let meta = event.metadata();
    format!(
        "{} {:>5} {}: {}{}\n",
        rfc3339_utc(now),
        meta.level().as_str(),
        meta.target(),
        fields.message,
        fields.rest
    )
}

fn rfc3339_utc(t: SystemTime) -> String {
    let d = t.duration_since(UNIX_EPOCH).unwrap_or_default();
    let secs = d.as_secs();
    let (y, m, day) = civil_from_days((secs / 86_400) as i64);
    let sod = secs % 86_400;
    format!(
        "{y:04}-{m:02}-{day:02}T{:02}:{:02}:{:02}.{:06}Z",
        sod / 3600,
        sod / 60 % 60,
        sod % 60,
        d.subsec_micros()
    )
}

/// Days since 1970-01-01 → proleptic Gregorian (year, month, day).
/// Howard Hinnant's `civil_from_days`.
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let year = yoe + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    use super::*;

    #[test]
    fn timestamps_are_rfc3339_utc() {
        let at = |s: u64, us: u64| UNIX_EPOCH + Duration::from_secs(s) + Duration::from_micros(us);
        assert_eq!(rfc3339_utc(at(0, 0)), "1970-01-01T00:00:00.000000Z");
        assert_eq!(
            rfc3339_utc(at(951_782_400, 5)),
            "2000-02-29T00:00:00.000005Z"
        );
        assert_eq!(
            rfc3339_utc(at(1_700_000_000, 123_456)),
            "2023-11-14T22:13:20.123456Z"
        );
        assert_eq!(
            rfc3339_utc(at(4_107_542_399, 0)),
            "2100-02-28T23:59:59.000000Z"
        );
    }

    #[test]
    fn filter_directives() {
        let f = Filter::parse("warn, modsecurity=debug ,ext_proc_modsec::metrics=off,bogus=nope");
        assert_eq!(f.level_for("h2::codec"), LevelFilter::WARN);
        assert_eq!(f.level_for("modsecurity"), LevelFilter::DEBUG);
        assert_eq!(f.level_for("modsecurity_x"), LevelFilter::WARN);
        assert_eq!(f.level_for("ext_proc_modsec::metrics"), LevelFilter::OFF);
        assert_eq!(f.level_for("ext_proc_modsec::processor"), LevelFilter::WARN);
        assert_eq!(f.max_level(), LevelFilter::DEBUG);
        assert_eq!(Filter::parse("").level_for("x"), LevelFilter::INFO);
    }

    #[test]
    fn lines_match_the_parsed_format() {
        let buf = Arc::new(Mutex::new(String::new()));
        let logger = Logger::new(Filter::parse("info"), Sink::Buffer(Arc::clone(&buf)));
        tracing::subscriber::with_default(logger, || {
            let rid = "rid-1";
            tracing::info!(
                request_id = rid,
                phase = "request_headers",
                action = "deny",
                latency_ms = 0.5,
                client = %"1.2.3.4:5",
                "modsec phase complete"
            );
            tracing::debug!("filtered out");
        });
        let out = buf.lock().unwrap().clone();
        let line = out.lines().next().expect("one line");
        assert_eq!(out.lines().count(), 1, "{out}");
        assert!(line.ends_with(
            "  INFO ext_proc_modsec::logging::tests: modsec phase complete request_id=\"rid-1\" \
             phase=\"request_headers\" action=\"deny\" latency_ms=0.5 client=1.2.3.4:5"
        ), "{line}");
    }
}
