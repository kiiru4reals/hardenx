#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  HardenX Ubuntu Engine — ubuntu.sh
#  CIS Ubuntu Linux 24.04 LTS Benchmark v2.0.0 Compliance Engine
#
#  Usage: ubuntu.sh [OPTIONS]
#
#  Options:
#    --level <1|2>        Benchmark level to scan (default: 1)
#    --output-dir <dir>   Directory for output files (default: /tmp/hardenx)
#    --scan-id <id>       Override auto-generated scan ID
#    --help               Show this help message
#
#  Output files (all prefixed with hardenx_ubuntu):
#    *_<timestamp>.csv         4-column CSV compliance report
#    *_os_<timestamp>.json     Machine-readable OS engine report (JSON)
#    *_manual_<timestamp>.txt  Manual review workbook for operator sign-off
#
#  Notes:
#    - Must be run as root for complete results. Non-root runs will produce
#      SKIPPED records for checks that require elevated privileges.
#    - Level 1 checks cover essential server hardening.
#    - Level 2 adds defence-in-depth controls and auditd rules.
#    - This engine targets Ubuntu 24.04 LTS Server only.
# ─────────────────────────────────────────────────────────────────────────────
# Note: -e intentionally absent — check functions return 1 for FAIL state, not script error
set -u  # unbound variable check only
# pipefail is kept but all pipeline results handled via if/[[ ]] — never bare

# ─── Resolve script location ──────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Default parameters ───────────────────────────────────────────────────────
SCAN_LEVEL=1
OUTPUT_DIR="/tmp/hardenx"
SCAN_ID=""

# ─── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --level)
            if [[ -z "${2:-}" ]]; then
                echo "[ERROR] --level requires a value: 1 or 2" >&2; exit 1
            fi
            SCAN_LEVEL="$2"
            if [[ "$SCAN_LEVEL" != "1" && "$SCAN_LEVEL" != "2" ]]; then
                echo "[ERROR] --level must be 1 or 2 (got: ${SCAN_LEVEL})" >&2; exit 1
            fi
            shift 2 ;;
        --output-dir)
            if [[ -z "${2:-}" ]]; then
                echo "[ERROR] --output-dir requires a path" >&2; exit 1
            fi
            OUTPUT_DIR="$2"
            shift 2 ;;
        --scan-id)
            if [[ -z "${2:-}" ]]; then
                echo "[ERROR] --scan-id requires a value" >&2; exit 1
            fi
            SCAN_ID="$2"
            shift 2 ;;
        --help|-h)
            sed -n '/^# ─/,/^# ─.*──$/p' "$0" | sed 's/^# //' | sed 's/^#//'
            exit 0 ;;
        *)
            echo "[ERROR] Unknown option: $1" >&2
            echo "        Run with --help for usage." >&2
            exit 1 ;;
    esac
done

export SCAN_LEVEL

# ─── Source libraries ─────────────────────────────────────────────────────────
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/preflight.sh"

# ─── Source sections ─────────────────────────────────────────────────────────
source "${SCRIPT_DIR}/sections/section1.sh"
source "${SCRIPT_DIR}/sections/section2.sh"
source "${SCRIPT_DIR}/sections/section3.sh"
source "${SCRIPT_DIR}/sections/section4.sh"
source "${SCRIPT_DIR}/sections/section5.sh"
source "${SCRIPT_DIR}/sections/section6.sh"
source "${SCRIPT_DIR}/sections/section7.sh"

# ─── Banner ───────────────────────────────────────────────────────────────────
echo ""
echo "${BOLD}${SEP}${RESET}"
printf " ${BOLD}HARDENX — Ubuntu 24.04 LTS CIS Benchmark Engine${RESET}\n"
printf " Benchmark : CIS Ubuntu Linux 24.04 LTS Benchmark v2.0.0\n"
printf " Level     : %s\n" "$SCAN_LEVEL"
echo "${BOLD}${SEP}${RESET}"
echo ""

# ─── Pre-flight phases ────────────────────────────────────────────────────────
print_info "Phase 1: OS Verification"
preflight_os

print_info "Phase 2: Privilege Check"
preflight_privilege

print_info "Phase 3: Desktop Environment Detection"
preflight_desktop

print_info "Phase 4: Host Profile Detection"
preflight_host_profile
print_host_profile

# ─── Scan ID and timestamp ────────────────────────────────────────────────────
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
HOSTNAME=$(hostname -s 2>/dev/null || hostname)

