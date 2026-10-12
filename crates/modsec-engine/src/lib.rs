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
//! | Engine | [OWASP ModSecurity / libmodsecurity](https://github.com/owasp-modsecurity/ModSecurity) v3.x (pin `v3.0.17`), C API declared in [`ffi`] |
//! | CRS (optional) | [OWASP CRS](https://github.com/coreruleset/coreruleset) (pin `v4.30.0`), loaded by the caller via `Include` chains |

#![deny(unsafe_op_in_unsafe_fn)]

mod ffi;

use std::collections::hash_map::RandomState;
use std::ffi::{CStr, CString};
use std::fmt;
use std::hash::{BuildHasher, Hasher};
use std::os::raw::{c_char, c_int, c_uchar, c_void};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::ptr::{self, NonNull};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

use tracing::{debug, info, warn};

const CONNECTOR_INFO: &str = concat!("envoy-modsec-connex/", env!("CARGO_PKG_VERSION"));

/// First of the two engine-mode probe rule ids. They are only ever loaded
/// into the throwaway probe ruleset, never into the one serving traffic.
const PROBE_RULE_ID: u64 = 4_200_000_001;

/// Longest rule `msg` the WARN intervention log carries; CRS messages can
/// expand request data through macros.
const MAX_LOGGED_MSG: usize = 200;

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
    RulesLoad {
        path: PathBuf,
        message: String,
    },
    NoRules,
    /// Every file parsed, but together they define zero rules (e.g. an empty
    /// or directives-only ConfigMap): the engine would allow everything.
    ZeroRulesLoaded {
        paths: Vec<PathBuf>,
    },
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
            Self::ZeroRulesLoaded { paths } => {
                let names: Vec<String> = paths.iter().map(|p| p.display().to_string()).collect();
                write!(
                    f,
                    "rules files loaded but define 0 rules (would allow every request): {}",
                    names.join(", ")
                )
            }
            Self::Init(m) => write!(f, "modsecurity init failed: {m}"),
            Self::Transaction(m) => write!(f, "modsecurity transaction error: {m}"),
        }
    }
}

impl std::error::Error for EngineError {}

/// How the loaded ruleset's `SecRuleEngine` resolves for a transaction,
/// measured once at load by [`Engine::load_files`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EngineMode {
    /// Disruptive actions run: traffic is enforced.
    On,
    /// Rules run and log, nothing is blocked. Also what an unset
    /// `SecRuleEngine` means in libmodsecurity v3.
    DetectionOnly,
    /// Rules do not run.
    Off,
    /// The probe could not run (see the load log).
    Unknown,
}

impl EngineMode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::On => "On",
            Self::DetectionOnly => "DetectionOnly",
            Self::Off => "Off",
            Self::Unknown => "unknown",
        }
    }
}

/// ModSecurity transaction id (`UNIQUE_ID`, audit-log key): generated here
/// so a client-chosen `x-request-id` cannot set or collide with it.
fn next_tx_id() -> String {
    static PREFIX: OnceLock<u64> = OnceLock::new();
    static SEQ: AtomicU64 = AtomicU64::new(0);
    let prefix = *PREFIX.get_or_init(|| {
        let mut h = RandomState::new().build_hasher();
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or_default();
        h.write_u128(now);
        h.write_u32(std::process::id());
        h.finish()
    });
    format!("{prefix:016x}-{:x}", SEQ.fetch_add(1, Ordering::Relaxed))
}

/// The value of a `[name "value"]` tag in a libmodsecurity log line.
fn log_tag<'a>(log: &'a str, name: &str) -> Option<&'a str> {
    let open = format!("[{name} \"");
    let start = log.find(&open)? + open.len();
    let len = log[start..].find("\"]")?;
    Some(&log[start..start + len])
}

