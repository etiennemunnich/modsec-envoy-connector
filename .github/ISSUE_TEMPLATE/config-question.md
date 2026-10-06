---
name: Config / question
about: Body mode, CRS pin, or fail-closed setup
title: ""
labels: question
---

**What you are configuring**

**Body mode** (`BODY_MODE`): BUFFERED / STREAMED / BUFFERED_PARTIAL / FULL_DUPLEX_STREAMED / NONE

**Pins** (`ENVOY_PIN` and `CRS_TAG` from `versions.lock.md`):

**Question**

`failure_mode_allow` stays `false` on enforcement. FULL_DUPLEX turns `message_timeout` off; the other modes use 2s. Say which of those you are on.
