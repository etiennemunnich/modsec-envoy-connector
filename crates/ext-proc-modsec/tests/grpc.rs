//! End-to-end tests of the ExternalProcessor over real gRPC, with libmodsecurity
//! linked. Each test drives one `Process` stream the way Envoy does: send a
//! message, wait for its answer, send the next.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use ext_proc_modsec::connection_meta::EXT_PROC_ATTR_NAMESPACE;
use ext_proc_modsec::metrics::ConnectorMetrics;
use ext_proc_modsec::pb::envoy::config::core::v3::{HeaderMap, HeaderValue};
use ext_proc_modsec::pb::envoy::service::ext_proc::v3::external_processor_client::ExternalProcessorClient;
use ext_proc_modsec::pb::envoy::service::ext_proc::v3::external_processor_server::ExternalProcessorServer;
use ext_proc_modsec::pb::envoy::service::ext_proc::v3::processing_request::Request as ProcRequest;
use ext_proc_modsec::pb::envoy::service::ext_proc::v3::processing_response::Response as ProcResponse;
use ext_proc_modsec::pb::envoy::service::ext_proc::v3::{
    HttpBody, HttpHeaders, HttpTrailers, ProcessingRequest, ProcessingResponse,
};
use ext_proc_modsec::pb::google::protobuf::{value::Kind, Struct, Value};
use ext_proc_modsec::{metrics_server, ModSecProcessor};
use modsec_engine::Engine;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;
use tokio_stream::wrappers::ReceiverStream;
use tokio_stream::StreamExt;
use tonic::transport::server::TcpIncoming;
use tonic::transport::{Channel, Server};
use tonic::Streaming;

fn rules_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/rules")
        .join(name)
}

struct Harness {
    addr: SocketAddr,
    metrics: Arc<ConnectorMetrics>,
    processor: ModSecProcessor,
}

fn processor() -> ModSecProcessor {
    let engine = Engine::load_files(&[rules_path("connector-test.conf")]).expect("rules");
    ModSecProcessor::new(engine, Arc::new(ConnectorMetrics::default()))
}

async fn start() -> Harness {
    let processor = processor();
    let metrics = Arc::clone(processor.metrics());
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let addr = listener.local_addr().expect("addr");
    let svc = ExternalProcessorServer::new(processor.clone());
    tokio::spawn(async move {
        Server::builder()
            .serve_with_incoming(svc, TcpIncoming::from(listener))
            .await
            .expect("serve");
    });
    Harness {
        addr,
        metrics,
        processor,
    }
}

/// One Envoy-like `Process` stream.
struct Stream {
    tx: mpsc::Sender<ProcessingRequest>,
    rx: Streaming<ProcessingResponse>,
}

impl Stream {
    async fn open(addr: SocketAddr) -> Self {
        let channel = Channel::from_shared(format!("http://{addr}"))
            .expect("uri")
            .connect()
            .await
            .expect("connect");
        let mut client = ExternalProcessorClient::new(channel);
        let (tx, rx) = mpsc::channel(8);
        let rx = client
            .process(ReceiverStream::new(rx))
            .await
            .expect("process")
            .into_inner();
        Self { tx, rx }
    }

    async fn send(&mut self, req: ProcessingRequest) -> Result<ProcessingResponse, tonic::Status> {
        self.tx.send(req).await.expect("send");
        tokio::time::timeout(Duration::from_secs(5), self.rx.next())
            .await
            .expect("answer within 5s")
            .expect("stream answered")
    }

    async fn expect_closed(&mut self) {
        let next = tokio::time::timeout(Duration::from_secs(5), self.rx.next())
            .await
            .expect("close within 5s");
        assert!(next.is_none(), "stream must close after a terminal reply");
    }
}

fn hv(k: &str, v: &str) -> HeaderValue {
    HeaderValue {
        key: k.into(),
        raw_value: v.as_bytes().to_vec(),
        ..Default::default()
    }
}

fn req_headers(method: &str, path: &str, extra: &[(&str, &str)], eos: bool) -> ProcessingRequest {
    let mut headers = vec![
        hv(":method", method),
        hv(":path", path),
        hv(":authority", "app.test"),
        hv(":scheme", "http"),
        hv("user-agent", "connex-test"),
        hv("accept", "*/*"),
        hv("x-request-id", "rid-test"),
    ];
    headers.extend(extra.iter().map(|(k, v)| hv(k, v)));
    ProcessingRequest {
        request: Some(ProcRequest::RequestHeaders(HttpHeaders {
            headers: Some(HeaderMap { headers }),
            end_of_stream: eos,
            ..Default::default()
        })),
        ..Default::default()
    }
}

