#!/usr/bin/env bash
# Look up the sha256 of one Envoy release asset inside checksums.txt.asc.
#
# Envoy's signed checksum list has shipped two layouts:
#   bare filename (v1.39.2, v1.38.5, v1.37.7, ...):
#     <sha256>  envoy-1.39.2-linux-x86_64
#   absolute build path (v1.39.1 and older window tags such as v1.38.4 / v1.37.6):
#     <sha256>  /tmp/tmp.../bin/envoy-1.39.1-linux-x86_64
# Compare the final path segment so both layouts hit, and so an envoy-* asset
# is not satisfied by envoy-contrib-*. Prints the hex digest, or nothing.
#
# Sourced by demo/scripts/install-envoy.sh. Not executed on its own.
envoy_checksum_sha256() {
  local file="$1" asset="$2"
  awk -v a="${asset}" '
    {
      n = $2
      sub(/^.*\//, "", n)
      if (n == a) { print $1; exit }
    }
  ' "${file}"
}
