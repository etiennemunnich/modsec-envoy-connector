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
use ext_proc_modsec::pb::envoy::extensions::filters::http::ext_proc::v3::processing_mode::BodySendMode;
use ext_proc_modsec::pb::envoy::service::ext_proc::v3::body_mutation::Mutation;
use ext_proc_modsec::pb::envoy::service::ext_proc::v3::external_processor_client::ExternalProcessorClient;
use ext_proc_modsec::pb::envoy::service::ext_proc::v3::processing_request::Request as ProcRequest;
use ext_proc_modsec::pb::envoy::service::ext_proc::v3::processing_response::Response as ProcResponse;
use ext_proc_modsec::pb::envoy::service::ext_proc::v3::{
    HttpBody, HttpHeaders, HttpTrailers, ProcessingRequest, ProcessingResponse,
    ProtocolConfiguration,
};
use ext_proc_modsec::pb::google::protobuf::{value::Kind, Struct, Value};
use ext_proc_modsec::{metrics_server, BodyReply, Limits, ModSecProcessor};
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

impl Harness {
    /// A stream whose first message declares STREAMED (`--body-reply
    /// common`) or FULL_DUPLEX_STREAMED (`streamed`) in both directions.
    async fn stream(&self) -> Stream {
        let mode = match self.processor.expected_protocol_config().request_body_mode {
            m if m == BodySendMode::FullDuplexStreamed as i32 => BodySendMode::FullDuplexStreamed,
            _ => BodySendMode::Streamed,
        };
        self.stream_with(mode, mode).await
    }

    async fn stream_with(&self, request: BodySendMode, response: BodySendMode) -> Stream {
        let mut s = Stream::open(self.addr).await;
        s.config = Some(modes(request, response));
        s
    }
}

fn modes(request: BodySendMode, response: BodySendMode) -> ProtocolConfiguration {
    ProtocolConfiguration {
        request_body_mode: request as i32,
        response_body_mode: response as i32,
        send_body_without_waiting_for_header_response: false,
    }
}

fn processor() -> ModSecProcessor {
    processor_with(BodyReply::Common, Limits::default())
}

fn processor_with(body_reply: BodyReply, limits: Limits) -> ModSecProcessor {
    let engine = Engine::load_files(&[rules_path("connector-test.conf")]).expect("rules");
    ModSecProcessor::with_limits(
        engine,
        Arc::new(ConnectorMetrics::default()),
        body_reply,
        limits,
    )
}

async fn start() -> Harness {
    start_with(BodyReply::Common, Limits::default()).await
}

/// `--body-reply streamed` (Envoy FULL_DUPLEX_STREAMED).
async fn start_duplex() -> Harness {
    start_with(BodyReply::Streamed, Limits::default()).await
}

async fn start_with(body_reply: BodyReply, limits: Limits) -> Harness {
    serve(processor_with(body_reply, limits)).await
}

async fn serve(processor: ModSecProcessor) -> Harness {
    let metrics = Arc::clone(processor.metrics());
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let addr = listener.local_addr().expect("addr");
    // Same service construction (message limits) as the product binary.
    let svc = processor.clone().into_server();
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
    /// Put on the next message sent, as Envoy does on the first one.
    config: Option<ProtocolConfiguration>,
}

impl Stream {
    /// A stream that sends no `protocol_config` (see [`Harness::stream`]).
    async fn open(addr: SocketAddr) -> Self {
        let channel = Channel::from_shared(format!("http://{addr}"))
            .expect("uri")
            .connect()
            .await
            .expect("connect");
        // Envoy's ext_proc client has no receive limit by default.
        let mut client = ExternalProcessorClient::new(channel)
            .max_decoding_message_size(usize::MAX)
            .max_encoding_message_size(usize::MAX);
        let (tx, rx) = mpsc::channel(8);
        let rx = client
            .process(ReceiverStream::new(rx))
            .await
            .expect("process")
            .into_inner();
        Self {
            tx,
            rx,
            config: None,
        }
    }

    fn stamp(&mut self, mut req: ProcessingRequest) -> ProcessingRequest {
        if let Some(config) = self.config.take() {
            req.protocol_config.get_or_insert(config);
        }
        req
    }

    async fn send(&mut self, req: ProcessingRequest) -> Result<ProcessingResponse, tonic::Status> {
        let req = self.stamp(req);
        self.tx.send(req).await.expect("send");
        tokio::time::timeout(Duration::from_secs(5), self.rx.next())
            .await
            .expect("answer within 5s")
            .expect("stream answered")
    }

    /// Send without waiting for an answer (FULL_DUPLEX holds body chunks;
    /// observability mode expects none).
    async fn push(&mut self, req: ProcessingRequest) {
        let req = self.stamp(req);
        self.tx.send(req).await.expect("send");
    }

    /// The next item on the reply stream: `None` is a gRPC-OK close.
    async fn next(&mut self) -> Option<Result<ProcessingResponse, tonic::Status>> {
        tokio::time::timeout(Duration::from_secs(10), self.rx.next())
            .await
            .expect("stream item within 10s")
    }

    /// Envoy half-closes its side; returns what the connector does next.
    async fn close_send(mut self) -> Option<Result<ProcessingResponse, tonic::Status>> {
        drop(self.tx);
        tokio::time::timeout(Duration::from_secs(5), self.rx.next())
            .await
            .expect("stream item within 5s")
    }

    async fn expect_closed(&mut self) {
        let next = tokio::time::timeout(Duration::from_secs(5), self.rx.next())
            .await
            .expect("close within 5s");
        assert!(next.is_none(), "stream must close after a terminal reply");
    }
}

/// A read error, panic or drop must reach Envoy as a non-OK gRPC status:
/// a clean close (`None`) makes Envoy continue the exchange uninspected.
fn assert_stream_error(
    next: Option<Result<ProcessingResponse, tonic::Status>>,
    want: tonic::Code,
    what: &str,
) -> tonic::Status {
    match next {
        Some(Err(status)) => {
            assert_ne!(status.code(), tonic::Code::Ok, "{what}");
            assert_eq!(status.code(), want, "{what}: {status:?}");
            status
        }
        Some(Ok(r)) => panic!("{what}: want gRPC error, got reply {:?}", r.response),
        None => panic!("{what}: stream ended with gRPC OK (Envoy would continue = fail-open)"),
    }
}

fn streamed_echo(r: &ProcessingResponse, dir: &str) -> (Vec<u8>, bool) {
    let body = match (&r.response, dir) {
        (Some(ProcResponse::RequestBody(b)), "request") => b,
        (Some(ProcResponse::ResponseBody(b)), "response") => b,
        other => panic!("want {dir} StreamedBodyResponse, got {other:?}"),
    };
    let mutation = body
        .response
        .as_ref()
        .and_then(|c| c.body_mutation.as_ref())
        .and_then(|m| m.mutation.as_ref());
    match mutation {
        Some(Mutation::StreamedResponse(s)) => (s.body.clone(), s.end_of_stream),
        other => panic!("want streamed_response mutation, got {other:?}"),
    }
}

