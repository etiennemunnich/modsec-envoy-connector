#!/usr/bin/env bash
# List (default) or delete allowlisted stale GHCR package versions.
#
# Secure by design: default is dry-run; --delete only removes version ids whose
# container tags match the hard-coded allowlist below. Never widens auth —
# the human must already have packages scopes on their gh token.
#
# Usage:
#   ./scripts/ghcr-delete-stale.sh                 # list allowlisted stale only
#   ./scripts/ghcr-delete-stale.sh --all-versions  # read-only dump of every version
#   ./scripts/ghcr-delete-stale.sh --delete        # delete allowlisted ids only
#
# Defaults match this repo's GHCR package (modsec-envoy-connector).
# Predecessor private package (stale v0.1.0-rc.1 allowlist) — override:
#   OWNER=etiennemunnich PACKAGE=envoy-modsec-connex ./scripts/ghcr-delete-stale.sh
#
# Requires: gh (logged in), jq. No secrets in this script.
set -euo pipefail

OWNER="${OWNER:-etiennemunnich}"
PACKAGE="${PACKAGE:-modsec-envoy-connector}"
API_BASE="/users/${OWNER}/packages/container/${PACKAGE}/versions"

# Exact gh auth refresh the human must run when packages scopes are missing.
AUTH_REFRESH='gh auth refresh -h github.com -s read:packages,delete:packages,gist,read:org,repo,workflow'

MODE="list" # list | delete | all-versions

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

