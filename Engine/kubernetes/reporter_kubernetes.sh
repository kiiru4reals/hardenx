#!/usr/bin/env bash
# =============================================================================
#  HardenX — Kubernetes Reporting Helper
#  Component  : reporter_kubernetes.sh
#  Purpose    : Consumes parsed kube-bench findings from engine/kubernetes.sh
#               and produces the standard four-column HardenX CSV report.
#               This is a temporary stopgap until reporter.sh is ready.
#               Interface is designed to be compatible with reporter.sh.
#  Version    : 0.1
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------
OUTPUT_FILE=""
FINDINGS_JSON=""
OVERALL_SCORE=""
SECTION_SCORES_DECL=""
SECTION_TITLES_DECL=""
LEVEL=1

TIMESTAMP=$(date -u +"%Y-%m-%dT%H%M")

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
_error() { echo "[ERROR] $*" >&2; }

_usage() {
  cat <<EOF
USAGE
  bash reporter_kubernetes.sh [OPTIONS]

OPTIONS
  --output-file <path>       Path for the CSV output file. Required.
  --findings-json <path>     Path to the raw kube-bench JSON. Required.
  --overall-score <score>    Overall compliance score string (e.g. "79.2%").
  --section-scores <decl>    Bash declare -A string for section scores.
  --section-titles <decl>    Bash declare -A string for section titles.
  --level <1|2>              Scan level used. Default: 1.
  --help                     Display this help menu and exit.
EOF
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
_parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output-file)      OUTPUT_FILE="${2:?'--output-file requires a path'}"; shift 2 ;;
      --findings-json)    FINDINGS_JSON="${2:?'--findings-json requires a path'}"; shift 2 ;;
      --overall-score)    OVERALL_SCORE="${2:-N/A}"; shift 2 ;;
      --section-scores)   SECTION_SCORES_DECL="${2:-}"; shift 2 ;;
      --section-titles)   SECTION_TITLES_DECL="${2:-}"; shift 2 ;;
      --level)            LEVEL="${2:-1}"; shift 2 ;;
      --help)             _usage; exit 0 ;;
      *) _error "Unrecognised argument: $1"; exit 1 ;;
    esac
  done

  if [[ -z "${OUTPUT_FILE}" ]]; then
    _error "--output-file is required."
    exit 1
  fi
  if [[ -z "${FINDINGS_JSON}" || ! -f "${FINDINGS_JSON}" ]]; then
    _error "--findings-json is required and must point to an existing file."
    exit 1
  fi
}

# -----------------------------------------------------------------------------
# CSV escaping
# -----------------------------------------------------------------------------
_csv_field() {
  # Wrap in double quotes and escape any internal double quotes
  local val="${1:-}"
  val="${val//\"/\"\"}"
  echo "\"${val}\""
}

# -----------------------------------------------------------------------------
# Parse findings from kube-bench JSON and write CSV rows
# Uses the same parsing logic as engine/kubernetes.sh but writes directly to CSV
# -----------------------------------------------------------------------------
_write_findings() {
  local level="${LEVEL}"

  python3 - <<PYEOF >> "${OUTPUT_FILE}"
import json, sys, re, csv

def clean(s):
    return re.sub(r'[\t\r\n]+', ' ', str(s or '')).strip()

def iter_json_objects(path):
    with open(path) as f:
        content = f.read()
    decoder = json.JSONDecoder()
    pos = 0
    while pos < len(content):
        while pos < len(content) and content[pos] in ' \t\n\r':
            pos += 1
        if pos >= len(content):
            break
        obj, end = decoder.raw_decode(content, pos)
        yield obj
        pos = end

writer = csv.writer(sys.stdout, quoting=csv.QUOTE_ALL, lineterminator='\n')

for root in iter_json_objects('${FINDINGS_JSON}'):
    if isinstance(root, list):
        controls_list = root
    elif isinstance(root, dict) and 'Controls' in root:
        controls_list = root['Controls'] or []
    else:
        controls_list = [root]

    for controls in controls_list:
        section_id    = clean(controls.get('id', ''))
        section_title = clean(controls.get('text', '') or controls.get('desc', ''))
        if not section_id:
            continue

        tests = controls.get('tests', []) or []
        for test_group in tests:
            results = test_group.get('results', []) or []
            for result in results:
                check_id    = clean(result.get('test_number', ''))
                description = clean(result.get('test_desc', ''))
                kb_status   = clean(result.get('status', '')).upper()
                remediation = clean(result.get('remediation', ''))
                scored      = result.get('scored', True)

                if not check_id:
                    continue

                # Level filter
                if ${level} == 1 and not scored:
                    continue

                # Status mapping
                if kb_status == 'PASS':
                    status = 'PASS'
                    remediation = ''
                elif kb_status == 'FAIL':
                    status = 'FAIL'
                elif kb_status in ('WARN', 'INFO'):
                    status = 'MANUAL_REVIEW'
                    remediation = '[MANUAL REVIEW REQUIRED] ' + remediation
                else:
                    status = 'MANUAL_REVIEW'
                    remediation = '[MANUAL REVIEW REQUIRED] ' + remediation

                writer.writerow([check_id, description, status, remediation])
PYEOF
}

# -----------------------------------------------------------------------------
# Write score metadata rows
# -----------------------------------------------------------------------------
_write_scores() {
  # Restore section scores and titles from the declare strings passed in
  if [[ -n "${SECTION_SCORES_DECL}" ]]; then
    eval "${SECTION_SCORES_DECL}" 2>/dev/null || true
  fi
  if [[ -n "${SECTION_TITLES_DECL}" ]]; then
    eval "${SECTION_TITLES_DECL}" 2>/dev/null || true
  fi

  # Write per-section score rows
  if declare -p SECTION_SCORES &>/dev/null; then
    for section in $(echo "${!SECTION_SCORES[@]}" | tr ' ' '\n' | sort); do
      local title=""
      if declare -p SECTION_TITLE &>/dev/null; then
        title="${SECTION_TITLE[${section}]:-}"
      fi
      title="${title//\"/\"\"}"
      echo "\"SCORE:section_${section}\",\"${title}\",\"${SECTION_SCORES[${section}]}\",\"\"" \
        >> "${OUTPUT_FILE}"
    done
  fi

  # Write overall score row
  echo "\"SCORE:overall\",\"Overall Compliance Score\",\"${OVERALL_SCORE}\",\"\"" \
    >> "${OUTPUT_FILE}"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  _parse_args "$@"

  local output_dir
  output_dir=$(dirname "${OUTPUT_FILE}")
  if [[ ! -d "${output_dir}" || ! -w "${output_dir}" ]]; then
    _error "Output directory is not writable or does not exist: ${output_dir}"
    exit 1
  fi

  # Write header
  echo '"Check Name","Description","Status","Remediation"' > "${OUTPUT_FILE}"

  # Write findings
  _write_findings

  # Write score rows
  _write_scores

  echo "[INFO]     Report written: ${OUTPUT_FILE}"
}

main "$@"