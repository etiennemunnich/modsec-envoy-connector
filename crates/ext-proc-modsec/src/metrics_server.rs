//! Minimal HTTP/1.1 endpoint for scrapes and readiness.
//!
//! - `GET /metrics` — Prometheus text exposition.
//! - `GET /healthz` — 200 only if all hold within 2s:
//!   1. the engine mode measured at load is `On` (`SecRuleEngine On`), or
//!      `--allow-detection-only` accepts DetectionOnly / Off,
//!   2. the gRPC listener completes an HTTP/2 connection preface + SETTINGS
//!      exchange (the same server stack Envoy talks to), and
//!   3. a headers-only `GET /__ext_proc_healthz` run through a fresh
//!      `Exchange` (the code `Process` runs per message, with the loaded
//!      rules) answers request-headers Continue. The probe exchange has its
//!      own throwaway metrics and logs its phases at DEBUG, so probes never
//!      count as traffic.
//!
//!   An engine that does not enforce, an `ImmediateResponse` (deny or
//!   fail-closed), a dead listener, or a timeout yields 503. Every answer
//!   ends with `engine_mode=<mode>` and `rules=<count>` lines.

use std::net::SocketAddr;
use std::time::Duration;

use modsec_engine::EngineMode;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tracing::{info, warn};

use crate::pb::envoy::config::core::v3::{HeaderMap, HeaderValue};
use crate::pb::envoy::service::ext_proc::v3::processing_request::Request as ProcRequest;
use crate::pb::envoy::service::ext_proc::v3::processing_response::Response as ProcResponse;
use crate::pb::envoy::service::ext_proc::v3::{HttpHeaders, ProcessingRequest};
use crate::processor::{run_blocking, ModSecProcessor, Step};

const PROBE_TIMEOUT: Duration = Duration::from_secs(2);
const READ_TIMEOUT: Duration = Duration::from_secs(5);
/// Accept errors (e.g. EMFILE) repeat immediately; back off instead of
/// spinning a core and flooding the log.
const ACCEPT_BACKOFF_MIN: Duration = Duration::from_millis(10);
const ACCEPT_BACKOFF_MAX: Duration = Duration::from_secs(1);

/// HTTP/2 client connection preface (RFC 9113 §3.4) followed by an empty
/// SETTINGS frame.
const H2_PREFACE: &[u8] = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n\x00\x00\x00\x04\x00\x00\x00\x00\x00";
const H2_FRAME_SETTINGS: u8 = 0x4;

/// Serve `/metrics` and `/healthz` on an already-bound listener.
/// `allow_detection_only` lets `/healthz` pass with an engine that is not
/// `SecRuleEngine On`.
pub async fn serve(
    listener: TcpListener,
    processor: ModSecProcessor,
    grpc_addr: SocketAddr,
    allow_detection_only: bool,
) {
    if let Ok(addr) = listener.local_addr() {
        info!(%addr, "metrics + healthz listening (GET /metrics, GET /healthz)");
    }
    let mut backoff = ACCEPT_BACKOFF_MIN;
    loop {
        let (sock, peer) = match listener.accept().await {
            Ok(x) => {
                backoff = ACCEPT_BACKOFF_MIN;
                x
            }
            Err(e) => {
                warn!(error = %e, retry_ms = backoff.as_millis() as u64, "metrics accept error");
                tokio::time::sleep(backoff).await;
                backoff = (backoff * 2).min(ACCEPT_BACKOFF_MAX);
                continue;
            }
        };
        let processor = processor.clone();
        tokio::spawn(async move {
            handle(sock, peer, &processor, grpc_addr, allow_detection_only).await;
        });
    }
}

async fn handle(
    mut sock: TcpStream,
    peer: SocketAddr,
    processor: &ModSecProcessor,
    grpc_addr: SocketAddr,
    allow_detection_only: bool,
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
            let body = processor.metrics().render();
            write_response(
                &mut sock,
                "200 OK",
                "text/plain; version=0.0.4; charset=utf-8",
                body.as_bytes(),
            )
            .await;
        }
        Some("/healthz") => {
            let engine = processor.engine();
            let mode = engine.mode();
            let facts = format!(
                "engine_mode={}\nrules={}\n",
                mode.as_str(),
                engine.rule_count()
            );
            let verdict = if mode != EngineMode::On && !allow_detection_only {
                Err(format!(
                    "engine mode {} is not On (SecRuleEngine); traffic would not be blocked \
                     (--allow-detection-only accepts it)",
                    mode.as_str()
                ))
            } else {
                match tokio::time::timeout(PROBE_TIMEOUT, probe(processor, grpc_addr)).await {
                    Ok(Ok(())) => Ok(()),
                    Ok(Err(e)) => Err(format!("process probe failed: {e}")),
                    Err(_) => Err("process probe timeout".into()),
                }
            };
            match verdict {
                Ok(()) => {
                    let body = format!("ok\n{facts}");
                    write_response(&mut sock, "200 OK", "text/plain", body.as_bytes()).await
                }
                Err(e) => {
                    warn!(?peer, error = %e, "healthz not ready");
                    let body = format!("{e}\n{facts}");
                    write_response(
                        &mut sock,
                        "503 Service Unavailable",
                        "text/plain",
                        body.as_bytes(),
                    )
                    .await;
                }
            }
        }
        _ => write_response(&mut sock, "404 Not Found", "text/plain", b"not found\n").await,
    }
}

async fn probe(processor: &ModSecProcessor, grpc_addr: SocketAddr) -> Result<(), String> {
    h2_handshake(grpc_addr).await?;
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
                    hv(":path", "/__ext_proc_healthz"),
                    hv(":authority", "localhost"),
                    hv("user-agent", "ext-proc-modsec-healthz"),
                    hv("accept", "*/*"),
                    hv("x-request-id", "ext-proc-healthz-probe"),
                ],
            }),
            end_of_stream: true,
            ..Default::default()
        })),
        protocol_config: Some(processor.expected_protocol_config()),
        ..Default::default()
    };
    let mut exchange = processor.probe_exchange();
    let resp = match run_blocking(|| exchange.on_message(msg)) {
        Step::Reply(r) | Step::Final(r) | Step::Replies(r, _) => r,
        Step::Silent => return Err("process step answered nothing".into()),
        Step::Abort(s) => return Err(format!("process aborted: {s}")),
    };
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

/// The gRPC listener must answer an HTTP/2 preface with a SETTINGS frame.
async fn h2_handshake(grpc_addr: SocketAddr) -> Result<(), String> {
    let mut sock = TcpStream::connect(grpc_addr)
        .await
        .map_err(|e| format!("connect gRPC {grpc_addr}: {e}"))?;
    sock.write_all(H2_PREFACE)
        .await
        .map_err(|e| format!("send HTTP/2 preface: {e}"))?;
    let mut header = [0u8; 9];
    sock.read_exact(&mut header)
        .await
        .map_err(|e| format!("read HTTP/2 SETTINGS: {e}"))?;
    if header[3] != H2_FRAME_SETTINGS {
        return Err(format!(
            "gRPC listener answered frame type {:#x}, want SETTINGS",
            header[3]
        ));
    }
    let _ = sock.shutdown().await;
    Ok(())
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
