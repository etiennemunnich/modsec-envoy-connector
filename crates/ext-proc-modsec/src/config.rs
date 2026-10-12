//! Command-line / environment configuration.
//!
//! Each flag falls back to an environment variable; the command line wins.

use std::fmt;
use std::net::SocketAddr;
use std::path::PathBuf;

pub const USAGE: &str = "\
Envoy ExternalProcessor that inspects HTTP traffic with libmodsecurity (fail-closed)

Usage: ext-proc-modsec --modsec-rules <FILE>... [OPTIONS]

Options:
      --listen <ADDR>          gRPC listen address for Envoy's ext_proc filter
                               [env: EXT_PROC_LISTEN] [default: 127.0.0.1:18081]
      --metrics-listen <ADDR>  Metrics + readiness listen address (GET /metrics, GET /healthz)
                               [env: EXT_PROC_METRICS_LISTEN] [default: 127.0.0.1:18082]
      --modsec-rules <FILE>... ModSecurity rules files, loaded in order (repeatable or
                               comma-separated). At least one is required.
                               [env: MODSEC_RULES]
      --body-reply <MODE>      How Continue answers HttpBody messages:
                               common (default) — BodyResponse/CommonResponse for
                               BUFFERED / BUFFERED_PARTIAL / STREAMED / NONE;
                               streamed — BodyMutation.streamed_response
                               (StreamedBodyResponse) for FULL_DUPLEX_STREAMED.
                               [env: EXT_PROC_BODY_REPLY] [default: common]
      --max-grpc-message-bytes <N>
                               Largest ProcessingRequest accepted from Envoy, in bytes.
                               A larger message (e.g. a BUFFERED body when Envoy's buffer
                               limit is raised past N) ends the stream with gRPC INTERNAL,
                               which Envoy (failure_mode_allow: false) answers with 500.
                               Keep N above Envoy's per_connection_buffer_limit_bytes
                               plus the header block.
                               [env: EXT_PROC_MAX_GRPC_MESSAGE_BYTES] [default: 4194304]
      --max-held-body-bytes <N>
                               --body-reply streamed only: largest body (per direction)
                               held until ModSecurity allows it; past N the exchange
                               fails closed with 500. At most --max-grpc-message-bytes.
                               [env: EXT_PROC_MAX_HELD_BODY_BYTES]
                               [default: --max-grpc-message-bytes]
  -h, --help                   Print help
  -V, --version                Print version

Logging: RUST_LOG=<level>[,<target>=<level>...] (default info).
";

const DEFAULT_LISTEN: &str = "127.0.0.1:18081";
const DEFAULT_METRICS_LISTEN: &str = "127.0.0.1:18082";
/// tonic's own default decode limit; above Envoy's default 1 MiB buffer limit.
pub const DEFAULT_MAX_GRPC_MESSAGE_BYTES: usize = 4 * 1024 * 1024;
/// Outbound messages may exceed the inbound limit by this much, so a held
/// body of `max_held_body_bytes` always fits in one `StreamedBodyResponse`.
pub const REPLY_ENVELOPE_BYTES: usize = 64 * 1024;

/// Wire shape used when Continue-answering an `HttpBody` message.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum BodyReply {
    /// Empty `BodyResponse` / `CommonResponse` (BUFFERED, BUFFERED_PARTIAL, STREAMED).
    #[default]
    Common,
    /// Echo chunk via `StreamedBodyResponse` (FULL_DUPLEX_STREAMED).
    Streamed,
}

impl BodyReply {
    fn parse(value: &str) -> Option<Self> {
        match value {
            "common" => Some(Self::Common),
            "streamed" => Some(Self::Streamed),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Common => "common",
            Self::Streamed => "streamed",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Config {
    /// gRPC listen address for Envoy's `ext_proc` filter.
    pub listen: SocketAddr,
    /// Metrics + readiness listen address (`GET /metrics`, `GET /healthz`).
    pub metrics_listen: SocketAddr,
    /// ModSecurity rules files, loaded in order. Never empty: the connector
    /// never runs without an engine.
    pub modsec_rules: Vec<PathBuf>,
    /// Continue shape for body messages — must match Envoy `request_body_mode`.
    pub body_reply: BodyReply,
    pub limits: Limits,
}

/// Per-stream size bounds.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Limits {
    /// tonic `max_decoding_message_size`; outbound is this plus
    /// [`REPLY_ENVELOPE_BYTES`].
    pub max_grpc_message_bytes: usize,
    /// `BodyReply::Streamed`: bytes held per direction before failing closed.
    /// Never above `max_grpc_message_bytes`.
    pub max_held_body_bytes: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            max_grpc_message_bytes: DEFAULT_MAX_GRPC_MESSAGE_BYTES,
            max_held_body_bytes: DEFAULT_MAX_GRPC_MESSAGE_BYTES,
        }
    }
}

