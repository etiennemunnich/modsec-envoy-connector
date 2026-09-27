//! Safe façade over libmodsecurity for the Envoy `ext_proc` connector.
//!
//! All `unsafe` / FFI lives in this crate; `ext-proc-modsec` never calls raw
//! `msc_*` functions.
//!
//! ## Transaction contract
//!
//! - One ext_proc bidi stream = one HTTP request/response = **one**
//!   ModSecurity transaction ([`InspectionSession`]).
//! - Phases are fed in order: `connection` → `uri` → `request_headers` →
//!   `request_body` → `response_headers` → `response_body` → logging (on drop).
//! - `intervention()` is read after **every** Transaction API step that can
//!   fire rules — including each `append_*_body` — so body-limit rejects and
//!   mid-stream denies are honoured immediately (ModSecurity-nginx parity).
//! - Any engine error is returned as [`EngineError`]; the connector maps it to
//!   a fail-closed `ImmediateResponse` 500, never to `Continue`.
//!
//! ## Attribution
//!
//! | Piece | Source |
//! |-------|--------|
//! | Engine | [OWASP ModSecurity / libmodsecurity](https://github.com/owasp-modsecurity/ModSecurity) v3.x (pin `v3.0.16`), C API declared in [`ffi`] |
//! | CRS (optional) | [OWASP CRS](https://github.com/coreruleset/coreruleset) (pin `v4.29.0`), loaded by the caller via `Include` chains |

#![deny(unsafe_op_in_unsafe_fn)]

mod ffi;

use std::ffi::{CStr, CString};
use std::fmt;
use std::os::raw::{c_char, c_int, c_uchar, c_void};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::ptr::{self, NonNull};
use std::sync::{Arc, Mutex, MutexGuard};

use tracing::{debug, info, warn};

const CONNECTOR_INFO: &str = concat!("envoy-modsec-connex/", env!("CARGO_PKG_VERSION"));

/// libmodsecurity's SecLang parser and its engine/rules teardown are not
/// re-entrant (owasp-modsecurity/ModSecurity#3138); every call into them
/// holds this lock. Transactions run concurrently without it.
static PARSE_LOCK: Mutex<()> = Mutex::new(());

fn parse_lock() -> MutexGuard<'static, ()> {
    PARSE_LOCK.lock().unwrap_or_else(|p| p.into_inner())
}

/// Result of evaluating one ModSecurity Transaction API step.
///
/// Maps 1:1 onto intervention semantics: `url` → redirect, `status == 0` →
/// drop, otherwise deny with status.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Decision {
    /// Continue to the next Transaction / ext_proc step.
    Allow,
    /// Disruptive deny — connector emits `ImmediateResponse` with `status`.
    Block { status: i32, log: Option<String> },
    /// Disruptive redirect — `Location` + status.
    Redirect {
        status: i32,
        url: String,
        log: Option<String>,
    },
    /// Disruptive drop (`status == 0`) — close without a normal HTTP response.
    Drop { log: Option<String> },
}

impl Decision {
    /// True when the connector must stop the exchange.
    pub fn is_disruptive(&self) -> bool {
        !matches!(self, Self::Allow)
    }

    /// Stable action label for structured logs.
    pub fn action_label(&self) -> &'static str {
        match self {
            Self::Allow => "allow",
            Self::Block { .. } => "deny",
            Self::Redirect { .. } => "redirect",
            Self::Drop { .. } => "drop",
        }
    }
}

/// Errors from engine construction or a single transaction.
#[derive(Debug)]
pub enum EngineError {
    RulesLoad { path: PathBuf, message: String },
    NoRules,
    Init(String),
    Transaction(String),
}

impl fmt::Display for EngineError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::RulesLoad { path, message } => {
                write!(f, "failed to load rules from {}: {message}", path.display())
            }
            Self::NoRules => f.write_str("no rules files provided"),
            Self::Init(m) => write!(f, "modsecurity init failed: {m}"),
            Self::Transaction(m) => write!(f, "modsecurity transaction error: {m}"),
        }
    }
}

impl std::error::Error for EngineError {}

