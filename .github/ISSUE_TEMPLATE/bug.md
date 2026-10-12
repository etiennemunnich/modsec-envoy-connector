---
name: Bug
about: Wrong allow, deny, or fail-closed result
title: ""
labels: bug
---

**Connector:** output of `ext-proc-modsec --version`, plus the release tag, image digest or commit

**Install method:** release tarball / container image / built from source / demo (`demo/scripts/up.sh`)

**OS and architecture:** e.g. Ubuntu 24.04 x86_64, macOS 15 arm64

**Body mode** (`BODY_MODE` or your `processing_mode`): BUFFERED / STREAMED / BUFFERED_PARTIAL / FULL_DUPLEX_STREAMED / NONE / REQ_BUFFERED_RESP_STREAMED / REQ_STREAMED_RESP_BUFFERED, and `--body-reply`

**Versions you ran:** Envoy, libmodsecurity, CRS (pins in `versions.lock.md`: `ENVOY_PIN=` `MODSECURITY_PIN=` `CRS_TAG=`)

**Expected:** 200 allow / 403 rule deny / 500 fail-closed / 504 `message_timeout`

**Actual:** status, method, path, and the header or body that triggered it

**Where it failed:** connector log line or Envoy `%RESPONSE_CODE_DETAILS%`, if you have one

Enforcement is fail-closed (`failure_mode_allow: false`). 403 is a rule deny. 500 and 504 mean the engine could not decide. Status meanings: [troubleshooting](https://github.com/etiennemunnich/modsec-envoy-connector/blob/main/docs/troubleshooting.md).
