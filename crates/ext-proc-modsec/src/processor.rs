//! `envoy.service.ext_proc.v3.ExternalProcessor` implementation.
//!
//! One bidi `Process` stream = one HTTP exchange = one ModSecurity
//! transaction. Every message is answered with exactly one of:
//!
//! - a Continue for the phase Envoy sent (no mutation), or
//! - an `ImmediateResponse` (deny / redirect → rule status; engine error or
//!   protocol violation → **500**), after which the stream is closed, or
//! - a gRPC error (ModSecurity `drop`, an unreadable or oversized inbound
//!   message), which Envoy with `failure_mode_allow: false` turns into a
//!   local 500 without contacting the origin.
//!
//! There is no code path that answers Continue after an engine error, and the
//! stream only ends with gRPC OK after a terminal `ImmediateResponse` or when
//! Envoy closes its side with nothing left unanswered. Envoy treats an OK
//! close as "processing complete" and forwards whatever it holds.
//!
//! Body phases follow the body modes Envoy declares in the first message's
//! `protocol_config` (a stream without one fails closed). Envoy marks a body
//! that trailers follow with `end_of_stream=false` and, with trailer mode
//! SKIP, never sends the trailers, so `end_of_stream` alone cannot end a
//! body phase:
//!
//! - BUFFERED / BUFFERED_PARTIAL: Envoy sends one body message; it ends the
//!   phase whatever its `end_of_stream`.
//! - NONE: no body message comes; the phase ends at the headers.
//! - STREAMED / FULL_DUPLEX_STREAMED: the phase ends at `end_of_stream` or
//!   trailers. Response headers that arrive while the request body phase is
//!   still open mean Envoy forwarded the request without a final body
//!   (trailer mode SKIP): that fails closed instead of being inspected late.

use std::collections::{HashMap, VecDeque};
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

use modsec_engine::{Decision, Engine, InspectionSession};
use tokio::runtime::{Handle, RuntimeFlavor};
use tokio_stream::Stream;
use tonic::{Code, Request, Response, Status, Streaming};
use tracing::warn;

use crate::config::{BodyReply, Limits};
use crate::connection_meta::ConnectionEndpoints;
use crate::metrics::{ConnectorMetrics, Phase};
use crate::pb::envoy::config::core::v3::HeaderValue;
use crate::pb::envoy::extensions::filters::http::ext_proc::v3::processing_mode::BodySendMode;
use crate::pb::envoy::service::ext_proc::v3::external_processor_server::{
    ExternalProcessor, ExternalProcessorServer,
};
use crate::pb::envoy::service::ext_proc::v3::processing_request::Request as ProcRequest;
use crate::pb::envoy::service::ext_proc::v3::{
    HttpBody, HttpHeaders, ProcessingRequest, ProcessingResponse, ProtocolConfiguration,
};
use crate::pb::google::protobuf::Struct;
use crate::responses::{self, Direction};

const DENY_BODY: &[u8] = b"Forbidden\n";
const REDIRECT_BODY: &[u8] = b"Redirect\n";

/// Per-phase INFO logs; the readiness probe logs them at DEBUG.
macro_rules! phase_info {
    ($exchange:expr, $($arg:tt)+) => {
        if $exchange.probe {
            tracing::debug!($($arg)+)
        } else {
            tracing::info!($($arg)+)
        }
    };
}

/// The gRPC service Envoy's `ext_proc` filter calls.
#[derive(Clone)]
pub struct ModSecProcessor {
    engine: Arc<Engine>,
    metrics: Arc<ConnectorMetrics>,
    body_reply: BodyReply,
    limits: Limits,
}

impl ModSecProcessor {
    pub fn new(engine: Arc<Engine>, metrics: Arc<ConnectorMetrics>) -> Self {
        Self::with_body_reply(engine, metrics, BodyReply::Common)
    }

    pub fn with_body_reply(
        engine: Arc<Engine>,
        metrics: Arc<ConnectorMetrics>,
        body_reply: BodyReply,
    ) -> Self {
        Self::with_limits(engine, metrics, body_reply, Limits::default())
    }

