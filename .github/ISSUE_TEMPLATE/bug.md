---
name: Bug
about: Wrong allow, deny, or fail-closed result
title: ""
labels: bug
---

**Body mode** (`BODY_MODE`): BUFFERED / STREAMED / BUFFERED_PARTIAL / FULL_DUPLEX_STREAMED / NONE / REQ_BUFFERED_RESP_STREAMED / REQ_STREAMED_RESP_BUFFERED

**Pins** (from `versions.lock.md`, or the versions you actually ran): `ENVOY_PIN=` `CRS_TAG=`

**Expected:** 200 allow / 403 rule deny / 500 fail-closed / 504 `message_timeout`

**Actual:** status, method, path, and the header or body that triggered it

**Where it failed:** connector log line or Envoy response flag, if you have one

Enforcement is fail-closed (`failure_mode_allow: false`). 403 is a rule deny. 500 and 504 mean the engine could not decide.