fn resp_trailers() -> ProcessingRequest {
    ProcessingRequest {
        request: Some(ProcRequest::ResponseTrailers(HttpTrailers {
            trailers: Some(HeaderMap {
                headers: vec![hv("grpc-status", "0")],
            }),
        })),
        ..Default::default()
    }
}

fn form_post() -> ProcessingRequest {
    req_headers(
        "POST",
        "/post",
        &[("content-type", "application/x-www-form-urlencoded")],
        false,
    )
}

fn hv(k: &str, v: &str) -> HeaderValue {
    HeaderValue {
        key: k.into(),
        raw_value: v.as_bytes().to_vec(),
        ..Default::default()
    }
}

fn req_headers_raw(pairs: &[(&str, &str)], eos: bool) -> ProcessingRequest {
    ProcessingRequest {
        request: Some(ProcRequest::RequestHeaders(HttpHeaders {
            headers: Some(HeaderMap {
                headers: pairs.iter().map(|(k, v)| hv(k, v)).collect(),
            }),
            end_of_stream: eos,
            ..Default::default()
        })),
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
            | Some(ProcResponse::RequestTrailers(_))
            | Some(ProcResponse::ResponseTrailers(_))
    );
    assert!(ok, "{what}: expected Continue, got {:?}", r.response);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn benign_exchange_continues_every_phase() {
    let h = start().await;
    let mut s = h.stream().await;
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
    let mut s = h.stream().await;
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
    let mut s = h.stream().await;
    let r = s
        .send(req_headers("GET", "/teapot", &[], true))
        .await
        .unwrap();
    assert_eq!(immediate(&r).expect("immediate").0, 406);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn redirect_sets_location() {
    let h = start().await;
    let mut s = h.stream().await;
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
    let mut s = h.stream().await;
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
    let mut s = h.stream().await;
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
    let mut s = h.stream().await;
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
    let mut s = h.stream().await;
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
    let mut s = h.stream().await;
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
    let mut s = h.stream().await;
    let r = s.send(req_body(b"x", true)).await.unwrap();
    let (code, details, _) = immediate(&r).expect("immediate");
    assert_eq!(code, 500);
    assert_eq!(details, "modsec_fail_closed");
    assert_eq!(h.metrics.fail_closed_total(), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn response_before_request_fails_closed() {
    let h = start().await;
    let mut s = h.stream().await;
    let r = s.send(resp_headers("200", &[], true)).await.unwrap();
    assert_eq!(immediate(&r).expect("immediate").0, 500);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn envoy_local_reply_without_request_passes_through() {
    let h = start().await;
    for status in ["400", "404", "503"] {
        let mut s = h.stream().await;
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
        let mut s = h.stream().await;
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
    let mut s = h.stream().await;
    assert!(matches!(
        s.send(resp_headers("400", &[], false))
            .await
            .unwrap()
            .response,
        Some(ProcResponse::ResponseHeaders(_))
    ));
    let r = s.send(req_body(b"x", true)).await.unwrap();
    assert_eq!(immediate(&r).expect("immediate").0, 500);

    let mut s = h.stream().await;
    s.send(resp_headers("400", &[], false)).await.unwrap();
    let r = s.send(req_headers("GET", "/", &[], true)).await.unwrap();
    assert_eq!(immediate(&r).expect("immediate").0, 500);

    let mut s = h.stream().await;
    s.send(resp_headers("400", &[], false)).await.unwrap();
    let r = s.send(resp_headers("400", &[], false)).await.unwrap();
    assert_eq!(immediate(&r).expect("immediate").0, 500);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn duplicate_request_headers_fail_closed() {
    let h = start().await;
    let mut s = h.stream().await;
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
    let mut s = h.stream().await;
    let r = s.send(ProcessingRequest::default()).await.unwrap();
    assert_eq!(immediate(&r).expect("immediate").0, 500);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn invalid_response_status_fails_closed() {
    let h = start().await;
    let mut s = h.stream().await;
    assert_continue(
        &s.send(req_headers("GET", "/", &[], true)).await.unwrap(),
        "req",
    );
    let r = s.send(resp_headers("abc", &[], true)).await.unwrap();
    assert_eq!(immediate(&r).expect("immediate").0, 500);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn authority_becomes_host_when_host_is_absent() {
    let h = start().await;
    let mut s = h.stream().await;
    let r = s
        .send(req_headers_raw(
            &[
                (":method", "GET"),
                (":path", "/"),
                (":authority", "blocked.test"),
                (":scheme", "http"),
            ],
            true,
        ))
        .await
        .unwrap();
    assert_eq!(immediate(&r).expect("immediate").0, 403);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn explicit_host_is_not_replaced_by_authority() {
    let h = start().await;
    let mut s = h.stream().await;
    let r = s
        .send(req_headers_raw(
            &[
                (":method", "GET"),
                (":path", "/"),
                (":authority", "blocked.test"),
                (":scheme", "http"),
                ("host", "app.test"),
            ],
            true,
        ))
        .await
        .unwrap();
    assert_continue(&r, "explicit host wins");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn missing_method_and_path_still_run_phase1() {
    let h = start().await;
    let mut s = h.stream().await;
    let r = s
        .send(req_headers_raw(
            &[(":authority", "app.test"), (":scheme", "http")],
            true,
        ))
        .await
        .unwrap();
    assert_continue(&r, "omitted pseudo-headers are GET /");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn trace_method_reaches_modsecurity() {
    let h = start().await;
    let mut s = h.stream().await;
    let r = s.send(req_headers("TRACE", "/", &[], true)).await.unwrap();
    assert_eq!(immediate(&r).expect("immediate").0, 403);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn connect_is_rejected() {
    let h = start().await;
    let mut s = h.stream().await;
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
    let mut s = h.stream().await;
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
    let mut s = h.stream().await;
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
    let mut s = h.stream().await;
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
    let mut s = h.stream().await;
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
    let mut s = h.stream().await;
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
    let mut s = h.stream().await;
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
    let mut s = h.stream().await;
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
    let mut s = h.stream().await;
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
    let mut s = h.stream().await;
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
    let mut s = h.stream().await;
    let r = s
        .send(req_trailers(&[("x-evil", "1 UNION SELECT 1")]))
        .await
        .unwrap();
    assert_fail_closed(&r, "trailers with no session");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn trailers_after_allowed_body_continue_uninspected() {
    // Trailers values are not CRS-inspected; they must not open a hole and must not deny.
    let h = start().await;
    let mut s = h.stream().await;
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

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn streamed_body_sqli_denied_when_trailers_mark_eos() {
    // Envoy STREAMED/BUFFERED with trailers: last body chunk has eos=false,
    // then request_trailers. Body must still be CRS-denied; trailer values
    // themselves are not inspected.
    let h = start().await;
    let mut s = h.stream().await;
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
        &s.send(req_body(b"q=1 UNION SELECT password FROM users", false))
            .await
            .unwrap(),
        "body eos=false",
    );
    let r = s
        .send(req_trailers(&[("x-harmless", "trailers-not-inspected")]))
        .await
        .unwrap();
    assert_eq!(
        immediate(&r).expect("deny at trailers finalize").0,
        403,
        "body SQLi must deny when trailers mark EOS"
    );
    s.expect_closed().await;
    assert_eq!(h.metrics.allow_total(), 0);
    assert_eq!(h.metrics.deny_total(), 1);
    assert_eq!(h.metrics.fail_closed_total(), 0);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn streamed_allow_then_trailers_continue_no_spurious_500() {
    let h = start().await;
    let mut s = h.stream().await;
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
        &s.send(req_body(b"name=alice", false)).await.unwrap(),
        "body eos=false",
    );
    let r = s
        .send(req_trailers(&[("x-attack", "1 UNION SELECT password")]))
        .await
        .unwrap();
    assert!(
        matches!(r.response, Some(ProcResponse::RequestTrailers(_))),
        "allow + trailers Continue (trailer attack uninspected), got {:?}",
        r.response
    );
    assert_eq!(h.metrics.allow_total(), 1);
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
    tokio::spawn(metrics_server::serve(
        listener,
        h.processor.clone(),
        h.addr,
        false,
    ));

    for _ in 0..5 {
        let health = http_get(maddr, "/healthz").await;
        assert!(health.starts_with("HTTP/1.1 200"), "{health}");
    }

    // Probes run the real Exchange but must not count as traffic.
    let metrics = http_get(maddr, "/metrics").await;
    assert!(metrics.starts_with("HTTP/1.1 200"), "{metrics}");
    assert!(metrics.contains("ext_proc_requests_total 0\n"), "{metrics}");
    assert!(metrics.contains("ext_proc_allow_total 0\n"), "{metrics}");
    assert!(
        metrics.contains("ext_proc_phase_request_headers_seconds_count 0\n"),
        "{metrics}"
    );
    assert_eq!(h.metrics.allow_total(), 0);

    // Real traffic still counts.
    let mut s = h.stream().await;
    assert_continue(
        &s.send(req_headers("GET", "/", &[], true)).await.unwrap(),
        "req",
    );
    let metrics = http_get(maddr, "/metrics").await;
    assert!(metrics.contains("ext_proc_requests_total 1\n"), "{metrics}");
    assert!(metrics.contains("ext_proc_phase_request_headers_seconds_bucket"));

    let missing = http_get(maddr, "/nope").await;
    assert!(missing.starts_with("HTTP/1.1 404"), "{missing}");

    let health = http_get(maddr, "/healthz").await;
    let rules = h.processor.engine().rule_count();
    assert!(
        health.ends_with(&format!("ok\nengine_mode=On\nrules={rules}\n")),
        "{health}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn healthz_is_503_unless_the_engine_enforces() {
    let engine = Engine::load_files(&[rules_path("detection-only.conf")]).expect("rules");
    let p = ModSecProcessor::new(engine, Arc::new(ConnectorMetrics::default()));
    let h = serve(p).await;
    for (allow, want) in [(false, "HTTP/1.1 503"), (true, "HTTP/1.1 200")] {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let maddr = listener.local_addr().unwrap();
        tokio::spawn(metrics_server::serve(
            listener,
            h.processor.clone(),
            h.addr,
            allow,
        ));
        let health = http_get(maddr, "/healthz").await;
        assert!(health.starts_with(want), "allow={allow}: {health}");
        assert!(
            health.contains("engine_mode=DetectionOnly\nrules=1\n"),
            "{health}"
        );
    }
    // What the gate is for: a deny rule matches and the request passes.
    let mut s = h.stream().await;
    assert_continue(
        &s.send(req_headers("GET", "/admin", &[], true))
            .await
            .unwrap(),
        "admin",
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn healthz_is_503_when_grpc_is_down() {
    let dead = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let dead_addr = dead.local_addr().unwrap();
    drop(dead);
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let maddr = listener.local_addr().unwrap();
    tokio::spawn(metrics_server::serve(
        listener,
        processor(),
        dead_addr,
        false,
    ));
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
    tokio::spawn(metrics_server::serve(
        listener,
        processor(),
        fake_addr,
        false,
    ));
    let health = http_get(maddr, "/healthz").await;
    assert!(health.starts_with("HTTP/1.1 503"), "{health}");
}

// --- Stream termination: never a gRPC-OK close without a verdict -------------
// Envoy v1.39 treats an OK close as "processing complete" and forwards
// whatever it holds (onGrpcClose → clearAsyncState), so every abnormal end
// must be a non-OK status, which failure_mode_allow: false turns into 500.

fn sqli_body(len: usize) -> Vec<u8> {
    let mut body = b"q=1 UNION SELECT password FROM users&pad=".to_vec();
    body.resize(len, b'A');
    body
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn oversize_message_aborts_stream_never_ok() {
    // 5 MiB > default --max-grpc-message-bytes (4 MiB): tonic cannot decode
    // it. Before the fix this closed the stream with grpc-status 0 and Envoy
    // forwarded the SQLi body to origin.
    let h = start().await;
    let mut s = h.stream().await;
    assert_continue(&s.send(form_post()).await.unwrap(), "headers");
    s.push(req_body(&sqli_body(5 * 1024 * 1024), true)).await;
    let status = assert_stream_error(s.next().await, tonic::Code::Internal, "oversize body");
    assert!(status.message().contains("fail-closed"), "{status:?}");
    assert!(s.next().await.is_none(), "nothing follows the error");
    assert_eq!(h.metrics.stream_errors_total(), 1);
    assert_eq!(h.metrics.allow_total(), 0);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn oversize_message_never_ok_in_full_duplex() {
    let h = start_duplex().await;
    let mut s = h.stream().await;
    assert_continue(&s.send(form_post()).await.unwrap(), "headers");
    s.push(req_body(&sqli_body(5 * 1024 * 1024), true)).await;
    assert_stream_error(
        s.next().await,
        tonic::Code::Internal,
        "oversize duplex body",
    );
    assert_eq!(h.metrics.allow_total(), 0);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn raised_message_limit_inspects_large_body() {
    // Negative control for the oversize case: with the limit raised above the
    // message, the same 5 MiB body is decoded and CRS-style denied.
    let limits = Limits {
        max_grpc_message_bytes: 8 * 1024 * 1024,
        max_held_body_bytes: 8 * 1024 * 1024,
        ..Limits::default()
    };
    let h = start_with(BodyReply::Common, limits).await;
    let mut s = h.stream().await;
    assert_continue(&s.send(form_post()).await.unwrap(), "headers");
    let r = s
        .send(req_body(&sqli_body(5 * 1024 * 1024), true))
        .await
        .unwrap();
    assert_eq!(immediate(&r).expect("deny").0, 403);
    s.expect_closed().await;
    assert_eq!(h.metrics.stream_errors_total(), 0);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn half_close_with_held_body_aborts_stream() {
    // FULL_DUPLEX holds the body unanswered; if Envoy's side ends there, an
    // OK close would let Envoy inject the held chunks uninspected.
    let h = start_duplex().await;
    let mut s = h.stream().await;
    assert_continue(&s.send(form_post()).await.unwrap(), "headers");
    s.push(req_body(b"q=1 UNION SELECT password", false)).await;
    let next = s.close_send().await;
    assert_stream_error(next, tonic::Code::Internal, "half-close with held body");
    assert_eq!(h.metrics.stream_errors_total(), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn half_close_with_nothing_pending_is_clean() {
    let h = start().await;
    let mut s = h.stream().await;
    assert_continue(
        &s.send(req_headers("GET", "/", &[], true)).await.unwrap(),
        "req",
    );
    assert!(
        s.close_send().await.is_none(),
        "every message answered: OK close"
    );
    assert_eq!(h.metrics.stream_errors_total(), 0);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn panic_resets_stream_never_ok() {
    // A connector panic must reach Envoy as a stream reset (h2 RST_STREAM →
    // tonic Cancelled/Unknown), never a clean OK close.
    let h = start().await;
    let mut s = h.stream().await;
    assert_continue(&s.send(form_post()).await.unwrap(), "headers");
    h.processor.engine().inject_panic_next_transaction_step();
    s.push(req_body(b"name=alice", true)).await;
    match s.next().await {
        Some(Err(status)) => assert_ne!(status.code(), tonic::Code::Ok, "{status:?}"),
        Some(Ok(r)) => panic!("panic answered a reply: {:?}", r.response),
        None => panic!("panic ended the stream with gRPC OK (fail-open)"),
    }
    assert_eq!(h.metrics.allow_total(), 0);

    // The server keeps serving other streams.
    let mut s = h.stream().await;
    assert_continue(
        &s.send(req_headers("GET", "/", &[], true)).await.unwrap(),
        "after panic",
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn drop_intervention_aborts_stream() {
    let h = start().await;
    let mut s = h.stream().await;
    s.push(req_headers("GET", "/drop-zero", &[], true)).await;
    assert_stream_error(s.next().await, tonic::Code::Aborted, "status-0 drop");
    assert_eq!(h.metrics.deny_total(), 1);
    assert_eq!(h.metrics.allow_total(), 0);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn observability_mode_messages_get_no_answer() {
    // Envoy does not wait for answers in observability mode; the connector
    // must not answer (a deny would be meaningless and desync the stream).
    let h = start().await;
    let mut s = h.stream().await;
    let mut observed = req_headers("GET", "/admin", &[], true);
    observed.observability_mode = true;
    // Envoy sends no protocol_config in observability mode.
    s.tx.send(observed).await.expect("send");
    let r = s.send(req_headers("GET", "/", &[], true)).await.unwrap();
    assert!(
        matches!(r.response, Some(ProcResponse::RequestHeaders(_))),
        "first answer belongs to the non-observability message, got {:?}",
        r.response
    );
    assert_eq!(h.metrics.deny_total(), 0);
    assert_eq!(h.metrics.allow_total(), 1);
}

// --- Response trailers --------------------------------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn response_trailers_continue_after_allowed_response() {
    let h = start().await;
    let mut s = h.stream().await;
    assert_continue(
        &s.send(req_headers("GET", "/", &[], true)).await.unwrap(),
        "req",
    );
    assert_continue(
        &s.send(resp_headers("200", &[], false)).await.unwrap(),
        "resp",
    );
    assert_continue(
        &s.send(resp_body(b"hello", false)).await.unwrap(),
        "resp body",
    );
    let r = s.send(resp_trailers()).await.unwrap();
    assert!(
        matches!(r.response, Some(ProcResponse::ResponseTrailers(_))),
        "{:?}",
        r.response
    );
    assert_eq!(h.metrics.deny_total(), 0);
    assert_eq!(h.metrics.fail_closed_total(), 0);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn response_body_denied_when_response_trailers_mark_eos() {
    let h = start().await;
    let mut s = h.stream().await;
    assert_continue(
        &s.send(req_headers("GET", "/", &[], true)).await.unwrap(),
        "req",
    );
    assert_continue(
        &s.send(resp_headers("200", &[], false)).await.unwrap(),
        "resp",
    );
    assert_continue(
        &s.send(resp_body(b"token=CONNEX-LEAK-MARKER", false))
            .await
            .unwrap(),
        "resp body eos=false",
    );
    let r = s.send(resp_trailers()).await.unwrap();
    assert_eq!(immediate(&r).expect("deny at trailers").0, 403);
    s.expect_closed().await;
}

// --- FULL_DUPLEX_STREAMED (--body-reply streamed) ------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn full_duplex_benign_chunks_echo_once_after_allow() {
    let h = start_duplex().await;
    let mut s = h.stream().await;
    assert_continue(&s.send(form_post()).await.unwrap(), "headers");
    s.push(req_body(b"name=", false)).await;
    s.push(req_body(b"alice", false)).await;
    s.push(req_body(b"", true)).await;
    // The first answer is the whole body: nothing was released per chunk.
    let r = s.next().await.expect("answer").expect("ok");
    assert_eq!(streamed_echo(&r, "request"), (b"name=alice".to_vec(), true));
    assert_eq!(h.metrics.allow_total(), 1);

    assert_continue(
        &s.send(resp_headers("200", &[], false)).await.unwrap(),
        "resp",
    );
    s.push(resp_body(b"hello ", false)).await;
    s.push(resp_body(b"world", true)).await;
    let r = s.next().await.expect("answer").expect("ok");
    assert_eq!(
        streamed_echo(&r, "response"),
        (b"hello world".to_vec(), true)
    );
    assert!(s.close_send().await.is_none(), "all answered: OK close");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn full_duplex_sqli_denied_at_eos_nothing_echoed() {
    let h = start_duplex().await;
    let mut s = h.stream().await;
    assert_continue(&s.send(form_post()).await.unwrap(), "headers");
    s.push(req_body(b"q=1 ", false)).await;
    s.push(req_body(b"UNION ", false)).await;
    s.push(req_body(b"SELECT password FROM users", true)).await;
    let r = s.next().await.expect("answer").expect("ok");
    assert_eq!(immediate(&r).expect("deny, not echo").0, 403);
    s.expect_closed().await;
    assert_eq!(h.metrics.allow_total(), 0);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn full_duplex_trailers_release_held_body_then_trailers() {
    let h = start_duplex().await;
    let mut s = h.stream().await;
    assert_continue(&s.send(form_post()).await.unwrap(), "headers");
    s.push(req_body(b"name=alice", false)).await;
    s.push(req_trailers(&[("x-trailer", "1")])).await;
    let r = s.next().await.expect("body").expect("ok");
    assert_eq!(streamed_echo(&r, "request"), (b"name=alice".to_vec(), true));
    let r = s.next().await.expect("trailers").expect("ok");
    assert!(
        matches!(r.response, Some(ProcResponse::RequestTrailers(_))),
        "{:?}",
        r.response
    );
    assert_eq!(h.metrics.allow_total(), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn full_duplex_sqli_denied_when_trailers_mark_eos() {
    let h = start_duplex().await;
    let mut s = h.stream().await;
    assert_continue(&s.send(form_post()).await.unwrap(), "headers");
    s.push(req_body(b"q=1 UNION SELECT password FROM users", false))
        .await;
    s.push(req_trailers(&[("x-trailer", "1")])).await;
    let r = s.next().await.expect("answer").expect("ok");
    assert_eq!(immediate(&r).expect("deny at trailers").0, 403);
    s.expect_closed().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn full_duplex_headers_then_trailers_without_body_answers_trailers_only() {
    // Envoy sends no body message for headers → trailers and rejects a body
    // reply it did not ask for (spurious → 500), e.g. a gRPC upstream that
    // answers HEADERS + trailers with zero DATA frames.
    let h = start_duplex().await;
    let mut s = h.stream().await;
    assert_continue(&s.send(form_post()).await.unwrap(), "headers");
    let r = s.send(req_trailers(&[("x-trailer", "1")])).await.unwrap();
    assert!(
        matches!(r.response, Some(ProcResponse::RequestTrailers(_))),
        "request trailers only, got {:?}",
        r.response
    );
    assert_continue(
        &s.send(resp_headers("200", &[], false)).await.unwrap(),
        "resp",
    );
    let r = s.send(resp_trailers()).await.unwrap();
    assert!(
        matches!(r.response, Some(ProcResponse::ResponseTrailers(_))),
        "response trailers only, got {:?}",
        r.response
    );
    assert!(s.close_send().await.is_none(), "no extra replies queued");
    assert_eq!(h.metrics.allow_total(), 1);
    assert_eq!(h.metrics.fail_closed_total(), 0);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn full_duplex_response_body_marker_denied() {
    let h = start_duplex().await;
    let mut s = h.stream().await;
    assert_continue(
        &s.send(req_headers("GET", "/", &[], true)).await.unwrap(),
        "req",
    );
    assert_continue(
        &s.send(resp_headers("200", &[], false)).await.unwrap(),
        "resp",
    );
    s.push(resp_body(b"token=CONNEX-", false)).await;
    s.push(resp_body(b"LEAK-MARKER\n", true)).await;
    let r = s.next().await.expect("answer").expect("ok");
    assert_eq!(immediate(&r).expect("deny, not echo").0, 403);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn full_duplex_local_reply_body_echoes_per_chunk() {
    let h = start_duplex().await;
    let mut s = h.stream().await;
    let r = s.send(resp_headers("400", &[], false)).await.unwrap();
    assert!(matches!(r.response, Some(ProcResponse::ResponseHeaders(_))));
    let r = s.send(resp_body(b"Bad ", false)).await.unwrap();
    assert_eq!(streamed_echo(&r, "response"), (b"Bad ".to_vec(), false));
    let r = s.send(resp_body(b"Request", true)).await.unwrap();
    assert_eq!(streamed_echo(&r, "response"), (b"Request".to_vec(), true));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn full_duplex_held_body_cap_fails_closed() {
    let limits = Limits {
        max_grpc_message_bytes: 4 * 1024 * 1024,
        max_held_body_bytes: 1024,
        ..Limits::default()
    };
    let h = start_with(BodyReply::Streamed, limits).await;

    // Exactly at the cap: held, then echoed.
    let mut s = h.stream().await;
    assert_continue(&s.send(form_post()).await.unwrap(), "headers");
    s.push(req_body(&[b'a'; 512], false)).await;
    s.push(req_body(&[b'b'; 512], true)).await;
    let r = s.next().await.expect("answer").expect("ok");
    assert_eq!(streamed_echo(&r, "request").0.len(), 1024);

    // One byte over: 500 before anything is echoed.
    let mut s = h.stream().await;
    assert_continue(&s.send(form_post()).await.unwrap(), "headers");
    s.push(req_body(&[b'a'; 512], false)).await;
    s.push(req_body(&[b'b'; 513], false)).await;
    let r = s.next().await.expect("answer").expect("ok");
    assert_fail_closed(&r, "held body over cap");
    s.expect_closed().await;
    assert_eq!(h.metrics.fail_closed_total(), 1);

    // Response direction too.
    let mut s = h.stream().await;
    assert_continue(
        &s.send(req_headers("GET", "/", &[], true)).await.unwrap(),
        "req",
    );
    assert_continue(
        &s.send(resp_headers("200", &[], false)).await.unwrap(),
        "resp",
    );
    s.push(resp_body(&[b'x'; 2048], false)).await;
    let r = s.next().await.expect("answer").expect("ok");
    assert_fail_closed(&r, "held response body over cap");
    assert_eq!(h.metrics.fail_closed_total(), 2);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn full_duplex_default_cap_bounds_held_body() {
    // 5 × 1 MiB chunks: each message decodes (< 4 MiB) but the held total
    // passes the default cap (= --max-grpc-message-bytes), so the connector
    // fails closed instead of growing without bound.
    let h = start_duplex().await;
    let mut s = h.stream().await;
    assert_continue(&s.send(form_post()).await.unwrap(), "headers");
    for _ in 0..5 {
        s.push(req_body(&vec![b'a'; 1024 * 1024], false)).await;
    }
    let r = s.next().await.expect("answer").expect("ok");
    assert_fail_closed(&r, "default held cap");
    assert_eq!(h.metrics.allow_total(), 0);
}

// --- Logging phase still runs after the reply ----------------------------------

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn audit_log_written_after_deny_off_the_reply_path() {
    // The session (and its logging phase) is dropped on the blocking pool
    // after the terminal reply; the audit record must still be written.
    let dir = std::env::temp_dir().join(format!("connex-audit-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("tmp dir");
    let audit = dir.join("audit.log");
    let rules = dir.join("audit.conf");
    std::fs::write(
        &rules,
        format!(
            "SecRuleEngine On\nSecAuditEngine On\nSecAuditLogType Serial\n\
             SecAuditLogParts ABZ\nSecAuditLog {}\n\
             SecRule REQUEST_URI \"@contains /admin\" \"id:1,phase:1,deny,status:403\"\n",
            audit.display()
        ),
    )
    .expect("write rules");
    let engine = Engine::load_files(&[&rules]).expect("rules");
    let h = serve(ModSecProcessor::new(
        engine,
        Arc::new(ConnectorMetrics::default()),
    ))
    .await;
    let mut s = h.stream().await;
    let r = s
        .send(req_headers(
            "GET",
            "/admin",
            &[("x-request-id", "rid-audit-1")],
            true,
        ))
        .await
        .unwrap();
    assert_eq!(immediate(&r).expect("deny").0, 403);
    s.expect_closed().await;
    let mut found = false;
    for _ in 0..50 {
        if std::fs::read_to_string(&audit).is_ok_and(|t| t.contains("/admin")) {
            found = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    let _ = std::fs::remove_dir_all(&dir);
    assert!(found, "logging phase must still write the audit record");
}

// --- /healthz probe logs at DEBUG ---------------------------------------------

#[derive(Clone, Default)]
struct Levels(Arc<std::sync::Mutex<Vec<(tracing::Level, String)>>>);

impl tracing::Subscriber for Levels {
    fn enabled(&self, _: &tracing::Metadata<'_>) -> bool {
        true
    }
    fn new_span(&self, _: &tracing::span::Attributes<'_>) -> tracing::span::Id {
        tracing::span::Id::from_u64(1)
    }
    fn record(&self, _: &tracing::span::Id, _: &tracing::span::Record<'_>) {}
    fn record_follows_from(&self, _: &tracing::span::Id, _: &tracing::span::Id) {}
    fn event(&self, event: &tracing::Event<'_>) {
        let m = event.metadata();
        self.0
            .lock()
            .unwrap()
            .push((*m.level(), m.target().to_owned()));
    }
    fn enter(&self, _: &tracing::span::Id) {}
    fn exit(&self, _: &tracing::span::Id) {}
}

impl Levels {
    fn info_or_above(&self) -> usize {
        self.0
            .lock()
            .unwrap()
            .iter()
            .filter(|(l, _)| *l <= tracing::Level::INFO)
            .count()
    }
}

#[test]
fn probe_exchange_logs_below_info_and_keeps_metrics_clean() {
    let p = processor();
    let run = |probe: bool| {
        let levels = Levels::default();
        let step = tracing::subscriber::with_default(levels.clone(), || {
            let mut ex = if probe {
                p.probe_exchange()
            } else {
                p.exchange()
            };
            let mut msg = req_headers("GET", "/", &[], true);
            msg.protocol_config = Some(p.expected_protocol_config());
            ex.on_message(msg)
        });
        assert!(
            matches!(step, ext_proc_modsec::processor::Step::Reply(_)),
            "{step:?}"
        );
        levels
    };
    // Negative control: real traffic logs its phases at INFO and counts.
    assert!(run(false).info_or_above() >= 2);
    assert_eq!(p.metrics().requests_total(), 1);
    let probe = run(true);
    assert_eq!(probe.info_or_above(), 0, "{:?}", probe.0.lock().unwrap());
    assert_eq!(p.metrics().requests_total(), 1, "probe must not count");
    assert_eq!(p.metrics().allow_total(), 1);
}

// --- Body modes from protocol_config ---------------------------------------
//
// Envoy marks a body that trailers follow with end_of_stream=false and, with
// trailer mode SKIP, never sends the trailers. Each mode below gets the
// message sequences Envoy v1.39.3 produces for body + trailers, trailers
// only, and (PARTIAL) a truncated body; the deny must answer the message
// Envoy holds the request on, never a later one.

const SQLI_FORM: &[u8] = b"q=1 union select password from users";
const SQLI_QUERY: &str = "/search?q=1%20union%20select%201";

fn assert_deny(r: &ProcessingResponse, what: &str) {
    let (code, details, _) =
        immediate(r).unwrap_or_else(|| panic!("{what}: want deny, got {:?}", r.response));
    assert_eq!(code, 403, "{what}: details={details}");
    assert_eq!(details, "modsecurity_intervention", "{what}");
}

fn assert_timed_out(r: &ProcessingResponse, what: &str) {
    let (code, details, _) =
        immediate(r).unwrap_or_else(|| panic!("{what}: want 504, got {:?}", r.response));
    assert_eq!(code, 504, "{what}");
    assert_eq!(details, "modsec_stream_timeout", "{what}");
}

/// Answer to a message Envoy sends in `mode`: FULL_DUPLEX holds non-final
/// body chunks without an answer.
async fn send_body(
    s: &mut Stream,
    mode: BodySendMode,
    body: &[u8],
    eos: bool,
) -> Option<ProcessingResponse> {
    let msg = req_body(body, eos);
    if mode == BodySendMode::FullDuplexStreamed && !eos {
        s.push(msg).await;
        None
    } else {
        Some(s.send(msg).await.expect("body answer"))
    }
}

async fn harness_for(mode: BodySendMode) -> Harness {
    if mode == BodySendMode::FullDuplexStreamed {
        start_duplex().await
    } else {
        start().await
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn single_message_modes_finish_the_body_phase_on_any_body() {
    for mode in [BodySendMode::Buffered, BodySendMode::BufferedPartial] {
        let h = start().await;
        // Body then trailers: Envoy sends the body with end_of_stream=false.
        let mut s = h.stream_with(mode, mode).await;
        assert_continue(&s.send(form_post()).await.unwrap(), "headers");
        let r = s.send(req_body(SQLI_FORM, false)).await.unwrap();
        assert_deny(&r, &format!("{mode:?}: SQLi body with eos=false"));
        s.expect_closed().await;

        // Benign body then trailers: allowed at the body, trailers Continue,
        // and the response is not mistaken for a skipped body phase.
        let mut s = h.stream_with(mode, mode).await;
        assert_continue(&s.send(form_post()).await.unwrap(), "headers");
        assert_continue(&s.send(req_body(b"q=hello", false)).await.unwrap(), "body");
        assert_eq!(h.metrics.allow_total(), 1, "{mode:?}: allowed at the body");
        assert_continue(
            &s.send(req_trailers(&[("x-t", "1")])).await.unwrap(),
            "trailers",
        );
        assert_continue(
            &s.send(resp_headers("200", &[], false)).await.unwrap(),
            "resp",
        );
        let r = s
            .send(resp_body(b"token=CONNEX-LEAK-MARKER", false))
            .await
            .unwrap();
        assert_deny(&r, &format!("{mode:?}: response body with eos=false"));
        assert_eq!(h.metrics.fail_closed_total(), 0, "{mode:?}");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn partial_truncated_body_is_inspected_as_sent() {
    let h = start().await;
    let partial = BodySendMode::BufferedPartial;
    // Envoy sends only the first buffer-limit bytes, end_of_stream=false,
    // and forwards the rest uninspected: the prefix is the inspected body.
    let mut s = h.stream_with(partial, partial).await;
    assert_continue(&s.send(form_post()).await.unwrap(), "headers");
    assert_deny(
        &s.send(req_body(SQLI_FORM, false)).await.unwrap(),
        "SQLi prefix",
    );

    let mut s = h.stream_with(partial, partial).await;
    assert_continue(&s.send(form_post()).await.unwrap(), "headers");
    assert_continue(
        &s.send(req_body(b"q=hello&pad=", false)).await.unwrap(),
        "prefix",
    );
    assert_continue(
        &s.send(resp_headers("200", &[], true)).await.unwrap(),
        "resp",
    );
    assert_eq!(h.metrics.allow_total(), 1);
    assert_eq!(h.metrics.fail_closed_total(), 0);
    assert!(
        s.close_send().await.is_none(),
        "verdict complete: clean close"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn streaming_modes_finish_the_body_phase_at_trailers() {
    for mode in [BodySendMode::Streamed, BodySendMode::FullDuplexStreamed] {
        let h = harness_for(mode).await;
        // Body then trailers: the chunk is not final; the trailers are.
        let mut s = h.stream_with(mode, mode).await;
        assert_continue(&s.send(form_post()).await.unwrap(), "headers");
        if let Some(r) = send_body(&mut s, mode, SQLI_FORM, false).await {
            assert_continue(&r, &format!("{mode:?}: non-final chunk"));
        }
        let r = s.send(req_trailers(&[("x-t", "1")])).await.unwrap();
        assert_deny(&r, &format!("{mode:?}: SQLi body, verdict at trailers"));
        s.expect_closed().await;
        assert_eq!(h.metrics.allow_total(), 0, "{mode:?}");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn trailers_only_request_runs_phase_two_at_the_trailers() {
    // HTTP/2 HEADERS then trailers, no DATA: Envoy sends no body message
    // in any mode; with trailer mode SEND the trailers end the phase.
    for mode in [
        BodySendMode::Buffered,
        BodySendMode::BufferedPartial,
        BodySendMode::Streamed,
        BodySendMode::FullDuplexStreamed,
    ] {
        let h = harness_for(mode).await;
        let mut s = h.stream_with(mode, mode).await;
        let r = s
            .send(req_headers("GET", SQLI_QUERY, &[], false))
            .await
            .unwrap();
        assert_continue(&r, &format!("{mode:?}: phase 1 passes"));
        let r = s.send(req_trailers(&[("x-t", "1")])).await.unwrap();
        assert_deny(&r, &format!("{mode:?}: query SQLi, verdict at trailers"));

        let mut s = h.stream_with(mode, mode).await;
        assert_continue(
            &s.send(req_headers("GET", "/q?q=hi", &[], false))
                .await
                .unwrap(),
            "h",
        );
        assert_continue(
            &s.send(req_trailers(&[("x-t", "1")])).await.unwrap(),
            "trailers",
        );
        assert_continue(
            &s.send(resp_headers("200", &[], true)).await.unwrap(),
            "resp",
        );
        assert_eq!(h.metrics.allow_total(), 1, "{mode:?}");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn response_before_the_request_body_phase_fails_closed() {
    // Trailer mode SKIP: Envoy forwards a request whose body ended with
    // trailers without a final body message. A success must not pass.
    for mode in [
        BodySendMode::Buffered,
        BodySendMode::BufferedPartial,
        BodySendMode::Streamed,
        BodySendMode::FullDuplexStreamed,
    ] {
        let h = harness_for(mode).await;
        let mut s = h.stream_with(mode, mode).await;
        assert_continue(
            &s.send(req_headers("GET", "/q?q=hi", &[], false))
                .await
                .unwrap(),
            "h",
        );
        let r = s.send(resp_headers("200", &[], false)).await.unwrap();
        assert_fail_closed(&r, &format!("{mode:?}: 200 before the body phase"));
        s.expect_closed().await;
        assert_eq!(h.metrics.allow_total(), 0, "{mode:?}");
    }
    // Streamed chunk, no final chunk or trailers, then a 200.
    let h = start().await;
    let mut s = h.stream().await;
    assert_continue(&s.send(form_post()).await.unwrap(), "headers");
    assert_continue(&s.send(req_body(b"q=hello", false)).await.unwrap(), "chunk");
    assert_fail_closed(
        &s.send(resp_headers("200", &[], false)).await.unwrap(),
        "200",
    );

    // A 4xx/5xx (Envoy's own 413, a rejected upgrade) is inspected late:
    // it can only become a deny.
    let mut s = h
        .stream_with(BodySendMode::Buffered, BodySendMode::Buffered)
        .await;
    assert_continue(
        &s.send(req_headers("GET", SQLI_QUERY, &[], false))
            .await
            .unwrap(),
        "h",
    );
    assert_deny(
        &s.send(resp_headers("413", &[], true)).await.unwrap(),
        "late phase 2",
    );
    let mut s = h
        .stream_with(BodySendMode::Buffered, BodySendMode::Buffered)
        .await;
    assert_continue(
        &s.send(req_headers("GET", "/q?q=hi", &[], false))
            .await
            .unwrap(),
        "h",
    );
    assert_continue(
        &s.send(resp_headers("413", &[], true)).await.unwrap(),
        "local 413",
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn none_mode_finishes_body_phases_at_the_headers() {
    let none = BodySendMode::None;
    let h = start().await;
    // A request with a body (eos=false) still runs phase 2 at the headers.
    let mut s = h.stream_with(none, none).await;
    let r = s
        .send(req_headers("POST", SQLI_QUERY, &[], false))
        .await
        .unwrap();
    assert_deny(&r, "NONE: query SQLi at request headers");

    let mut s = h.stream_with(none, none).await;
    assert_continue(
        &s.send(req_headers("POST", "/q?q=hi", &[], false))
            .await
            .unwrap(),
        "h",
    );
    assert_eq!(h.metrics.allow_total(), 1, "settled at the headers");
    assert_continue(
        &s.send(resp_headers("200", &[], false)).await.unwrap(),
        "resp",
    );
    // Response phase 4 ran at the headers too: the verdict is complete.
    assert!(
        s.close_send().await.is_none(),
        "clean close after the verdict"
    );
    assert_eq!(h.metrics.stream_errors_total(), 0);

    let mut s = h.stream_with(none, none).await;
    assert_continue(
        &s.send(req_headers("POST", "/q?q=hi", &[], false))
            .await
            .unwrap(),
        "h",
    );
    assert_fail_closed(&s.send(req_body(b"x", true)).await.unwrap(), "body in NONE");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn response_streaming_body_ends_at_trailers() {
    for mode in [BodySendMode::Streamed, BodySendMode::FullDuplexStreamed] {
        let h = harness_for(mode).await;
        let mut s = h.stream_with(mode, mode).await;
        assert_continue(
            &s.send(req_headers("GET", "/", &[], true)).await.unwrap(),
            "req",
        );
        assert_continue(
            &s.send(resp_headers("200", &[], false)).await.unwrap(),
            "resp",
        );
        let chunk = resp_body(b"token=CONNEX-LEAK-MARKER", false);
        if mode == BodySendMode::FullDuplexStreamed {
            s.push(chunk).await;
        } else {
            assert_continue(&s.send(chunk).await.unwrap(), "chunk");
        }
        assert_deny(
            &s.send(resp_trailers()).await.unwrap(),
            &format!("{mode:?}"),
        );
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn open_body_phase_at_half_close_aborts() {
    let h = start().await;
    let mut s = h.stream().await;
    assert_continue(&s.send(form_post()).await.unwrap(), "headers");
    assert_continue(&s.send(req_body(b"q=hello", false)).await.unwrap(), "chunk");
    assert_stream_error(
        s.close_send().await,
        tonic::Code::Internal,
        "request body open",
    );

    let mut s = h.stream().await;
    assert_continue(
        &s.send(req_headers("GET", "/", &[], true)).await.unwrap(),
        "req",
    );
    assert_continue(
        &s.send(resp_headers("200", &[], false)).await.unwrap(),
        "resp",
    );
    assert_stream_error(
        s.close_send().await,
        tonic::Code::Internal,
        "response body open",
    );
    assert_eq!(h.metrics.stream_errors_total(), 2);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn protocol_config_is_required_and_checked() {
    let h = start().await;
    let mut raw = Stream::open(h.addr).await;
    let r = raw.send(req_headers("GET", "/", &[], true)).await.unwrap();
    assert_fail_closed(&r, "no protocol_config");

    // --body-reply common cannot answer FULL_DUPLEX_STREAMED, and the
    // reverse; GRPC is not supported.
    let mut s = h
        .stream_with(BodySendMode::Buffered, BodySendMode::FullDuplexStreamed)
        .await;
    assert_fail_closed(
        &s.send(req_headers("GET", "/", &[], true)).await.unwrap(),
        "common/FDX",
    );
    let d = start_duplex().await;
    let mut s = d
        .stream_with(BodySendMode::Buffered, BodySendMode::Buffered)
        .await;
    assert_fail_closed(
        &s.send(req_headers("GET", "/", &[], true)).await.unwrap(),
        "streamed/BUF",
    );
    let mut s = h.stream_with(BodySendMode::Grpc, BodySendMode::Grpc).await;
    assert_fail_closed(
        &s.send(req_headers("GET", "/", &[], true)).await.unwrap(),
        "GRPC",
    );
    assert_eq!(h.metrics.allow_total(), 0);

    // Mixed modes that --body-reply streamed covers: per-direction replies.
    let mut s = d
        .stream_with(BodySendMode::FullDuplexStreamed, BodySendMode::Buffered)
        .await;
    assert_continue(&s.send(form_post()).await.unwrap(), "headers");
    s.push(req_body(b"q=hi", false)).await;
    let r = s.send(req_body(b"&x=1", true)).await.unwrap();
    assert_eq!(streamed_echo(&r, "request"), (b"q=hi&x=1".to_vec(), true));
    assert_continue(
        &s.send(resp_headers("200", &[], false)).await.unwrap(),
        "resp",
    );
    let r = s.send(resp_body(b"fine", false)).await.unwrap();
    assert!(
        matches!(&r.response, Some(ProcResponse::ResponseBody(b)) if b.response.as_ref().and_then(|c| c.body_mutation.as_ref()).is_none()),
        "BUFFERED response: plain Continue, got {:?}",
        r.response
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn read_error_after_the_verdict_is_not_a_stream_error() {
    // An unreadable message once the response body phase ran (Envoy tearing
    // down a finished exchange) ends the stream cleanly; nothing it could
    // carry still needs a verdict.
    let h = start().await;
    let mut s = h.stream().await;
    assert_continue(
        &s.send(req_headers("GET", "/", &[], true)).await.unwrap(),
        "req",
    );
    assert_continue(
        &s.send(resp_headers("200", &[], false)).await.unwrap(),
        "resp",
    );
    assert_continue(
        &s.send(resp_body(b"fine", true)).await.unwrap(),
        "resp body",
    );
    s.push(resp_body(&sqli_body(5 * 1024 * 1024), true)).await;
    assert!(s.next().await.is_none(), "after the verdict: clean close");
    assert_eq!(h.metrics.stream_errors_total(), 0);

    // Negative control: the same read error mid-response is still an error.
    let mut s = h.stream().await;
    assert_continue(
        &s.send(req_headers("GET", "/", &[], true)).await.unwrap(),
        "req",
    );
    assert_continue(
        &s.send(resp_headers("200", &[], false)).await.unwrap(),
        "resp",
    );
    s.push(resp_body(&sqli_body(5 * 1024 * 1024), true)).await;
    assert_stream_error(
        s.next().await,
        tonic::Code::Internal,
        "mid-response read error",
    );
    assert_eq!(h.metrics.stream_errors_total(), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn idle_and_duplex_deadlines_answer_504() {
    let short = Duration::from_millis(200);
    let h = start_with(
        BodyReply::Common,
        Limits {
            stream_idle_timeout: short,
            ..Limits::default()
        },
    )
    .await;
    let mut s = h.stream().await;
    assert_continue(&s.send(form_post()).await.unwrap(), "headers");
    let r = s.next().await.expect("timeout reply").expect("reply");
    assert_timed_out(&r, "stream idle");
    s.expect_closed().await;
    // After the verdict an idle stream ends cleanly.
    let mut s = h.stream().await;
    assert_continue(
        &s.send(req_headers("GET", "/", &[], true)).await.unwrap(),
        "req",
    );
    assert_continue(
        &s.send(resp_headers("200", &[], true)).await.unwrap(),
        "resp",
    );
    assert!(
        s.next().await.is_none(),
        "idle after the verdict: clean close"
    );

    // FULL_DUPLEX: a held body may not wait past --duplex-idle-timeout.
    let d = start_with(
        BodyReply::Streamed,
        Limits {
            duplex_idle_timeout: short,
            ..Limits::default()
        },
    )
    .await;
    let mut s = d.stream().await;
    assert_continue(&s.send(form_post()).await.unwrap(), "headers");
    s.push(req_body(b"q=hi", false)).await;
    assert_timed_out(
        &s.next().await.expect("reply").expect("reply"),
        "duplex idle",
    );

    // ...and a stream may not outlive --duplex-total-timeout, even busy.
    let d = start_with(
        BodyReply::Streamed,
        Limits {
            duplex_total_timeout: Duration::from_millis(400),
            ..Limits::default()
        },
    )
    .await;
    let mut s = d.stream().await;
    assert_continue(&s.send(form_post()).await.unwrap(), "headers");
    let started = std::time::Instant::now();
    let r = loop {
        s.push(req_body(b"a", false)).await;
        let next = tokio::time::timeout(Duration::from_millis(50), s.rx.next()).await;
        if let Ok(item) = next {
            break item.expect("reply").expect("reply");
        }
        assert!(
            started.elapsed() < Duration::from_secs(3),
            "no total deadline"
        );
    };
    assert_timed_out(&r, "duplex total");
    assert!(started.elapsed() >= Duration::from_millis(350));
    assert_eq!(d.metrics.fail_closed_total(), 1);
}