    pub fn with_limits(
        engine: Arc<Engine>,
        metrics: Arc<ConnectorMetrics>,
        body_reply: BodyReply,
        limits: Limits,
    ) -> Self {
        Self {
            engine,
            metrics,
            body_reply,
            limits,
        }
    }

    pub fn metrics(&self) -> &Arc<ConnectorMetrics> {
        &self.metrics
    }

    pub fn engine(&self) -> &Arc<Engine> {
        &self.engine
    }

    pub fn limits(&self) -> Limits {
        self.limits
    }

    /// The tonic service with this processor's message-size limits applied.
    pub fn into_server(self) -> ExternalProcessorServer<Self> {
        let limits = self.limits;
        ExternalProcessorServer::new(self)
            .max_decoding_message_size(limits.max_grpc_message_bytes)
            .max_encoding_message_size(limits.max_encoding_message_bytes())
    }

    /// A fresh per-stream state, exactly as `Process` creates one.
    pub fn exchange(&self) -> Exchange {
        Exchange::new(
            Arc::clone(&self.engine),
            Arc::clone(&self.metrics),
            self.body_reply,
            self.limits,
        )
    }

    /// A `protocol_config` that `--body-reply` accepts (for probes).
    pub fn expected_protocol_config(&self) -> ProtocolConfiguration {
        let mode = match self.body_reply {
            BodyReply::Common => BodySendMode::Buffered,
            BodyReply::Streamed => BodySendMode::FullDuplexStreamed,
        };
        ProtocolConfiguration {
            request_body_mode: mode as i32,
            response_body_mode: mode as i32,
            send_body_without_waiting_for_header_response: false,
        }
    }

    /// Like [`Self::exchange`], for `/healthz`: same engine and rules, but
    /// throwaway metrics and DEBUG-level phase logs, so probes do not show
    /// up as traffic.
    pub fn probe_exchange(&self) -> Exchange {
        let mut exchange = Exchange::new(
            Arc::clone(&self.engine),
            Arc::new(ConnectorMetrics::default()),
            self.body_reply,
            self.limits,
        );
        exchange.probe = true;
        exchange
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
            pending_out: VecDeque::new(),
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
/// `Exchange`, which hands the ModSecurity logging phase to the blocking pool.
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
    /// Extra replies queued after a multi-message duplex finalize (body then
    /// trailers). Drained before the next inbound read.
    pending_out: VecDeque<ProcessingResponse>,
}

impl Driver {
    /// Read until one message yields a reply. `None` (gRPC OK) only when
    /// Envoy closed its side with nothing awaiting an answer; a terminal
    /// reply comes without a driver.
    async fn step(mut self) -> Option<(Reply, Option<Driver>)> {
        if let Some(r) = self.pending_out.pop_front() {
            return Some((Ok(r), Some(self)));
        }
        loop {
            let (deadline, timer) = self.exchange.read_deadline(Instant::now());
            let read = tokio::time::timeout_at(deadline.into(), self.inbound.message()).await;
            let msg = match read {
                Ok(Ok(Some(m))) => m,
                // Envoy closed its side: OK only if nothing awaits an answer.
                Ok(Ok(None)) => return self.half_closed(),
                // A reset after the final verdict is Envoy tearing down a
                // finished exchange, not a failure.
                Ok(Err(e)) if self.exchange.verdict_complete() => {
                    tracing::debug!(
                        request_id = self.exchange.rid(),
                        code = ?e.code(),
                        "ext_proc stream reset after the final verdict"
                    );
                    return None;
                }
                Ok(Err(e)) => return Some((Err(self.read_error(&e)), None)),
                Err(_) if self.exchange.verdict_complete() => return None,
                Err(_) => return Some((Ok(self.exchange.timed_out(timer)), None)),
            };
            return match run_blocking(|| self.exchange.on_message(msg)) {
                Step::Reply(r) => Some((Ok(r), Some(self))),
                Step::Replies(first, mut rest) => {
                    self.pending_out.append(&mut rest);
                    Some((Ok(first), Some(self)))
                }
                Step::Silent => continue,
                Step::Final(r) => Some((Ok(r), None)),
                Step::Abort(status) => Some((Err(status), None)),
            };
        }
    }

