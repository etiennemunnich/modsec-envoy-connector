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
  -h, --help                   Print help
  -V, --version                Print version

Logging: RUST_LOG=<level>[,<target>=<level>...] (default info).
";

const DEFAULT_LISTEN: &str = "127.0.0.1:18081";
const DEFAULT_METRICS_LISTEN: &str = "127.0.0.1:18082";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Config {
    /// gRPC listen address for Envoy's `ext_proc` filter.
    pub listen: SocketAddr,
    /// Metrics + readiness listen address (`GET /metrics`, `GET /healthz`).
    pub metrics_listen: SocketAddr,
    /// ModSecurity rules files, loaded in order. Never empty: the connector
    /// never runs without an engine.
    pub modsec_rules: Vec<PathBuf>,
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
    if rules.is_empty() {
        if let Some(v) = env("MODSEC_RULES") {
            push_rules(&mut rules, &v);
        }
    }
    if rules.is_empty() {
        return Err(ConfigError::MissingRules);
    }
    Ok(Command::Run(Config {
        listen,
        metrics_listen,
        modsec_rules: rules,
    }))
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
        assert_eq!(parse(["--help"], no_env), Ok(Command::Help));
        assert_eq!(parse(["-V"], no_env), Ok(Command::Version));
    }
}
