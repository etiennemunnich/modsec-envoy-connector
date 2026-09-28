//! `envoy.service.ext_proc.v3.ExternalProcessor` implementation.
//!
//! One bidi `Process` stream = one HTTP exchange = one ModSecurity
//! transaction. Every message is answered with exactly one of:
//!
//! - a Continue for the phase Envoy sent (no mutation), or
//! - an `ImmediateResponse` (deny / redirect → rule status; engine error or
//!   protocol violation → **500**), after which the stream is closed, or
//! - a gRPC error (ModSecurity `drop`), which Envoy with
//!   `failure_mode_allow: false` turns into a local 500 without contacting
//!   the origin.
//!
//! There is no code path that answers Continue after an engine error.

use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

use modsec_engine::{Decision, Engine, InspectionSession};
use tokio::runtime::{Handle, RuntimeFlavor};
use tokio_stream::Stream;
use tonic::{Request, Response, Status, Streaming};
use tracing::{info, warn};

use crate::connection_meta::ConnectionEndpoints;
use crate::metrics::{ConnectorMetrics, Phase};
use crate::pb::envoy::config::core::v3::HeaderValue;
use crate::pb::envoy::service::ext_proc::v3::external_processor_server::ExternalProcessor;
use crate::pb::envoy::service::ext_proc::v3::processing_request::Request as ProcRequest;
use crate::pb::envoy::service::ext_proc::v3::{
    HttpBody, HttpHeaders, ProcessingRequest, ProcessingResponse,
};
use crate::pb::google::protobuf::Struct;
use crate::responses::{self, Direction};

const DENY_BODY: &[u8] = b"Forbidden\n";
const REDIRECT_BODY: &[u8] = b"Redirect\n";

/// The gRPC service Envoy's `ext_proc` filter calls.
#[derive(Clone)]
pub struct ModSecProcessor {
    engine: Arc<Engine>,
    metrics: Arc<ConnectorMetrics>,
}

impl ModSecProcessor {
    pub fn new(engine: Arc<Engine>, metrics: Arc<ConnectorMetrics>) -> Self {
        Self { engine, metrics }
    }

    pub fn metrics(&self) -> &Arc<ConnectorMetrics> {
        &self.metrics
    }

    pub fn engine(&self) -> &Arc<Engine> {
        &self.engine
    }

    /// A fresh per-stream state, exactly as `Process` creates one.
    pub fn exchange(&self) -> Exchange {
        Exchange::new(Arc::clone(&self.engine), Arc::clone(&self.metrics))
    }
}

type ProcessStream =
    Pin<Box<dyn Stream<Item = Result<ProcessingResponse, Status>> + Send + 'static>>;

#[tonic::async_trait]
impl ExternalProcessor for ModSecProcessor {
    type ProcessStream = ProcessStream;

    async fn process(
        &self,
        request: Request<Streaming<ProcessingRequest>>,
    ) -> Result<Response<Self::ProcessStream>, Status> {
        let driver = Driver {
            exchange: self.exchange(),
            inbound: request.into_inner(),
        };
        Ok(Response::new(Box::pin(Outbound {
            next: Some(Box::pin(driver.step())),
        }) as ProcessStream))
    }
}

type Reply = Result<ProcessingResponse, Status>;
type PendingStep = Pin<Box<dyn Future<Output = Option<(Reply, Option<Driver>)>> + Send>>;

/// Reply stream for one `Process` call. Envoy's messages are read only while
/// tonic polls for the next reply, so once the stream is finished (or tonic
/// drops it) nothing reads the inbound side again; dropping it drops the
/// `Exchange`, which runs the ModSecurity logging phase.
struct Outbound {
    next: Option<PendingStep>,
}

impl Stream for Outbound {
    type Item = Reply;

    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Reply>> {
        let Some(step) = self.next.as_mut() else {
            return Poll::Ready(None);
        };
        match step.as_mut().poll(cx) {
            Poll::Pending => Poll::Pending,
            Poll::Ready(None) => {
                self.next = None;
                Poll::Ready(None)
            }
            Poll::Ready(Some((reply, more))) => {
                self.next = more.map(|d| Box::pin(d.step()) as PendingStep);
                Poll::Ready(Some(reply))
            }
        }
    }
}

struct Driver {
    exchange: Exchange,
    inbound: Streaming<ProcessingRequest>,
}