    /// An unreadable inbound message (decode error, oversized message,
    /// transport error) must not end the stream OK: Envoy would then
    /// forward the exchange uninspected.
    fn read_error(&self, e: &Status) -> Status {
        let hint = if e.code() == Code::OutOfRange {
            "message larger than --max-grpc-message-bytes"
        } else {
            "-"
        };
        warn!(
            request_id = self.exchange.rid(),
            action = "fail_closed",
            code = ?e.code(),
            error = %e.message(),
            hint,
            "ext_proc stream read error; aborting stream (Envoy answers 500)"
        );
        self.exchange.metrics.inc_stream_errors();
        Status::internal(format!(
            "ext_proc read error (fail-closed): {}",
            e.message()
        ))
    }

    /// Envoy half-closed. A held body or a body phase that never ran means
    /// the exchange ended without a verdict for it: non-OK, never a clean
    /// "processing complete".
    fn half_closed(&self) -> Option<(Reply, Option<Driver>)> {
        let (dir, what) = if let Some(dir) = self.exchange.unanswered_body() {
            (dir, "a body was still held unanswered")
        } else {
            let dir = self.exchange.open_body_phase()?;
            (dir, "its body phase never ran (no final body or trailers)")
        };
        warn!(
            request_id = self.exchange.rid(),
            action = "fail_closed",
            direction = ?dir,
            "Envoy closed the stream while {what}; aborting stream"
        );
        self.exchange.metrics.inc_stream_errors();
        Some((
            Err(Status::internal(format!(
                "ext_proc stream closed before the {dir:?} body verdict (fail-closed)"
            ))),
            None,
        ))
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

/// Dropping a session runs ModSecurity's logging phase (audit-log writes) and
/// frees the transaction. Inside a runtime that goes to the blocking pool, so
/// it neither stalls an async worker nor delays a reply already decided.
fn retire(session: InspectionSession) {
    match Handle::try_current() {
        Ok(handle) => drop(handle.spawn_blocking(move || drop(session))),
        Err(_) => drop(session),
    }
}

/// What to send back for one inbound message.
#[derive(Debug)]
pub enum Step {
    /// Answer and keep the stream open.
    Reply(ProcessingResponse),
    /// Several answers for one inbound, in order (FULL_DUPLEX finalize:
    /// `StreamedBodyResponse` then trailers Continue). Never empty.
    Replies(ProcessingResponse, VecDeque<ProcessingResponse>),
    /// Observability-mode message: Envoy expects no answer.
    /// Also used while holding FULL_DUPLEX body chunks before EOS/trailers.
    Silent,
    /// Answer with a terminal `ImmediateResponse` and close the stream.
    Final(ProcessingResponse),
    /// Terminate the stream with a gRPC error.
    Abort(Status),
}

impl Step {
    fn is_terminal(&self) -> bool {
        matches!(self, Self::Final(_) | Self::Abort(_))
    }
}

/// Envoy `ProcessingMode.BodySendMode` of one direction, from the stream's
/// `protocol_config`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BodyMode {
    None,
    Streamed,
    Buffered,
    BufferedPartial,
    FullDuplexStreamed,
}

impl BodyMode {
    /// `None` for values the connector does not support, including GRPC
    /// (not implemented in Envoy; de-framed messages need their own body
    /// phase handling).
    fn from_wire(value: i32) -> Option<Self> {
        Some(match BodySendMode::try_from(value).ok()? {
            BodySendMode::None => Self::None,
            BodySendMode::Streamed => Self::Streamed,
            BodySendMode::Buffered => Self::Buffered,
            BodySendMode::BufferedPartial => Self::BufferedPartial,
            BodySendMode::FullDuplexStreamed => Self::FullDuplexStreamed,
            BodySendMode::Grpc => return None,
        })
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::None => "NONE",
            Self::Streamed => "STREAMED",
            Self::Buffered => "BUFFERED",
            Self::BufferedPartial => "BUFFERED_PARTIAL",
            Self::FullDuplexStreamed => "FULL_DUPLEX_STREAMED",
        }
    }

