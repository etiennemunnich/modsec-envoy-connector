#!/usr/bin/env bash
# Remap stock demo Envoy port_value tokens without chained-sed collapse.
#
# One sed that rewrites 18080 → 18081 and then 18081 → 18082 also rewrites the
# listener it just produced, so the listener and the connector land on the
# same port. Placeholders break that chain: stock ports become tokens, any
# extra sed expressions run, then the tokens become the caller's ports.
#
# Source, do not execute.
#
# remap_stock_ports <src> <dest> <admin> <envoy> <conn> <origin> [sed-expr...]
remap_stock_ports() {
  local src="$1" dest="$2" admin="$3" envoy="$4" conn="$5" origin="$6"
  shift 6
  sed \
    -e 's/port_value: 18089/port_value: __CONNEX_ADMIN__/g' \
    -e 's/port_value: 18080/port_value: __CONNEX_ENVOY__/g' \
    -e 's/port_value: 18081/port_value: __CONNEX_EXTPROC__/g' \
    -e 's/port_value: 18098/port_value: __CONNEX_ORIGIN__/g' \
    "$@" \
    "${src}" \
    | sed \
      -e "s/__CONNEX_ADMIN__/${admin}/g" \
      -e "s/__CONNEX_ENVOY__/${envoy}/g" \
      -e "s/__CONNEX_EXTPROC__/${conn}/g" \
      -e "s/__CONNEX_ORIGIN__/${origin}/g" \
      >"${dest}"
}