impl Driver {
    /// Read until one message yields a reply. `None` ends the stream (Envoy
    /// closed it or a read failed); a terminal reply comes without a driver.
    async fn step(mut self) -> Option<(Reply, Option<Driver>)> {
        loop {
            let msg = match self.inbound.message().await {
                Ok(Some(m)) => m,
                Ok(None) => return None,
                Err(e) => {
                    warn!(
                        request_id = self.exchange.rid(),
                        error = %e,
                        "ext_proc stream read error"
                    );
                    self.exchange.metrics.inc_stream_errors();
                    return None;
                }
            };
            return match run_blocking(|| self.exchange.on_message(msg)) {
                Step::Reply(r) => Some((Ok(r), Some(self))),
                Step::Silent => continue,
                Step::Final(r) => Some((Ok(r), None)),
                Step::Abort(status) => Some((Err(status), None)),
            };
        }
    }
}

/// libmodsecurity evaluation is synchronous CPU work (CRS on large bodies can
/// take milliseconds). On the multi-threaded runtime, move it off the async
/// worker so other streams keep making progress.
pub fn run_blocking<T>(f: impl FnOnce() -> T) -> T {
    match Handle::try_current().map(|h| h.runtime_flavor()) {
        Ok(RuntimeFlavor::MultiThread) => tokio::task::block_in_place(f),
        _ => f(),
    }
}

/// What to send back for one inbound message.
#[derive(Debug)]
pub enum Step {
    /// Answer and keep the stream open.
    Reply(ProcessingResponse),
    /// Observability-mode message: Envoy expects no answer.
    Silent,
    /// Answer with a terminal `ImmediateResponse` and close the stream.
    Final(ProcessingResponse),
    /// Terminate the stream with a gRPC error.
    Abort(Status),
}

/// Per-stream state: one ModSecurity transaction plus correlation data.
pub struct Exchange {
    engine: Arc<Engine>,
    metrics: Arc<ConnectorMetrics>,
    session: Option<InspectionSession>,
    request_id: Option<String>,
    endpoints: ConnectionEndpoints,
    request_settled: bool,
    /// Set once response headers of an Envoy local reply (no request on this
    /// stream) were passed through; only its response body may follow.
    local_reply: bool,
}

impl Exchange {
    pub fn new(engine: Arc<Engine>, metrics: Arc<ConnectorMetrics>) -> Self {
        Self {
            engine,
            metrics,
            session: None,
            request_id: None,
            endpoints: ConnectionEndpoints::fallback(),
            request_settled: false,
            local_reply: false,
        }
    }

    fn rid(&self) -> &str {
        self.request_id.as_deref().unwrap_or("-")
    }

    /// Handle one `ProcessingRequest` from Envoy.
    pub fn on_message(&mut self, msg: ProcessingRequest) -> Step {
        if msg.observability_mode {
            // Envoy does not wait for answers in observability mode, so the
            // connector cannot enforce anything; enforcement configs must not
            // enable it.
            warn!(
                request_id = self.rid(),
                "observability_mode message ignored (cannot enforce)"
            );
            return Step::Silent;
        }
        match msg.request {
            Some(ProcRequest::RequestHeaders(h)) => self.request_headers(&h, &msg.attributes),
            Some(ProcRequest::RequestBody(b)) => self.body(Phase::RequestBody, &b),
            Some(ProcRequest::ResponseHeaders(h)) => self.response_headers(&h),
            Some(ProcRequest::ResponseBody(b)) => self.body(Phase::ResponseBody, &b),
            Some(ProcRequest::RequestTrailers(_)) => self.trailers(Direction::Request),
            Some(ProcRequest::ResponseTrailers(_)) => self.trailers(Direction::Response),
            None => self.fail_closed(Phase::RequestHeaders, "ProcessingRequest without a request"),
        }
    }