    /// Envoy sends the body (or, for PARTIAL, its inspected prefix) in one
    /// message, with `end_of_stream=false` when trailers follow.
    fn single_message(self) -> bool {
        matches!(self, Self::Buffered | Self::BufferedPartial)
    }
}

#[derive(Debug, Clone, Copy)]
struct Modes {
    request: BodyMode,
    response: BodyMode,
}

/// Which connector deadline expired.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Timer {
    StreamIdle,
    DuplexIdle,
    DuplexTotal,
}

impl Timer {
    fn flag(self) -> &'static str {
        match self {
            Self::StreamIdle => "--stream-idle-timeout",
            Self::DuplexIdle => "--duplex-idle-timeout",
            Self::DuplexTotal => "--duplex-total-timeout",
        }
    }
}

/// Per-stream state: one ModSecurity transaction plus correlation data.
pub struct Exchange {
    engine: Arc<Engine>,
    metrics: Arc<ConnectorMetrics>,
    body_reply: BodyReply,
    limits: Limits,
    /// From the first message's `protocol_config`; `None` until then.
    modes: Option<Modes>,
    started: Instant,
    /// Response headers seen (from the origin or an Envoy local reply).
    response_started: bool,
    /// The response body phase ran (or the response had no body): the
    /// final verdict for this exchange is given.
    response_done: bool,
    /// Kept after a terminal step too, so it is dropped (logging phase) by
    /// [`retire`] rather than inline before the reply is sent.
    session: Option<InspectionSession>,
    request_id: Option<String>,
    endpoints: ConnectionEndpoints,
    request_settled: bool,
    /// Set once a terminal step was produced; nothing may follow it.
    finished: bool,
    /// Set once response headers of an Envoy local reply (no request on this
    /// stream) were passed through; only its response body may follow.
    local_reply: bool,
    /// `BodyReply::Streamed`: request body received but not yet answered
    /// (echoed only after ModSecurity allows). `None` = nothing pending.
    req_held: Option<Vec<u8>>,
    /// `BodyReply::Streamed`: response body received but not yet answered.
    resp_held: Option<Vec<u8>>,
    /// Readiness probe: DEBUG-level phase logs.
    probe: bool,
}

impl Drop for Exchange {
    fn drop(&mut self) {
        if let Some(session) = self.session.take() {
            retire(session);
        }
    }
}

impl Exchange {
    pub fn new(
        engine: Arc<Engine>,
        metrics: Arc<ConnectorMetrics>,
        body_reply: BodyReply,
        limits: Limits,
    ) -> Self {
        Self {
            engine,
            metrics,
            body_reply,
            limits,
            modes: None,
            started: Instant::now(),
            response_started: false,
            response_done: false,
            session: None,
            request_id: None,
            endpoints: ConnectionEndpoints::fallback(),
            request_settled: false,
            finished: false,
            local_reply: false,
            req_held: None,
            resp_held: None,
            probe: false,
        }
    }

    fn held_mut(&mut self, dir: Direction) -> &mut Option<Vec<u8>> {
        match dir {
            Direction::Request => &mut self.req_held,
            Direction::Response => &mut self.resp_held,
        }
    }

    /// A direction whose body Envoy sent but the connector has not answered.
    fn unanswered_body(&self) -> Option<Direction> {
        if self.req_held.is_some() {
            Some(Direction::Request)
        } else if self.resp_held.is_some() {
            Some(Direction::Response)
        } else {
            None
        }
    }

    fn mode(&self, dir: Direction) -> BodyMode {
        let modes = self
            .modes
            .expect("modes are adopted before any handler runs");
        match dir {
            Direction::Request => modes.request,
            Direction::Response => modes.response,
        }
    }

    /// FULL_DUPLEX_STREAMED answers body messages with `StreamedBodyResponse`
    /// and holds them until the verdict.
    fn streamed_reply(&self, dir: Direction) -> bool {
        self.mode(dir) == BodyMode::FullDuplexStreamed
    }

    fn duplex(&self) -> bool {
        self.modes.is_some_and(|m| {
            m.request == BodyMode::FullDuplexStreamed || m.response == BodyMode::FullDuplexStreamed
        })
    }

    /// The final verdict is given: a terminal reply, or the response body
    /// phase ran. Nothing Envoy does afterwards needs an answer.
    pub fn verdict_complete(&self) -> bool {
        self.finished || self.response_done
    }

