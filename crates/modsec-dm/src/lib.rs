//! Envoy **dynamic module** HTTP filter for ModSecurity (alpha).
//!
//! In-process `cdylib` loaded by `envoy.filters.http.dynamic_modules`. Drives
//! [`modsec_engine`] on Envoy worker threads. **Not** the ext_proc sidecar:
//! no process isolation, no `failure_mode_allow`, no hang→504 via
//! `message_timeout`. CatchUnwind covers **Rust** panics only — libmodsecurity
//! SIGSEGV/UB still shares Envoy's fate.
//!
//! ## Native body policies (not Envoy `BodySendMode`)
//!
//! | `body_policy` | Product intent | Notes |
//! |---------------|----------------|-------|
//! | `buffer_until_eos` | BUFFERED | Hold headers until body EOS; deny before origin |
//! | `stream_chunks` | STREAMED | Per-chunk inspect; early bytes may hit origin |
//! | `headers_only` | NONE | Finish empty body at headers; body bypass |
//! | `prefix_then_continue` | BUFFERED_PARTIAL | Soft-limit prefix; never CRS-complete |
//! | `full_duplex_hold` | FULL_DUPLEX | **Config reject** (UNSUPPORTED) |
//!
//! Forbid `module.remote` for enforcement (fetch fail → filter omitted = fail-open).
//!
//! Status: early testing / alpha dual option — not production-ready.

#![deny(unsafe_op_in_unsafe_fn)]

use std::sync::Arc;

use envoy_proxy_dynamic_modules_rust_sdk::*;
use modsec_engine::{Decision, Engine, EngineError, InspectionSession};
use serde::Deserialize;

declare_init_functions!(init, new_http_filter_config_fn);