    fn request_headers(
        &mut self,
        headers: &HttpHeaders,
        attributes: &HashMap<String, Struct>,
    ) -> Step {
        let phase = Phase::RequestHeaders;
        self.metrics.inc_requests();
        if self.session.is_some() || self.local_reply {
            return self.fail_closed(phase, "request_headers received twice on one stream");
        }
        self.request_id = header(headers, "x-request-id");
        let method = header(headers, ":method").unwrap_or_else(|| "GET".into());
        let path = header(headers, ":path").unwrap_or_else(|| "/".into());

        // A CONNECT tunnel never reaches end_of_stream, so BUFFERED body mode
        // would hold it until message_timeout. Reverse-proxy deployments have
        // no CONNECT targets; reject explicitly.
        if method.eq_ignore_ascii_case("CONNECT") {
            info!(
                request_id = self.rid(),
                phase = phase.as_str(),
                action = "deny",
                "CONNECT rejected"
            );
            self.metrics.inc_deny();
            return Step::Final(responses::block(403, DENY_BODY, "connect_rejected"));
        }

        let t0 = Instant::now();
        let mut session = match self.engine.open_transaction(self.request_id.as_deref()) {
            Ok(s) => s,
            Err(e) => return self.fail_closed(phase, &e),
        };

        let mut hdrs: Vec<(String, String)> = regular_headers(headers).collect();
        if !hdrs.iter().any(|(k, _)| k.eq_ignore_ascii_case("host")) {
            if let Some(authority) = header(headers, ":authority") {
                hdrs.push(("host".into(), authority));
            }
        }

        self.endpoints = ConnectionEndpoints::from_ext_proc_attributes(attributes);
        let ep = &self.endpoints;
        let decision = match session.process_request_headers(
            &ep.client_ip,
            ep.client_port,
            &ep.server_ip,
            ep.server_port,
            &method,
            &path,
            ep.http_version,
            &hdrs,
        ) {
            Ok(d) => d,
            Err(e) => return self.fail_closed(phase, &e),
        };
        info!(
            request_id = self.rid(),
            phase = phase.as_str(),
            conn_source = self.endpoints.source,
            client = %format!("{}:{}", self.endpoints.client_ip, self.endpoints.client_port),
            server = %format!("{}:{}", self.endpoints.server_ip, self.endpoints.server_port),
            http_version = self.endpoints.http_version,
            method = %method,
            "request headers inspected"
        );
        if let Some(step) = self.settle(phase, decision, t0.elapsed(), None) {
            return step;
        }

        if headers.end_of_stream {
            let t1 = Instant::now();
            match session.finish_request_body() {
                Ok(d) => {
                    if let Some(step) = self.settle(Phase::RequestBody, d, t1.elapsed(), Some(0)) {
                        return step;
                    }
                    self.mark_request_allowed();
                }
                Err(e) => return self.fail_closed(Phase::RequestBody, &e),
            }
        }

        self.session = Some(session);
        Step::Reply(responses::headers_continue(Direction::Request))
    }

    fn body(&mut self, phase: Phase, body: &HttpBody) -> Step {
        let dir = match phase {
            Phase::RequestBody => Direction::Request,
            Phase::ResponseBody => Direction::Response,
            Phase::RequestHeaders | Phase::ResponseHeaders => {
                return self.fail_closed(phase, "body handler called for a headers phase")
            }
        };
        if self.local_reply && dir == Direction::Response {
            return Step::Reply(responses::body_continue(dir));
        }
        let Some(mut session) = self.session.take() else {
            return self.fail_closed(phase, "body received before headers");
        };
        let t0 = Instant::now();
        let nbytes = body.body.len() as u64;
        self.metrics.add_body_bytes(phase, nbytes);

        let appended = match dir {
            Direction::Request => session.append_request_body(&body.body),
            Direction::Response => session.append_response_body(&body.body),
        };
        match appended {
            Ok(d) if d.is_disruptive() => {
                if let Some(step) = self.settle(phase, d, t0.elapsed(), Some(nbytes)) {
                    return step;
                }
            }
            Ok(_) => {}
            Err(e) => return self.fail_closed(phase, &e),
        }

        if body.end_of_stream {
            let finished = match dir {
                Direction::Request => session.finish_request_body(),
                Direction::Response => session.finish_response_body(),
            };
            match finished {
                Ok(d) => {
                    if let Some(step) = self.settle(phase, d, t0.elapsed(), Some(nbytes)) {
                        return step;
                    }
                    if dir == Direction::Request {
                        self.mark_request_allowed();
                    }
                }
                Err(e) => return self.fail_closed(phase, &e),
            }
        }

        self.session = Some(session);
        Step::Reply(responses::body_continue(dir))
    }

    /// Trailers are not inspected (SecLang / CRS have no trailer phase here).
    /// Without a session they must not open a path past fail-closed: answer
    /// Continue only when a request was already allowed, or for an Envoy
    /// local-reply stream that never had a request.
    fn trailers(&self, dir: Direction) -> Step {
        if self.session.is_some() || self.request_settled || self.local_reply {
            return Step::Reply(responses::trailers_continue(dir));
        }
        let phase = match dir {
            Direction::Request => Phase::RequestBody,
            Direction::Response => Phase::ResponseBody,
        };
        self.fail_closed(phase, "trailers received without an open session")
    }