    /// A direction whose headers announced a body but whose body phase has
    /// not run (no final body message, no trailers).
    fn open_body_phase(&self) -> Option<Direction> {
        if self.finished {
            None
        } else if self.session.is_some() && !self.request_settled {
            Some(Direction::Request)
        } else if self.response_started && !self.response_done {
            Some(Direction::Response)
        } else {
            None
        }
    }

    /// When the next inbound read gives up, and which deadline that is.
    pub fn read_deadline(&self, now: Instant) -> (Instant, Timer) {
        let mut next = (now + self.limits.stream_idle_timeout, Timer::StreamIdle);
        if self.duplex() && !self.verdict_complete() {
            let total = self.started + self.limits.duplex_total_timeout;
            if total < next.0 {
                next = (total, Timer::DuplexTotal);
            }
            let idle = now + self.limits.duplex_idle_timeout;
            if self.unanswered_body().is_some() && idle < next.0 {
                next = (idle, Timer::DuplexIdle);
            }
        }
        next
    }

    /// A connector deadline expired before the verdict: 504, never Continue.
    pub fn timed_out(&mut self, timer: Timer) -> ProcessingResponse {
        warn!(
            request_id = self.rid(),
            action = "fail_closed",
            timer = timer.flag(),
            elapsed_ms = self.started.elapsed().as_millis() as u64,
            "connector stream deadline expired before the verdict; ImmediateResponse 504"
        );
        self.metrics.inc_fail_closed();
        self.finished = true;
        responses::timed_out()
    }

    /// Take the stream's body modes from the first message. Without them the
    /// connector cannot tell when a body phase ends.
    fn adopt_modes(&mut self, config: Option<&ProtocolConfiguration>) -> Result<(), String> {
        let Some(config) = config else {
            return Err(
                "first ProcessingRequest carries no protocol_config, so the body modes are \
                 unknown (Envoy sends it on the first message of every stream)"
                    .into(),
            );
        };
        let mode = |dir: &str, value: i32| {
            BodyMode::from_wire(value).ok_or_else(|| format!("unsupported {dir}_body_mode {value}"))
        };
        let modes = Modes {
            request: mode("request", config.request_body_mode)?,
            response: mode("response", config.response_body_mode)?,
        };
        self.modes = Some(modes);
        let want = if self.duplex() {
            BodyReply::Streamed
        } else {
            BodyReply::Common
        };
        if self.body_reply != want {
            return Err(format!(
                "Envoy body modes request={} response={} need --body-reply {}, connector runs \
                 --body-reply {}",
                modes.request.as_str(),
                modes.response.as_str(),
                want.as_str(),
                self.body_reply.as_str()
            ));
        }
        Ok(())
    }

    fn streamed_body_allow(&mut self, dir: Direction) -> ProcessingResponse {
        let buf = self.held_mut(dir).take().unwrap_or_default();
        responses::body_streamed_continue(dir, &buf, true)
    }

    fn rid(&self) -> &str {
        self.request_id.as_deref().unwrap_or("-")
    }

    /// Handle one `ProcessingRequest` from Envoy.
    pub fn on_message(&mut self, msg: ProcessingRequest) -> Step {
        if self.finished {
            return self.fail_closed(Phase::RequestHeaders, "message after a terminal reply");
        }
        let step = self.dispatch(msg);
        if step.is_terminal() {
            self.finished = true;
        }
        step
    }

