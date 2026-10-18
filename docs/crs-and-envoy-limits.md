# CRS and custom rules behind Envoy

Envoy normalizes some headers before `ext_proc` sees them. Rules that only look at those signals may not fire the way they would under a typical nginx + ModSecurity setup. This page is for early testers writing or reviewing SecRules: what ModSecurity usually sees on this path, what Envoy handles first, and how to aim custom rules.

**Pins:** Envoy `v1.39.4`, libmodsecurity `v3.0.17`, CRS `v4.30.0` (see [`versions.lock.md`](../versions.lock.md)). No Envoy tip flags are claimed here.

Fail-closed is unchanged: connector down, hang/timeout, bad rules, or ModSec/FFI `Err` → traffic must not reach origin as OK. Details: [fail-closed.md](./fail-closed.md).

Three useful lenses (not a scorecard against nginx):

| Lens | Meaning |
|------|---------|
| Signal Envoy does not forward | The value never reaches ModSecurity; write rules against other surfaces |
| Envoy answers or closes first | Codec / connection manager stops the request before ModSec; origin is untouched |
| Harness / go-ftw quirk | Suite remaps or cloud status checks; not proof that CRS saw (or missed) a signal |

---

## What Envoy forwards to ModSecurity

URI, query, Cookie, User-Agent, and ordinary request headers that survive Envoy’s connection-manager sanitization still reach the connector. Absolute-URI `Referer` values are kept. Bodies and trailers depend on the configured body mode (see below).

Rule deny under BUFFERED or FULL_DUPLEX_STREAMED still answers **403** with the origin untouched. Fail-closed paths in [fail-closed.md](./fail-closed.md) still apply.

### Headers Envoy may remove first

Envoy sanitizes `Referer` before any HTTP filter (including `ext_proc`). Values that are not a valid absolute URL or relative-ref are removed. Filter order cannot restore them; there is no `HttpConnectionManager` knob on Envoy `v1.39.4` to disable this.

CRS rules that read `REQUEST_HEADERS:Referer` (for example **932161**, **932237**, **932239**, **941101**, **941110**) therefore cannot score bare shell or script strings in Referer. Absolute-URI Referers that carry a payload in the URL can still be scored.

On non-upgrade requests, Envoy also strips the hop-by-hop `Connection` header before filters. Rules that need duplicate or conflicting `Connection` values (CRS **920210**) never see those values here.

Illustrative probe (demo stack, early testing; not a product guarantee of status codes):

```bash
curl -s -o /dev/null -w '%{http_code}\n' -H 'Referer: cat /etc/passwd' http://127.0.0.1:18080/get
# often 200 with this pin; ModSecurity audit log has no Referer
```

The same bare Referer string may score under nginx + ModSec in a lab. Prefer writing rules against URI, query, body, Cookie, User-Agent, and other headers Envoy still forwards. See [Notes from probes](#notes-from-probes) for context.

### Bodies and trailers

| Limit | Effect |
|-------|--------|
| Body mode **NONE** | Bodies are never sent; body attacks can reach origin if headers are clean |
| **BUFFERED_PARTIAL** | Only the prefix up to Envoy’s buffer; the rest is not inspected |
| **STREAMED** | Early request chunks may reach origin before a late deny |
| Trailer **values** | Never passed to ModSecurity; trailers only end a STREAMED / FULL_DUPLEX body phase |
| HTTP/3, WebSocket **frames**, gRPC **protobuf bodies** | Not inspected (handshake / headers / metadata may be) |

Default product path is **BUFFERED**. Lab modes: [body-modes.md](./body-modes.md). Surfaces table: [how-it-works.md (What is not inspected)](./how-it-works.md#what-is-not-inspected).

### Misconfiguration (BYO Envoy)

- Missing `request_attributes` → client IP/protocol often fall back (e.g. `127.0.0.1`); GEO / IP rules miss.
- `observability_mode` or DetectionOnly / `--allow-detection-only` → no real enforcement.
- Trailer mode `SKIP` with a body mode other than NONE → body phase may never finish; request can reach origin.

---

## When Envoy answers first

ModSecurity never runs, but this is not a soft allow to origin. Envoy’s codec or connection manager refuses the request; the origin stays untouched. For some malformed shapes Envoy may close with an empty reply or transport error ([envoy#29440](https://github.com/envoyproxy/envoy/issues/29440)). CRS go-ftw uses [`demo/ftw/envoy-overrides.yaml`](../demo/ftw/envoy-overrides.yaml) (`expect_error` / status remaps) so the suite matches Envoy.

Examples: invalid request-line, HTTP/0.9 or bad version, malformed `Content-Length`, `Transfer-Encoding` + `Content-Length` together, some codec-hostile payloads.

**CONNECT:** recommended config answers **403** with ext_proc disabled (BUFFERED cannot complete CONNECT cleanly).

**Custom methods:** demo configs set `http_protocol_options.allow_custom_methods: true` so CRS **911100** can judge non-standard methods instead of the codec rejecting them first.

---

## Harness / go-ftw quirks

| Quirk | Read it as |
|-------|------------|
| go-ftw **cloud** mode | HTTP status only; does not prove rule ids in logs |
| Envoy overrides file | Expected status / error remapped for Envoy codec behavior |
| Host / On-mode status deltas | Headers often reach ModSec; status differences vs Apache expectations are harness |
| PL4 `:path` false positives | Envoy populates `:path`; some PL4 charset rules FP (demo default is PL1) |
| Green cloud run on Referer/Connection-style ids | Not proof CRS saw those headers (cloud ignores `expect_ids`; PL1 may not block PL2 Referer rules anyway) |

go-ftw proves **HTTP/1.x** CRS fidelity only, not HTTP/2 WAF coverage. See [testing.md](./testing.md).

---

## Custom SecRules: write for Envoy

1. Do not rely on non-URI `Referer` or hop-by-hop `Connection` as the only signal.
2. Prefer URI, query, body, Cookie, User-Agent, and ordinary request headers.
3. Match body mode to the rule (body rules need a mode that sends bodies).
4. Do not put the only match in HTTP trailers.
5. Set Envoy `request_attributes`; keep `SecRuleEngine On` and `failure_mode_allow: false`.

---

## Notes from probes

Lab comparisons with nginx + ModSecurity (same CRS pin, early testing around 2026-10) are useful for understanding signal loss, not for ranking products. Illustrative outcomes under this connector’s pins:

| Probe shape | What ModSec saw here | Typical nginx + ModSec lab note |
|-------------|----------------------|----------------------------------|
| `Referer: cat /etc/passwd` | Header absent | Often scored → deny |
| `Referer: <script>…` / `javascript:…` | Header absent | Often scored → deny |
| `Referer: https://evil.example/?x=<script>…` | Kept; XSS rules can still deny | Also denied |
| Duplicate / conflicting `Connection` | Stripped before filters | CRS **920210** may deny |

Status codes in those probes (often **200** here vs often **403** on nginx for the same bare Referer) are lab snapshots, not guarantees. Re-check after pin bumps. Absolute-URI Referers and the surfaces listed under [What Envoy forwards](#what-envoy-forwards-to-modsecurity) remain the practical targets for custom rules.
