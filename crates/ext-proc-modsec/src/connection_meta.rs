//! Connection metadata for ModSecurity `process_connection` / `process_uri`.
//!
//! libmodsecurity's `REMOTE_ADDR` / `SERVER_ADDR` (and GEO / IP rules) come
//! from `msc_process_connection`. Envoy supplies the real values when the
//! `ext_proc` filter lists them in `request_attributes`:
//! `source.address`, `source.port`, `destination.address`,
//! `destination.port`, `request.protocol`. The filter packs them under the
//! Struct key `envoy.filters.http.ext_proc`.
//!
//! Missing attributes fall back to loopback placeholders (logged as
//! `conn_source=fallback`). That only degrades IP-based rules; it never
//! affects the allow/deny path for evaluation errors.

use std::collections::HashMap;

use envoy_types::pb::google::protobuf::{value::Kind, Struct};

/// Namespace key Envoy's ext_proc filter uses when packing attributes.
pub const EXT_PROC_ATTR_NAMESPACE: &str = "envoy.filters.http.ext_proc";

/// Client/server endpoints + HTTP version for one transaction.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConnectionEndpoints {
    pub client_ip: String,
    pub client_port: i32,
    pub server_ip: String,
    pub server_port: i32,
    /// ModSecurity-style HTTP version (`1.0`, `1.1`, `2.0`, `3.0`).
    pub http_version: &'static str,
    /// `"attrs"` when any field came from Envoy; `"fallback"` otherwise.
    pub source: &'static str,
}

impl ConnectionEndpoints {
    /// Placeholders used when Envoy sends no attributes.
    pub fn fallback() -> Self {
        Self {
            client_ip: "127.0.0.1".into(),
            client_port: 0,
            server_ip: "127.0.0.1".into(),
            server_port: 0,
            http_version: "1.1",
            source: "fallback",
        }
    }

    /// Parse endpoints from `ProcessingRequest.attributes`. Each missing field
    /// keeps its fallback so partial configuration still helps.
    pub fn from_ext_proc_attributes(attributes: &HashMap<String, Struct>) -> Self {
        let mut out = Self::fallback();
        let Some(ns) = attributes.get(EXT_PROC_ATTR_NAMESPACE) else {
            return out;
        };
        let mut from_attrs = false;

        if let Some(addr) = struct_string(ns, "source.address") {
            let (host, port) = split_host_port(&addr);
            out.client_ip = host;
            if let Some(p) = port {
                out.client_port = p;
            }
            from_attrs = true;
        }
        if let Some(p) = struct_port(ns, "source.port") {
            out.client_port = p;
            from_attrs = true;
        }
        if let Some(addr) = struct_string(ns, "destination.address") {
            let (host, port) = split_host_port(&addr);
            out.server_ip = host;
            if let Some(p) = port {
                out.server_port = p;
            }
            from_attrs = true;
        }
        if let Some(p) = struct_port(ns, "destination.port") {
            out.server_port = p;
            from_attrs = true;
        }
        if let Some(proto) = struct_string(ns, "request.protocol") {
            out.http_version = http_version_from_protocol(&proto);
            from_attrs = true;
        }

        if from_attrs {
            out.source = "attrs";
        }
        out
    }

    /// Protocol string for `process_response_headers` (e.g. `HTTP/1.1`).
    pub fn response_protocol(&self) -> String {
        format!("HTTP/{}", self.http_version)
    }
}

/// Map Envoy's `request.protocol` (`HTTP/1.0`, `HTTP/1.1`, `HTTP/2`,
/// `HTTP/3`) to the version string ModSecurity expects in `process_uri`.
fn http_version_from_protocol(proto: &str) -> &'static str {
    match proto.trim().to_ascii_uppercase().as_str() {
        "HTTP/1.0" => "1.0",
        "HTTP/2" | "HTTP/2.0" => "2.0",
        "HTTP/3" | "HTTP/3.0" => "3.0",
        _ => "1.1",
    }
}

fn struct_string(s: &Struct, key: &str) -> Option<String> {
    match s.fields.get(key)?.kind.as_ref()? {
        Kind::StringValue(v) if !v.is_empty() => Some(v.clone()),
        _ => None,
    }
}

