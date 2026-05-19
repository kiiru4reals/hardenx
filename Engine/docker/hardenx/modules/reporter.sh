#!/usr/bin/env bash

# ----------------------------------------------------------------------------
# Initialize Assessment Directory
# ----------------------------------------------------------------------------
init_assessment_dir() {
    local assessment_name="$1"

    CURRENT_ASSESSMENT_NAME="$assessment_name"
    CURRENT_ASSESSMENT_DIR="$REPORTS_DIR/$assessment_name"

    mkdir -p "$CURRENT_ASSESSMENT_DIR"
    rm -f "$CURRENT_ASSESSMENT_DIR"/*
}

# ----------------------------------------------------------------------------
# Get Current Assessment Directory
# ----------------------------------------------------------------------------
get_assessment_dir() {
    echo "$CURRENT_ASSESSMENT_DIR"
}

# ----------------------------------------------------------------------------
# Select Report Output Format
# ----------------------------------------------------------------------------
# REPORT_FORMAT values:
#   csv     -> Separate CSV reports only
#   excel   -> Combined Excel workbook only
#   both    -> CSV reports + Excel workbook
# ----------------------------------------------------------------------------
select_report_format() {
    # Preserve previously selected format during multi-engine runs
    if [[ -n "${REPORT_FORMAT:-}" ]]; then
        return
    fi

    echo
    echo "=============================================================="
    echo " Report Output Format"
    echo "=============================================================="
    echo " 1) Separate Reports (CSV files only)"
    echo " 2) Combined Excel Workbook (.xlsx)"
    echo " 3) Both"
    echo "=============================================================="

    read -rp "Select option [1]: " choice
    choice="${choice:-1}"

    case "$choice" in
        1) REPORT_FORMAT="csv" ;;
        2) REPORT_FORMAT="excel" ;;
        3) REPORT_FORMAT="both" ;;
        *) REPORT_FORMAT="csv" ;;
    esac
}

# ----------------------------------------------------------------------------
# Generate Combined Excel Workbook
# ----------------------------------------------------------------------------
generate_excel_report() {
    local assessment_dir="$1"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    echo
    echo "=============================================================="
    echo " DEBUG: Excel Report Generation"
    echo "=============================================================="
    echo "REPORT_FORMAT          : ${REPORT_FORMAT:-<unset>}"
    echo "CURRENT_ASSESSMENT_DIR : ${CURRENT_ASSESSMENT_DIR:-<unset>}"
    echo "assessment_dir         : $assessment_dir"
    echo "script_dir             : $script_dir"
    echo "excel_reporter.py      : $script_dir/excel_reporter.py"
    echo "=============================================================="
    echo

    case "${REPORT_FORMAT:-csv}" in
        csv)
            echo "[DEBUG] CSV-only mode selected. Skipping Excel generation."
            return
            ;;

        excel|both)
            # ----------------------------------------------------------------
            # Generate Excel Workbook
            # ----------------------------------------------------------------
            echo "[DEBUG] Running Excel reporter..."

            if [[ "${QUIET:-false}" == true && "${VERBOSE:-false}" != true ]]; then
                python3 "$script_dir/excel_reporter.py" \
                    "$assessment_dir" >/dev/null 2>&1
            else
                python3 "$script_dir/excel_reporter.py" \
                    "$assessment_dir"
            fi

            local rc=$?
            echo "[DEBUG] Python exit code: $rc"

            if [[ $rc -ne 0 ]]; then
                echo "[ERROR] Excel workbook generation failed."
                return "$rc"
            fi

            echo "[DEBUG] Excel workbook generated successfully."

            # ----------------------------------------------------------------
            # Generate Consolidated HTML Assessment Report
            # ----------------------------------------------------------------
            if [[ -f "$script_dir/full_assessment_html.py" ]]; then
                local assessment_html
                assessment_html="$assessment_dir/$(basename "$assessment_dir").html"

                echo "[DEBUG] Running full assessment HTML generator..."

                if [[ "${QUIET:-false}" == true && "${VERBOSE:-false}" != true ]]; then
                    python3 "$script_dir/full_assessment_html.py" \
                        "$assessment_dir" \
                        "$assessment_html" >/dev/null 2>&1
                else
                    python3 "$script_dir/full_assessment_html.py" \
                        "$assessment_dir" \
                        "$assessment_html"
                fi

                local html_rc=$?
                echo "[DEBUG] HTML generator exit code: $html_rc"

                if [[ $html_rc -ne 0 ]]; then
                    echo "[WARNING] Consolidated HTML report generation failed."
                else
                    echo "[DEBUG] Consolidated HTML report generated successfully."
                fi
            else
                echo "[DEBUG] full_assessment_html.py not found. Skipping HTML generation."
            fi
            ;;

        *)
            echo "[DEBUG] Unknown REPORT_FORMAT: ${REPORT_FORMAT:-<unset>}"
            ;;
    esac
}