fn resp_headers(status: &str, extra: &[(&str, &str)], eos: bool) -> ProcessingRequest {
    let mut headers = vec![hv(":status", status), hv("content-type", "text/plain")];
    headers.extend(extra.iter().map(|(k, v)| hv(k, v)));
    ProcessingRequest {
        request: Some(ProcRequest::ResponseHeaders(HttpHeaders {
            headers: Some(HeaderMap { headers }),
            end_of_stream: eos,
            ..Default::default()
        })),
        ..Default::default()
    }
}

fn req_body(body: &[u8], eos: bool) -> ProcessingRequest {
    ProcessingRequest {
        request: Some(ProcRequest::RequestBody(HttpBody {
            body: body.to_vec(),
            end_of_stream: eos,
            ..Default::default()
        })),
        ..Default::default()
    }
}

fn resp_body(body: &[u8], eos: bool) -> ProcessingRequest {
    ProcessingRequest {
        request: Some(ProcRequest::ResponseBody(HttpBody {
            body: body.to_vec(),
            end_of_stream: eos,
            ..Default::default()
        })),
        ..Default::default()
    }
}

fn req_trailers(extra: &[(&str, &str)]) -> ProcessingRequest {
    let headers: Vec<HeaderValue> = extra.iter().map(|(k, v)| hv(k, v)).collect();
    ProcessingRequest {
        request: Some(ProcRequest::RequestTrailers(HttpTrailers {
            trailers: Some(HeaderMap { headers }),
        })),
        ..Default::default()
    }
}

fn assert_fail_closed(r: &ProcessingResponse, what: &str) {
    let (code, details, _) =
        immediate(r).unwrap_or_else(|| panic!("{what}: expected ImmediateResponse"));
    assert_eq!(code, 500, "{what}: want 500, got {code} details={details}");
    assert_eq!(details, "modsec_fail_closed", "{what}");
}

fn immediate(r: &ProcessingResponse) -> Option<(i32, String, Vec<u8>)> {
    match r.response.as_ref()? {
        ProcResponse::ImmediateResponse(ir) => Some((
            ir.status.as_ref().map(|s| s.code).unwrap_or(0),
            ir.details.clone(),
            ir.body.clone(),
        )),
        _ => None,
    }
}