if [[ -z "$SCAN_ID" ]]; then
    # Generate UUID-like scan ID
    if command -v uuidgen &>/dev/null; then
        SCAN_ID=$(uuidgen)
    else
        SCAN_ID="$(date '+%Y%m%d%H%M%S')-$(od -vN4 -tx4 /dev/urandom 2>/dev/null | \
            head -1 | awk '{print $2}' || echo "$(date +%N)")"
    fi
fi

export SCAN_ID TIMESTAMP HOSTNAME

# ─── Output filenames ─────────────────────────────────────────────────────────
mkdir -p "$OUTPUT_DIR"
CSV_FILE="${OUTPUT_DIR}/hardenx_ubuntu_${TIMESTAMP}.csv"
JSON_FILE="${OUTPUT_DIR}/hardenx_ubuntu_os_${TIMESTAMP}.json"
MANUAL_TXT="${OUTPUT_DIR}/hardenx_ubuntu_manual_${TIMESTAMP}.txt"

export CSV_FILE JSON_FILE MANUAL_TXT

printf " Scan ID   : %s\n" "$SCAN_ID"
printf " Timestamp : %s\n" "$TIMESTAMP"
printf " Host      : %s\n" "$HOSTNAME"
echo ""
printf " Output:\n"
printf "   CSV     : %s\n" "$CSV_FILE"
printf "   JSON    : %s\n" "$JSON_FILE"
printf "   Manual  : %s\n" "$MANUAL_TXT"
echo ""
echo "${SEP}"
echo ""

# ─── Run sections ─────────────────────────────────────────────────────────────
section1_run
section2_run
section3_run
section4_run
section5_run
section6_run
section7_run

# ─── Write output files ───────────────────────────────────────────────────────
write_csv "$CSV_FILE"
write_manual_txt "$MANUAL_TXT" "$HOSTNAME" "$SCAN_ID" "$SCAN_LEVEL" "$TIMESTAMP"
write_os_report "$JSON_FILE" "$SCAN_ID" "$HOSTNAME" "$SCAN_LEVEL" "$TIMESTAMP"

# ─── Summary ──────────────────────────────────────────────────────────────────
TOTAL=$(( COUNT_PASS + COUNT_FAIL + COUNT_MANUAL + COUNT_SKIPPED + COUNT_NA ))

echo ""
echo "${BOLD}${SEP}${RESET}"
printf " ${BOLD}SCAN COMPLETE${RESET}\n"
echo "${BOLD}${SEP}${RESET}"
printf "\n"
printf "  %-20s : %d\n" "Checks run" "$TOTAL"
printf "  ${GREEN}%-20s : %d${RESET}\n" "PASS" "$COUNT_PASS"
printf "  ${RED}%-20s : %d${RESET}\n" "FAIL" "$COUNT_FAIL"
printf "  ${YELLOW}%-20s : %d${RESET}\n" "MANUAL_REVIEW" "$COUNT_MANUAL"
printf "  ${CYAN}%-20s : %d${RESET}\n" "SKIPPED" "$COUNT_SKIPPED"
printf "  ${CYAN}%-20s : %d${RESET}\n" "N/A" "$COUNT_NA"
printf "\n"

# Compliance percentage (PASS / (PASS + FAIL + MANUAL) — N/A and SKIPPED excluded)
AUDITABLE=$(( COUNT_PASS + COUNT_FAIL + COUNT_MANUAL ))
if [[ "$AUDITABLE" -gt 0 ]]; then
    COMPLIANCE_PCT=$(( COUNT_PASS * 100 / AUDITABLE ))
    printf "  %-20s : %d%%\n" "Compliance (PASS/auditable)" "$COMPLIANCE_PCT"
fi

printf "\n"
printf "  Output files:\n"
printf "    CSV    : %s\n" "$CSV_FILE"
printf "    JSON   : %s\n" "$JSON_FILE"
printf "    Manual : %s\n" "$MANUAL_TXT"
printf "\n"

if [[ "$COUNT_FAIL" -gt 0 ]]; then
    printf "  ${RED}Review the CSV report and address all FAIL findings.${RESET}\n"
fi
if [[ "$COUNT_MANUAL" -gt 0 ]]; then
    printf "  ${YELLOW}Complete the manual review workbook for all MANUAL_REVIEW items.${RESET}\n"
fi

echo "${BOLD}${SEP}${RESET}"
echo ""