fn tx_err(e: impl fmt::Display) -> EngineError {
    EngineError::Transaction(e.to_string())
}

fn c_string(what: &str, s: &str) -> Result<CString, EngineError> {
    CString::new(s).map_err(|_| tx_err(format!("{what} contains a NUL byte")))
}

/// `msc_*` Transaction calls return 1 on success.
fn check(what: &str, rc: c_int) -> Result<(), EngineError> {
    if rc == 1 {
        Ok(())
    } else {
        Err(tx_err(format!("{what} returned {rc}")))
    }
}

/// Shared, process-long ModSecurity instance + ruleset.
///
/// Build one [`Engine`] at boot and share it across streams.
pub struct Engine {
    msc: NonNull<ffi::ModSecurity>,
    rules: NonNull<ffi::RulesSet>,
    rules_paths: Vec<PathBuf>,
}

// SAFETY: after loading, `msc` and `rules` are only read by libmodsecurity
// transactions, which it supports running concurrently from many threads;
// parsing and cleanup are serialised by PARSE_LOCK.
unsafe impl Send for Engine {}
unsafe impl Sync for Engine {}

impl Drop for Engine {
    fn drop(&mut self) {
        let _g = parse_lock();
        // SAFETY: both pointers came from msc_create_rules_set / msc_init, are
        // freed exactly once, and every InspectionSession holds an Arc<Engine>,
        // so no transaction outlives them.
        unsafe {
            ffi::msc_rules_cleanup(self.rules.as_ptr());
            ffi::msc_cleanup(self.msc.as_ptr());
        }
    }
}

impl Engine {
    /// Build an engine, loading each rules file in order (e.g. engine
    /// directives, then CRS setup, then `rules/*.conf` via `Include`).
    pub fn load_files(paths: &[impl AsRef<Path>]) -> Result<Arc<Self>, EngineError> {
        if paths.is_empty() {
            return Err(EngineError::NoRules);
        }
        let connector =
            CString::new(CONNECTOR_INFO).map_err(|e| EngineError::Init(e.to_string()))?;

        let mut engine = {
            let _g = parse_lock();
            // SAFETY: plain constructors; NULL is handled below.
            let (msc, rules) = unsafe { (ffi::msc_init(), ffi::msc_create_rules_set()) };
            match (NonNull::new(msc), NonNull::new(rules)) {
                (Some(msc), Some(rules)) => Self {
                    msc,
                    rules,
                    rules_paths: Vec::with_capacity(paths.len()),
                },
                _ => {
                    // SAFETY: free whichever half was allocated.
                    unsafe {
                        if !rules.is_null() {
                            ffi::msc_rules_cleanup(rules);
                        }
                        if !msc.is_null() {
                            ffi::msc_cleanup(msc);
                        }
                    }
                    return Err(EngineError::Init(
                        "msc_init / msc_create_rules_set returned NULL".into(),
                    ));
                }
            }
        };
        // SAFETY: `msc` is live; libmodsecurity copies the connector string.
        unsafe {
            ffi::msc_set_connector_info(engine.msc.as_ptr(), connector.as_ptr());
            ffi::msc_set_log_cb(engine.msc.as_ptr(), Some(log_cb));
        }

        for path in paths {
            let path = path.as_ref().to_path_buf();
            engine.add_rules_file(&path)?;
            info!(path = %path.display(), "loaded ModSecurity rules file");
            engine.rules_paths.push(path);
        }
        Ok(Arc::new(engine))
    }

    fn add_rules_file(&mut self, path: &Path) -> Result<(), EngineError> {
        let load_err = |message: String| EngineError::RulesLoad {
            path: path.to_path_buf(),
            message,
        };
        let file = CString::new(path.as_os_str().as_bytes())
            .map_err(|_| load_err("path contains a NUL byte".into()))?;
        let mut error: *const c_char = ptr::null();
        let _g = parse_lock();
        // SAFETY: `rules` is live and exclusively borrowed; `file` is a valid C
        // string; on failure libmodsecurity allocates `error`, freed below.
        let rc = unsafe { ffi::msc_rules_add_file(self.rules.as_ptr(), file.as_ptr(), &mut error) };
        if rc >= 0 {
            return Ok(());
        }
        let message = if error.is_null() {
            "unknown error".to_owned()
        } else {
            // SAFETY: non-NULL `error` is a NUL-terminated string we now own.
            unsafe {
                let m = CStr::from_ptr(error).to_string_lossy().into_owned();
                ffi::msc_rules_error_cleanup(error);
                m
            }
        };
        Err(load_err(message))
    }