die() { echo "ghcr-delete-stale FAIL: $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

# True if any container tag is exactly v0.1.0-rc.1 or starts with sha-770ab01.
is_allowlisted() {
  local tags_json="$1"
  jq -e '
    (. // []) as $t
    | ($t | index("v0.1.0-rc.1") != null)
      or (any($t[]; startswith("sha-770ab01")))
  ' >/dev/null <<<"${tags_json}"
}

print_version_line() {
  local id="$1" name="$2" tags_json="$3" updated="$4"
  local tags
  tags="$(jq -cr '(. // []) | join(", ")' <<<"${tags_json}")"
  printf 'id=%s  name=%s  tags=[%s]  updated=%s\n' "${id}" "${name}" "${tags}" "${updated}"
}

fail_packages_403() {
  local verb="$1"
  cat >&2 <<EOF
ghcr-delete-stale FAIL: GitHub returned 403 on packages ${verb}.
Your gh token needs read:packages (and delete:packages for --delete).

Run exactly:
  ${AUTH_REFRESH}

Then re-run this script. The script does not widen auth.
EOF
  exit 1
}

# Fetch all versions as a JSON array (paginated). On 403, fail with refresh hint.
fetch_versions() {
  local tmp body
  tmp="$(mktemp)"
  # gh api --paginate concatenates page arrays into a stream of objects when
  # using --jq, but raw paginate yields concatenated JSON arrays. Use --slurp
  # via jq after collecting successful output; detect 403 from gh exit + stderr.
  if ! body="$(gh api --paginate "${API_BASE}?per_page=100" 2>"${tmp}.err")"; then
    if grep -qiE '403|read:packages|packages scope' "${tmp}.err" 2>/dev/null \
      || grep -qiE '403|read:packages|packages scope' <<<"${body:-}" 2>/dev/null; then
      rm -f "${tmp}.err"
      fail_packages_403 "list"
    fi
    cat "${tmp}.err" >&2 || true
    rm -f "${tmp}.err"
    die "gh api list failed for ${API_BASE}"
  fi
  rm -f "${tmp}.err"
  # Paginate returns concatenated JSON arrays: [{...}][{...}] → flatten.
  jq -cs 'add // []' <<<"${body}" >"${tmp}"
  echo "${tmp}"
}

list_allowlisted() {
  local versions_file="$1"
  local count=0
  local id name tags updated
  while IFS=$'\t' read -r id name tags updated; do
    [[ -n "${id}" ]] || continue
    if is_allowlisted "${tags}"; then
      print_version_line "${id}" "${name}" "${tags}" "${updated}"
      count=$((count + 1))
    fi
  done < <(jq -r '
    .[] | [
      (.id | tostring),
      (.name // ""),
      (.metadata.container.tags // [] | tojson),
      (.updated_at // "")
    ] | @tsv
  ' "${versions_file}")
  echo "allowlisted_stale_count=${count}"
  return 0
}

list_all() {
  local versions_file="$1"
  local count=0
  local id name tags updated
  while IFS=$'\t' read -r id name tags updated; do
    [[ -n "${id}" ]] || continue
    print_version_line "${id}" "${name}" "${tags}" "${updated}"
    count=$((count + 1))
  done < <(jq -r '
    .[] | [
      (.id | tostring),
      (.name // ""),
      (.metadata.container.tags // [] | tojson),
      (.updated_at // "")
    ] | @tsv
  ' "${versions_file}")
  echo "all_versions_count=${count}"
}

delete_allowlisted() {
  local versions_file="$1"
  local id name tags updated deleted=0
  local -a ids=()

  while IFS=$'\t' read -r id name tags updated; do
    [[ -n "${id}" ]] || continue
    if is_allowlisted "${tags}"; then
      print_version_line "${id}" "${name}" "${tags}" "${updated}"
      ids+=("${id}")
    fi
  done < <(jq -r '
    .[] | [
      (.id | tostring),
      (.name // ""),
      (.metadata.container.tags // [] | tojson),
      (.updated_at // "")
    ] | @tsv
  ' "${versions_file}")

  if [[ ${#ids[@]} -eq 0 ]]; then
    echo "nothing to delete (no allowlisted stale versions)"
    return 0
  fi

  for id in "${ids[@]}"; do
    # Refuse non-numeric ids (defense in depth — never DELETE an unexpected path).
    [[ "${id}" =~ ^[0-9]+$ ]] || die "refusing non-numeric version id: ${id}"
    echo "DELETE version id=${id}"
    if ! gh api -X DELETE "${API_BASE}/${id}" 2>"${TMPDIR:-/tmp}/ghcr-del-${id}.err"; then
      if grep -qiE '403|delete:packages|packages scope' "${TMPDIR:-/tmp}/ghcr-del-${id}.err" 2>/dev/null; then
        rm -f "${TMPDIR:-/tmp}/ghcr-del-${id}.err"
        fail_packages_403 "delete"
      fi
      cat "${TMPDIR:-/tmp}/ghcr-del-${id}.err" >&2 || true
      rm -f "${TMPDIR:-/tmp}/ghcr-del-${id}.err"
      die "DELETE failed for version id=${id}"
    fi
    rm -f "${TMPDIR:-/tmp}/ghcr-del-${id}.err"
    deleted=$((deleted + 1))
  done
  echo "deleted_count=${deleted}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --delete)
      [[ "${MODE}" == "list" ]] || die "--delete cannot combine with --all-versions"
      MODE="delete"
      shift
      ;;
    --all-versions)
      [[ "${MODE}" == "list" ]] || die "--all-versions cannot combine with --delete"
      MODE="all-versions"
      shift
      ;;
    --list) MODE="list"; shift ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

need_cmd gh
need_cmd jq

command -v gh >/dev/null
gh auth status >/dev/null 2>&1 || die "gh is not logged in (run: gh auth login)"

echo "package=ghcr.io/${OWNER}/${PACKAGE}"
echo "mode=${MODE}"

versions_file="$(fetch_versions)"
trap 'rm -f "${versions_file}"' EXIT

case "${MODE}" in
  list)
    list_allowlisted "${versions_file}"
    ;;
  all-versions)
    list_all "${versions_file}"
    ;;
  delete)
    delete_allowlisted "${versions_file}"
    ;;
  *)
    die "internal: unknown mode ${MODE}"
    ;;
esac
