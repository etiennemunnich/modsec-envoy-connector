# Runtime image for one architecture. The build context is a release tarball
# directory produced natively on the matching runner (bin/, lib/, LICENSE,
# NOTICE, versions.lock.md), built on the same Ubuntu 24.04 base, so the
# bundled libmodsecurity matches the system libraries below.
# lib/ includes alpha libmodsec_dm.so (operators copy it out for Envoy); the
# ENTRYPOINT remains the ext_proc sidecar.
#
# Listeners default to loopback (binary defaults: 127.0.0.1:18081 gRPC,
# 127.0.0.1:18082 metrics/healthz) — right for a pod sidecar, where only
# Envoy and the metrics scraper share the network namespace. The gRPC
# listener is plaintext and unauthenticated, so binding beyond loopback is an
# explicit operator opt-in (the binary refuses otherwise):
#   --listen 0.0.0.0:18081 --metrics-listen 0.0.0.0:18082 --listen-public
# (or EXT_PROC_LISTEN / EXT_PROC_METRICS_LISTEN / EXT_PROC_LISTEN_PUBLIC=1).
# Even then, restrict reachability to Envoy and the scraper (NetworkPolicy /
# mesh); see docs/deploy.md.
FROM ubuntu:24.04

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates libcurl4t64 libgeoip1t64 liblmdb0 libpcre2-8-0 libxml2 libyajl2 \
 && rm -rf /var/lib/apt/lists/*

COPY lib/ /usr/local/lib/
COPY bin/ext-proc-modsec /usr/local/bin/ext-proc-modsec
COPY LICENSE NOTICE versions.lock.md /usr/share/doc/ext-proc-modsec/

RUN ldconfig \
 && ! ldd /usr/local/bin/ext-proc-modsec | grep -q 'not found' \
 && /usr/local/bin/ext-proc-modsec --version \
 && test -f /usr/local/lib/libmodsec_dm.so \
 && ! ldd /usr/local/lib/libmodsec_dm.so | grep -q 'not found'

USER 65532:65532
EXPOSE 18081 18082
ENTRYPOINT ["/usr/local/bin/ext-proc-modsec"]