    fn response_headers(&mut self, headers: &HttpHeaders) -> Step {
        let phase = Phase::ResponseHeaders;
        let status = header(headers, ":status").and_then(|s| s.parse::<i32>().ok());
        let Some(mut session) = self.session.take() else {
            return self.response_without_request(status);
        };
        let Some(status) = status else {
            return self.fail_closed(phase, "response_headers without a valid :status");
        };
        let t0 = Instant::now();
        let hdrs: Vec<(String, String)> = regular_headers(headers).collect();
        let protocol = self.endpoints.response_protocol();
        let decision = match session.process_response_headers(status, &protocol, &hdrs) {
            Ok(d) => d,
            Err(e) => return self.fail_closed(phase, &e),
        };
        if let Some(step) = self.settle(phase, decision, t0.elapsed(), None) {
            return step;
        }
        // The engine closes an unfinished request body before response
        // headers; reaching here means the request path was allowed.
        self.mark_request_allowed();

        if headers.end_of_stream {
            let t1 = Instant::now();
            match session.finish_response_body() {
                Ok(d) => {
                    if let Some(step) = self.settle(Phase::ResponseBody, d, t1.elapsed(), Some(0)) {
                        return step;
                    }
                }
                Err(e) => return self.fail_closed(Phase::ResponseBody, &e),
            }
        }

        self.session = Some(session);
        Step::Reply(responses::headers_continue(Direction::Response))
    }

    /// Response headers on a stream that never carried request headers.
    ///
    /// Envoy only does this for its own local reply to a request it rejected
    /// before the request phase (e.g. a `#fragment` URI → 400): with
    /// `request_header_mode: SEND`, nothing reaches the origin without a
    /// request_headers message first. A 4xx/5xx is therefore already closed
    /// and passes through unchanged; anything else fails closed.
    fn response_without_request(&mut self, status: Option<i32>) -> Step {
        let phase = Phase::ResponseHeaders;
        match status {
            Some(code) if (400..=599).contains(&code) && !self.local_reply => {
                self.local_reply = true;
                self.metrics.inc_local_reply_passthrough();
                info!(
                    request_id = self.rid(),
                    phase = phase.as_str(),
                    action = "local_reply_passthrough",
                    status = code,
                    "Envoy local reply without request phase passed through"
                );
                Step::Reply(responses::headers_continue(Direction::Response))
            }
            _ => self.fail_closed(phase, "response_headers received before request_headers"),
        }
    }

    fn mark_request_allowed(&mut self) {
        if !self.request_settled {
            self.request_settled = true;
            self.metrics.inc_allow();
        }
    }

    /// Record phase latency, log the decision, and map disruptive decisions
    /// to a terminal step.
    fn settle(
        &self,
        phase: Phase,
        decision: Decision,
        elapsed: Duration,
        body_bytes: Option<u64>,
    ) -> Option<Step> {
        self.metrics.observe_phase(phase, elapsed);
        let redirect_url = match &decision {
            Decision::Redirect { url, .. } => url.as_str(),
            _ => "-",
        };
        info!(
            request_id = self.rid(),
            phase = phase.as_str(),
            action = decision.action_label(),
            latency_ms = elapsed.as_secs_f64() * 1000.0,
            body_bytes = body_bytes.unwrap_or(0),
            redirect_url,
            "modsec phase complete"
        );
        match decision {
            Decision::Allow => None,
            Decision::Block { status, .. } => {
                self.metrics.inc_deny();
                Some(Step::Final(responses::block(
                    status,
                    DENY_BODY,
                    "modsecurity_intervention",
                )))
            }
            Decision::Redirect { status, url, .. } => {
                self.metrics.inc_deny();
                Some(Step::Final(responses::redirect(
                    status,
                    &url,
                    REDIRECT_BODY,
                )))
            }
            Decision::Drop { .. } => {
                // ImmediateResponse cannot close a connection, and status 0
                // would be sent as 200. Abort the stream instead: Envoy
                // (failure_mode_allow: false) answers 500 without the origin.
                self.metrics.inc_deny();
                Some(Step::Abort(Status::aborted(
                    "modsecurity drop intervention",
                )))
            }
        }
    }

    fn fail_closed(&self, phase: Phase, err: impl std::fmt::Display) -> Step {
        warn!(
            request_id = self.rid(),
            phase = phase.as_str(),
            action = "fail_closed",
            error = %err,
            "fail-closed ImmediateResponse 500"
        );
        self.metrics.inc_fail_closed();
        Step::Final(responses::fail_closed())
    }
}

fn header_value(hv: &HeaderValue) -> String {
    if hv.raw_value.is_empty() {
        hv.value.clone()
    } else {
        String::from_utf8_lossy(&hv.raw_value).into_owned()
    }
}

fn header(headers: &HttpHeaders, name: &str) -> Option<String> {
    headers
        .headers
        .as_ref()?
        .headers
        .iter()
        .find(|h| h.key.eq_ignore_ascii_case(name))
        .map(header_value)
}

/// Non-pseudo headers, in order (duplicates preserved).
fn regular_headers(headers: &HttpHeaders) -> impl Iterator<Item = (String, String)> + '_ {
    headers
        .headers
        .iter()
        .flat_map(|m| m.headers.iter())
        .filter(|h| !h.key.starts_with(':'))
        .map(|h| (h.key.clone(), header_value(h)))
}
