#!/usr/bin/env bash
# One-year stable matrix: discover tags, plan cells, run one cell locally.
#
#   ./scripts/one-year-matrix.sh list [--days N]
#   ./scripts/one-year-matrix.sh plan [--strategy axis|diagonal|cartesian]
#                                    [--days N] [--json] [--confirm-cartesian]
#   ./scripts/one-year-matrix.sh run --profile smoke|fail-closed|fail-modes|go-ftw-smoke|full-cell
#                                    [--envoy TAG] [--modsec TAG] [--crs TAG]
#
# Policy defaults: versions.one-year.yaml (POLICY_FILE). Pins: versions.lock.md.
# Stable discovery reuses scripts/stable-releases.sh (never releases/latest).
# Full Cartesian requires --confirm-cartesian. Fail-closed stays absolute in
# every live cell (ci-live-e2e.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
POLICY_FILE="${POLICY_FILE:-${ROOT}/versions.one-year.yaml}"
STABLE="${ROOT}/scripts/stable-releases.sh"
E2E="${ROOT}/scripts/ci-live-e2e.sh"
MODSEC_FLOOR="${MODSEC_FLOOR:-v3.0.13}"

die() { echo "one-year-matrix: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "need $1 on PATH"; }

policy_get() { # policy_get <yaml.key> [default]
  local key="$1" def="${2:-}"
  need python3
  python3 - "$POLICY_FILE" "$key" "$def" <<'PY'
import sys
path, key, default = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    import yaml  # type: ignore
except ImportError:
    yaml = None
text = open(path, encoding="utf-8").read() if path else ""
val = None
if yaml is not None and text:
    data = yaml.safe_load(text) or {}
    cur = data
    for part in key.split("."):
        if not isinstance(cur, dict) or part not in cur:
            cur = None
            break
        cur = cur[part]
    val = cur
else:
    # Minimal fallback: top-level "key: value" and profiles.<name>: "suites"
    import re
    if "." not in key:
        m = re.search(rf"(?m)^{re.escape(key)}:\s*(.+)$", text)
        if m:
            val = m.group(1).strip().strip("\"'")
    else:
        head, _, tail = key.partition(".")
        if head == "profiles":
            m = re.search(rf"(?m)^\s+{re.escape(tail)}:\s*[\"']?([^\"'\n]+)[\"']?\s*$", text)
            if m:
                val = m.group(1).strip()
if val is None or val == "":
    print(default)
else:
    print(val)
PY
}

below_floor() { # below_floor <tag> <floor> → 0 if tag < floor
  local tag="$1" floor="$2"
  [[ "$(printf '%s\n%s\n' "$tag" "$floor" | sort -V | head -1)" != "$floor" ]]
}

axis_tags() { # axis_tags <axis> <days>
  local axis="$1" days="$2" collapse
  case "${axis}" in
    envoy) collapse="$(policy_get envoy_collapse top-patch-per-minor)" ;;
    crs) collapse="$(policy_get crs_collapse top-patch-per-minor)" ;;
    modsecurity) collapse="$(policy_get modsecurity_collapse all)" ;;
    *) die "unknown axis ${axis}" ;;
  esac
  if [[ "${collapse}" == "all" ]]; then
    "${STABLE}" since "${axis}" "${days}"
  else
    "${STABLE}" since-window "${axis}" "${days}"
  fi
}

emit_cell_json() { # emit_cell_json <name> <envoy> <modsec> <crs>
  python3 -c 'import json,sys; print(json.dumps({"cell":sys.argv[1],"envoy":sys.argv[2],"modsec":sys.argv[3],"crs":sys.argv[4]}))' "$@"
}