fn struct_port(s: &Struct, key: &str) -> Option<i32> {
    let port = match s.fields.get(key)?.kind.as_ref()? {
        Kind::NumberValue(n) if n.fract() == 0.0 => *n as i64,
        Kind::StringValue(v) => v.parse().ok()?,
        _ => return None,
    };
    (0..=65_535).contains(&port).then_some(port as i32)
}

/// Split `host:port` / `[ipv6]:port`; bare IPv6 is returned unchanged.
fn split_host_port(addr: &str) -> (String, Option<i32>) {
    if let Some(rest) = addr.strip_prefix('[') {
        if let Some((host, port)) = rest.split_once("]:") {
            if let Ok(p) = port.parse::<u16>() {
                return (host.to_owned(), Some(i32::from(p)));
            }
        }
        return (addr.trim_matches(['[', ']']).to_owned(), None);
    }
    if addr.matches(':').count() == 1 {
        if let Some((host, port)) = addr.rsplit_once(':') {
            if let Ok(p) = port.parse::<u16>() {
                return (host.to_owned(), Some(i32::from(p)));
            }
        }
    }
    (addr.to_owned(), None)
}

#[cfg(test)]
mod tests {
    use super::*;
    use envoy_types::pb::google::protobuf::Value;

    fn s(v: &str) -> Value {
        Value {
            kind: Some(Kind::StringValue(v.into())),
        }
    }

    fn n(v: f64) -> Value {
        Value {
            kind: Some(Kind::NumberValue(v)),
        }
    }

    fn attrs(fields: Vec<(&str, Value)>) -> HashMap<String, Struct> {
        let fields = fields.into_iter().map(|(k, v)| (k.to_owned(), v)).collect();
        HashMap::from([(EXT_PROC_ATTR_NAMESPACE.to_owned(), Struct { fields })])
    }

    #[test]
    fn parses_namespace_fields() {
        let ep = ConnectionEndpoints::from_ext_proc_attributes(&attrs(vec![
            ("source.address", s("203.0.113.10")),
            ("source.port", n(55_432.0)),
            ("destination.address", s("198.51.100.1")),
            ("destination.port", n(443.0)),
            ("request.protocol", s("HTTP/2")),
        ]));
        assert_eq!(ep.source, "attrs");
        assert_eq!(ep.client_ip, "203.0.113.10");
        assert_eq!(ep.client_port, 55_432);
        assert_eq!(ep.server_ip, "198.51.100.1");
        assert_eq!(ep.server_port, 443);
        assert_eq!(ep.http_version, "2.0");
        assert_eq!(ep.response_protocol(), "HTTP/2.0");
    }

    #[test]
    fn fallback_when_namespace_missing() {
        let ep = ConnectionEndpoints::from_ext_proc_attributes(&HashMap::new());
        assert_eq!(ep, ConnectionEndpoints::fallback());
    }

    #[test]
    fn rejects_out_of_range_ports() {
        let ep = ConnectionEndpoints::from_ext_proc_attributes(&attrs(vec![
            ("source.port", n(70_000.0)),
            ("destination.port", n(-1.0)),
        ]));
        assert_eq!(ep.client_port, 0);
        assert_eq!(ep.server_port, 0);
        assert_eq!(ep.source, "fallback");
    }

    #[test]
    fn splits_embedded_port_in_address() {
        assert_eq!(
            split_host_port("192.0.2.1:9000"),
            ("192.0.2.1".into(), Some(9000))
        );
        assert_eq!(
            split_host_port("[2001:db8::1]:8443"),
            ("2001:db8::1".into(), Some(8443))
        );
        assert_eq!(split_host_port("2001:db8::1"), ("2001:db8::1".into(), None));
    }

    #[test]
    fn maps_protocol_strings() {
        assert_eq!(http_version_from_protocol("HTTP/1.0"), "1.0");
        assert_eq!(http_version_from_protocol("HTTP/1.1"), "1.1");
        assert_eq!(http_version_from_protocol("HTTP/3"), "3.0");
        assert_eq!(http_version_from_protocol("weird"), "1.1");
    }
}
