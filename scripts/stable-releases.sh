#!/usr/bin/env bash
# Stable upstream releases per axis, from the GitHub releases API (needs gh
# with a token: GH_TOKEN in Actions). Never trusts releases/latest: upstream
# interleaves release lines (ModSecurity v2.9.x after v3.0.x, CRS LTS and
# v3.3.x after v4.x, several Envoy minors on one day).
#
#   ./scripts/stable-releases.sh list   <axis>      all stable tags, ascending
#   ./scripts/stable-releases.sh latest <axis>      highest stable tag
#   ./scripts/stable-releases.sh window <axis> [n]  newest n (default 3): for envoy
#                                                   and crs the top patch of each of
#                                                   the newest n minors
#   ./scripts/stable-releases.sh pin    <axis>      pin from versions.lock.md
#   ./scripts/stable-releases.sh valid  <axis> <tag>  exit 0 if tag matches the stable pattern
#
# Axes: envoy (v1.x.y) · modsecurity (v3.0.x, never v2) · crs (v4.x.y).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

repo_of() {
  case "$1" in
    envoy) echo envoyproxy/envoy ;;
    modsecurity) echo owasp-modsecurity/ModSecurity ;;
    crs) echo coreruleset/coreruleset ;;
    *) echo "unknown axis '$1' (envoy|modsecurity|crs)" >&2; exit 2 ;;
  esac
}

pattern_of() {
  case "$1" in
    envoy) echo '^v1\.[0-9]+\.[0-9]+$' ;;
    modsecurity) echo '^v3\.0\.[0-9]+$' ;;
    crs) echo '^v4\.[0-9]+\.[0-9]+$' ;;
    *) repo_of "$1" ;;
  esac
}

pin_key() {
  case "$1" in
    envoy) echo ENVOY_PIN ;;
    modsecurity) echo MODSECURITY_PIN ;;
    crs) echo CRS_TAG ;;
    *) repo_of "$1" ;;
  esac
}

list() {
  local repo pat
  repo="$(repo_of "$1")"
  pat="$(pattern_of "$1")"
  gh api "repos/${repo}/releases?per_page=100" \
    -q '.[] | select(.draft | not) | select(.prerelease | not) | .tag_name' \
    | grep -E "${pat}" | sort -uV
}

window() {
  local axis="$1" n="${2:-3}"
  case "${axis}" in
    modsecurity) list "${axis}" | tail -n "${n}" | sort -rV ;;
    *)
      # Highest patch per minor, newest n minors.
      list "${axis}" | awk -F. '{ top[$1"."$2] = $0 } END { for (m in top) print top[m] }' \
        | sort -rV | head -n "${n}"
      ;;
  esac
}

cmd="${1:-}"
axis="${2:-}"
[[ -n "${cmd}" && -n "${axis}" ]] || { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
case "${cmd}" in
  list) list "${axis}" ;;
  latest) list "${axis}" | tail -n 1 ;;
  window) window "${axis}" "${3:-3}" ;;
  pin) grep -E "^$(pin_key "${axis}")=" "${ROOT}/versions.lock.md" | head -1 | cut -d= -f2 ;;
  valid) [[ "${3:-}" =~ $(pattern_of "${axis}") ]] ;;
  *) echo "unknown command '${cmd}'" >&2; exit 2 ;;
esac
