//! Minimal HTTP/1.1 endpoint for scrapes and readiness.
//!
//! - `GET /metrics` — Prometheus text exposition.
//! - `GET /healthz` — exercises the real gRPC `Process` path: dials this
//!   process's ExternalProcessor, sends headers-only `GET /__connex_healthz`,
//!   and expects a request-headers Continue within 2s. An `ImmediateResponse`
//!   (deny or fail-closed) or a timeout yields 503.

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use envoy_types::pb::envoy::config::core::v3::{HeaderMap, HeaderValue};
use envoy_types::pb::envoy::service::ext_proc::v3::external_processor_client::ExternalProcessorClient;
use envoy_types::pb::envoy::service::ext_proc::v3::processing_request::Request as ProcRequest;
use envoy_types::pb::envoy::service::ext_proc::v3::processing_response::Response as ProcResponse;
use envoy_types::pb::envoy::service::ext_proc::v3::{HttpHeaders, ProcessingRequest};
use futures::StreamExt;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tracing::{info, warn};

use crate::metrics::ConnectorMetrics;

const PROBE_TIMEOUT: Duration = Duration::from_secs(2);
const READ_TIMEOUT: Duration = Duration::from_secs(5);

/// Serve `/metrics` and `/healthz` on an already-bound listener.
pub async fn serve(listener: TcpListener, metrics: Arc<ConnectorMetrics>, grpc_addr: SocketAddr) {
    if let Ok(addr) = listener.local_addr() {
        info!(%addr, "metrics + healthz listening (GET /metrics, GET /healthz)");
    }
    loop {
        let (sock, peer) = match listener.accept().await {
            Ok(x) => x,
            Err(e) => {
                warn!(error = %e, "metrics accept error");
                continue;
            }
        };
        let metrics = Arc::clone(&metrics);
        tokio::spawn(async move {
            handle(sock, peer, &metrics, grpc_addr).await;
        });
    }
}

async fn handle(
    mut sock: TcpStream,
    peer: SocketAddr,
    metrics: &ConnectorMetrics,
    grpc_addr: SocketAddr,
) {
    let mut buf = [0u8; 1024];
    let n = match tokio::time::timeout(READ_TIMEOUT, sock.read(&mut buf)).await {
        Ok(Ok(n)) if n > 0 => n,
        _ => return,
    };
    let request_line = String::from_utf8_lossy(&buf[..n]);
    let target = request_line
        .lines()
        .next()
        .and_then(|l| l.strip_prefix("GET "))
        .and_then(|rest| rest.split_whitespace().next());

    match target {
        Some("/metrics") => {
            let body = metrics.render();
            write_response(
                &mut sock,
                "200 OK",
                "text/plain; version=0.0.4; charset=utf-8",
                body.as_bytes(),
            )
            .await;
        }
        Some("/healthz") => match tokio::time::timeout(PROBE_TIMEOUT, probe(grpc_addr)).await {
            Ok(Ok(())) => write_response(&mut sock, "200 OK", "text/plain", b"ok\n").await,
            Ok(Err(e)) => {
                warn!(?peer, error = %e, "healthz Process probe failed");
                let body = format!("process probe failed: {e}\n");
                write_response(
                    &mut sock,
                    "503 Service Unavailable",
                    "text/plain",
                    body.as_bytes(),
                )
                .await;
            }
            Err(_) => {
                warn!(?peer, "healthz Process probe timed out");
                write_response(
                    &mut sock,
                    "503 Service Unavailable",
                    "text/plain",
                    b"process probe timeout\n",
                )
                .await;
            }
        },
        _ => write_response(&mut sock, "404 Not Found", "text/plain", b"not found\n").await,
    }
}

async fn probe(grpc_addr: SocketAddr) -> Result<(), String> {
    let mut client = ExternalProcessorClient::connect(format!("http://{grpc_addr}"))
        .await
        .map_err(|e| format!("connect: {e}"))?;
    let hv = |k: &str, v: &str| HeaderValue {
        key: k.into(),
        raw_value: v.as_bytes().to_vec(),
        ..Default::default()
    };
    let msg = ProcessingRequest {
        request: Some(ProcRequest::RequestHeaders(HttpHeaders {
            headers: Some(HeaderMap {
                headers: vec![
                    hv(":method", "GET"),
                    hv(":path", "/__connex_healthz"),
                    hv(":authority", "localhost"),
                    hv("user-agent", "ext-proc-modsec-healthz"),
                    hv("accept", "*/*"),
                    hv("x-request-id", "connex-healthz-probe"),
                ],
            }),
            end_of_stream: true,
            ..Default::default()
        })),
        ..Default::default()
    };
    let mut stream = client
        .process(futures::stream::iter([msg]))
        .await
        .map_err(|e| format!("process rpc: {e}"))?
        .into_inner();
    let resp = stream
        .next()
        .await
        .ok_or("process stream ended with no response")?
        .map_err(|e| format!("process message: {e}"))?;
    match resp.response {
        Some(ProcResponse::RequestHeaders(_)) => Ok(()),
        Some(ProcResponse::ImmediateResponse(ir)) => Err(format!(
            "ImmediateResponse status={} details={}",
            ir.status.map(|s| s.code).unwrap_or(0),
            ir.details
        )),
        other => Err(format!("unexpected Process response: {other:?}")),
    }
}

async fn write_response(sock: &mut TcpStream, status: &str, content_type: &str, body: &[u8]) {
    let head = format!(
        "HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    if sock.write_all(head.as_bytes()).await.is_ok() {
        let _ = sock.write_all(body).await;
    }
    let _ = sock.shutdown().await;
}