    /// Paths that were successfully loaded at construction.
    pub fn rules_paths(&self) -> &[PathBuf] {
        &self.rules_paths
    }

    /// Open one ModSecurity transaction for an ext_proc stream.
    pub fn open_transaction(
        self: &Arc<Self>,
        request_id: Option<&str>,
    ) -> Result<InspectionSession, EngineError> {
        InspectionSession::begin(Arc::clone(self), request_id)
    }
}

/// Per-transaction data handed to libmodsecurity's log callback.
struct LogContext {
    request_id: String,
}

unsafe extern "C" fn log_cb(data: *mut c_void, msg: *const c_void) {
    if data.is_null() || msg.is_null() {
        return;
    }
    // SAFETY: `data` is the boxed LogContext of a live InspectionSession
    // (freed only after msc_transaction_cleanup); with the default text log
    // property `msg` is a NUL-terminated string.
    let (ctx, msg) = unsafe {
        (
            &*(data as *const LogContext),
            CStr::from_ptr(msg as *const c_char).to_string_lossy(),
        )
    };
    debug!(
        target: "modsecurity",
        request_id = %ctx.request_id,
        message = %msg,
        "modsec engine log"
    );
}

/// One ModSecurity transaction spanning request + response phases for a single
/// HTTP exchange.
pub struct InspectionSession {
    tx: NonNull<ffi::Transaction>,
    request_id: Option<String>,
    request_headers_done: bool,
    request_body_done: bool,
    response_headers_done: bool,
    response_body_done: bool,
    // Dropped after `tx` is cleaned up in `Drop::drop`.
    _id: Option<CString>,
    _log_ctx: Box<LogContext>,
    _engine: Arc<Engine>,
}

// SAFETY: a libmodsecurity Transaction may move between threads; it is only
// ever used through `&mut self`, so never concurrently.
unsafe impl Send for InspectionSession {}

impl Drop for InspectionSession {
    fn drop(&mut self) {
        // Logging phase is best-effort: the stream is ending either way.
        // SAFETY: `tx` is live until the cleanup call below.
        let rc = unsafe { ffi::msc_process_logging(self.tx.as_ptr()) };
        if rc != 1 {
            debug!(
                request_id = self.request_id.as_deref().unwrap_or("-"),
                rc, "modsecurity process_logging failed"
            );
        }
        // SAFETY: freed exactly once; the engine, id and log context it
        // references are dropped only after this.
        unsafe { ffi::msc_transaction_cleanup(self.tx.as_ptr()) };
    }
}

impl InspectionSession {
    fn begin(engine: Arc<Engine>, request_id: Option<&str>) -> Result<Self, EngineError> {
        let id = request_id.map(|r| c_string("request id", r)).transpose()?;
        let log_ctx = Box::new(LogContext {
            request_id: request_id.unwrap_or("-").to_owned(),
        });
        let log_data = &*log_ctx as *const LogContext as *mut c_void;
        // SAFETY: engine pointers are live (we hold the Arc); `id` and
        // `log_ctx` are kept in the session for the transaction's lifetime.
        let tx = unsafe {
            match &id {
                Some(id) => ffi::msc_new_transaction_with_id(
                    engine.msc.as_ptr(),
                    engine.rules.as_ptr(),
                    id.as_ptr() as *mut c_char,
                    log_data,
                ),
                None => {
                    ffi::msc_new_transaction(engine.msc.as_ptr(), engine.rules.as_ptr(), log_data)
                }
            }
        };
        let tx = NonNull::new(tx).ok_or_else(|| tx_err("msc_new_transaction returned NULL"))?;
        Ok(Self {
            tx,
            request_id: request_id.map(str::to_owned),
            request_headers_done: false,
            request_body_done: false,
            response_headers_done: false,
            response_body_done: false,
            _id: id,
            _log_ctx: log_ctx,
            _engine: engine,
        })
    }