fn truncated(s: &str, max: usize) -> &str {
    match s.char_indices().nth(max) {
        Some((i, _)) => &s[..i],
        None => s,
    }
}

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
    rule_count: usize,
    mode: EngineMode,
    /// Test-only (`fail-inject` feature): next Transaction step on a session
    /// from this engine returns [`EngineError`]. Per-engine so parallel tests
    /// do not race. Compiled out of product builds.
    #[cfg(feature = "fail-inject")]
    fail_next: AtomicBool,
    /// Test-only (`fail-inject` feature): next Transaction step panics.
    #[cfg(feature = "fail-inject")]
    panic_next: AtomicBool,
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
    /// directives, then CRS setup, then `rules/*.conf` via `Include`), and
    /// measure its [`EngineMode`].
    pub fn load_files(paths: &[impl AsRef<Path>]) -> Result<Arc<Self>, EngineError> {
        let mut engine = Self::build(paths, false)?;
        engine.mode = Self::probe_mode(paths);
        info!(
            files = engine.rules_paths.len(),
            rules = engine.rule_count,
            mode = engine.mode.as_str(),
            "ModSecurity ruleset loaded"
        );
        Ok(Arc::new(engine))
    }

    /// `SecRuleEngine` is not readable through the C API, so load the same
    /// files plus two phase-1 rules for a random URI into a throwaway
    /// ruleset and run one request through it: a logging `pass` rule (a
    /// rule with a disruptive action never reaches the log callback) and a
    /// `deny`. A disruptive intervention means On, only the logged match
    /// means DetectionOnly, neither means Off. `noauditlog` would also
    /// silence the log callback; the probe transaction skips the logging
    /// phase instead, so it writes no audit log entry.
    fn probe_mode(paths: &[impl AsRef<Path>]) -> EngineMode {
        let token = next_tx_id();
        let uri = format!("/__modsec_engine_probe/{token}");
        let rule = format!(
            "SecRule REQUEST_URI \"@streq {uri}\" \"id:{PROBE_RULE_ID},phase:1,pass,log,\
             msg:'engine mode probe {token}'\"\n\
             SecRule REQUEST_URI \"@streq {uri}\" \"id:{},phase:1,deny,status:403,nolog,\
             noauditlog\"\n",
            PROBE_RULE_ID + 1
        );
        let run = || -> Result<EngineMode, EngineError> {
            let mut probe = Self::build(paths, true)?;
            probe.add_rules_text(&rule)?;
            let probe = Arc::new(probe);
            let mut session = InspectionSession::begin(probe, None, Some(token.clone()))?;
            let decision = session.process_request_headers(
                "192.0.2.1",
                40000,
                "127.0.0.1",
                80,
                "GET",
                &uri,
                "1.1",
                &[("host", "localhost")],
            )?;
            Ok(if decision.is_disruptive() {
                EngineMode::On
            } else if session._log_ctx.probe_matched.load(Ordering::Relaxed) {
                EngineMode::DetectionOnly
            } else {
                EngineMode::Off
            })
        };
        run().unwrap_or_else(|e| {
            warn!(error = %e, "ModSecurity engine mode probe failed; mode unknown");
            EngineMode::Unknown
        })
    }

    fn build(paths: &[impl AsRef<Path>], quiet: bool) -> Result<Self, EngineError> {
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
                    rule_count: 0,
                    mode: EngineMode::Unknown,
                    #[cfg(feature = "fail-inject")]
                    fail_next: AtomicBool::new(false),
                    #[cfg(feature = "fail-inject")]
                    panic_next: AtomicBool::new(false),
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
            let rules = engine.add_rules_file(&path)?;
            engine.rule_count += rules;
            if !quiet {
                info!(path = %path.display(), rules, "loaded ModSecurity rules file");
            }
            engine.rules_paths.push(path);
        }
        if engine.rule_count == 0 {
            return Err(EngineError::ZeroRulesLoaded {
                paths: std::mem::take(&mut engine.rules_paths),
            });
        }
        Ok(engine)
    }

    fn add_rules_text(&mut self, text: &str) -> Result<usize, EngineError> {
        let rules = c_string("rules text", text)?;
        let mut error: *const c_char = ptr::null();
        let _g = parse_lock();
        // SAFETY: as in add_rules_file.
        let rc = unsafe { ffi::msc_rules_add(self.rules.as_ptr(), rules.as_ptr(), &mut error) };
        if let Ok(n) = usize::try_from(rc) {
            return Ok(n);
        }
        Err(EngineError::Init(format!(
            "probe rule rejected: {}",
            take_rules_error(error)
        )))
    }

    /// Returns the number of rules the file added (`msc_rules_add_file`'s
    /// return value; directives such as `SecRuleEngine` are not rules).
    fn add_rules_file(&mut self, path: &Path) -> Result<usize, EngineError> {
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
        if let Ok(rules) = usize::try_from(rc) {
            return Ok(rules);
        }
        Err(load_err(take_rules_error(error)))
    }

    /// Paths that were successfully loaded at construction.
    pub fn rules_paths(&self) -> &[PathBuf] {
        &self.rules_paths
    }

    /// Total rules libmodsecurity reported across all files (never 0).
    pub fn rule_count(&self) -> usize {
        self.rule_count
    }

    /// `SecRuleEngine` as measured at load.
    pub fn mode(&self) -> EngineMode {
        self.mode
    }

    /// Arm a one-shot mid-exchange engine error on the next Transaction API
    /// step for a session from this engine (test builds with `fail-inject` only).
    #[cfg(feature = "fail-inject")]
    pub fn inject_fail_next_transaction_step(&self) {
        self.fail_next.store(true, Ordering::SeqCst);
    }

    /// Arm a one-shot panic on the next Transaction API step (test builds with
    /// `fail-inject` only), to prove a connector panic never ends a stream OK.
    #[cfg(feature = "fail-inject")]
    pub fn inject_panic_next_transaction_step(&self) {
        self.panic_next.store(true, Ordering::SeqCst);
    }

    #[cfg(feature = "fail-inject")]
    fn take_injected_fail(&self, what: &str) -> Result<(), EngineError> {
        if self.panic_next.swap(false, Ordering::SeqCst) {
            panic!("{what}: injected test panic");
        }
        if self.fail_next.swap(false, Ordering::SeqCst) {
            Err(tx_err(format!("{what}: injected test failure")))
        } else {
            Ok(())
        }
    }

    #[cfg(not(feature = "fail-inject"))]
    #[inline]
    fn take_injected_fail(&self, _what: &str) -> Result<(), EngineError> {
        Ok(())
    }

    /// Open one ModSecurity transaction for an ext_proc stream.
    pub fn open_transaction(
        self: &Arc<Self>,
        request_id: Option<&str>,
    ) -> Result<InspectionSession, EngineError> {
        InspectionSession::begin(Arc::clone(self), request_id, None)
    }
}