fn init() -> bool {
    true
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum BodyPolicy {
    BufferUntilEos,
    StreamChunks,
    HeadersOnly,
    PrefixThenContinue,
}

impl BodyPolicy {
    fn parse(s: &str) -> Result<Self, ()> {
        match s {
            "buffer_until_eos" | "BUFFERED" => Ok(Self::BufferUntilEos),
            "stream_chunks" | "STREAMED" => Ok(Self::StreamChunks),
            "headers_only" | "NONE" => Ok(Self::HeadersOnly),
            "prefix_then_continue" | "BUFFERED_PARTIAL" | "PARTIAL" => Ok(Self::PrefixThenContinue),
            "full_duplex_hold" | "FULL_DUPLEX_STREAMED" | "FULL_DUPLEX" => {
                eprintln!(
                    "modsec-dm: UNSUPPORTED body_policy={s} (no StreamedBodyResponse / hold-until-allow on DM)"
                );
                Err(())
            }
            _ => {
                eprintln!("modsec-dm: unknown body_policy={s}");
                Err(())
            }
        }
    }
}

#[derive(Debug, Deserialize)]
struct FilterConfigJson {
    rules_path: String,
    #[serde(default)]
    label: Option<String>,
    #[serde(default = "default_body_policy")]
    body_policy: String,
    #[serde(default = "default_soft_limit")]
    partial_soft_limit_bytes: usize,
}

fn default_body_policy() -> String {
    "buffer_until_eos".into()
}

fn default_soft_limit() -> usize {
    1_048_576
}

struct ModSecFilterConfig {
    engine: Arc<Engine>,
    label: String,
    body_policy: BodyPolicy,
    partial_soft_limit_bytes: usize,
}

impl ModSecFilterConfig {
    fn from_bytes(config: &[u8]) -> Option<Self> {
        let text = std::str::from_utf8(config).ok()?;
        let cfg: FilterConfigJson = match serde_json::from_str(text) {
            Ok(c) => c,
            Err(e) => {
                eprintln!("modsec-dm: bad JSON filter_config: {e}");
                return None;
            }
        };
        let body_policy = BodyPolicy::parse(&cfg.body_policy).ok()?;
        let engine = match Engine::load_files(&[cfg.rules_path.as_str()]) {
            Ok(e) => e,
            Err(e) => {
                eprintln!("modsec-dm: Engine::load_files failed: {e}");
                return None;
            }
        };
        Some(Self {
            engine,
            label: cfg.label.unwrap_or_else(|| "modsec".into()),
            body_policy,
            partial_soft_limit_bytes: cfg.partial_soft_limit_bytes.max(1),
        })
    }
}

impl<EHF: EnvoyHttpFilter> HttpFilterConfig<EHF> for ModSecFilterConfig {
    fn new_http_filter(&self, _envoy: &mut EHF) -> Box<dyn HttpFilter<EHF>> {
        Box::new(CatchUnwind::new(ModSecFilter {
            engine: Arc::clone(&self.engine),
            label: self.label.clone(),
            body_policy: self.body_policy,
            partial_soft_limit_bytes: self.partial_soft_limit_bytes,
            session: None,
            headers_done: false,
            body_finished: false,
            response_body_finished: false,
            denied: false,
        }))
    }
}

struct ModSecFilter {
    engine: Arc<Engine>,
    label: String,
    body_policy: BodyPolicy,
    partial_soft_limit_bytes: usize,
    session: Option<InspectionSession>,
    headers_done: bool,
    body_finished: bool,
    response_body_finished: bool,
    denied: bool,
}

fn new_http_filter_config_fn<EC: EnvoyHttpFilterConfig, EHF: EnvoyHttpFilter>(
    _envoy_filter_config: &mut EC,
    name: &str,
    config: &[u8],
) -> Option<Box<dyn HttpFilterConfig<EHF>>> {
    match name {
        "modsecurity" => {
            let cfg = ModSecFilterConfig::from_bytes(config)?;
            eprintln!(
                "modsec-dm: loaded filter_name=modsecurity label={} policy={:?} rules={}",
                cfg.label,
                cfg.body_policy,
                cfg.engine
                    .rules_paths()
                    .first()
                    .map(|p| p.display().to_string())
                    .unwrap_or_default()
            );
            Some(Box::new(cfg))
        }
        _ => {
            eprintln!("modsec-dm: unknown filter_name={name}");
            None
        }
    }
}

impl ModSecFilter {
    fn fail_closed<EHF: EnvoyHttpFilter>(&mut self, envoy: &mut EHF, err: &EngineError) {
        eprintln!("modsec-dm[{}]: EngineError → 500: {err}", self.label);
        self.denied = true;
        #[cfg(feature = "negctl-continue-on-err")]
        {
            let _ = (envoy, err);
            // Intentional fail-open for negctl red proof only.
            self.denied = false;
            return;
        }
        #[cfg(not(feature = "negctl-continue-on-err"))]
        {
            envoy.send_response(
                500,
                &[],
                Some(b"modsecurity evaluation error\n"),
                Some("modsec_dm_engine_error"),
            );
        }
    }

    fn settle_disruptive<EHF: EnvoyHttpFilter>(
        &mut self,
        envoy: &mut EHF,
        decision: Decision,
    ) -> bool {
        match decision {
            Decision::Allow => false,
            Decision::Block { status, .. } => {
                let code = if (400..600).contains(&status) {
                    status as u32
                } else {
                    403
                };
                self.denied = true;
                envoy.send_response(code, &[], Some(b"Forbidden\n"), Some("modsec_dm_deny"));
                true
            }
            Decision::Redirect { status, url, .. } => {
                let code = if (300..400).contains(&status) {
                    status as u32
                } else {
                    302
                };
                let loc = url.into_bytes();
                self.denied = true;
                envoy.send_response(
                    code,
                    &[("location", loc.as_slice())],
                    Some(b"Redirect\n"),
                    Some("modsec_dm_redirect"),
                );
                true
            }
            Decision::Drop { .. } => {
                self.denied = true;
                envoy.send_response(403, &[], Some(b"dropped\n"), Some("modsec_dm_drop"));
                true
            }
        }
    }

    fn attr_string<EHF: EnvoyHttpFilter>(
        envoy: &EHF,
        id: abi::envoy_dynamic_module_type_attribute_id,
        default: &str,
    ) -> String {
        envoy
            .get_attribute_string(id)
            .map(|b| String::from_utf8_lossy(b.as_slice()).into_owned())
            .unwrap_or_else(|| default.to_owned())
    }

    fn attr_port<EHF: EnvoyHttpFilter>(
        envoy: &EHF,
        id: abi::envoy_dynamic_module_type_attribute_id,
        default: i32,
    ) -> i32 {
        envoy
            .get_attribute_int(id)
            .map(|v| v as i32)
            .unwrap_or(default)
    }

    fn collect_request_headers<EHF: EnvoyHttpFilter>(
        envoy: &EHF,
    ) -> (String, String, Vec<(Vec<u8>, Vec<u8>)>) {
        let mut method = String::from("GET");
        let mut path = String::from("/");
        let mut hdrs: Vec<(Vec<u8>, Vec<u8>)> = Vec::new();
        let mut host: Option<Vec<u8>> = None;
        let mut has_host = false;

        for (k, v) in envoy.get_request_headers() {
            let key = k.as_slice();
            let val = v.as_slice().to_vec();
            if key == b":method" {
                method = String::from_utf8_lossy(&val).into_owned();
                continue;
            }
            if key == b":path" {
                path = String::from_utf8_lossy(&val).into_owned();
                continue;
            }
            if key == b":authority" {
                host = Some(val.clone());
                continue;
            }
            if key.starts_with(b":") {
                continue;
            }
            if key.eq_ignore_ascii_case(b"host") {
                has_host = true;
            }
            hdrs.push((key.to_vec(), val));
        }
        if !has_host {
            if let Some(h) = host {
                hdrs.push((b"host".to_vec(), h));
            }
        }
        (method, path, hdrs)
    }

    fn collect_response_headers<EHF: EnvoyHttpFilter>(envoy: &EHF) -> (i32, Vec<(Vec<u8>, Vec<u8>)>) {
        let mut status: i32 = 200;
        let mut hdrs: Vec<(Vec<u8>, Vec<u8>)> = Vec::new();
        for (k, v) in envoy.get_response_headers() {
            let key = k.as_slice();
            let val = v.as_slice().to_vec();
            if key == b":status" {
                status = String::from_utf8_lossy(&val)
                    .parse()
                    .unwrap_or(200);
                continue;
            }
            if key.starts_with(b":") {
                continue;
            }
            hdrs.push((key.to_vec(), val));
        }
        (status, hdrs)
    }

    fn copy_buffered_request_body<EHF: EnvoyHttpFilter>(envoy: &mut EHF) -> Vec<u8> {
        let Some(bufs) = envoy.get_buffered_request_body() else {
            return Vec::new();
        };
        let mut out = Vec::new();
        for b in bufs {
            out.extend_from_slice(b.as_slice());
        }
        out
    }

    fn copy_received_request_body<EHF: EnvoyHttpFilter>(envoy: &mut EHF) -> Vec<u8> {
        let Some(bufs) = envoy.get_received_request_body() else {
            return Vec::new();
        };
        let mut out = Vec::new();
        for b in bufs {
            out.extend_from_slice(b.as_slice());
        }
        out
    }

    fn copy_buffered_response_body<EHF: EnvoyHttpFilter>(envoy: &mut EHF) -> Vec<u8> {
        let Some(bufs) = envoy.get_buffered_response_body() else {
            return Vec::new();
        };
        let mut out = Vec::new();
        for b in bufs {
            out.extend_from_slice(b.as_slice());
        }
        out
    }

    fn copy_received_response_body<EHF: EnvoyHttpFilter>(envoy: &mut EHF) -> Vec<u8> {
        let Some(bufs) = envoy.get_received_response_body() else {
            return Vec::new();
        };
        let mut out = Vec::new();
        for b in bufs {
            out.extend_from_slice(b.as_slice());
        }
        out
    }

    fn strip_ip(s: String) -> String {
        s.rsplit_once(':')
            .map(|(ip, _)| ip.trim_matches(|c| c == '[' || c == ']').to_owned())
            .unwrap_or(s)
    }
}

impl<EHF: EnvoyHttpFilter> HttpFilter<EHF> for ModSecFilter {
    fn on_request_headers(
        &mut self,
        envoy_filter: &mut EHF,
        end_of_stream: bool,
    ) -> abi::envoy_dynamic_module_type_on_http_filter_request_headers_status {
        use abi::envoy_dynamic_module_type_on_http_filter_request_headers_status as HS;

        let (method, path, hdrs) = Self::collect_request_headers(envoy_filter);
        let client_ip = Self::strip_ip(Self::attr_string(
            envoy_filter,
            abi::envoy_dynamic_module_type_attribute_id::SourceAddress,
            "127.0.0.1",
        ));
        let client_port = Self::attr_port(
            envoy_filter,
            abi::envoy_dynamic_module_type_attribute_id::SourcePort,
            0,
        );
        let server_ip = Self::strip_ip(Self::attr_string(
            envoy_filter,
            abi::envoy_dynamic_module_type_attribute_id::DestinationAddress,
            "127.0.0.1",
        ));
        let server_port = Self::attr_port(
            envoy_filter,
            abi::envoy_dynamic_module_type_attribute_id::DestinationPort,
            80,
        );
        let proto = Self::attr_string(
            envoy_filter,
            abi::envoy_dynamic_module_type_attribute_id::RequestProtocol,
            "HTTP/1.1",
        );
        let http_version = if proto.contains('2') {
            "2.0"
        } else if proto.contains('3') {
            "3.0"
        } else {
            "1.1"
        };
        let rid = Self::attr_string(
            envoy_filter,
            abi::envoy_dynamic_module_type_attribute_id::RequestId,
            "-",
        );

        let mut session = match self.engine.open_transaction(Some(rid.as_str())) {
            Ok(s) => s,
            Err(e) => {
                self.fail_closed(envoy_filter, &e);
                return HS::StopIteration;
            }
        };

        match session.process_request_headers(
            &client_ip,
            client_port,
            &server_ip,
            server_port,
            &method,
            &path,
            http_version,
            &hdrs,
        ) {
            Ok(d) if d.is_disruptive() => {
                self.settle_disruptive(envoy_filter, d);
                return HS::StopIteration;
            }
            Ok(_) => {}
            Err(e) => {
                self.fail_closed(envoy_filter, &e);
                return HS::StopIteration;
            }
        }

        self.headers_done = true;

        let close_body_now = end_of_stream || self.body_policy == BodyPolicy::HeadersOnly;
        if close_body_now {
            match session.finish_request_body() {
                Ok(d) if d.is_disruptive() => {
                    self.settle_disruptive(envoy_filter, d);
                    return HS::StopIteration;
                }
                Ok(_) => self.body_finished = true,
                Err(e) => {
                    self.fail_closed(envoy_filter, &e);
                    return HS::StopIteration;
                }
            }
        }

        self.session = Some(session);

        if !end_of_stream
            && matches!(
                self.body_policy,
                BodyPolicy::BufferUntilEos | BodyPolicy::PrefixThenContinue
            )
        {
            return HS::StopIteration;
        }

        HS::Continue
    }

    fn on_request_body(
        &mut self,
        envoy_filter: &mut EHF,
        end_of_stream: bool,
    ) -> abi::envoy_dynamic_module_type_on_http_filter_request_body_status {
        use abi::envoy_dynamic_module_type_on_http_filter_request_body_status as BS;

        if self.denied {
            return BS::StopIterationNoBuffer;
        }
        if self.body_policy == BodyPolicy::HeadersOnly {
            return BS::Continue;
        }
        if self.body_finished {
            return BS::Continue;
        }

        match self.body_policy {
            BodyPolicy::BufferUntilEos => {
                if !end_of_stream {
                    return BS::StopIterationAndBuffer;
                }
                let Some(mut session) = self.session.take() else {
                    self.fail_closed(
                        envoy_filter,
                        &EngineError::Transaction("body without session".into()),
                    );
                    return BS::StopIterationNoBuffer;
                };
                let body = Self::copy_buffered_request_body(envoy_filter);
                match session.append_request_body(&body) {
                    Ok(d) if d.is_disruptive() => {
                        self.settle_disruptive(envoy_filter, d);
                        return BS::StopIterationNoBuffer;
                    }
                    Ok(_) => {}
                    Err(e) => {
                        self.fail_closed(envoy_filter, &e);
                        return BS::StopIterationNoBuffer;
                    }
                }
                match session.finish_request_body() {
                    Ok(d) if d.is_disruptive() => {
                        self.settle_disruptive(envoy_filter, d);
                        BS::StopIterationNoBuffer
                    }
                    Ok(_) => {
                        self.body_finished = true;
                        self.session = Some(session);
                        BS::Continue
                    }
                    Err(e) => {
                        self.fail_closed(envoy_filter, &e);
                        BS::StopIterationNoBuffer
                    }
                }
            }
            BodyPolicy::StreamChunks => {
                let Some(session) = self.session.as_mut() else {
                    self.fail_closed(
                        envoy_filter,
                        &EngineError::Transaction("body without session".into()),
                    );
                    return BS::StopIterationNoBuffer;
                };
                let chunk = Self::copy_received_request_body(envoy_filter);
                match session.append_request_body(&chunk) {
                    Ok(d) if d.is_disruptive() => {
                        self.settle_disruptive(envoy_filter, d);
                        return BS::StopIterationNoBuffer;
                    }
                    Ok(_) => {}
                    Err(e) => {
                        self.fail_closed(envoy_filter, &e);
                        return BS::StopIterationNoBuffer;
                    }
                }
                if end_of_stream {
                    match session.finish_request_body() {
                        Ok(d) if d.is_disruptive() => {
                            self.settle_disruptive(envoy_filter, d);
                            return BS::StopIterationNoBuffer;
                        }
                        Ok(_) => self.body_finished = true,
                        Err(e) => {
                            self.fail_closed(envoy_filter, &e);
                            return BS::StopIterationNoBuffer;
                        }
                    }
                }
                BS::Continue
            }
            BodyPolicy::PrefixThenContinue => {
                let soft = self.partial_soft_limit_bytes;
                if !end_of_stream {
                    let buffered = envoy_filter.get_buffered_request_body_size();
                    if buffered < soft {
                        return BS::StopIterationAndBuffer;
                    }
                }
                let Some(mut session) = self.session.take() else {
                    self.fail_closed(
                        envoy_filter,
                        &EngineError::Transaction("body without session".into()),
                    );
                    return BS::StopIterationNoBuffer;
                };
                let body = Self::copy_buffered_request_body(envoy_filter);
                let n = body.len().min(soft);
                match session.append_request_body(&body[..n]) {
                    Ok(d) if d.is_disruptive() => {
                        self.settle_disruptive(envoy_filter, d);
                        return BS::StopIterationNoBuffer;
                    }
                    Ok(_) => {}
                    Err(e) => {
                        self.fail_closed(envoy_filter, &e);
                        return BS::StopIterationNoBuffer;
                    }
                }
                match session.finish_request_body() {
                    Ok(d) if d.is_disruptive() => {
                        self.settle_disruptive(envoy_filter, d);
                        BS::StopIterationNoBuffer
                    }
                    Ok(_) => {
                        self.body_finished = true;
                        self.session = Some(session);
                        BS::Continue
                    }
                    Err(e) => {
                        self.fail_closed(envoy_filter, &e);
                        BS::StopIterationNoBuffer
                    }
                }
            }
            BodyPolicy::HeadersOnly => BS::Continue,
        }
    }

    fn on_response_headers(
        &mut self,
        envoy_filter: &mut EHF,
        end_of_stream: bool,
    ) -> abi::envoy_dynamic_module_type_on_http_filter_response_headers_status {
        use abi::envoy_dynamic_module_type_on_http_filter_response_headers_status as HS;

        if self.denied {
            return HS::StopIteration;
        }
        let Some(session) = self.session.as_mut() else {
            return HS::Continue;
        };

        let (status, hdrs) = Self::collect_response_headers(envoy_filter);
        // Protocol string is informational for ModSec; reuse request protocol attr if present.
        let proto = Self::attr_string(
            envoy_filter,
            abi::envoy_dynamic_module_type_attribute_id::RequestProtocol,
            "HTTP/1.1",
        );
        match session.process_response_headers(status, &proto, &hdrs) {
            Ok(d) if d.is_disruptive() => {
                self.settle_disruptive(envoy_filter, d);
                return HS::StopIteration;
            }
            Ok(_) => {}
            Err(e) => {
                self.fail_closed(envoy_filter, &e);
                return HS::StopIteration;
            }
        }

        let close_body_now = end_of_stream || self.body_policy == BodyPolicy::HeadersOnly;
        if close_body_now {
            match session.finish_response_body() {
                Ok(d) if d.is_disruptive() => {
                    self.settle_disruptive(envoy_filter, d);
                    return HS::StopIteration;
                }
                Ok(_) => self.response_body_finished = true,
                Err(e) => {
                    self.fail_closed(envoy_filter, &e);
                    return HS::StopIteration;
                }
            }
        }

        if !end_of_stream
            && matches!(
                self.body_policy,
                BodyPolicy::BufferUntilEos | BodyPolicy::PrefixThenContinue
            )
        {
            return HS::StopIteration;
        }
        HS::Continue
    }

    fn on_response_body(
        &mut self,
        envoy_filter: &mut EHF,
        end_of_stream: bool,
    ) -> abi::envoy_dynamic_module_type_on_http_filter_response_body_status {
        use abi::envoy_dynamic_module_type_on_http_filter_response_body_status as BS;

        if self.denied {
            return BS::StopIterationNoBuffer;
        }
        if self.body_policy == BodyPolicy::HeadersOnly || self.response_body_finished {
            return BS::Continue;
        }
        let Some(session) = self.session.as_mut() else {
            return BS::Continue;
        };

        match self.body_policy {
            BodyPolicy::BufferUntilEos | BodyPolicy::PrefixThenContinue => {
                if !end_of_stream {
                    return BS::StopIterationAndBuffer;
                }
                let body = if self.body_policy == BodyPolicy::PrefixThenContinue {
                    let raw = Self::copy_buffered_response_body(envoy_filter);
                    let n = raw.len().min(self.partial_soft_limit_bytes);
                    raw[..n].to_vec()
                } else {
                    Self::copy_buffered_response_body(envoy_filter)
                };
                match session.append_response_body(&body) {
                    Ok(d) if d.is_disruptive() => {
                        self.settle_disruptive(envoy_filter, d);
                        return BS::StopIterationNoBuffer;
                    }
                    Ok(_) => {}
                    Err(e) => {
                        self.fail_closed(envoy_filter, &e);
                        return BS::StopIterationNoBuffer;
                    }
                }
                match session.finish_response_body() {
                    Ok(d) if d.is_disruptive() => {
                        self.settle_disruptive(envoy_filter, d);
                        BS::StopIterationNoBuffer
                    }
                    Ok(_) => {
                        self.response_body_finished = true;
                        BS::Continue
                    }
                    Err(e) => {
                        self.fail_closed(envoy_filter, &e);
                        BS::StopIterationNoBuffer
                    }
                }
            }
            BodyPolicy::StreamChunks => {
                let chunk = Self::copy_received_response_body(envoy_filter);
                match session.append_response_body(&chunk) {
                    Ok(d) if d.is_disruptive() => {
                        self.settle_disruptive(envoy_filter, d);
                        return BS::StopIterationNoBuffer;
                    }
                    Ok(_) => {}
                    Err(e) => {
                        self.fail_closed(envoy_filter, &e);
                        return BS::StopIterationNoBuffer;
                    }
                }
                if end_of_stream {
                    match session.finish_response_body() {
                        Ok(d) if d.is_disruptive() => {
                            self.settle_disruptive(envoy_filter, d);
                            return BS::StopIterationNoBuffer;
                        }
                        Ok(_) => self.response_body_finished = true,
                        Err(e) => {
                            self.fail_closed(envoy_filter, &e);
                            return BS::StopIterationNoBuffer;
                        }
                    }
                }
                BS::Continue
            }
            BodyPolicy::HeadersOnly => BS::Continue,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    // Envoy host symbols are absent outside the proxy. CatchUnwind logs via the
    // SDK macros, which still call these FFI entry points when *our* crate is
    // under `cfg(test)` but the SDK dependency is not. Stub them for MockEnvoy.
    #[no_mangle]
    pub extern "C" fn envoy_dynamic_module_callback_log_enabled(
        _level: abi::envoy_dynamic_module_type_log_level,
    ) -> bool {
        false
    }

    #[no_mangle]
    pub extern "C" fn envoy_dynamic_module_callback_log(
        _level: abi::envoy_dynamic_module_type_log_level,
        _message: abi::envoy_dynamic_module_type_module_buffer,
    ) {
    }

    #[no_mangle]
    pub extern "C" fn envoy_dynamic_module_callback_get_log_level(
    ) -> abi::envoy_dynamic_module_type_log_level {
        abi::envoy_dynamic_module_type_log_level::Info
    }

    fn write_rules(dir: &std::path::Path, body: &str) -> std::path::PathBuf {
        let path = dir.join("rules.conf");
        let mut f = std::fs::File::create(&path).unwrap();
        writeln!(f, "SecRuleEngine On").unwrap();
        write!(f, "{body}").unwrap();
        path
    }

    #[test]
    fn full_duplex_config_rejected() {
        let json = br#"{"rules_path":"/dev/null","body_policy":"full_duplex_hold"}"#;
        assert!(ModSecFilterConfig::from_bytes(json).is_none());
        assert!(BodyPolicy::parse("FULL_DUPLEX_STREAMED").is_err());
    }

    #[test]
    fn bad_json_rejected() {
        assert!(ModSecFilterConfig::from_bytes(b"not-json").is_none());
    }

    #[test]
    fn deny_on_admin_path_sends_403() {
        let tmp = tempfile::tempdir().unwrap();
        let rules = write_rules(
            tmp.path(),
            r#"
SecRule REQUEST_URI "@beginsWith /admin" \
  "id:1001,phase:1,deny,status:403,log,msg:'admin deny'"
"#,
        );
        let cfg = ModSecFilterConfig::from_bytes(
            format!(
                r#"{{"rules_path":"{}","body_policy":"headers_only"}}"#,
                rules.display()
            )
            .as_bytes(),
        )
        .expect("config");

        let mut envoy = MockEnvoyHttpFilter::new();
        envoy.expect_get_request_headers().returning(|| {
            vec![
                (
                    EnvoyBuffer::new(b":method"),
                    EnvoyBuffer::new(b"GET"),
                ),
                (
                    EnvoyBuffer::new(b":path"),
                    EnvoyBuffer::new(b"/admin"),
                ),
                (
                    EnvoyBuffer::new(b"host"),
                    EnvoyBuffer::new(b"example.test"),
                ),
            ]
        });
        envoy.expect_get_attribute_string().returning(|_| None);
        envoy.expect_get_attribute_int().returning(|_| None);
        envoy
            .expect_send_response()
            .withf(|status, _, _, details| {
                *status == 403 && details == &Some("modsec_dm_deny")
            })
            .returning(|_, _, _, _| {})
            .times(1);

        let mut filter = cfg.new_http_filter(&mut envoy);
        let st = filter.on_request_headers(&mut envoy, true);
        assert_eq!(
            st,
            abi::envoy_dynamic_module_type_on_http_filter_request_headers_status::StopIteration
        );
    }

    #[test]
    fn engine_error_sends_500_never_continue() {
        let tmp = tempfile::tempdir().unwrap();
        // Zero rules → Engine::load_files fails with ZeroRulesLoaded / NoRules.
        // Use a valid engine then inject fail on the transaction step.
        let rules = write_rules(
            tmp.path(),
            r#"
SecRule REQUEST_URI "@unconditionalMatch" \
  "id:1002,phase:1,pass,log,msg:'noop'"
"#,
        );
        let cfg = ModSecFilterConfig::from_bytes(
            format!(
                r#"{{"rules_path":"{}","body_policy":"headers_only"}}"#,
                rules.display()
            )
            .as_bytes(),
        )
        .expect("config");
        cfg.engine.inject_fail_next_transaction_step();

        let mut envoy = MockEnvoyHttpFilter::new();
        envoy.expect_get_request_headers().returning(|| {
            vec![
                (
                    EnvoyBuffer::new(b":method"),
                    EnvoyBuffer::new(b"GET"),
                ),
                (EnvoyBuffer::new(b":path"), EnvoyBuffer::new(b"/")),
                (
                    EnvoyBuffer::new(b"host"),
                    EnvoyBuffer::new(b"example.test"),
                ),
            ]
        });
        envoy.expect_get_attribute_string().returning(|_| None);
        envoy.expect_get_attribute_int().returning(|_| None);
        envoy
            .expect_send_response()
            .withf(|status, _, _, details| {
                *status == 500 && details == &Some("modsec_dm_engine_error")
            })
            .returning(|_, _, _, _| {})
            .times(1);

        let mut filter = cfg.new_http_filter(&mut envoy);
        let st = filter.on_request_headers(&mut envoy, true);
        assert_eq!(
            st,
            abi::envoy_dynamic_module_type_on_http_filter_request_headers_status::StopIteration
        );
    }

    #[test]
    fn buffered_body_sqli_denies_before_continue() {
        let tmp = tempfile::tempdir().unwrap();
        let rules = write_rules(
            tmp.path(),
            r#"
SecRule REQUEST_BODY "@contains UNION SELECT" \
  "id:1003,phase:2,deny,status:403,log,msg:'body sqli'"
"#,
        );
        let cfg = ModSecFilterConfig::from_bytes(
            format!(
                r#"{{"rules_path":"{}","body_policy":"buffer_until_eos"}}"#,
                rules.display()
            )
            .as_bytes(),
        )
        .expect("config");

        let mut envoy = MockEnvoyHttpFilter::new();
        envoy.expect_get_request_headers().returning(|| {
            vec![
                (
                    EnvoyBuffer::new(b":method"),
                    EnvoyBuffer::new(b"POST"),
                ),
                (
                    EnvoyBuffer::new(b":path"),
                    EnvoyBuffer::new(b"/login"),
                ),
                (
                    EnvoyBuffer::new(b"content-type"),
                    EnvoyBuffer::new(b"application/x-www-form-urlencoded"),
                ),
                (
                    EnvoyBuffer::new(b"host"),
                    EnvoyBuffer::new(b"example.test"),
                ),
            ]
        });
        envoy.expect_get_attribute_string().returning(|_| None);
        envoy.expect_get_attribute_int().returning(|_| None);

        let mut filter = cfg.new_http_filter(&mut envoy);
        let st = filter.on_request_headers(&mut envoy, false);
        assert_eq!(
            st,
            abi::envoy_dynamic_module_type_on_http_filter_request_headers_status::StopIteration
        );

        let st = filter.on_request_body(&mut envoy, false);
        assert_eq!(
            st,
            abi::envoy_dynamic_module_type_on_http_filter_request_body_status::StopIterationAndBuffer
        );

        envoy
            .expect_get_buffered_request_body()
            .returning(|| {
                static mut BODY: [u8; 28] = *b"q=1' UNION SELECT password--";
                // SAFETY: mock-only static buffer; single-threaded test.
                Some(vec![unsafe { EnvoyMutBuffer::new(&raw mut BODY) }])
            })
            .times(1);
        envoy
            .expect_send_response()
            .withf(|status, _, _, _| *status == 403)
            .returning(|_, _, _, _| {})
            .times(1);

        let st = filter.on_request_body(&mut envoy, true);
        assert_eq!(
            st,
            abi::envoy_dynamic_module_type_on_http_filter_request_body_status::StopIterationNoBuffer
        );
    }
}