impl Limits {
    pub fn max_encoding_message_bytes(&self) -> usize {
        self.max_grpc_message_bytes
            .saturating_add(REPLY_ENVELOPE_BYTES)
    }
}

/// Outcome of parsing the command line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Command {
    Run(Config),
    Help,
    Version,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConfigError {
    MissingRules,
    MissingValue(&'static str),
    UnknownArgument(String),
    InvalidAddress { flag: &'static str, value: String },
    InvalidBodyReply(String),
    InvalidBytes { flag: &'static str, value: String },
    HeldBodyAboveMessageLimit { held: usize, message: usize },
}

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingRules => {
                f.write_str("at least one --modsec-rules <FILE> (or MODSEC_RULES) is required")
            }
            Self::MissingValue(flag) => write!(f, "{flag} needs a value"),
            Self::UnknownArgument(a) => write!(f, "unexpected argument '{a}'"),
            Self::InvalidAddress { flag, value } => {
                write!(f, "invalid socket address '{value}' for {flag}")
            }
            Self::InvalidBodyReply(value) => {
                write!(f, "invalid --body-reply '{value}' (want common|streamed)")
            }
            Self::InvalidBytes { flag, value } => {
                write!(
                    f,
                    "invalid byte count '{value}' for {flag} (want an integer > 0)"
                )
            }
            Self::HeldBodyAboveMessageLimit { held, message } => write!(
                f,
                "--max-held-body-bytes {held} exceeds --max-grpc-message-bytes {message}: \
                 the held body could not be sent back in one message"
            ),
        }
    }
}

impl std::error::Error for ConfigError {}

impl Config {
    /// Parse `std::env::args()` with `std::env::var` fallbacks.
    pub fn from_env() -> Result<Command, ConfigError> {
        parse(std::env::args().skip(1), |k| std::env::var(k).ok())
    }
}

/// Parse `args` (without the program name), reading unset flags from `env`.
pub fn parse<I, S>(args: I, env: impl Fn(&str) -> Option<String>) -> Result<Command, ConfigError>
where
    I: IntoIterator<Item = S>,
    S: Into<String>,
{
    let mut listen = None;
    let mut metrics_listen = None;
    let mut body_reply = None;
    let mut max_grpc = None;
    let mut max_held = None;
    let mut rules: Vec<PathBuf> = Vec::new();

    let mut args = args.into_iter().map(Into::into).peekable();
    while let Some(arg) = args.next() {
        let (flag, inline) = match arg.split_once('=') {
            Some((f, v)) if f.starts_with("--") => (f.to_owned(), Some(v.to_owned())),
            _ => (arg.clone(), None),
        };
        match flag.as_str() {
            "-h" | "--help" => return Ok(Command::Help),
            "-V" | "--version" => return Ok(Command::Version),
            "--listen" => {
                listen = Some(address("--listen", inline.or_else(|| args.next()))?);
            }
            "--metrics-listen" => {
                metrics_listen = Some(address("--metrics-listen", inline.or_else(|| args.next()))?);
            }
            "--body-reply" => {
                let value = inline
                    .or_else(|| args.next())
                    .ok_or(ConfigError::MissingValue("--body-reply"))?;
                body_reply =
                    Some(BodyReply::parse(&value).ok_or(ConfigError::InvalidBodyReply(value))?);
            }
            "--max-grpc-message-bytes" => {
                max_grpc = Some(bytes(
                    "--max-grpc-message-bytes",
                    inline.or_else(|| args.next()),
                )?);
            }
            "--max-held-body-bytes" => {
                max_held = Some(bytes(
                    "--max-held-body-bytes",
                    inline.or_else(|| args.next()),
                )?);
            }
            "--modsec-rules" => {
                let first = inline
                    .or_else(|| args.next())
                    .ok_or(ConfigError::MissingValue("--modsec-rules"))?;
                push_rules(&mut rules, &first);
                while let Some(more) = args.next_if(|a| !a.starts_with('-')) {
                    push_rules(&mut rules, &more);
                }
            }
            _ => return Err(ConfigError::UnknownArgument(arg)),
        }
    }

    let listen = match listen {
        Some(a) => a,
        None => address(
            "EXT_PROC_LISTEN",
            Some(env("EXT_PROC_LISTEN").unwrap_or_else(|| DEFAULT_LISTEN.into())),
        )?,
    };
    let metrics_listen = match metrics_listen {
        Some(a) => a,
        None => address(
            "EXT_PROC_METRICS_LISTEN",
            Some(env("EXT_PROC_METRICS_LISTEN").unwrap_or_else(|| DEFAULT_METRICS_LISTEN.into())),
        )?,
    };
    let body_reply = match body_reply {
        Some(m) => m,
        None => match env("EXT_PROC_BODY_REPLY") {
            Some(v) => BodyReply::parse(&v).ok_or(ConfigError::InvalidBodyReply(v))?,
            None => BodyReply::Common,
        },
    };
    if rules.is_empty() {
        if let Some(v) = env("MODSEC_RULES") {
            push_rules(&mut rules, &v);
        }
    }
    if rules.is_empty() {
        return Err(ConfigError::MissingRules);
    }
    let max_grpc_message_bytes = match max_grpc {
        Some(n) => n,
        None => match env("EXT_PROC_MAX_GRPC_MESSAGE_BYTES") {
            Some(v) => bytes("EXT_PROC_MAX_GRPC_MESSAGE_BYTES", Some(v))?,
            None => DEFAULT_MAX_GRPC_MESSAGE_BYTES,
        },
    };
    let max_held_body_bytes = match max_held {
        Some(n) => n,
        None => match env("EXT_PROC_MAX_HELD_BODY_BYTES") {
            Some(v) => bytes("EXT_PROC_MAX_HELD_BODY_BYTES", Some(v))?,
            None => max_grpc_message_bytes,
        },
    };
    if max_held_body_bytes > max_grpc_message_bytes {
        return Err(ConfigError::HeldBodyAboveMessageLimit {
            held: max_held_body_bytes,
            message: max_grpc_message_bytes,
        });
    }
    Ok(Command::Run(Config {
        listen,
        metrics_listen,
        modsec_rules: rules,
        body_reply,
        limits: Limits {
            max_grpc_message_bytes,
            max_held_body_bytes,
        },
    }))
}