/// Message of a failed `msc_rules_add*` call; frees it.
fn take_rules_error(error: *const c_char) -> String {
    if error.is_null() {
        return "unknown error".to_owned();
    }
    // SAFETY: non-NULL `error` is a NUL-terminated string we now own.
    unsafe {
        let m = CStr::from_ptr(error).to_string_lossy().into_owned();
        ffi::msc_rules_error_cleanup(error);
        m
    }
}

/// Per-transaction data handed to libmodsecurity's log callback.
struct LogContext {
    tx_id: String,
    request_id: String,
    /// Engine-mode probe only: token of the probe rule's `msg`.
    probe_token: Option<String>,
    probe_matched: AtomicBool,
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
    if ctx.probe_token.as_deref().is_some_and(|t| msg.contains(t)) {
        ctx.probe_matched.store(true, Ordering::Relaxed);
    }
    debug!(
        target: "modsecurity",
        tx_id = %ctx.tx_id,
        request_id = %ctx.request_id,
        message = %msg,
        "modsec engine log"
    );
}

/// One ModSecurity transaction spanning request + response phases for a single
/// HTTP exchange.
pub struct InspectionSession {
    tx: NonNull<ffi::Transaction>,
    tx_id: String,
    request_id: Option<String>,
    request_headers_done: bool,
    request_body_done: bool,
    response_headers_done: bool,
    response_body_done: bool,
    // Dropped after `tx` is cleaned up in `Drop::drop`.
    _id: CString,
    _log_ctx: Box<LogContext>,
    _engine: Arc<Engine>,
}

// SAFETY: a libmodsecurity Transaction may move between threads; it is only
// ever used through `&mut self`, so never concurrently.
unsafe impl Send for InspectionSession {}

