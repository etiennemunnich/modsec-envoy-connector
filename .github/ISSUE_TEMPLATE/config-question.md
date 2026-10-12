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

`failure_mode_allow` stays `false` on enforcement. Envoy applies no `message_timeout` under FULL_DUPLEX_STREAMED; the demo configs use 2s in the other modes. Say which of those you are on. Reference config: [deploy.md](https://github.com/etiennemunnich/modsec-envoy-connector/blob/main/docs/deploy.md).
