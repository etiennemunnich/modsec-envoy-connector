# CRS and custom rules behind Envoy

What **cannot** be fully used with this connector, compared with a typical **nginx + ModSecurity** setup. Operators and early testers should not assume every SecRule or CRS test behaves the same way.

**Pins:** Envoy `v1.39.4`, libmodsecurity `v3.0.17`, CRS `v4.30.0` — see [`versions.lock.md`](../versions.lock.md). No Envoy tip flags are claimed here.

Fail-closed is unchanged: connector down, hang/timeout, bad rules, or ModSec/FFI `Err` → traffic must **not** reach origin as OK. Details: [fail-closed.md](./fail-closed.md).

Read each limit in one of three buckets:

| Bucket | Meaning |
|--------|---------|
| **Security weaker than nginx** | An attack string nginx+CRS would score never reaches ModSecurity; the client can get **200** |
| **Envoy rejects first (still safe)** | Envoy’s codec or connection manager refuses the request before ModSec; the origin is untouched |
| **Harness / FTW quirk** | go-ftw status remaps or cloud mode; not proof that CRS saw (or missed) a signal |

---

## Security weaker than nginx

### Non-URI `Referer`

Envoy sanitizes `Referer` **before** any HTTP filter (including `ext_proc`). Values that are not a valid absolute URL or relative-ref are **removed**. Filter order cannot restore them; there is no `HttpConnectionManager` knob on Envoy `v1.39.4` to disable this.

| Example `Referer` | This product | Typical nginx + ModSec |
|-------------------|--------------|-------------------------|
| `cat /etc/passwd` | Header absent → often **200** | ModSec sees it → often **403** |
| `<script>…</script>` or `javascript:…` | Absent → **200** | Sees it → **403** |
| `https://evil.example/?x=<script>…` | Kept → CRS XSS can still **403** | Also **403** |

CRS rules that read `REQUEST_HEADERS:Referer` (for example **932161**, **932237**, **932239**, **941101**, **941110**) cannot score bare shell or script strings in Referer. Absolute-URI Referers with payloads still can.

With the demo up:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -H 'Referer: cat /etc/passwd' http://127.0.0.1:18080/get
# expect 200; ModSecurity audit log has no Referer
```

### Duplicate `Connection` (CRS **920210**)

On non-upgrade requests, Envoy strips the hop-by-hop `Connection` header before filters. Rules that need duplicate or conflicting `Connection` values never see them (soft **200** here vs **403** on nginx+ModSec for the same probe).

### Bodies and trailers (mode and surface limits)

| Limit | Effect |
|-------|--------|
| Body mode **NONE** | Bodies are never sent; body attacks can reach origin if headers are clean |
| **BUFFERED_PARTIAL** | Only the prefix up to Envoy’s buffer; the rest is not inspected |
| **STREAMED** | Early request chunks may reach origin before a late deny |
| Trailer **values** | Never passed to ModSecurity; trailers only end a STREAMED / FULL_DUPLEX body phase |
| HTTP/3, WebSocket **frames**, gRPC **protobuf bodies** | Not inspected (handshake / headers / metadata may be) |

Default product path is **BUFFERED**. Lab modes: [body-modes.md](./body-modes.md). Surfaces table: [how-it-works.md — What is not inspected](./how-it-works.md#what-is-not-inspected).

### Misconfiguration (BYO Envoy)

- Missing `request_attributes` → client IP/protocol often fall back (e.g. `127.0.0.1`); GEO / IP rules miss.
- `observability_mode` or DetectionOnly / `--allow-detection-only` → no real enforcement.
- Trailer mode `SKIP` with a body mode other than NONE → body phase may never finish; request can reach origin.

---

## Envoy rejects first (still safe)

ModSecurity never runs, but this is **not** a soft allow to origin. nginx often answers **400** / **505** for the same shapes; Envoy may close with an empty reply or transport error ([envoy#29440](https://github.com/envoyproxy/envoy/issues/29440)). CRS go-ftw uses [`demo/ftw/envoy-overrides.yaml`](../demo/ftw/envoy-overrides.yaml) (`expect_error` / status remaps) so the suite matches Envoy, not Apache.

Examples: invalid request-line, HTTP/0.9 or bad version, malformed `Content-Length`, `Transfer-Encoding` + `Content-Length` together, some codec-hostile payloads.

**CONNECT:** recommended config answers **403** with ext_proc disabled (BUFFERED cannot complete CONNECT cleanly). nginx often **405**. Both deny.

**Custom methods:** demo configs set `http_protocol_options.allow_custom_methods: true` so CRS **911100** can judge non-standard methods instead of the codec rejecting them first.

---

## Harness / FTW quirk

| Quirk | Read it as |
|-------|------------|
| go-ftw **cloud** mode | HTTP **status** only — does not prove rule ids in logs |
| Envoy overrides file | Expected status / error remapped for Envoy codec behavior |
| Host / On-mode status deltas | Headers often **reach** ModSec; **403** vs Apache **400** or expect-**200** is harness |
| PL4 `:path` false positives | Envoy populates `:path`; some PL4 charset rules FP — demo default is PL1 |
| Green cloud run on Referer/Connection-style ids | Not proof CRS saw those headers (cloud ignores `expect_ids`; PL1 may not block PL2 Referer rules anyway) |

go-ftw proves **HTTP/1.x** CRS fidelity only — not HTTP/2 WAF coverage. See [testing.md](./testing.md).

---

## What still works

- URI, query, body (per [body-modes.md](./body-modes.md)), and headers Envoy still forwards after sanitization  
- Absolute-URI `Referer` attacks  
- Rule deny → **403** with origin untouched under BUFFERED / FULL_DUPLEX_STREAMED  
- Fail-closed paths in [fail-closed.md](./fail-closed.md)

### Custom SecRules — write for Envoy

1. Do not rely on non-URI `Referer` or hop-by-hop `Connection` as the only signal.  
2. Prefer URI, query, body, Cookie, User-Agent, and ordinary request headers.  
3. Match body mode to the rule (body rules need a mode that sends bodies).  
4. Do not put the only match in HTTP trailers.  
5. Set Envoy `request_attributes`; keep `SecRuleEngine On` and `failure_mode_allow: false`.