fn assert_continue(r: &ProcessingResponse, what: &str) {
    let ok = matches!(
        r.response,
        Some(ProcResponse::RequestHeaders(_))
            | Some(ProcResponse::RequestBody(_))
            | Some(ProcResponse::ResponseHeaders(_))
            | Some(ProcResponse::ResponseBody(_))
    );
    assert!(ok, "{what}: expected Continue, got {:?}", r.response);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn benign_exchange_continues_every_phase() {
    let h = start().await;
    let mut s = Stream::open(h.addr).await;
    let r = s.send(req_headers("GET", "/", &[], true)).await.unwrap();
    assert!(matches!(r.response, Some(ProcResponse::RequestHeaders(_))));
    let r = s.send(resp_headers("200", &[], false)).await.unwrap();
    assert!(matches!(r.response, Some(ProcResponse::ResponseHeaders(_))));
    let r = s.send(resp_body(b"hello world\n", true)).await.unwrap();
    assert!(matches!(r.response, Some(ProcResponse::ResponseBody(_))));
    assert_eq!(h.metrics.allow_total(), 1);
    assert_eq!(h.metrics.deny_total(), 0);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn phase1_deny_is_403_with_generic_body() {
    let h = start().await;
    let mut s = Stream::open(h.addr).await;
    let r = s
        .send(req_headers("GET", "/admin", &[], true))
        .await
        .unwrap();
    let (code, details, body) = immediate(&r).expect("immediate");
    assert_eq!(code, 403);
    assert_eq!(details, "modsecurity_intervention");
    assert_eq!(
        body, b"Forbidden\n",
        "rule details must not leak to clients"
    );
    s.expect_closed().await;
    assert_eq!(h.metrics.deny_total(), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn rule_status_is_honoured() {
    let h = start().await;
    let mut s = Stream::open(h.addr).await;
    let r = s
        .send(req_headers("GET", "/teapot", &[], true))
        .await
        .unwrap();
    assert_eq!(immediate(&r).expect("immediate").0, 406);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn redirect_sets_location() {
    let h = start().await;
    let mut s = Stream::open(h.addr).await;
    let r = s
        .send(req_headers("GET", "/go-away", &[], true))
        .await
        .unwrap();
    let Some(ProcResponse::ImmediateResponse(ir)) = r.response else {
        panic!("expected immediate redirect")
    };
    assert_eq!(ir.status.unwrap().code, 302);
    let loc = &ir.headers.unwrap().set_headers[0];
    let loc = loc.header.as_ref().unwrap();
    assert_eq!(loc.key, "location");
    assert_eq!(loc.raw_value, b"https://example.test/bye");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn request_body_sqli_is_denied_after_headers_continue() {
    let h = start().await;
    let mut s = Stream::open(h.addr).await;
    let r = s
        .send(req_headers(
            "POST",
            "/post",
            &[("content-type", "application/x-www-form-urlencoded")],
            false,
        ))
        .await
        .unwrap();
    assert_continue(&r, "request headers");
    let r = s
        .send(req_body(b"q=1 UNION SELECT password FROM users", true))
        .await
        .unwrap();
    assert_eq!(immediate(&r).expect("immediate").0, 403);
    s.expect_closed().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn benign_request_body_continues() {
    let h = start().await;
    let mut s = Stream::open(h.addr).await;
    let r = s
        .send(req_headers(
            "POST",
            "/post",
            &[("content-type", "application/x-www-form-urlencoded")],
            false,
        ))
        .await
        .unwrap();
    assert_continue(&r, "request headers");
    let r = s.send(req_body(b"name=alice", true)).await.unwrap();
    assert!(matches!(r.response, Some(ProcResponse::RequestBody(_))));
    assert_eq!(h.metrics.allow_total(), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn response_header_rule_denies() {
    let h = start().await;
    let mut s = Stream::open(h.addr).await;
    assert_continue(
        &s.send(req_headers("GET", "/", &[], true)).await.unwrap(),
        "req",
    );
    let r = s
        .send(resp_headers("200", &[("x-leak", "yes")], false))
        .await
        .unwrap();
    assert_eq!(immediate(&r).expect("immediate").0, 403);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn response_body_rule_denies() {
    let h = start().await;
    let mut s = Stream::open(h.addr).await;
    assert_continue(
        &s.send(req_headers("GET", "/leak", &[], true))
            .await
            .unwrap(),
        "req",
    );
    assert_continue(
        &s.send(resp_headers("200", &[], false)).await.unwrap(),
        "resp headers",
    );
    let r = s
        .send(resp_body(b"token=CONNEX-LEAK-MARKER\n", true))
        .await
        .unwrap();
    assert_eq!(immediate(&r).expect("immediate").0, 403);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn remote_addr_comes_from_ext_proc_attributes() {
    let h = start().await;
    let mut s = Stream::open(h.addr).await;
    let mut req = req_headers("GET", "/", &[], true);
    let str_val = |v: &str| Value {
        kind: Some(Kind::StringValue(v.into())),
    };
    let fields = HashMap::from([
        ("source.address".to_owned(), str_val("192.0.2.66:40000")),
        (
            "destination.address".to_owned(),
            str_val("198.51.100.1:443"),
        ),
        ("request.protocol".to_owned(), str_val("HTTP/2")),
    ]);
    req.attributes = HashMap::from([(EXT_PROC_ATTR_NAMESPACE.to_owned(), Struct { fields })]);
    let r = s.send(req).await.unwrap();
    assert_eq!(
        immediate(&r).expect("REMOTE_ADDR rule must fire").0,
        403,
        "REMOTE_ADDR must be the Envoy-supplied peer"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn body_before_headers_fails_closed() {
    let h = start().await;
    let mut s = Stream::open(h.addr).await;
    let r = s.send(req_body(b"x", true)).await.unwrap();
    let (code, details, _) = immediate(&r).expect("immediate");
    assert_eq!(code, 500);
    assert_eq!(details, "modsec_fail_closed");
    assert_eq!(h.metrics.fail_closed_total(), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn response_before_request_fails_closed() {
    let h = start().await;
    let mut s = Stream::open(h.addr).await;
    let r = s.send(resp_headers("200", &[], true)).await.unwrap();
    assert_eq!(immediate(&r).expect("immediate").0, 500);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn envoy_local_reply_without_request_passes_through() {
    let h = start().await;
    for status in ["400", "404", "503"] {
        let mut s = Stream::open(h.addr).await;
        let r = s.send(resp_headers(status, &[], false)).await.unwrap();
        assert!(
            matches!(r.response, Some(ProcResponse::ResponseHeaders(_))),
            "{status}: Envoy's local reply status must pass through, got {:?}",
            r.response
        );
        let r = s.send(resp_body(b"Bad Request", true)).await.unwrap();
        assert!(
            matches!(r.response, Some(ProcResponse::ResponseBody(_))),
            "{status}: local reply body must continue, got {:?}",
            r.response
        );
    }
    assert_eq!(h.metrics.local_reply_passthrough_total(), 3);
    assert_eq!(h.metrics.fail_closed_total(), 0);
    assert_eq!(h.metrics.allow_total(), 0);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn response_without_request_below_400_fails_closed() {
    let h = start().await;
    for status in ["200", "204", "302", "399", "600", "abc"] {
        let mut s = Stream::open(h.addr).await;
        let r = s.send(resp_headers(status, &[], true)).await.unwrap();
        let (code, details, _) = immediate(&r).expect("immediate");
        assert_eq!(
            code, 500,
            "status {status} without a request must fail closed"
        );
        assert_eq!(details, "modsec_fail_closed");
        s.expect_closed().await;
    }
    assert_eq!(h.metrics.local_reply_passthrough_total(), 0);
    assert_eq!(h.metrics.fail_closed_total(), 6);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn local_reply_does_not_open_the_request_path() {
    let h = start().await;
    let mut s = Stream::open(h.addr).await;
    assert!(matches!(
        s.send(resp_headers("400", &[], false))
            .await
            .unwrap()
            .response,
        Some(ProcResponse::ResponseHeaders(_))
    ));
    let r = s.send(req_body(b"x", true)).await.unwrap();
    assert_eq!(immediate(&r).expect("immediate").0, 500);

    let mut s = Stream::open(h.addr).await;
    s.send(resp_headers("400", &[], false)).await.unwrap();
    let r = s.send(req_headers("GET", "/", &[], true)).await.unwrap();
    assert_eq!(immediate(&r).expect("immediate").0, 500);

    let mut s = Stream::open(h.addr).await;
    s.send(resp_headers("400", &[], false)).await.unwrap();
    let r = s.send(resp_headers("400", &[], false)).await.unwrap();
    assert_eq!(immediate(&r).expect("immediate").0, 500);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn duplicate_request_headers_fail_closed() {
    let h = start().await;
    let mut s = Stream::open(h.addr).await;
    assert_continue(
        &s.send(req_headers("POST", "/", &[], false)).await.unwrap(),
        "first headers",
    );
    let r = s.send(req_headers("POST", "/", &[], false)).await.unwrap();
    assert_eq!(immediate(&r).expect("immediate").0, 500);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn empty_request_oneof_fails_closed() {
    let h = start().await;
    let mut s = Stream::open(h.addr).await;
    let r = s.send(ProcessingRequest::default()).await.unwrap();
    assert_eq!(immediate(&r).expect("immediate").0, 500);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn invalid_response_status_fails_closed() {
    let h = start().await;
    let mut s = Stream::open(h.addr).await;
    assert_continue(
        &s.send(req_headers("GET", "/", &[], true)).await.unwrap(),
        "req",
    );
    let r = s.send(resp_headers("abc", &[], true)).await.unwrap();
    assert_eq!(immediate(&r).expect("immediate").0, 500);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn connect_is_rejected() {
    let h = start().await;
    let mut s = Stream::open(h.addr).await;
    let r = s
        .send(req_headers("CONNECT", "app.test:443", &[], false))
        .await
        .unwrap();
    let (code, details, _) = immediate(&r).expect("immediate");
    assert_eq!(code, 403);
    assert_eq!(details, "connect_rejected");
}

// --- Class 3: per-request engine Err after the session is open -----------------
// A real libmodsecurity Err cannot be forced through a well-behaved Envoy, so
// these drive the same fail_closed path over gRPC. Floor: ≥ 8 cases named
// *fails_closed* that assert ImmediateResponse 500 (see docs/fail-closed.md).

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn injected_engine_err_on_request_body_fails_closed() {
    // Mid-exchange: headers Continue, then fail-inject on append → 500.
    // Negative control (same request, no inject) Continues — see
    // benign_request_body_continues / streamed_benign_body_chunks_continue.
    let h = start().await;
    let mut s = Stream::open(h.addr).await;
    assert_continue(
        &s.send(req_headers(
            "POST",
            "/post",
            &[("content-type", "application/x-www-form-urlencoded")],
            false,
        ))
        .await
        .unwrap(),
        "headers",
    );
    h.processor.engine().inject_fail_next_transaction_step();
    let r = s.send(req_body(b"name=alice", true)).await.unwrap();
    assert_fail_closed(&r, "injected append Err");
    s.expect_closed().await;
    assert_eq!(h.metrics.fail_closed_total(), 1);
    assert_eq!(h.metrics.allow_total(), 0);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn injected_engine_err_negative_control_continues() {
    // Same bytes as the inject test; without arming the hook, the path Continues.
    let h = start().await;
    let mut s = Stream::open(h.addr).await;
    assert_continue(
        &s.send(req_headers(
            "POST",
            "/post",
            &[("content-type", "application/x-www-form-urlencoded")],
            false,
        ))
        .await
        .unwrap(),
        "headers",
    );
    let r = s.send(req_body(b"name=alice", true)).await.unwrap();
    assert_continue(&r, "body without inject");
    assert_eq!(h.metrics.fail_closed_total(), 0);
    assert_eq!(h.metrics.allow_total(), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn append_after_request_body_finished_fails_closed() {
    // Real EngineError from the façade (phase-order), after a successful session.
    let h = start().await;
    let mut s = Stream::open(h.addr).await;
    assert_continue(
        &s.send(req_headers(
            "POST",
            "/post",
            &[("content-type", "application/x-www-form-urlencoded")],
            false,
        ))
        .await
        .unwrap(),
        "headers",
    );
    assert_continue(&s.send(req_body(b"name=alice", true)).await.unwrap(), "eos");
    let r = s.send(req_body(b"extra", true)).await.unwrap();
    assert_fail_closed(&r, "body after finish");
    s.expect_closed().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn response_body_before_response_headers_fails_closed() {
    let h = start().await;
    let mut s = Stream::open(h.addr).await;
    assert_continue(
        &s.send(req_headers("GET", "/", &[], true)).await.unwrap(),
        "req",
    );
    let r = s.send(resp_body(b"oops", true)).await.unwrap();
    assert_fail_closed(&r, "response body before headers");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn nul_in_request_header_fails_closed() {
    // CString rejection → EngineError::Transaction during process_request_headers
    // (session already opened by open_transaction).
    let h = start().await;
    let mut s = Stream::open(h.addr).await;
    let mut req = req_headers("GET", "/", &[("x-bad", "ok")], true);
    if let Some(ProcRequest::RequestHeaders(ref mut h)) = req.request {
        if let Some(ref mut map) = h.headers {
            map.headers.push(HeaderValue {
                key: "x-nul".into(),
                raw_value: b"a\0b".to_vec(),
                ..Default::default()
            });
        }
    }
    let r = s.send(req).await.unwrap();
    assert_fail_closed(&r, "NUL in header value");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn duplicate_response_headers_fail_closed() {
    let h = start().await;
    let mut s = Stream::open(h.addr).await;
    assert_continue(
        &s.send(req_headers("GET", "/", &[], true)).await.unwrap(),
        "req",
    );
    assert_continue(
        &s.send(resp_headers("200", &[], false)).await.unwrap(),
        "resp1",
    );
    let r = s.send(resp_headers("200", &[], false)).await.unwrap();
    assert_fail_closed(&r, "duplicate response headers");
}

// --- BUFFERED / STREAMED body path (gRPC multi-chunk = Envoy STREAMED) --------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn streamed_benign_body_chunks_continue() {
    let h = start().await;
    let mut s = Stream::open(h.addr).await;
    assert_continue(
        &s.send(req_headers(
            "POST",
            "/post",
            &[("content-type", "application/x-www-form-urlencoded")],
            false,
        ))
        .await
        .unwrap(),
        "headers",
    );
    assert_continue(&s.send(req_body(b"name=", false)).await.unwrap(), "chunk1");
    assert_continue(&s.send(req_body(b"alice", false)).await.unwrap(), "chunk2");
    let r = s.send(req_body(b"", true)).await.unwrap();
    assert_continue(&r, "eos empty");
    assert_eq!(h.metrics.allow_total(), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn streamed_sqli_denied_at_end_of_stream() {
    // Phase-2 rule fires at process_request_body (EOS), after benign chunks Continue.
    let h = start().await;
    let mut s = Stream::open(h.addr).await;
    assert_continue(
        &s.send(req_headers(
            "POST",
            "/post",
            &[("content-type", "application/x-www-form-urlencoded")],
            false,
        ))
        .await
        .unwrap(),
        "headers",
    );
    assert_continue(&s.send(req_body(b"q=1 ", false)).await.unwrap(), "chunk1");
    assert_continue(&s.send(req_body(b"UNION ", false)).await.unwrap(), "chunk2");
    let r = s
        .send(req_body(b"SELECT password FROM users", true))
        .await
        .unwrap();
    assert_eq!(immediate(&r).expect("deny at EOS").0, 403);
    s.expect_closed().await;
    assert_eq!(h.metrics.allow_total(), 0);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn empty_request_body_eos_continues() {
    let h = start().await;
    let mut s = Stream::open(h.addr).await;
    assert_continue(
        &s.send(req_headers(
            "POST",
            "/post",
            &[("content-type", "application/x-www-form-urlencoded")],
            false,
        ))
        .await
        .unwrap(),
        "headers",
    );
    let r = s.send(req_body(b"", true)).await.unwrap();
    assert_continue(&r, "empty eos body");
    assert_eq!(h.metrics.allow_total(), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn trailers_without_session_fail_closed() {
    let h = start().await;
    let mut s = Stream::open(h.addr).await;
    let r = s
        .send(req_trailers(&[("x-evil", "1 UNION SELECT 1")]))
        .await
        .unwrap();
    assert_fail_closed(&r, "trailers with no session");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn trailers_after_allowed_body_continue_uninspected() {
    // Trailers are not inspected; they must not open a hole and must not deny.
    let h = start().await;
    let mut s = Stream::open(h.addr).await;
    assert_continue(
        &s.send(req_headers(
            "POST",
            "/post",
            &[("content-type", "application/x-www-form-urlencoded")],
            false,
        ))
        .await
        .unwrap(),
        "headers",
    );
    assert_continue(
        &s.send(req_body(b"name=alice", true)).await.unwrap(),
        "body",
    );
    let r = s
        .send(req_trailers(&[("x-attack", "1 UNION SELECT password")]))
        .await
        .unwrap();
    assert!(
        matches!(r.response, Some(ProcResponse::RequestTrailers(_))),
        "trailers Continue (uninspected), got {:?}",
        r.response
    );
    assert_eq!(h.metrics.deny_total(), 0);
    assert_eq!(h.metrics.fail_closed_total(), 0);
}

async fn http_get(addr: SocketAddr, path: &str) -> String {
    let mut sock = TcpStream::connect(addr).await.expect("connect");
    sock.write_all(format!("GET {path} HTTP/1.1\r\nHost: x\r\n\r\n").as_bytes())
        .await
        .expect("write");
    let mut out = String::new();
    sock.read_to_string(&mut out).await.expect("read");
    out
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn healthz_exercises_process_and_metrics_render() {
    let h = start().await;
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let maddr = listener.local_addr().unwrap();
    tokio::spawn(metrics_server::serve(listener, h.processor.clone(), h.addr));

    let health = http_get(maddr, "/healthz").await;
    assert!(health.starts_with("HTTP/1.1 200"), "{health}");

    let metrics = http_get(maddr, "/metrics").await;
    assert!(metrics.starts_with("HTTP/1.1 200"), "{metrics}");
    assert!(metrics.contains("ext_proc_requests_total 1"), "{metrics}");
    assert!(metrics.contains("ext_proc_phase_request_headers_seconds_bucket"));

    let missing = http_get(maddr, "/nope").await;
    assert!(missing.starts_with("HTTP/1.1 404"), "{missing}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn healthz_is_503_when_grpc_is_down() {
    let dead = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let dead_addr = dead.local_addr().unwrap();
    drop(dead);
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let maddr = listener.local_addr().unwrap();
    tokio::spawn(metrics_server::serve(listener, processor(), dead_addr));
    let health = http_get(maddr, "/healthz").await;
    assert!(health.starts_with("HTTP/1.1 503"), "{health}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn healthz_is_503_when_listener_does_not_speak_http2() {
    let fake = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let fake_addr = fake.local_addr().unwrap();
    tokio::spawn(async move {
        while let Ok((mut sock, _)) = fake.accept().await {
            let _ = sock.write_all(b"HTTP/1.1 400 Bad Request\r\n\r\n").await;
        }
    });
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let maddr = listener.local_addr().unwrap();
    tokio::spawn(metrics_server::serve(listener, processor(), fake_addr));
    let health = http_get(maddr, "/healthz").await;
    assert!(health.starts_with("HTTP/1.1 503"), "{health}");
}