impl Drop for InspectionSession {
    fn drop(&mut self) {
        // Logging phase is best-effort: the stream is ending either way.
        // The engine-mode probe skips it so it never writes an audit entry.
        if self._log_ctx.probe_token.is_none() {
            // SAFETY: `tx` is live until the cleanup call below.
            let rc = unsafe { ffi::msc_process_logging(self.tx.as_ptr()) };
            if rc != 1 {
                debug!(
                    tx_id = %self.tx_id,
                    request_id = self.request_id.as_deref().unwrap_or("-"),
                    rc,
                    "modsecurity process_logging failed"
                );
            }
        }
        // SAFETY: freed exactly once; the engine, id and log context it
        // references are dropped only after this.
        unsafe { ffi::msc_transaction_cleanup(self.tx.as_ptr()) };
    }
}

impl InspectionSession {
    /// `request_id` (Envoy `x-request-id`) is only a log field; the
    /// ModSecurity transaction id is generated by [`next_tx_id`].
    fn begin(
        engine: Arc<Engine>,
        request_id: Option<&str>,
        probe_token: Option<String>,
    ) -> Result<Self, EngineError> {
        let tx_id = next_tx_id();
        let id = c_string("transaction id", &tx_id)?;
        let log_ctx = Box::new(LogContext {
            tx_id: tx_id.clone(),
            request_id: request_id.unwrap_or("-").to_owned(),
            probe_token,
            probe_matched: AtomicBool::new(false),
        });
        let log_data = &*log_ctx as *const LogContext as *mut c_void;
        // SAFETY: engine pointers are live (we hold the Arc); `id` and
        // `log_ctx` are kept in the session for the transaction's lifetime.
        let tx = unsafe {
            ffi::msc_new_transaction_with_id(
                engine.msc.as_ptr(),
                engine.rules.as_ptr(),
                id.as_ptr() as *mut c_char,
                log_data,
            )
        };
        let tx = NonNull::new(tx).ok_or_else(|| tx_err("msc_new_transaction returned NULL"))?;
        Ok(Self {
            tx,
            tx_id,
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

    /// ModSecurity transaction id (`UNIQUE_ID`, audit-log key).
    pub fn tx_id(&self) -> &str {
        &self.tx_id
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
        self._engine.take_injected_fail("append_request_body")?;
        // A zero-length chunk does not change the buffered body. Limit
        // rejects are evaluated on the append that crosses the limit; phase 2
        // rules run in `finish_request_body`.
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
        self._engine.take_injected_fail("process_request_body")?;
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
        self._engine.take_injected_fail("append_response_body")?;
        // A zero-length chunk does not change the buffered body. Limit
        // rejects are evaluated on the append that crosses the limit; phase 4
        // rules run in `finish_response_body`.
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
        self._engine.take_injected_fail("process_response_body")?;
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
        let tx_id = self.tx_id.as_str();
        if pause != 0 {
            warn!(
                tx_id,
                request_id = rid,
                phase,
                pause,
                "modsecurity pause intervention unsupported; ignoring pause"
            );
        }
        let decision = map_intervention(disruptive, status, url.as_deref(), log);
        match &decision {
            Decision::Allow => {
                debug!(
                    tx_id,
                    request_id = rid,
                    phase,
                    status,
                    "modsecurity non-disruptive intervention ignored"
                );
            }
            Decision::Block { log, .. }
            | Decision::Redirect { log, .. }
            | Decision::Drop { log } => {
                // The full log quotes matched request data; it stays at DEBUG.
                let log = log.as_deref().unwrap_or("");
                warn!(
                    tx_id,
                    request_id = rid,
                    phase,
                    action = decision.action_label(),
                    status,
                    rule_id = log_tag(log, "id").unwrap_or("-"),
                    msg = truncated(log_tag(log, "msg").unwrap_or("-"), MAX_LOGGED_MSG),
                    "modsecurity disruptive intervention"
                );
                debug!(
                    tx_id,
                    request_id = rid,
                    phase,
                    log,
                    "modsecurity intervention log"
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
/// libmodsecurity v3.0.17 executes the SecLang `drop` action as deny/403, so
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
    fn zero_rule_rulesets_are_rejected() {
        let dir = std::env::temp_dir().join(format!("modsec-engine-zero-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("tmp dir");
        let empty = dir.join("empty.conf");
        let directives = dir.join("directives.conf");
        std::fs::write(&empty, "").expect("write");
        std::fs::write(
            &directives,
            "SecRuleEngine On\nSecRequestBodyAccess On\n# rules would follow\n",
        )
        .expect("write");
        let only_empty = Engine::load_files(&[&empty]);
        let only_directives = Engine::load_files(&[&directives]);
        let both = Engine::load_files(&[&empty, &directives]);
        let with_rules = Engine::load_files(&[&directives, &testdata("phase1-deny-admin.conf")]);
        let _ = std::fs::remove_dir_all(&dir);

        for (name, res) in [
            ("empty", only_empty),
            ("directives", only_directives),
            ("both", both),
        ] {
            match res {
                Err(EngineError::ZeroRulesLoaded { paths }) => {
                    assert!(!paths.is_empty(), "{name}: error names the files")
                }
                Err(other) => panic!("{name}: want ZeroRulesLoaded, got {other}"),
                Ok(_) => panic!("{name}: a 0-rule ruleset must not load"),
            }
        }
        let engine = with_rules.expect("directives + one rule file loads");
        assert!(engine.rule_count() >= 1, "{}", engine.rule_count());
    }

    fn mode_of(directives: &str) -> (EngineMode, usize) {
        let dir = std::env::temp_dir().join(format!(
            "modsec-engine-mode-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        std::fs::create_dir_all(&dir).expect("tmp dir");
        let engine_conf = dir.join("engine.conf");
        let rule = dir.join("rule.conf");
        std::fs::write(&engine_conf, directives).expect("write");
        std::fs::write(
            &rule,
            "SecRule REQUEST_URI \"@contains /admin\" \"id:1,phase:1,deny,status:403\"\n",
        )
        .expect("write");
        let engine = Engine::load_files(&[engine_conf, rule]).expect("load");
        let _ = std::fs::remove_dir_all(&dir);
        (engine.mode(), engine.rule_count())
    }

    #[test]
    fn engine_mode_is_measured_at_load() {
        let (on, on_rules) = mode_of("SecRuleEngine On\n");
        let (detect, _) = mode_of("SecRuleEngine DetectionOnly\n");
        let (off, _) = mode_of("SecRuleEngine Off\n");
        let (unset, _) = mode_of("SecRequestBodyAccess On\n");
        assert_eq!(on, EngineMode::On);
        assert_eq!(detect, EngineMode::DetectionOnly);
        assert_eq!(off, EngineMode::Off);
        assert_eq!(
            unset,
            EngineMode::DetectionOnly,
            "unset SecRuleEngine does not block"
        );
        assert_eq!(
            on_rules, 1,
            "the probe rules must not join the serving ruleset"
        );
    }

    #[test]
    fn detection_only_engine_does_not_block() {
        let dir = std::env::temp_dir().join(format!("modsec-engine-detect-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("tmp dir");
        let conf = dir.join("detect.conf");
        std::fs::write(&conf, "SecRuleEngine DetectionOnly\n").expect("write");
        let engine = Engine::load_files(&[conf, testdata("phase1-deny-admin.conf")]).expect("load");
        let _ = std::fs::remove_dir_all(&dir);
        let mut s = engine.open_transaction(Some("detect")).expect("tx");
        assert_eq!(get(&mut s, "/admin"), Decision::Allow);
    }

    #[test]
    fn transaction_id_is_generated_not_the_request_id() {
        let engine = Engine::load_files(&[testdata("phase1-deny-admin.conf")]).expect("load");
        let a = engine.open_transaction(Some("same-client-id")).expect("tx");
        let b = engine.open_transaction(Some("same-client-id")).expect("tx");
        assert_eq!(a.request_id(), Some("same-client-id"));
        assert_ne!(a.tx_id(), "same-client-id");
        assert_ne!(a.tx_id(), b.tx_id(), "transaction ids are unique");
        assert!(
            a.tx_id().chars().all(|c| c.is_ascii_hexdigit() || c == '-'),
            "{}",
            a.tx_id()
        );
    }

    #[test]
    fn log_tags_are_extracted() {
        let log = r#"ModSecurity: Access denied with code 403 (phase 2). Matched "Operator `Ge' with parameter `5' against variable `TX:BLOCKING_INBOUND_ANOMALY_SCORE' (Value: `5' ) [file "/crs/rules/REQUEST-949-BLOCKING-EVALUATION.conf"] [line "222"] [id "949110"] [rev ""] [msg "Inbound Anomaly Score Exceeded (Total Score: 5)"] [data "secret=1' OR '1'='1"]"#;
        assert_eq!(log_tag(log, "id"), Some("949110"));
        assert_eq!(
            log_tag(log, "msg"),
            Some("Inbound Anomaly Score Exceeded (Total Score: 5)")
        );
        assert_eq!(log_tag(log, "missing"), None);
        assert_eq!(truncated("héllo", 2), "hé");
        assert_eq!(truncated("ab", 5), "ab");
    }

    #[test]
    fn rule_count_sums_every_file() {
        let one = Engine::load_files(&[testdata("phase1-deny-admin.conf")]).expect("load");
        let two = Engine::load_files(&[
            testdata("phase1-deny-admin.conf"),
            testdata("phase1-deny-trace.conf"),
        ])
        .expect("load");
        assert!(one.rule_count() >= 1);
        assert!(
            two.rule_count() > one.rule_count(),
            "{} vs {}",
            two.rule_count(),
            one.rule_count()
        );
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
    fn seclang_drop_action_is_deny_403() {
        // v3.0.17 still logs "executing deny instead of drop" and sets status
        // 403. A real status-0 Drop would be a pin change, not this alias.
        let engine = Engine::load_files(&[testdata("phase1-drop.conf")]).expect("load");
        let mut s = engine.open_transaction(Some("test-drop")).expect("tx");
        match get(&mut s, "/drop-me") {
            Decision::Block { status, .. } => assert_eq!(status, 403),
            other => panic!("v3.0.17 drop executes as deny/403, got {other:?}"),
        }
    }

    #[test]
    fn request_method_is_the_process_uri_method() {
        // The C API names this argument `protocol`; it is REQUEST_METHOD.
        let engine = Engine::load_files(&[testdata("phase1-deny-trace.conf")]).expect("load");
        let mut allow = engine.open_transaction(Some("test-get")).expect("tx");
        assert_eq!(get(&mut allow, "/"), Decision::Allow);
        let mut deny = engine.open_transaction(Some("test-trace")).expect("tx");
        let d = deny
            .process_request_headers(
                "127.0.0.1",
                1,
                "127.0.0.1",
                80,
                "TRACE",
                "/",
                "1.1",
                &headers_host(),
            )
            .expect("headers");
        assert!(matches!(d, Decision::Block { status: 403, .. }), "{d:?}");
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
    /// created by `demo/scripts/install-crs.sh`). Without CRS it skips, unless
    /// `CONNEX_REQUIRE_CRS=1` (set in CI), where a missing CRS fails the test.
    fn crs_engine() -> Option<Arc<Engine>> {
        let required = std::env::var("CONNEX_REQUIRE_CRS").is_ok_and(|v| v == "1");
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
        let crs = std::env::var_os("CONNEX_CRS_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| root.join("demo/.crs"));
        let rules = crs.join("rules");
        let setup = [
            crs.join("crs-setup.conf"),
            crs.join("crs-setup.conf.example"),
        ]
        .into_iter()
        .find(|p| p.is_file());
        let Some(setup) = setup.filter(|_| rules.is_dir()) else {
            assert!(
                !required,
                "CONNEX_REQUIRE_CRS=1 but no CRS rules/ + crs-setup.conf at {} \
                 (run demo/scripts/install-crs.sh)",
                crs.display()
            );
            eprintln!(
                "skip: no CRS at {} (run demo/scripts/install-crs.sh)",
                crs.display()
            );
            return None;
        };
        let dir = std::env::temp_dir().join(format!(
            "modsec-engine-crs-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        std::fs::create_dir_all(&dir).expect("CRS tmp dir");
        let include = dir.join("crs.conf");
        std::fs::write(
            &include,
            format!(
                "SecRuleEngine On\nSecRequestBodyAccess On\nInclude {}\nInclude {}/*.conf\n",
                setup.display(),
                rules.display()
            ),
        )
        .expect("write CRS include chain");
        let engine = Engine::load_files(&[&include]).expect("load CRS include chain");
        let _ = std::fs::remove_dir_all(&dir);
        // CRS v4 ships several hundred rules; a handful means a broken checkout.
        assert!(
            engine.rule_count() >= 100,
            "CRS at {} loaded only {} rules",
            crs.display(),
            engine.rule_count()
        );
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