    fn raw(&mut self) -> *mut ffi::Transaction {
        self.tx.as_ptr()
    }

    /// Request id this transaction was opened with (Envoy `x-request-id`).
    pub fn request_id(&self) -> Option<&str> {
        self.request_id.as_deref()
    }

    /// Phase 1: connection + URI + request headers.
    ///
    /// Intervention is checked after each of `process_connection`,
    /// `process_uri`, and `process_request_headers`. Does **not** run the
    /// request-body phase; call [`Self::finish_request_body`] at body EOS (or
    /// right away when the request has no body).
    #[allow(clippy::too_many_arguments)]
    pub fn process_request_headers<K, V>(
        &mut self,
        client_ip: &str,
        client_port: i32,
        server_ip: &str,
        server_port: i32,
        method: &str,
        uri: &str,
        http_version: &str,
        headers: &[(K, V)],
    ) -> Result<Decision, EngineError>
    where
        K: AsRef<str>,
        V: AsRef<str>,
    {
        if self.request_headers_done {
            return Err(tx_err("process_request_headers called twice"));
        }
        let client = c_string("client address", client_ip)?;
        let server = c_string("server address", server_ip)?;
        // SAFETY: live transaction; C strings outlive the call.
        let rc = unsafe {
            ffi::msc_process_connection(
                self.raw(),
                client.as_ptr(),
                client_port,
                server.as_ptr(),
                server_port,
            )
        };
        check("process_connection", rc)?;
        if let Some(d) = self.disrupt_after("connection")? {
            return Ok(d);
        }

        let uri = c_string("uri", uri)?;
        let method = c_string("method", method)?;
        let version = c_string("http version", http_version)?;
        // SAFETY: as above.
        let rc = unsafe {
            ffi::msc_process_uri(self.raw(), uri.as_ptr(), method.as_ptr(), version.as_ptr())
        };
        check("process_uri", rc)?;
        if let Some(d) = self.disrupt_after("uri")? {
            return Ok(d);
        }

        for (k, v) in headers {
            let k = c_string("request header name", k.as_ref())?;
            let v = c_string("request header value", v.as_ref())?;
            // SAFETY: as above; libmodsecurity copies header strings.
            let rc = unsafe {
                ffi::msc_add_request_header(
                    self.raw(),
                    k.as_ptr() as *const c_uchar,
                    v.as_ptr() as *const c_uchar,
                )
            };
            check("add_request_header", rc)?;
        }
        // SAFETY: live transaction.
        check("process_request_headers", unsafe {
            ffi::msc_process_request_headers(self.raw())
        })?;
        self.request_headers_done = true;
        self.intervention("request_headers")
    }

    /// Append request-body bytes and honour intervention on this append
    /// (`SecRequestBodyLimitAction Reject` fires here, before EOS).
    pub fn append_request_body(&mut self, chunk: &[u8]) -> Result<Decision, EngineError> {
        if !self.request_headers_done {
            return Err(tx_err("append_request_body before request headers"));
        }
        if self.request_body_done {
            return Err(tx_err("append_request_body after request body finished"));
        }
        if chunk.is_empty() {
            return Ok(Decision::Allow);
        }
        // SAFETY: live transaction; libmodsecurity copies the bytes.
        check("append_request_body", unsafe {
            ffi::msc_append_request_body(self.raw(), chunk.as_ptr(), chunk.len())
        })?;
        self.intervention("append_request_body")
    }

    /// Finish the request-body phase (CRS phase 2). Idempotent.
    pub fn finish_request_body(&mut self) -> Result<Decision, EngineError> {
        if self.request_body_done {
            return Ok(Decision::Allow);
        }
        if !self.request_headers_done {
            return Err(tx_err("finish_request_body before request headers"));
        }
        // SAFETY: live transaction.
        check("process_request_body", unsafe {
            ffi::msc_process_request_body(self.raw())
        })?;
        self.request_body_done = true;
        self.intervention("request_body")
    }