fn bytes(flag: &'static str, value: Option<String>) -> Result<usize, ConfigError> {
    let value = value.ok_or(ConfigError::MissingValue(flag))?;
    match value.trim().parse::<usize>() {
        Ok(n) if n > 0 => Ok(n),
        _ => Err(ConfigError::InvalidBytes { flag, value }),
    }
}

fn address(flag: &'static str, value: Option<String>) -> Result<SocketAddr, ConfigError> {
    let value = value.ok_or(ConfigError::MissingValue(flag))?;
    value
        .parse()
        .map_err(|_| ConfigError::InvalidAddress { flag, value })
}

fn push_rules(rules: &mut Vec<PathBuf>, value: &str) {
    rules.extend(
        value
            .split(',')
            .filter(|s| !s.is_empty())
            .map(PathBuf::from),
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    fn no_env(_: &str) -> Option<String> {
        None
    }

    fn run(args: &[&str], env: impl Fn(&str) -> Option<String>) -> Result<Config, ConfigError> {
        match parse(args.iter().copied(), env)? {
            Command::Run(c) => Ok(c),
            other => panic!("expected Run, got {other:?}"),
        }
    }

    #[test]
    fn rules_are_required() {
        assert_eq!(run(&[], no_env), Err(ConfigError::MissingRules));
        assert_eq!(
            run(&["--modsec-rules"], no_env),
            Err(ConfigError::MissingValue("--modsec-rules"))
        );
    }

    #[test]
    fn parses_comma_separated_rules() {
        let c = run(
            &[
                "--modsec-rules",
                "a.conf,b.conf",
                "--listen",
                "0.0.0.0:9000",
            ],
            no_env,
        )
        .expect("parse");
        assert_eq!(
            c.modsec_rules,
            vec![PathBuf::from("a.conf"), PathBuf::from("b.conf")]
        );
        assert_eq!(c.listen, "0.0.0.0:9000".parse().unwrap());
        assert_eq!(c.metrics_listen, DEFAULT_METRICS_LISTEN.parse().unwrap());
    }

    #[test]
    fn rules_are_repeatable_and_multi_valued() {
        let c = run(
            &[
                "--modsec-rules=a.conf",
                "--modsec-rules",
                "b.conf",
                "c.conf",
                "--metrics-listen=127.0.0.1:1",
            ],
            no_env,
        )
        .expect("parse");
        assert_eq!(
            c.modsec_rules,
            ["a.conf", "b.conf", "c.conf"].map(PathBuf::from).to_vec()
        );
        assert_eq!(c.metrics_listen, "127.0.0.1:1".parse().unwrap());
    }

    #[test]
    fn env_fallbacks_and_cli_precedence() {
        let env = |k: &str| match k {
            "MODSEC_RULES" => Some("env.conf".into()),
            "EXT_PROC_LISTEN" => Some("127.0.0.1:7000".into()),
            _ => None,
        };
        let c = run(&[], env).expect("parse");
        assert_eq!(c.modsec_rules, vec![PathBuf::from("env.conf")]);
        assert_eq!(c.listen, "127.0.0.1:7000".parse().unwrap());
        let c = run(&["--modsec-rules", "cli.conf", "--listen", "[::1]:1"], env).expect("parse");
        assert_eq!(c.modsec_rules, vec![PathBuf::from("cli.conf")]);
        assert_eq!(c.listen, "[::1]:1".parse().unwrap());
    }

    #[test]
    fn rejects_bad_input() {
        assert!(matches!(
            run(&["--modsec-rules", "a.conf", "--listen", "nope"], no_env),
            Err(ConfigError::InvalidAddress { .. })
        ));
        assert_eq!(
            run(&["--modsec-rules", "a.conf", "--bogus"], no_env),
            Err(ConfigError::UnknownArgument("--bogus".into()))
        );
        assert_eq!(
            run(
                &["--modsec-rules", "a.conf", "--body-reply", "nope"],
                no_env
            ),
            Err(ConfigError::InvalidBodyReply("nope".into()))
        );
        assert_eq!(parse(["--help"], no_env), Ok(Command::Help));
        assert_eq!(parse(["-V"], no_env), Ok(Command::Version));
    }

    #[test]
    fn body_reply_defaults_and_parses() {
        let c = run(&["--modsec-rules", "a.conf"], no_env).expect("parse");
        assert_eq!(c.body_reply, BodyReply::Common);
        let c = run(
            &["--modsec-rules", "a.conf", "--body-reply", "streamed"],
            no_env,
        )
        .expect("parse");
        assert_eq!(c.body_reply, BodyReply::Streamed);
        let env = |k: &str| match k {
            "MODSEC_RULES" => Some("env.conf".into()),
            "EXT_PROC_BODY_REPLY" => Some("streamed".into()),
            _ => None,
        };
        let c = run(&[], env).expect("parse");
        assert_eq!(c.body_reply, BodyReply::Streamed);
        let c = run(&["--modsec-rules", "cli.conf", "--body-reply=common"], env).expect("parse");
        assert_eq!(c.body_reply, BodyReply::Common);
    }

    #[test]
    fn size_limits_default_parse_and_validate() {
        let c = run(&["--modsec-rules", "a.conf"], no_env).expect("parse");
        assert_eq!(c.limits, Limits::default());
        assert_eq!(c.limits.max_grpc_message_bytes, 4 * 1024 * 1024);
        assert_eq!(c.limits.max_held_body_bytes, 4 * 1024 * 1024);
        assert_eq!(
            c.limits.max_encoding_message_bytes(),
            4 * 1024 * 1024 + REPLY_ENVELOPE_BYTES
        );

        // The held-body cap follows the message limit unless set.
        let c = run(
            &[
                "--modsec-rules",
                "a.conf",
                "--max-grpc-message-bytes=16777216",
            ],
            no_env,
        )
        .expect("parse");
        assert_eq!(c.limits.max_grpc_message_bytes, 16 << 20);
        assert_eq!(c.limits.max_held_body_bytes, 16 << 20);

        let c = run(
            &[
                "--modsec-rules",
                "a.conf",
                "--max-grpc-message-bytes",
                "8388608",
                "--max-held-body-bytes",
                "1048576",
            ],
            no_env,
        )
        .expect("parse");
        assert_eq!(c.limits.max_held_body_bytes, 1 << 20);

        let env = |k: &str| match k {
            "MODSEC_RULES" => Some("env.conf".into()),
            "EXT_PROC_MAX_GRPC_MESSAGE_BYTES" => Some("2048".into()),
            "EXT_PROC_MAX_HELD_BODY_BYTES" => Some("1024".into()),
            _ => None,
        };
        let c = run(&[], env).expect("parse");
        assert_eq!(c.limits.max_grpc_message_bytes, 2048);
        assert_eq!(c.limits.max_held_body_bytes, 1024);

        for bad in ["0", "-1", "4MiB", ""] {
            assert_eq!(
                run(
                    &["--modsec-rules", "a.conf", "--max-grpc-message-bytes", bad],
                    no_env
                ),
                Err(ConfigError::InvalidBytes {
                    flag: "--max-grpc-message-bytes",
                    value: bad.into()
                }),
                "{bad:?}"
            );
        }
        assert_eq!(
            run(
                &["--modsec-rules", "a.conf", "--max-held-body-bytes"],
                no_env
            ),
            Err(ConfigError::MissingValue("--max-held-body-bytes"))
        );
        assert_eq!(
            run(
                &[
                    "--modsec-rules",
                    "a.conf",
                    "--max-grpc-message-bytes=1024",
                    "--max-held-body-bytes=1025"
                ],
                no_env
            ),
            Err(ConfigError::HeldBodyAboveMessageLimit {
                held: 1025,
                message: 1024
            })
        );
    }
}
