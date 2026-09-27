//! Raw libmodsecurity v3 C API: only the `msc_*` functions this crate calls.
//!
//! Declarations follow `modsecurity/{modsecurity,rules_set,transaction,
//! intervention}.h` of v3.0.x. Pointer-width and `char` types use
//! `std::os::raw`, so they are correct on both x86_64 and aarch64.

use std::os::raw::{c_char, c_int, c_uchar, c_void};

#[repr(C)]
pub struct ModSecurity {
    _private: [u8; 0],
}

#[repr(C)]
pub struct RulesSet {
    _private: [u8; 0],
}

#[repr(C)]
pub struct Transaction {
    _private: [u8; 0],
}

/// `ModSecurityIntervention` (intervention.h). `url` and `log` are
/// malloc'd by libmodsecurity and freed by `msc_intervention_cleanup`.
#[repr(C)]
pub struct ModSecurityIntervention {
    pub status: c_int,
    pub pause: c_int,
    pub url: *mut c_char,
    pub log: *mut c_char,
    pub disruptive: c_int,
}

/// `ModSecLogCb`: `(transaction log-callback data, message)`. With the
/// default text log property the message is a NUL-terminated `char *`.
pub type ModSecLogCb = Option<unsafe extern "C" fn(data: *mut c_void, msg: *const c_void)>;

extern "C" {
    pub fn msc_init() -> *mut ModSecurity;
    pub fn msc_set_connector_info(msc: *mut ModSecurity, connector: *const c_char);
    pub fn msc_set_log_cb(msc: *mut ModSecurity, cb: ModSecLogCb);
    pub fn msc_cleanup(msc: *mut ModSecurity);

    pub fn msc_create_rules_set() -> *mut RulesSet;
    pub fn msc_rules_add_file(
        rules: *mut RulesSet,
        file: *const c_char,
        error: *mut *const c_char,
    ) -> c_int;
    pub fn msc_rules_error_cleanup(error: *const c_char);
    pub fn msc_rules_cleanup(rules: *mut RulesSet) -> c_int;

    pub fn msc_new_transaction(
        msc: *mut ModSecurity,
        rules: *mut RulesSet,
        log_cb_data: *mut c_void,
    ) -> *mut Transaction;
    pub fn msc_new_transaction_with_id(
        msc: *mut ModSecurity,
        rules: *mut RulesSet,
        id: *mut c_char,
        log_cb_data: *mut c_void,
    ) -> *mut Transaction;
    pub fn msc_transaction_cleanup(tx: *mut Transaction);

    pub fn msc_process_connection(
        tx: *mut Transaction,
        client: *const c_char,
        client_port: c_int,
        server: *const c_char,
        server_port: c_int,
    ) -> c_int;
    /// `protocol` is the HTTP method.
    pub fn msc_process_uri(
        tx: *mut Transaction,
        uri: *const c_char,
        protocol: *const c_char,
        http_version: *const c_char,
    ) -> c_int;
    pub fn msc_add_request_header(
        tx: *mut Transaction,
        key: *const c_uchar,
        value: *const c_uchar,
    ) -> c_int;
    pub fn msc_process_request_headers(tx: *mut Transaction) -> c_int;
    pub fn msc_append_request_body(
        tx: *mut Transaction,
        body: *const c_uchar,
        size: usize,
    ) -> c_int;
    pub fn msc_process_request_body(tx: *mut Transaction) -> c_int;
    pub fn msc_add_response_header(
        tx: *mut Transaction,
        key: *const c_uchar,
        value: *const c_uchar,
    ) -> c_int;
    pub fn msc_process_response_headers(
        tx: *mut Transaction,
        code: c_int,
        protocol: *const c_char,
    ) -> c_int;
    pub fn msc_append_response_body(
        tx: *mut Transaction,
        body: *const c_uchar,
        size: usize,
    ) -> c_int;
    pub fn msc_process_response_body(tx: *mut Transaction) -> c_int;
    pub fn msc_process_logging(tx: *mut Transaction) -> c_int;

    pub fn msc_intervention(tx: *mut Transaction, it: *mut ModSecurityIntervention) -> c_int;
    pub fn msc_intervention_cleanup(it: *mut ModSecurityIntervention);
}
