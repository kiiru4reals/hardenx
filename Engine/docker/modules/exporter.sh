# ----------------------------------------------------------------------------
# Select Report Output Format
# ----------------------------------------------------------------------------
select_report_format() {
    echo
    echo "=============================================================="
    echo " Report Output Format"
    echo "=============================================================="
    echo " 1) Separate Reports (CSV files only)"
    echo " 2) Combined Excel Workbook (.xlsx)"
    echo " 3) Both"
    echo "=============================================================="

    read -rp "Select option [3]: " choice
    choice="${choice:-3}"

    case "$choice" in
        1)
            REPORT_FORMAT="separate"
            ;;
        2)
            REPORT_FORMAT="combined"
            ;;
        3)
            REPORT_FORMAT="both"
            ;;
        *)
            echo "[!] Invalid selection."
            exit 1
            ;;
    esac

    # Debug output only in verbose mode
    debug "REPORT_FORMAT set to: $REPORT_FORMAT"
}