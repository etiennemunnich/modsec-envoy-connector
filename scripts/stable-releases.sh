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
#   ./scripts/stable-releases.sh line   <axis> <tag>  highest stable on <tag>'s minor line
#                                                   (v1.38.3 -> top v1.38.x)
#   ./scripts/stable-releases.sh untracked <axis>   recent stable tags newer than the pin
#                                                   that the axis pattern does not cover
#                                                   (a new major/minor line, e.g. v3.1.0)
#   ./scripts/stable-releases.sh pin    <axis>      pin from versions.lock.md (LOCK_FILE)
#   ./scripts/stable-releases.sh valid  <axis> <tag>  exit 0 if tag matches the stable pattern
#
# Axes: envoy (v1.x.y) · modsecurity (v3.0.x, never v2) · crs (v4.x.y).
# Env: LOCK_FILE (default versions.lock.md) - tests point it at a fake lock.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK_FILE="${LOCK_FILE:-${ROOT}/versions.lock.md}"

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

stable_tags() { # every non-draft, non-prerelease tag (all pages unless $2 = "recent")
  local repo
  repo="$(repo_of "$1")"
  if [[ "${2:-}" == recent ]]; then
    gh api "repos/${repo}/releases?per_page=30" -q '.[] | select(.draft | not) | select(.prerelease | not) | .tag_name'
  else
    gh api --paginate "repos/${repo}/releases?per_page=100" -q '.[] | select(.draft | not) | select(.prerelease | not) | .tag_name'
  fi
}

list() {
  local tags
  tags="$(stable_tags "$1" | grep -E "$(pattern_of "$1")" | sort -uV || true)"
  [[ -n "${tags}" ]] || { echo "stable-releases: no $1 release matches $(pattern_of "$1")" >&2; exit 1; }
  echo "${tags}"
}

newer() { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" ]]; }

pin_of() {
  local v
  v="$(grep -E "^$(pin_key "$1")=" "${LOCK_FILE}" | head -1 | cut -d= -f2 || true)"
  [[ -n "${v}" ]] || { echo "stable-releases: no $(pin_key "$1")= in ${LOCK_FILE}" >&2; exit 1; }
  echo "${v}"
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
  line)
    [[ "${3:-}" =~ $(pattern_of "${axis}") ]] || { echo "not a stable ${axis} tag: '${3:-}'" >&2; exit 2; }
    prefix="${3%.*}."
    list "${axis}" | awk -v p="${prefix}" 'index($0, p) == 1' | tail -n 1
    ;;
  untracked)
    pin="$(pin_of "${axis}")"
    stable_tags "${axis}" recent | { grep -vE "$(pattern_of "${axis}")" || true; } | sort -uV \
      | while read -r t; do if newer "${t}" "${pin}"; then echo "${t}"; fi; done
    ;;
  pin) pin_of "${axis}" ;;
  valid) [[ "${3:-}" =~ $(pattern_of "${axis}") ]] ;;
  *) echo "unknown command '${cmd}'" >&2; exit 2 ;;
esac
