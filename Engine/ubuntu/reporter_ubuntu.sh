#!/usr/bin/env bash
# Adhiambo Ubuntu Engine — Reporter Wrapper
#
# Usage: reporter_ubuntu.sh --json <os_report.json> [--output-dir <dir>]
#
# Reads an existing OS engine report JSON and re-generates the CSV and
# manual review TXT from it. Useful for re-exporting reports without
# re-running the full scan.
#
# For standard runs, ubuntu.sh writes all three output files directly.
# This script exists as a thin re-export wrapper for downstream consumers.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

JSON_INPUT=""
OUTPUT_DIR="/tmp/adhiambo"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)   JSON_INPUT="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: reporter_ubuntu.sh --json <os_report.json> [--output-dir <dir>]"
            exit 0 ;;
        *) echo "[ERROR] Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$JSON_INPUT" || ! -f "$JSON_INPUT" ]]; then
    echo "[ERROR] --json must point to a valid OS engine report file." >&2
    exit 1
fi

# Parse key fields from JSON
SCAN_ID=$(grep -o '"scan_id":\s*"[^"]*"' "$JSON_INPUT" | cut -d'"' -f4)
HOSTNAME=$(grep -o '"hostname":\s*"[^"]*"' "$JSON_INPUT" | cut -d'"' -f4)
SCAN_LEVEL=$(grep -o '"level":\s*[0-9]' "$JSON_INPUT" | grep -o '[0-9]')
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

mkdir -p "$OUTPUT_DIR"
CSV_FILE="${OUTPUT_DIR}/adhiambo_ubuntu_${TIMESTAMP}.csv"
MANUAL_TXT="${OUTPUT_DIR}/adhiambo_ubuntu_manual_${TIMESTAMP}.txt"
export MANUAL_TXT

# Reconstruct CSV_ROWS from JSON findings
# Each finding: "id": {"status": "...", "description": "...", "remediation": "..."}
while IFS= read -r line; do
    local id status desc rem
    id=$(echo "$line" | grep -o '"[^"]*": {' | tr -d '"{ ')
    status=$(echo "$line" | grep -o '"status": "[^"]*"' | cut -d'"' -f4)
    desc=$(echo "$line" | grep -o '"description": "[^"]*"' | cut -d'"' -f4)
    rem=$(echo "$line" | grep -o '"remediation": "[^"]*"' | cut -d'"' -f4)
    [[ -n "$id" && -n "$status" ]] && CSV_ROWS+=("${id}|${desc}|${status}|${rem}")
done < <(python3 -c "
import json, sys
with open('${JSON_INPUT}') as f:
    data = json.load(f)
findings = data.get('findings', {})
for k, v in findings.items():
    rem = v.get('remediation', '')
    print(f'{k}|{v[\"status\"]}|{v[\"description\"]}|{rem}')
" 2>/dev/null || true)

write_csv "$CSV_FILE"
write_manual_txt "$MANUAL_TXT" "$HOSTNAME" "$SCAN_ID" "$SCAN_LEVEL" "$TIMESTAMP"

echo "Report re-exported:"
echo "  CSV    : $CSV_FILE"
echo "  Manual : $MANUAL_TXT"