    /// Phase 3: response status + headers. Closes the request body first if
    /// the caller never did (e.g. request body mode `NONE`).
    pub fn process_response_headers<K, V>(
        &mut self,
        status: i32,
        protocol: &str,
        headers: &[(K, V)],
    ) -> Result<Decision, EngineError>
    where
        K: AsRef<str>,
        V: AsRef<str>,
    {
        if self.response_headers_done {
            return Err(tx_err("process_response_headers called twice"));
        }
        if !self.request_body_done {
            let early = self.finish_request_body()?;
            if early.is_disruptive() {
                return Ok(early);
            }
        }
        for (k, v) in headers {
            let k = c_string("response header name", k.as_ref())?;
            let v = c_string("response header value", v.as_ref())?;
            // SAFETY: live transaction; libmodsecurity copies header strings.
            let rc = unsafe {
                ffi::msc_add_response_header(
                    self.raw(),
                    k.as_ptr() as *const c_uchar,
                    v.as_ptr() as *const c_uchar,
                )
            };
            check("add_response_header", rc)?;
        }
        let protocol = c_string("protocol", protocol)?;
        // SAFETY: live transaction; C string outlives the call.
        check("process_response_headers", unsafe {
            ffi::msc_process_response_headers(self.raw(), status, protocol.as_ptr())
        })?;
        self.response_headers_done = true;
        self.intervention("response_headers")
    }

    /// Append response-body bytes; honour intervention on this append.
    pub fn append_response_body(&mut self, chunk: &[u8]) -> Result<Decision, EngineError> {
        if !self.response_headers_done {
            return Err(tx_err("append_response_body before response headers"));
        }
        if self.response_body_done {
            return Err(tx_err("append_response_body after response body finished"));
        }
        if chunk.is_empty() {
            return Ok(Decision::Allow);
        }
        // SAFETY: live transaction; libmodsecurity copies the bytes.
        check("append_response_body", unsafe {
            ffi::msc_append_response_body(self.raw(), chunk.as_ptr(), chunk.len())
        })?;
        self.intervention("append_response_body")
    }

    /// Finish the response-body phase (CRS phase 4). Idempotent.
    pub fn finish_response_body(&mut self) -> Result<Decision, EngineError> {
        if self.response_body_done {
            return Ok(Decision::Allow);
        }
        if !self.response_headers_done {
            return Err(tx_err("finish_response_body before response headers"));
        }
        // SAFETY: live transaction.
        check("process_response_body", unsafe {
            ffi::msc_process_response_body(self.raw())
        })?;
        self.response_body_done = true;
        self.intervention("response_body")
    }

    fn disrupt_after(&mut self, phase: &str) -> Result<Option<Decision>, EngineError> {
        let d = self.intervention(phase)?;
        Ok(d.is_disruptive().then_some(d))
    }

    /// Read the pending intervention and map it to a [`Decision`].
    ///
    /// `pause` is logged and ignored: ext_proc has no delay primitive.
    fn intervention(&mut self, phase: &str) -> Result<Decision, EngineError> {
        let mut it = ffi::ModSecurityIntervention {
            status: 200,
            pause: 0,
            url: ptr::null_mut(),
            log: ptr::null_mut(),
            disruptive: 0,
        };
        // SAFETY: live transaction; `it` is a valid out-parameter. url/log
        // are copied out before msc_intervention_cleanup frees them.
        let (pending, disruptive, status, pause, url, log) = unsafe {
            let pending = ffi::msc_intervention(self.raw(), &mut it) > 0;
            let owned = |p: *mut c_char| {
                (!p.is_null()).then(|| CStr::from_ptr(p).to_string_lossy().into_owned())
            };
            let out = (
                pending,
                it.disruptive != 0,
                it.status,
                it.pause,
                owned(it.url),
                owned(it.log),
            );
            ffi::msc_intervention_cleanup(&mut it);
            out
        };
        if !pending {
            return Ok(Decision::Allow);
        }
        let rid = self.request_id.as_deref().unwrap_or("-");
        if pause != 0 {
            warn!(
                request_id = rid,
                phase, pause, "modsecurity pause intervention unsupported; ignoring pause"
            );
        }
        let decision = map_intervention(disruptive, status, url.as_deref(), log);
        match &decision {
            Decision::Allow => {
                debug!(
                    request_id = rid,
                    phase, status, "modsecurity non-disruptive intervention ignored"
                );
            }
            d => {
                let log = match d {
                    Decision::Block { log, .. }
                    | Decision::Redirect { log, .. }
                    | Decision::Drop { log } => log.as_deref(),
                    Decision::Allow => None,
                };
                warn!(
                    request_id = rid,
                    phase,
                    action = d.action_label(),
                    status,
                    log = log.unwrap_or("-"),
                    "modsecurity disruptive intervention"
                );
            }
        }
        Ok(decision)
    }
}

