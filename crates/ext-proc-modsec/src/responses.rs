//! `ProcessingResponse` builders for the ext_proc wire protocol.
//!
//! Envoy v1.39 turns an `ImmediateResponse` with a missing or invalid status
//! (including 0) into HTTP **200**, so every status sent here is validated
//! first: block statuses must be 4xx/5xx and redirect statuses 3xx.

use crate::pb::envoy::config::core::v3::header_value_option::HeaderAppendAction;
use crate::pb::envoy::config::core::v3::{HeaderValue, HeaderValueOption};
use crate::pb::envoy::r#type::v3::{HttpStatus, StatusCode};
use crate::pb::envoy::service::ext_proc::v3::processing_response::Response as ProcResponse;
use crate::pb::envoy::service::ext_proc::v3::{
    BodyResponse, HeaderMutation, HeadersResponse, ImmediateResponse, ProcessingResponse,
    TrailersResponse,
};

/// `ImmediateResponse.details` for fail-closed replies (visible in Envoy
/// access logs as `%RESPONSE_CODE_DETAILS%`).
pub const DETAILS_FAIL_CLOSED: &str = "modsec_fail_closed";

/// Which side of the exchange a Continue answers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    Request,
    Response,
}

pub fn headers_continue(dir: Direction) -> ProcessingResponse {
    let h = HeadersResponse { response: None };
    wrap(match dir {
        Direction::Request => ProcResponse::RequestHeaders(h),
        Direction::Response => ProcResponse::ResponseHeaders(h),
    })
}

pub fn body_continue(dir: Direction) -> ProcessingResponse {
    let b = BodyResponse { response: None };
    wrap(match dir {
        Direction::Request => ProcResponse::RequestBody(b),
        Direction::Response => ProcResponse::ResponseBody(b),
    })
}

pub fn trailers_continue(dir: Direction) -> ProcessingResponse {
    let t = TrailersResponse {
        header_mutation: None,
    };
    wrap(match dir {
        Direction::Request => ProcResponse::RequestTrailers(t),
        Direction::Response => ProcResponse::ResponseTrailers(t),
    })
}

/// Fail-closed local reply: HTTP 500, never Continue.
pub fn fail_closed() -> ProcessingResponse {
    immediate(
        StatusCode::InternalServerError,
        b"modsecurity evaluation error\n",
        DETAILS_FAIL_CLOSED,
        None,
    )
}

/// Policy deny with the rule's status (4xx/5xx), else 403.
pub fn block(status: i32, body: &[u8], details: &str) -> ProcessingResponse {
    immediate(deny_status(status), body, details, None)
}

/// Redirect with `Location`; status must be 3xx, else 302.
pub fn redirect(status: i32, location: &str, body: &[u8]) -> ProcessingResponse {
    let code = checked_status(status, 300..=399).unwrap_or(StatusCode::Found);
    let location = HeaderValueOption {
        header: Some(HeaderValue {
            key: "location".into(),
            raw_value: location.as_bytes().to_vec(),
            ..Default::default()
        }),
        append_action: HeaderAppendAction::OverwriteIfExistsOrAdd as i32,
        ..Default::default()
    };
    immediate(
        code,
        body,
        "modsecurity_redirect",
        Some(HeaderMutation {
            set_headers: vec![location],
            ..Default::default()
        }),
    )
}

fn deny_status(status: i32) -> StatusCode {
    checked_status(status, 400..=599).unwrap_or(StatusCode::Forbidden)
}

fn checked_status(status: i32, range: std::ops::RangeInclusive<i32>) -> Option<StatusCode> {
    if !range.contains(&status) {
        return None;
    }
    StatusCode::try_from(status).ok()
}

fn immediate(
    code: StatusCode,
    body: &[u8],
    details: &str,
    headers: Option<HeaderMutation>,
) -> ProcessingResponse {
    wrap(ProcResponse::ImmediateResponse(ImmediateResponse {
        status: Some(HttpStatus { code: code as i32 }),
        headers,
        body: body.to_vec(),
        details: details.into(),
        ..Default::default()
    }))
}

fn wrap(response: ProcResponse) -> ProcessingResponse {
    ProcessingResponse {
        response: Some(response),
        ..Default::default()
    }
}

/// Status code of an `ImmediateResponse`, if `resp` is one.
pub fn immediate_status(resp: &ProcessingResponse) -> Option<i32> {
    match resp.response.as_ref()? {
        ProcResponse::ImmediateResponse(ir) => ir.status.as_ref().map(|s| s.code),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn block_status_is_validated() {
        assert_eq!(immediate_status(&block(403, b"", "x")), Some(403));
        assert_eq!(immediate_status(&block(406, b"", "x")), Some(406));
        assert_eq!(immediate_status(&block(503, b"", "x")), Some(503));
        // Would become HTTP 200 in Envoy if passed through.
        assert_eq!(immediate_status(&block(0, b"", "x")), Some(403));
        assert_eq!(immediate_status(&block(200, b"", "x")), Some(403));
        assert_eq!(immediate_status(&block(302, b"", "x")), Some(403));
        assert_eq!(immediate_status(&block(999, b"", "x")), Some(403));
    }

    #[test]
    fn redirect_status_is_validated_and_sets_location() {
        let r = redirect(301, "https://example.test/", b"");
        assert_eq!(immediate_status(&r), Some(301));
        assert_eq!(immediate_status(&redirect(403, "/x", b"")), Some(302));
        let Some(ProcResponse::ImmediateResponse(ir)) = r.response else {
            panic!("not immediate")
        };
        let h = &ir.headers.expect("headers").set_headers[0];
        let hv = h.header.as_ref().expect("header");
        assert_eq!(hv.key, "location");
        assert_eq!(hv.raw_value, b"https://example.test/");
    }

    #[test]
    fn fail_closed_is_500() {
        let r = fail_closed();
        assert_eq!(immediate_status(&r), Some(500));
        let Some(ProcResponse::ImmediateResponse(ir)) = r.response else {
            panic!("not immediate")
        };
        assert_eq!(ir.details, DETAILS_FAIL_CLOSED);
    }

    #[test]
    fn continues_carry_direction() {
        assert!(matches!(
            headers_continue(Direction::Request).response,
            Some(ProcResponse::RequestHeaders(_))
        ));
        assert!(matches!(
            body_continue(Direction::Response).response,
            Some(ProcResponse::ResponseBody(_))
        ));
        assert!(matches!(
            trailers_continue(Direction::Request).response,
            Some(ProcResponse::RequestTrailers(_))
        ));
    }
}
