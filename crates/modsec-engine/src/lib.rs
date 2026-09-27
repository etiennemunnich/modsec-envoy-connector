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
//! | Engine | [OWASP ModSecurity / libmodsecurity](https://github.com/owasp-modsecurity/ModSecurity) v3.x (pin `v3.0.16`) |
//! | Rust bindings | [`modsecurity` / `modsecurity-sys`](https://crates.io/crates/modsecurity) (Apache-2.0 / MIT) |
//! | CRS (optional) | [OWASP CRS](https://github.com/coreruleset/coreruleset) (pin `v4.29.0`), loaded by the caller via `Include` chains |

#![deny(unsafe_op_in_unsafe_fn)]

use std::mem::ManuallyDrop;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use modsecurity::{ModSecurity, Rules, Transaction};
use thiserror::Error;
use tracing::{debug, info, warn};

const CONNECTOR_INFO: &str = concat!("envoy-modsec-connex/", env!("CARGO_PKG_VERSION"));

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
#[derive(Debug, Error)]
pub enum EngineError {
    #[error("failed to load rules from {path}: {message}")]
    RulesLoad { path: PathBuf, message: String },
    #[error("no rules files provided")]
    NoRules,
    #[error("modsecurity init failed: {0}")]
    Init(String),
    #[error("modsecurity transaction error: {0}")]
    Transaction(String),
}

fn tx_err(e: impl std::fmt::Display) -> EngineError {
    EngineError::Transaction(e.to_string())
}

/// Shared, process-long ModSecurity instance + ruleset.
///
/// libmodsecurity rule parsing is not re-entrant; the bindings serialize
/// parse/cleanup. Build one [`Engine`] at boot and share it across streams.
pub struct Engine {
    msc: ModSecurity,
    rules: Rules,
    rules_paths: Vec<PathBuf>,
}

impl Engine {
    /// Build an engine, loading each rules file in order (e.g. engine
    /// directives, then CRS setup, then `rules/*.conf` via `Include`).
    pub fn load_files(paths: &[impl AsRef<Path>]) -> Result<Arc<Self>, EngineError> {
        if paths.is_empty() {
            return Err(EngineError::NoRules);
        }

        let msc = ModSecurity::builder()
            .with_connector_info(CONNECTOR_INFO)
            .map_err(|e| EngineError::Init(e.to_string()))?
            .with_log_callbacks()
            .build();

        let mut rules = Rules::new();
        let mut rules_paths = Vec::with_capacity(paths.len());

        for path in paths {
            let path = path.as_ref().to_path_buf();
            rules.add_file(&path).map_err(|e| EngineError::RulesLoad {
                path: path.clone(),
                message: e.to_string(),
            })?;
            info!(path = %path.display(), "loaded ModSecurity rules file");
            rules_paths.push(path);
        }

        Ok(Arc::new(Self {
            msc,
            rules,
            rules_paths,
        }))
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

/// One ModSecurity transaction spanning request + response phases for a single
/// HTTP exchange.
///
/// # Lifetime / safety
///
/// `modsecurity::Transaction` borrows the engine's `ModSecurity` + `Rules`.
/// The session owns an [`Arc<Engine>`] and drops the transaction in [`Drop`]
/// *before* that `Arc` is released; the `'static` transmute in
/// [`InspectionSession::begin`] is only sound while that ordering holds.
pub struct InspectionSession {
    tx: ManuallyDrop<Transaction<'static>>,
    request_id: Option<String>,
    request_headers_done: bool,
    request_body_done: bool,
    response_headers_done: bool,
    response_body_done: bool,
    // Must be declared (and therefore dropped) after `tx`.
    _engine: Arc<Engine>,
}

impl Drop for InspectionSession {
    fn drop(&mut self) {
        // Logging phase is best-effort: the stream is ending either way.
        if let Err(e) = self.tx.process_logging() {
            debug!(
                request_id = self.request_id.as_deref().unwrap_or("-"),
                error = %e,
                "modsecurity process_logging failed"
            );
        }
        // SAFETY: `tx` is dropped exactly once, here, while `_engine` (which
        // owns the borrowed ModSecurity/Rules) is still alive.
        unsafe {
            ManuallyDrop::drop(&mut self.tx);
        }
    }
}

impl InspectionSession {
    fn begin(engine: Arc<Engine>, request_id: Option<&str>) -> Result<Self, EngineError> {
        let id_owned = request_id.map(str::to_owned);
        let mut builder = engine.msc.transaction_builder().with_rules(&engine.rules);
        if let Some(ref id) = id_owned {
            builder = builder.with_id(id);
        }
        let log_rid = id_owned.clone().unwrap_or_else(|| "-".into());
        builder = builder.with_logging(move |msg| {
            if let Some(m) = msg {
                debug!(
                    target: "modsecurity",
                    request_id = %log_rid,
                    message = %m,
                    "modsec engine log"
                );
            }
        });
        let tx = builder.build().map_err(tx_err)?;

        // SAFETY: `tx` borrows `engine.msc` / `engine.rules`. `engine` is moved
        // into the same struct and outlives `tx` (see `Drop`).
        let tx_static: Transaction<'static> = unsafe { std::mem::transmute(tx) };

        Ok(Self {
            tx: ManuallyDrop::new(tx_static),
            request_id: id_owned,
            request_headers_done: false,
            request_body_done: false,
            response_headers_done: false,
            response_body_done: false,
            _engine: engine,
        })
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
        self.tx
            .process_connection(client_ip, client_port, server_ip, server_port)
            .map_err(tx_err)?;
        if let Some(d) = self.disrupt_after("connection")? {
            return Ok(d);
        }

        self.tx
            .process_uri(uri, method, http_version)
            .map_err(tx_err)?;
        if let Some(d) = self.disrupt_after("uri")? {
            return Ok(d);
        }

        for (k, v) in headers {
            self.tx
                .add_request_header(k.as_ref(), v.as_ref())
                .map_err(tx_err)?;
        }
        self.tx.process_request_headers().map_err(tx_err)?;
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
        self.tx.append_request_body(chunk).map_err(tx_err)?;
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
        self.tx.process_request_body().map_err(tx_err)?;
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
            self.tx
                .add_response_header(k.as_ref(), v.as_ref())
                .map_err(tx_err)?;
        }
        self.tx
            .process_response_headers(status, protocol)
            .map_err(tx_err)?;
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
        self.tx.append_response_body(chunk).map_err(tx_err)?;
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
        self.tx.process_response_body().map_err(tx_err)?;
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
        let rid = self.request_id.as_deref().unwrap_or("-");
        let Some(it) = self.tx.intervention() else {
            return Ok(Decision::Allow);
        };
        let status = it.status();
        let pause = it.pause();
        if pause != 0 {
            warn!(
                request_id = rid,
                phase, pause, "modsecurity pause intervention unsupported; ignoring pause"
            );
        }
        let decision = map_intervention(
            it.disruptive(),
            status,
            it.url(),
            it.log().map(str::to_owned),
        );
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