/// Map raw intervention fields to a [`Decision`] (testable without FFI).
///
/// Priority:
/// 1. non-disruptive → Allow
/// 2. non-empty `url` → Redirect (status defaults to 302)
/// 3. `status == 0` → Drop
/// 4. else → Block with status
///
/// libmodsecurity v3.0.16 executes the SecLang `drop` action as deny/403, so
/// the Drop branch is only reached if the engine reports status 0.
pub fn map_intervention(
    disruptive: bool,
    status: i32,
    url: Option<&str>,
    log: Option<String>,
) -> Decision {
    if !disruptive {
        return Decision::Allow;
    }
    if let Some(url) = url.filter(|u| !u.is_empty()) {
        let redirect_status = if status > 0 { status } else { 302 };
        return Decision::Redirect {
            status: redirect_status,
            url: url.to_owned(),
            log,
        };
    }
    if status == 0 {
        return Decision::Drop { log };
    }
    Decision::Block { status, log }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn testdata(name: &str) -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("testdata")
            .join(name)
    }

    fn headers_host() -> Vec<(&'static str, &'static str)> {
        vec![
            ("host", "example.com"),
            ("user-agent", "modsec-engine-test"),
        ]
    }

    fn get(session: &mut InspectionSession, uri: &str) -> Decision {
        session
            .process_request_headers(
                "127.0.0.1",
                54321,
                "127.0.0.1",
                80,
                "GET",
                uri,
                "1.1",
                &headers_host(),
            )
            .expect("request headers")
    }

    #[test]
    fn empty_rules_list_is_rejected() {
        let none: [PathBuf; 0] = [];
        assert!(matches!(
            Engine::load_files(&none),
            Err(EngineError::NoRules)
        ));
    }

    #[test]
    fn missing_rules_file_is_rejected() {
        let err = Engine::load_files(&[testdata("does-not-exist.conf")])
            .err()
            .expect("missing file must fail");
        assert!(matches!(err, EngineError::RulesLoad { .. }), "{err:?}");
    }

    #[test]
    fn invalid_seclang_is_rejected() {
        let dir = std::env::temp_dir().join(format!("modsec-engine-bad-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("tmp dir");
        let bad = dir.join("bad.conf");
        std::fs::write(&bad, "SecRule THIS IS NOT SECLANG\n").expect("write");
        let res = Engine::load_files(&[&bad]);
        let _ = std::fs::remove_dir_all(&dir);
        assert!(matches!(res, Err(EngineError::RulesLoad { .. })));
    }

    #[test]
    fn allows_benign_root() {
        let engine = Engine::load_files(&[testdata("phase1-deny-admin.conf")]).expect("load");
        let mut s = engine.open_transaction(Some("test-allow")).expect("tx");
        assert_eq!(s.request_id(), Some("test-allow"));
        assert_eq!(get(&mut s, "/"), Decision::Allow);
        assert_eq!(s.finish_request_body().expect("body"), Decision::Allow);
    }

    #[test]
    fn blocks_admin_path_at_phase1() {
        let engine = Engine::load_files(&[testdata("phase1-deny-admin.conf")]).expect("load");
        let mut s = engine.open_transaction(Some("test-block")).expect("tx");
        match get(&mut s, "/admin") {
            Decision::Block { status, .. } => assert_eq!(status, 403),
            other => panic!("expected block for /admin, got {other:?}"),
        }
    }

    #[test]
    fn redirects_on_phase1_url_intervention() {
        let engine = Engine::load_files(&[testdata("phase1-redirect.conf")]).expect("load");
        let mut s = engine.open_transaction(Some("test-redirect")).expect("tx");
        match get(&mut s, "/go-away/now") {
            Decision::Redirect { status, url, .. } => {
                assert_eq!(status, 302);
                assert!(url.contains("example.test/bye"), "unexpected url: {url}");
            }
            other => panic!("expected redirect, got {other:?}"),
        }
    }

    #[test]
    fn map_intervention_priorities() {
        assert_eq!(map_intervention(false, 403, None, None), Decision::Allow);
        assert_eq!(
            map_intervention(true, 0, None, Some("drop-me".into())),
            Decision::Drop {
                log: Some("drop-me".into())
            }
        );
        assert!(matches!(
            map_intervention(true, 403, None, None),
            Decision::Block { status: 403, .. }
        ));
        assert!(matches!(
            map_intervention(true, 0, Some("http://example.test/x"), None),
            Decision::Redirect { status: 302, url, .. } if url == "http://example.test/x"
        ));
        assert!(matches!(
            map_intervention(true, 403, Some(""), None),
            Decision::Block { status: 403, .. }
        ));
    }

    #[test]
    fn seclang_drop_action_v3_aliases_deny() {
        let engine = Engine::load_files(&[testdata("phase1-drop.conf")]).expect("load");
        let mut s = engine.open_transaction(Some("test-drop")).expect("tx");
        match get(&mut s, "/drop-me") {
            Decision::Block { status, .. } => assert_eq!(status, 403),
            Decision::Drop { .. } => {}
            other => panic!("expected Block(403) or Drop, got {other:?}"),
        }
    }

    #[test]
    fn blocks_sqli_in_request_body() {
        let engine = Engine::load_files(&[testdata("phase2-deny-body.conf")]).expect("load");
        let mut s = engine.open_transaction(Some("test-body")).expect("tx");
        let headers = [
            ("host", "example.com"),
            ("content-type", "application/x-www-form-urlencoded"),
        ];
        let d = s
            .process_request_headers(
                "127.0.0.1",
                54321,
                "127.0.0.1",
                80,
                "POST",
                "/post",
                "1.1",
                &headers,
            )
            .expect("headers");
        assert_eq!(d, Decision::Allow);
        let mid = s.append_request_body(b"var=1' OR '1'='1").expect("append");
        let d = if mid.is_disruptive() {
            mid
        } else {
            s.finish_request_body().expect("body")
        };
        assert!(matches!(d, Decision::Block { status: 403, .. }), "{d:?}");
    }

    #[test]
    fn intervenes_after_append_when_body_limit_exceeded() {
        let engine = Engine::load_files(&[testdata("phase2-body-limit.conf")]).expect("load");
        let mut s = engine.open_transaction(Some("test-limit")).expect("tx");
        let headers = [("host", "example.com"), ("content-type", "text/plain")];
        let d = s
            .process_request_headers(
                "127.0.0.1",
                54321,
                "127.0.0.1",
                80,
                "POST",
                "/upload",
                "1.1",
                &headers,
            )
            .expect("headers");
        assert_eq!(d, Decision::Allow);
        let d = s.append_request_body(&[b'A'; 64]).expect("append");
        assert!(
            d.is_disruptive(),
            "oversized append must disrupt, got {d:?}"
        );
    }

    #[test]
    fn blocks_marker_in_response_body() {
        let engine =
            Engine::load_files(&[testdata("phase4-deny-response-body.conf")]).expect("load");
        let mut s = engine.open_transaction(Some("test-resp")).expect("tx");
        assert_eq!(get(&mut s, "/leak"), Decision::Allow);
        assert_eq!(s.finish_request_body().expect("req body"), Decision::Allow);
        let d = s
            .process_response_headers(200, "HTTP/1.1", &[("content-type", "text/plain")])
            .expect("resp headers");
        assert_eq!(d, Decision::Allow);
        let mid = s
            .append_response_body(b"secret: CONNEX-LEAK-MARKER\n")
            .expect("append");
        let d = if mid.is_disruptive() {
            mid
        } else {
            s.finish_response_body().expect("resp body")
        };
        assert!(matches!(d, Decision::Block { status: 403, .. }), "{d:?}");
    }

    #[test]
    fn allows_clean_response_body() {
        let engine =
            Engine::load_files(&[testdata("phase4-deny-response-body.conf")]).expect("load");
        let mut s = engine.open_transaction(Some("test-resp-ok")).expect("tx");
        assert_eq!(get(&mut s, "/"), Decision::Allow);
        let d = s
            .process_response_headers(200, "HTTP/1.1", &[("content-type", "text/plain")])
            .expect("resp headers (closes request body implicitly)");
        assert_eq!(d, Decision::Allow);
        assert_eq!(
            s.append_response_body(b"hello").expect("append"),
            Decision::Allow
        );
        assert_eq!(s.finish_response_body().expect("finish"), Decision::Allow);
    }

    #[test]
    fn out_of_order_phases_are_errors() {
        let engine = Engine::load_files(&[testdata("phase1-deny-admin.conf")]).expect("load");
        let mut s = engine.open_transaction(None).expect("tx");
        assert!(s.append_request_body(b"x").is_err());
        assert!(s.finish_request_body().is_err());
        assert!(s.append_response_body(b"x").is_err());
        assert!(s.finish_response_body().is_err());
        assert_eq!(get(&mut s, "/"), Decision::Allow);
        assert!(
            s.process_request_headers::<&str, &str>(
                "127.0.0.1",
                1,
                "127.0.0.1",
                80,
                "GET",
                "/",
                "1.1",
                &[]
            )
            .is_err(),
            "headers twice must be an error"
        );
    }

    /// Runs against a CRS checkout at `$CONNEX_CRS_DIR` (default `demo/.crs`,
    /// created by `demo/scripts/install-crs.sh`). Skips when absent.
    fn crs_engine() -> Option<Arc<Engine>> {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
        let crs = std::env::var_os("CONNEX_CRS_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| root.join("demo/.crs"));
        let rules = crs.join("rules");
        if !rules.is_dir() {
            eprintln!(
                "skip: no CRS at {} (run demo/scripts/install-crs.sh)",
                crs.display()
            );
            return None;
        }
        let setup = [
            crs.join("crs-setup.conf"),
            crs.join("crs-setup.conf.example"),
        ]
        .into_iter()
        .find(|p| p.is_file())?;
        let dir = std::env::temp_dir().join(format!(
            "modsec-engine-crs-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        std::fs::create_dir_all(&dir).ok()?;
        let include = dir.join("crs.conf");
        std::fs::write(
            &include,
            format!(
                "SecRuleEngine On\nSecRequestBodyAccess On\nInclude {}\nInclude {}/*.conf\n",
                setup.display(),
                rules.display()
            ),
        )
        .ok()?;
        let engine = Engine::load_files(&[&include]).expect("load CRS include chain");
        let _ = std::fs::remove_dir_all(&dir);
        Some(engine)
    }

    #[test]
    fn crs_allows_root_and_blocks_sqli_when_present() {
        let Some(engine) = crs_engine() else { return };
        let mut ok = engine.open_transaction(Some("crs-root")).expect("tx");
        assert_eq!(get(&mut ok, "/"), Decision::Allow);
        assert_eq!(ok.finish_request_body().expect("body"), Decision::Allow);

        let mut bad = engine.open_transaction(Some("crs-sqli")).expect("tx");
        let d = get(&mut bad, "/search?q=1%27%20UNION%20SELECT%201,2--");
        let d = if d.is_disruptive() {
            d
        } else {
            bad.finish_request_body().expect("body")
        };
        assert!(matches!(d, Decision::Block { status: 403, .. }), "{d:?}");
    }
}
