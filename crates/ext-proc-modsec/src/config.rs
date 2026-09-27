//! Command-line / environment configuration.

use std::net::SocketAddr;
use std::path::PathBuf;

use clap::Parser;

#[derive(Debug, Clone, Parser)]
#[command(
    name = "ext-proc-modsec",
    version,
    about = "Envoy ExternalProcessor that inspects HTTP traffic with libmodsecurity (fail-closed)"
)]
pub struct Config {
    /// gRPC listen address for Envoy's `ext_proc` filter.
    #[arg(long, env = "EXT_PROC_LISTEN", default_value = "127.0.0.1:18081")]
    pub listen: SocketAddr,

    /// Metrics + readiness listen address (`GET /metrics`, `GET /healthz`).
    #[arg(
        long,
        env = "EXT_PROC_METRICS_LISTEN",
        default_value = "127.0.0.1:18082"
    )]
    pub metrics_listen: SocketAddr,

    /// ModSecurity rules files, loaded in order (repeatable or comma-separated).
    /// At least one is required: the connector never runs without an engine.
    #[arg(
        long = "modsec-rules",
        env = "MODSEC_RULES",
        value_delimiter = ',',
        required = true,
        num_args = 1..
    )]
    pub modsec_rules: Vec<PathBuf>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rules_are_required() {
        let err = Config::try_parse_from(["ext-proc-modsec"]).unwrap_err();
        assert_eq!(
            err.kind(),
            clap::error::ErrorKind::MissingRequiredArgument,
            "{err}"
        );
    }

    #[test]
    fn parses_comma_separated_rules() {
        let c = Config::try_parse_from([
            "ext-proc-modsec",
            "--modsec-rules",
            "a.conf,b.conf",
            "--listen",
            "0.0.0.0:9000",
        ])
        .expect("parse");
        assert_eq!(
            c.modsec_rules,
            vec![PathBuf::from("a.conf"), PathBuf::from("b.conf")]
        );
        assert_eq!(c.listen, "0.0.0.0:9000".parse().unwrap());
    }
}