plan_axis() {
  local days="$1" pin_e pin_m pin_c tag
  pin_e="$("${STABLE}" pin envoy)"
  pin_m="$("${STABLE}" pin modsecurity)"
  pin_c="$("${STABLE}" pin crs)"
  emit_cell_json "pins" "" "" ""
  while read -r tag; do
    [[ -z "${tag}" || "${tag}" == "${pin_e}" ]] && continue
    emit_cell_json "envoy ${tag}" "${tag}" "" ""
  done < <(axis_tags envoy "${days}")
  while read -r tag; do
    [[ -z "${tag}" || "${tag}" == "${pin_m}" ]] && continue
    if below_floor "${tag}" "${MODSEC_FLOOR}"; then
      echo "one-year-matrix: skip modsecurity ${tag} (below floor ${MODSEC_FLOOR})" >&2
      continue
    fi
    emit_cell_json "modsecurity ${tag}" "" "${tag}" ""
  done < <(axis_tags modsecurity "${days}")
  while read -r tag; do
    [[ -z "${tag}" || "${tag}" == "${pin_c}" ]] && continue
    emit_cell_json "crs ${tag}" "" "" "${tag}"
  done < <(axis_tags crs "${days}")
}

plan_diagonal() {
  local days="$1" pin_e pin_m pin_c
  local e_old e_new m_old m_new c_old c_new
  pin_e="$("${STABLE}" pin envoy)"
  pin_m="$("${STABLE}" pin modsecurity)"
  pin_c="$("${STABLE}" pin crs)"
  e_old="$(axis_tags envoy "${days}" | sort -V | head -1)"
  e_new="$(axis_tags envoy "${days}" | sort -V | tail -1)"
  m_old="$(axis_tags modsecurity "${days}" | sort -V | head -1)"
  m_new="$(axis_tags modsecurity "${days}" | sort -V | tail -1)"
  c_old="$(axis_tags crs "${days}" | sort -V | head -1)"
  c_new="$(axis_tags crs "${days}" | sort -V | tail -1)"
  [[ -n "${e_old}" && -n "${m_old}" && -n "${c_old}" ]] \
    || die "diagonal needs at least one tag per axis in the since-window"
  # Filter ModSec below floor for corner cells.
  if below_floor "${m_old}" "${MODSEC_FLOOR}"; then m_old="${pin_m}"; fi
  if below_floor "${m_new}" "${MODSEC_FLOOR}"; then m_new="${pin_m}"; fi
  emit_cell_json "pins" "" "" ""
  emit_cell_json "diag oldest-envoy ${e_old}" "${e_old}" "" ""
  emit_cell_json "diag newest-envoy ${e_new}" "${e_new}" "" ""
  emit_cell_json "diag oldest-crs ${c_old}" "" "" "${c_old}"
  emit_cell_json "diag newest-crs ${c_new}" "" "" "${c_new}"
  emit_cell_json "diag oldest-triple" "${e_old}" "${m_old}" "${c_old}"
  emit_cell_json "diag newest-triple" "${e_new}" "${m_new}" "${c_new}"
}

plan_cartesian() {
  local days="$1" e m c
  while read -r e; do
    [[ -z "${e}" ]] && continue
    while read -r m; do
      [[ -z "${m}" ]] && continue
      if below_floor "${m}" "${MODSEC_FLOOR}"; then
        echo "one-year-matrix: skip modsecurity ${m} (below floor ${MODSEC_FLOOR})" >&2
        continue
      fi
      while read -r c; do
        [[ -z "${c}" ]] && continue
        emit_cell_json "${e} × ${m} × ${c}" "${e}" "${m}" "${c}"
      done < <(axis_tags crs "${days}")
    done < <(axis_tags modsecurity "${days}")
  done < <(axis_tags envoy "${days}")
}

cmd_list() {
  local days="${1:-}"
  [[ -n "${days}" ]] || days="$(policy_get days 365)"
  need gh
  echo "# one-year stables (days=${days}, floor modsecurity≥${MODSEC_FLOOR})"
  for axis in envoy modsecurity crs; do
    echo
    echo "## ${axis}"
    axis_tags "${axis}" "${days}" | while read -r t; do
      if [[ "${axis}" == modsecurity ]] && below_floor "${t}" "${MODSEC_FLOOR}"; then
        echo "${t}  (below floor — skipped in plan)"
      else
        echo "${t}"
      fi
    done
  done
}

