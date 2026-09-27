//! `ext-proc-modsec` — Envoy ExternalProcessor backed by libmodsecurity.
//!
//! Boot order is fail-closed: rules must load and both listeners must bind
//! before the process serves anything. Any failure exits non-zero, so Envoy
//! (with `failure_mode_allow: false`) keeps answering 500 instead of
//! forwarding uninspected traffic.

#![forbid(unsafe_code)]

use std::process::ExitCode;
use std::sync::Arc;

use ext_proc_modsec::config::{Command, Config, USAGE};
use ext_proc_modsec::metrics::ConnectorMetrics;
use ext_proc_modsec::pb::envoy::service::ext_proc::v3::external_processor_server::ExternalProcessorServer;
use ext_proc_modsec::{logging, metrics_server, ModSecProcessor};
use modsec_engine::Engine;
use tokio::net::TcpListener;
use tonic::transport::server::TcpIncoming;
use tonic::transport::Server;
use tracing::{error, info};

#[tokio::main]
async fn main() -> ExitCode {
    let config = match Config::from_env() {
        Ok(Command::Run(c)) => c,
        Ok(Command::Help) => {
            print!("{USAGE}");
            return ExitCode::SUCCESS;
        }
        Ok(Command::Version) => {
            println!("ext-proc-modsec {}", env!("CARGO_PKG_VERSION"));
            return ExitCode::SUCCESS;
        }
        Err(e) => {
            eprintln!("error: {e}\n\n{USAGE}");
            return ExitCode::from(2);
        }
    };
    logging::init();

    match run(config).await {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            error!(error = %e, "ext-proc-modsec exiting");
            ExitCode::FAILURE
        }
    }
}

async fn run(config: Config) -> Result<(), Box<dyn std::error::Error>> {
    let engine = Engine::load_files(&config.modsec_rules)
        .map_err(|e| format!("ModSecurity rules failed to load: {e}"))?;
    info!(rules = ?engine.rules_paths(), "ModSecurity engine ready");

    let grpc_listener = TcpListener::bind(config.listen)
        .await
        .map_err(|e| format!("bind gRPC {}: {e}", config.listen))?;
    let grpc_addr = grpc_listener.local_addr()?;
    let metrics_listener = TcpListener::bind(config.metrics_listen)
        .await
        .map_err(|e| format!("bind metrics {}: {e}", config.metrics_listen))?;

    let metrics = Arc::new(ConnectorMetrics::default());
    let processor = ModSecProcessor::new(engine, metrics);
    tokio::spawn(metrics_server::serve(
        metrics_listener,
        processor.clone(),
        grpc_addr,
    ));

    info!(
        listen = %grpc_addr,
        metrics = %config.metrics_listen,
        "ExternalProcessor serving (pair with Envoy failure_mode_allow: false)"
    );
    // Single service, no router: the generated server answers UNIMPLEMENTED
    // for any other gRPC path.
    Server::builder()
        .serve_with_incoming_shutdown(
            ExternalProcessorServer::new(processor),
            TcpIncoming::from(grpc_listener),
            shutdown_signal(),
        )
        .await?;
    info!("shutdown complete");
    Ok(())
}

async fn shutdown_signal() {
    let ctrl_c = async {
        if tokio::signal::ctrl_c().await.is_err() {
            std::future::pending::<()>().await;
        }
    };
    #[cfg(unix)]
    let term = async {
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(mut s) => {
                s.recv().await;
            }
            Err(_) => std::future::pending::<()>().await,
        }
    };
    #[cfg(not(unix))]
    let term = std::future::pending::<()>();
    tokio::select! {
        _ = ctrl_c => info!("SIGINT received"),
        _ = term => info!("SIGTERM received"),
    }
}
