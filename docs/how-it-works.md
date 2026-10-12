# How it works

Where the connector sits, how one HTTP exchange moves through it, and what the client sees. Failure handling: [fail-closed.md](./fail-closed.md). Body modes: [body-modes.md](./body-modes.md). Running it: [getting-started.md](./getting-started.md), [deploy.md](./deploy.md).

## What this is

Envoy cannot run ModSecurity itself. `ext-proc-modsec` is a small Rust gRPC server that Envoy's External Processing (`ext_proc`) filter calls for every HTTP exchange. It loads libmodsecurity in-process, feeds the request headers, request body, response headers and response body into **one ModSecurity transaction**, and answers each step with:

- **Continue**: Envoy may go on, and only then contacts the origin on the request path;
- a rule-driven **local reply**, typically **403**, or a redirect;
- a fail-closed **500** when the engine cannot produce a trustworthy decision.

The connector never connects to your origin. Only Envoy does, and only after Continue.

## Where it sits

| Hop | From → to | Protocol | Reaches the origin? |
|-----|-----------|----------|---------------------|
| 1 | client → Envoy | HTTP/1.1, HTTP/2 | no |
| 2 | Envoy ↔ connector | gRPC, `envoy.service.ext_proc.v3.ExternalProcessor/Process` | no (side call) |
| – | connector → libmodsecurity | in-process C API (`msc_*`) | no |
| 3 | Envoy → origin | HTTP | **yes, Envoy only**, after Continue |

```mermaid
flowchart LR
  C[Client] -->|HTTP| E[Envoy ext_proc filter]
  E <-->|gRPC Process| R[ext-proc-modsec]
  R -->|in-process C API| M[libmodsecurity and CRS]
  E -->|only after Continue| U[Origin]
```

Settings that must not be relaxed on a protecting filter:

- `failure_mode_allow: false`: connector down or stream error → Envoy local **500**;
- `message_timeout` (demo: 2 s): connector hung → Envoy local **504**. Envoy does not apply it under FULL_DUPLEX_STREAMED;
- never `observability_mode`: Envoy does not wait for the answers.

## Request path

One gRPC `Process` stream is one HTTP request and response, and one ModSecurity transaction. The diagram shows BUFFERED, the default; [body-modes.md](./body-modes.md) shows what changes in the other modes.

```mermaid
sequenceDiagram
  participant C as Client
  participant E as Envoy
  participant R as Connector
  participant M as libmodsecurity
  participant U as Origin

  C->>E: HTTP request
  E->>R: request_headers
  R->>M: connection, URI, request headers
  alt phase-1 deny or redirect
    R-->>E: ImmediateResponse 403
    E-->>C: local reply, origin not contacted
  else allow
    R-->>E: Continue
  end
  E->>R: request_body
  R->>M: append body, then process_request_body
  alt phase-2 deny or engine error
    R-->>E: ImmediateResponse 403 or 500
    E-->>C: local reply, origin not contacted
  else allow
    R-->>E: Continue
    E->>U: forward request
    U-->>E: response
  end
  E->>R: response_headers, response_body
  R->>M: response headers, body
  alt phase-3 or phase-4 deny
    R-->>E: ImmediateResponse 403
    E-->>C: local 403
  else allow
    R-->>E: Continue
    E-->>C: origin response
  end
```

HTTP/1.1 and HTTP/2 take the same path. Envoy joins split HTTP/2 `Cookie` headers before the connector sees them. `allow_custom_methods` in the Envoy config lets CRS rule 911100 judge non-standard methods instead of Envoy's codec dropping them. `demo/scripts/hop-trace.sh` follows one request across Envoy, the connector and the origin by `x-request-id`.

## One exchange, step by step

| Envoy sends | Connector does | Answers |
|-------------|----------------|---------|
| `request_headers` | opens the transaction (id = `x-request-id`); `process_connection` with the client and server address from Envoy's `request_attributes`, `process_uri`, the headers (`host` from `:authority` if missing), `process_request_headers`. If the request has no body, also the request-body phase | Continue, or a terminal reply |
| `request_body` | `append_request_body`, checking for an intervention on every append; when the body ends, `process_request_body` | Continue, or a terminal reply |
| `response_headers` | finishes an unfinished request body first; response headers; `process_response_headers`. If the response has no body, also the response-body phase | Continue, or a terminal reply |
| `response_body` | `append_response_body`; when the body ends, `process_response_body` | Continue, or a terminal reply |
| trailers (trailer mode `SEND`) | trailer values are not inspected (SecLang has no trailer phase); an unfinished body is finished here. Trailers on a stream with no transaction → fail closed | Continue, body deny **403**, or **500** |
| `response_headers` with no `request_headers` before them | Envoy rejected the request itself (for example a `#fragment` → 400); the origin was never contacted. 4xx and 5xx pass through; anything else fails closed | Continue, or **500** |

When the stream ends, the connector drops the transaction, which runs ModSecurity's logging phase (the audit log). Messages out of order or malformed fail closed with **500**.

## What the client sees

| Result | Connector answer | Client sees | Where to look |
|--------|------------------|-------------|---------------|
| no disruptive intervention | Continue | the origin's response | phase log `action=allow` |
| deny with a 4xx or 5xx status | `ImmediateResponse` with that status and a generic body | e.g. **403** `Forbidden` | Envoy `%RESPONSE_CODE_DETAILS%` = `modsecurity_intervention`; rule detail in the connector log and the ModSecurity audit log |
| deny with any other status | `ImmediateResponse` **403** (Envoy v1.39 would otherwise send an invalid status as **200**) | **403** | as above |
| redirect | `ImmediateResponse` 3xx with `Location` (302 if the rule's status is not 3xx) | **302** | `action=redirect` |
| drop (intervention status 0) | gRPC stream aborted | Envoy local **500** | deny metric |
| engine or protocol failure | `ImmediateResponse` **500**, details `modsec_fail_closed` | **500** | `action=fail_closed` |
| `CONNECT` | the recommended Envoy config answers it with a direct **403** and ext_proc disabled; if one reaches the connector anyway, `ImmediateResponse` **403**, details `connect_rejected` | **403** | Envoy access log |
| connector down | no answer | Envoy **500** | `ext_proc_error_*`; `failure_mode_allowed` must stay 0 |
| connector hung | no answer in time | Envoy **504** | `message_timeouts` |

The deny body is always generic. Rule ids and matched data go only to the connector log and the audit log, never to the client. After any terminal answer the connector closes the stream.

## What is not inspected

| Surface | What happens |
|---------|--------------|
| gRPC message bodies | headers, path and metadata are inspected (`hop-trace-grpc.sh`); protobuf bodies are not. Fail-closed still holds |
| WebSocket frames | the upgrade handshake can be inspected with a headers-only route; frames after the upgrade are not. BUFFERED on an upgrade route hangs |
| HTTP/3 | no QUIC listener is configured or tested |
| trailer values | never inspected. With trailer mode `SKIP`, a body followed by trailers is not inspected either ([deploy.md](./deploy.md#known-issues)) |
| bodies under NONE, and past the limit under BUFFERED_PARTIAL | [body-modes.md](./body-modes.md) |
| Envoy's own local replies before the request phase | passed through, not inspected; the origin was never contacted |
| pause interventions | logged and ignored: ext_proc has no delay primitive |

Configuration, health checks and metrics: [deploy.md](./deploy.md).