cmd_plan() {
  local strategy="${1:-}" days="${2:-}" as_json="${3:-0}" confirm="${4:-0}"
  [[ -n "${strategy}" ]] || strategy="$(policy_get strategy axis)"
  [[ -n "${days}" ]] || days="$(policy_get days 365)"
  MODSEC_FLOOR="$(policy_get modsecurity_floor "${MODSEC_FLOOR}")"
  need gh; need python3
  local cells lines
  case "${strategy}" in
    axis) lines="$(plan_axis "${days}")" ;;
    diagonal) lines="$(plan_diagonal "${days}")" ;;
    cartesian)
      [[ "${confirm}" == "1" ]] || die "cartesian requires --confirm-cartesian (expensive; see versions.one-year.yaml)"
      lines="$(plan_cartesian "${days}")"
      ;;
    *) die "unknown strategy '${strategy}' (axis|diagonal|cartesian)" ;;
  esac
  cells="$(printf '%s\n' "${lines}" | python3 -c 'import json,sys; print(json.dumps([json.loads(l) for l in sys.stdin if l.strip()]))')"
  if [[ "${as_json}" == "1" ]]; then
    echo "${cells}"
  else
    echo "# strategy=${strategy} days=${days} cells=$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "${cells}")"
    python3 -c 'import json,sys
for c in json.loads(sys.argv[1]):
  e=c["envoy"] or "(pin)"; m=c["modsec"] or "(pin)"; r=c["crs"] or "(pin)"
  print("- %s: envoy=%s modsec=%s crs=%s" % (c["cell"], e, m, r))
' "${cells}"
  fi
}

profile_suites() {
  local p="$1" s
  s="$(policy_get "profiles.${p}" "")"
  [[ -n "${s}" ]] || die "unknown profile '${p}' (smoke|fail-closed|fail-modes|go-ftw-smoke|full-cell)"
  echo "${s}"
}

cmd_run() {
  local profile="" envoy="" modsec="" crs=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile) profile="${2:-}"; shift 2 ;;
      --envoy) envoy="${2:-}"; shift 2 ;;
      --modsec) modsec="${2:-}"; shift 2 ;;
      --crs) crs="${2:-}"; shift 2 ;;
      *) die "run: unknown arg $1" ;;
    esac
  done
  [[ -n "${profile}" ]] || die "run: --profile required"
  local suites
  suites="$(profile_suites "${profile}")"
  [[ -n "${envoy}" ]] || envoy="$("${STABLE}" pin envoy)"
  [[ -n "${modsec}" ]] || modsec="$("${STABLE}" pin modsecurity)"
  [[ -n "${crs}" ]] || crs="$("${STABLE}" pin crs)"
  "${STABLE}" valid envoy "${envoy}" || die "bad envoy ${envoy}"
  "${STABLE}" valid modsecurity "${modsec}" || die "bad modsecurity ${modsec}"
  "${STABLE}" valid crs "${crs}" || die "bad crs ${crs}"
  if below_floor "${modsec}" "${MODSEC_FLOOR}"; then
    die "modsecurity ${modsec} is below floor ${MODSEC_FLOOR}"
  fi
  echo "one-year-matrix run: profile=${profile} suites='${suites}'"
  echo "  ENVOY_VERSION=${envoy} MODSECURITY_PIN=${modsec} CRS_TAG=${crs}"
  SUITES="${suites}" ENVOY_VERSION="${envoy}" MODSECURITY_PIN="${modsec}" CRS_TAG="${crs}" \
    "${E2E}"
}

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

cmd="${1:-}"
[[ -n "${cmd}" ]] || usage
shift || true

case "${cmd}" in
  list)
    days=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --days) days="${2:-}"; shift 2 ;;
        *) die "list: unknown arg $1" ;;
      esac
    done
    cmd_list "${days}"
    ;;
  plan)
    strategy="" days="" as_json=0 confirm=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --strategy) strategy="${2:-}"; shift 2 ;;
        --days) days="${2:-}"; shift 2 ;;
        --json) as_json=1; shift ;;
        --confirm-cartesian) confirm=1; shift ;;
        *) die "plan: unknown arg $1" ;;
      esac
    done
    cmd_plan "${strategy}" "${days}" "${as_json}" "${confirm}"
    ;;
  run) cmd_run "$@" ;;
  *) usage ;;
esac