    fn dispatch(&mut self, msg: ProcessingRequest) -> Step {
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
        if self.modes.is_none() {
            if let Err(e) = self.adopt_modes(msg.protocol_config.as_ref()) {
                return self.fail_closed(Phase::RequestHeaders, e);
            }
        }
        match msg.request {
            Some(ProcRequest::RequestHeaders(h)) => self.request_headers(&h, &msg.attributes),
            Some(ProcRequest::RequestBody(b)) => self.body(Direction::Request, &b),
            Some(ProcRequest::ResponseHeaders(h)) => self.response_headers(&h),
            Some(ProcRequest::ResponseBody(b)) => self.body(Direction::Response, &b),
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
        // Omitted :method/:path are not a protocol failure: phase 1 still
        // runs, as GET /. Engine errors and real protocol violations
        // fail-closed instead.
        let method = header(headers, ":method").unwrap_or_else(|| "GET".into());
        let path = header(headers, ":path").unwrap_or_else(|| "/".into());

        // A CONNECT tunnel never reaches end_of_stream, so BUFFERED body mode
        // would hold it until message_timeout. Reverse-proxy deployments have
        // no CONNECT targets; reject explicitly.
        if method.eq_ignore_ascii_case("CONNECT") {
            phase_info!(
                self,
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
        let step = self.request_headers_in(&mut session, headers, attributes, &method, &path, t0);
        self.session = Some(session);
        step
    }

    fn request_headers_in(
        &mut self,
        session: &mut InspectionSession,
        headers: &HttpHeaders,
        attributes: &HashMap<String, Struct>,
        method: &str,
        path: &str,
        t0: Instant,
    ) -> Step {
        let phase = Phase::RequestHeaders;
        // CRS matches REQUEST_HEADERS:Host. HTTP/2 and HTTP/3 put the host in
        // :authority and often omit Host; copy it only when Host is absent so
        // an explicit Host header is not overwritten.
        let mut hdrs: Vec<(String, Vec<u8>)> = regular_headers(headers).collect();
        if !hdrs.iter().any(|(k, _)| k.eq_ignore_ascii_case("host")) {
            if let Some(authority) = header(headers, ":authority") {
                hdrs.push(("host".into(), authority.into_bytes()));
            }
        }

        self.endpoints = ConnectionEndpoints::from_ext_proc_attributes(attributes);
        let ep = &self.endpoints;
        let decision = match session.process_request_headers(
            &ep.client_ip,
            ep.client_port,
            &ep.server_ip,
            ep.server_port,
            method,
            path,
            ep.http_version,
            &hdrs,
        ) {
            Ok(d) => d,
            Err(e) => return self.fail_closed(phase, &e),
        };
        phase_info!(
            self,
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

        // NONE: Envoy sends no body, so phase 2 runs now on headers and URI.
        if headers.end_of_stream || self.mode(Direction::Request) == BodyMode::None {
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
        Step::Reply(responses::headers_continue(Direction::Request))
    }

    fn body(&mut self, dir: Direction, body: &HttpBody) -> Step {
        let phase = match dir {
            Direction::Request => Phase::RequestBody,
            Direction::Response => Phase::ResponseBody,
        };
        let mode = self.mode(dir);
        if mode == BodyMode::None {
            return self.fail_closed(phase, "body message although Envoy declared body mode NONE");
        }
        if self.local_reply && dir == Direction::Response {
            if body.end_of_stream || mode.single_message() {
                self.response_done = true;
            }
            return Step::Reply(if self.streamed_reply(dir) {
                responses::body_streamed_continue(dir, &body.body, body.end_of_stream)
            } else {
                responses::body_continue(dir)
            });
        }
        if self.body_phase_done(dir) {
            return self.fail_closed(phase, "body message after the body phase ended");
        }
        let Some(mut session) = self.session.take() else {
            return self.fail_closed(phase, "body received before headers");
        };
        let step = self.body_in(&mut session, dir, phase, body);
        self.session = Some(session);
        step
    }

    fn body_in(
        &mut self,
        session: &mut InspectionSession,
        dir: Direction,
        phase: Phase,
        body: &HttpBody,
    ) -> Step {
        let t0 = Instant::now();
        let nbytes = body.body.len() as u64;
        self.metrics.add_body_bytes(phase, nbytes);

        let streamed = self.streamed_reply(dir);
        if streamed {
            // The whole body is answered in one StreamedBodyResponse after
            // ModSecurity allows it, so it must stay within one gRPC message.
            let cap = self.limits.max_held_body_bytes;
            let held = self.held_mut(dir).get_or_insert_with(Vec::new);
            if held.len().saturating_add(body.body.len()) > cap {
                let total = held.len() + body.body.len();
                return self.fail_closed(
                    phase,
                    format!("held body {total} bytes exceeds --max-held-body-bytes {cap}"),
                );
            }
            held.extend_from_slice(&body.body);
        }

        let appended = match dir {
            Direction::Request => session.append_request_body(&body.body),
            Direction::Response => session.append_response_body(&body.body),
        };
        match appended {
            // Allow is not settled here: a non-disruptive append is not the
            // end of the body phase, so it must not record phase latency.
            Ok(d) if d.is_disruptive() => {
                if let Some(step) = self.settle(phase, d, t0.elapsed(), Some(nbytes)) {
                    return step;
                }
            }
            Ok(_) => {}
            Err(e) => return self.fail_closed(phase, &e),
        }

        // BUFFERED / BUFFERED_PARTIAL send one body message, with
        // end_of_stream=false when trailers follow or (PARTIAL) when only
        // the inspected prefix is sent: it is the whole inspected body.
        if body.end_of_stream || self.mode(dir).single_message() {
            if let Some(step) = self.finish_body(session, dir, phase, t0, nbytes) {
                return step;
            }
            return Step::Reply(if streamed {
                self.streamed_body_allow(dir)
            } else {
                responses::body_continue(dir)
            });
        }

        if streamed {
            // FULL_DUPLEX: hold StreamedBodyResponse until EOS/trailers so a
            // late deny cannot race an already-forwarded body to origin.
            Step::Silent
        } else {
            Step::Reply(responses::body_continue(dir))
        }
    }

    fn body_phase_done(&self, dir: Direction) -> bool {
        match dir {
            Direction::Request => self.request_settled,
            Direction::Response => self.response_done,
        }
    }

    /// Run the body phase of `dir`. `Some` is the terminal step of a
    /// disruptive decision or an engine error.
    fn finish_body(
        &mut self,
        session: &mut InspectionSession,
        dir: Direction,
        phase: Phase,
        t0: Instant,
        nbytes: u64,
    ) -> Option<Step> {
        let finished = match dir {
            Direction::Request => session.finish_request_body(),
            Direction::Response => session.finish_response_body(),
        };
        match finished {
            Ok(d) => {
                if let Some(step) = self.settle(phase, d, t0.elapsed(), Some(nbytes)) {
                    return Some(step);
                }
            }
            Err(e) => return Some(self.fail_closed(phase, &e)),
        }
        match dir {
            Direction::Request => self.mark_request_allowed(),
            Direction::Response => self.response_done = true,
        }
        None
    }

    /// Trailers themselves are not inspected (SecLang / CRS have no trailer
    /// phase). They *do* mark true body end when Envoy sent the last body
    /// chunk with `end_of_stream=false` because trailers follow — so any
    /// unfinished request/response body is finalized here (Coraza #289 class).
    /// Without a session they must not open a path: Continue only when the
    /// request was already allowed, or for an Envoy local-reply stream.
    fn trailers(&mut self, dir: Direction) -> Step {
        let phase = match dir {
            Direction::Request => Phase::RequestBody,
            Direction::Response => Phase::ResponseBody,
        };
        if self.local_reply {
            if dir == Direction::Response {
                self.response_done = true;
            }
            return Step::Reply(responses::trailers_continue(dir));
        }
        let Some(mut session) = self.session.take() else {
            if self.request_settled {
                return Step::Reply(responses::trailers_continue(dir));
            }
            return self.fail_closed(phase, "trailers received without an open session");
        };
        let step = self.trailers_in(&mut session, dir, phase);
        self.session = Some(session);
        step
    }

    fn trailers_in(
        &mut self,
        session: &mut InspectionSession,
        dir: Direction,
        phase: Phase,
    ) -> Step {
        if dir == Direction::Response && !self.response_started {
            return self.fail_closed(phase, "response trailers before response headers");
        }
        // Finalize a body that Envoy ended with trailers instead of eos=true
        // (STREAMED, FULL_DUPLEX, or headers then trailers with no body).
        if !self.body_phase_done(dir) {
            if let Some(step) = self.finish_body(session, dir, phase, Instant::now(), 0) {
                return step;
            }
        }

        phase_info!(
            self,
            request_id = self.rid(),
            phase = phase.as_str(),
            action = "trailers_continue",
            "trailers Continue (values not CRS-inspected; body finalized if needed)"
        );
        // FULL_DUPLEX: release the held body now that ModSecurity allowed it.
        // Envoy sends no body message for headers → trailers, and rejects a
        // body reply it did not ask for, so only answer one that arrived.
        if self.streamed_reply(dir) && self.held_mut(dir).is_some() {
            let body = self.streamed_body_allow(dir);
            return Step::Replies(body, VecDeque::from([responses::trailers_continue(dir)]));
        }
        Step::Reply(responses::trailers_continue(dir))
    }

    fn response_headers(&mut self, headers: &HttpHeaders) -> Step {
        let phase = Phase::ResponseHeaders;
        let status = header(headers, ":status").and_then(|s| s.parse::<i32>().ok());
        let Some(mut session) = self.session.take() else {
            return self.response_without_request(status, headers.end_of_stream);
        };
        let step = match status {
            Some(status) => self.response_headers_in(&mut session, headers, status),
            None => self.fail_closed(phase, "response_headers without a valid :status"),
        };
        self.session = Some(session);
        step
    }

    fn response_headers_in(
        &mut self,
        session: &mut InspectionSession,
        headers: &HttpHeaders,
        status: i32,
    ) -> Step {
        let phase = Phase::ResponseHeaders;
        if self.response_started {
            return self.fail_closed(phase, "response_headers received twice on one stream");
        }
        self.response_started = true;
        if !self.request_settled {
            // Envoy passed the request on without a final body message or
            // trailers (e.g. trailer mode SKIP and a body ended by trailers),
            // so the origin saw a request whose body phase never ran. A
            // success must not reach the client on that basis. A 4xx/5xx is
            // usually Envoy's own local reply (413 buffer overflow, rejected
            // upgrade); it is inspected late, which can only tighten it.
            let mode = self.mode(Direction::Request).as_str();
            if status < 400 {
                return self.fail_closed(
                    phase,
                    format!(
                        "response headers (status {status}) arrived before the request body \
                         phase ran (request body mode {mode}); Envoy needs \
                         request_trailer_mode: SEND"
                    ),
                );
            }
            warn!(
                request_id = self.rid(),
                status,
                request_body_mode = mode,
                "response headers before the request body phase ran; inspecting the request \
                 body late"
            );
        }
        let t0 = Instant::now();
        let hdrs: Vec<(String, Vec<u8>)> = regular_headers(headers).collect();
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

        if headers.end_of_stream || self.mode(Direction::Response) == BodyMode::None {
            if let Some(step) = self.finish_body(
                session,
                Direction::Response,
                Phase::ResponseBody,
                Instant::now(),
                0,
            ) {
                return step;
            }
        }
        Step::Reply(responses::headers_continue(Direction::Response))
    }

    /// Response headers on a stream that never carried request headers.
    ///
    /// Envoy only does this for its own local reply to a request it rejected
    /// before the request phase (e.g. a `#fragment` URI → 400): with
    /// `request_header_mode: SEND`, nothing reaches the origin without a
    /// request_headers message first. A 4xx/5xx is therefore already closed
    /// and passes through unchanged; anything else fails closed.
    fn response_without_request(&mut self, status: Option<i32>, headers_eos: bool) -> Step {
        let phase = Phase::ResponseHeaders;
        match status {
            Some(code) if (400..=599).contains(&code) && !self.local_reply => {
                self.local_reply = true;
                self.response_started = true;
                if headers_eos || self.mode(Direction::Response) == BodyMode::None {
                    self.response_done = true;
                }
                self.metrics.inc_local_reply_passthrough();
                phase_info!(
                    self,
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
        phase_info!(
            self,
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

/// The bytes Envoy forwards for a header: `raw_value` when set, so a
/// non-UTF-8 value reaches ModSecurity as the origin will see it.
fn header_bytes(hv: &HeaderValue) -> Vec<u8> {
    if hv.raw_value.is_empty() {
        hv.value.as_bytes().to_vec()
    } else {
        hv.raw_value.clone()
    }
}

/// Non-pseudo headers, in order (duplicates preserved), with raw values.
fn regular_headers(headers: &HttpHeaders) -> impl Iterator<Item = (String, Vec<u8>)> + '_ {
    headers
        .headers
        .iter()
        .flat_map(|m| m.headers.iter())
        .filter(|h| !h.key.starts_with(':'))
        .map(|h| (h.key.clone(), header_bytes(h)))
}
