# Runtime image for one architecture. The build context is a release tarball
# directory produced natively on the matching runner (bin/, lib/, LICENSE,
# NOTICE, versions.lock.md), built on the same Ubuntu 24.04 base, so the
# bundled libmodsecurity matches the system libraries below.
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
 && /usr/local/bin/ext-proc-modsec --version

USER 65532:65532
EXPOSE 18081 18082
ENTRYPOINT ["/usr/local/bin/ext-proc-modsec", "--listen", "0.0.0.0:18081", "--metrics-listen", "0.0.0.0:18082"]
