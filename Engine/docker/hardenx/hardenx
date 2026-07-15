#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# HardenX v2.0.0-alpha
# Scan. Harden. Comply.
# ============================================================================

VERSION="2.0.0-alpha"

# ----------------------------------------------------------------------------
# Resolve Paths
# ----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES_DIR="$SCRIPT_DIR/modules"
CONFIG_FILE="$SCRIPT_DIR/config.sh"

# ----------------------------------------------------------------------------
# Validate Configuration
# ----------------------------------------------------------------------------
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[!] config.sh not found:"
    echo "    $CONFIG_FILE"
    exit 1
fi

# ----------------------------------------------------------------------------
# Load Modules
# ----------------------------------------------------------------------------
# shellcheck disable=SC1090
source "$CONFIG_FILE"

for module in \
    "$MODULES_DIR/utils.sh" \
    "$MODULES_DIR/reporter.sh" \
    "$MODULES_DIR/exporter.sh" \
    "$MODULES_DIR/engine_trivy_wrapper.sh"
do
    if [[ -f "$module" ]]; then
        # shellcheck disable=SC1090
        source "$module"
    fi
done

# ----------------------------------------------------------------------------
# Show Banner
# ----------------------------------------------------------------------------
show_banner() {
    # Suppress banner in quiet mode unless verbose mode is enabled
    if [[ "${QUIET:-false}" == true && "${VERBOSE:-false}" != true ]]; then
        return
    fi

    echo "=============================================================="
    echo " HardenX v${VERSION}"
    echo " Scan. Harden. Comply."
    echo "=============================================================="
    echo
}

# ----------------------------------------------------------------------------
# Usage
# ----------------------------------------------------------------------------
usage() {
    show_banner

    cat <<EOF
Usage: ./hardenx [options]

Options:
  -V, --vulnerability-scan   Run Vulnerability Scan
                             Detect vulnerabilities, secrets, and
                             configuration issues in Docker images.

  -C, --docker-cis           Run Docker CIS Compliance Scan
                             Validate the Docker host against the
                             CIS Docker Benchmark.

  -A, --full-assessment      Run Full Security Assessment
                             Execute both vulnerability and compliance scans.

  -q, --quiet                Minimal console output

  -v, --verbose              Debug-level output

  -H, -h, --help             Show this help message

Examples:
  ./hardenx
  ./hardenx -V
  ./hardenx -C
  ./hardenx -A
  ./hardenx -A --quiet
  ./hardenx -A --verbose
EOF
}

# ----------------------------------------------------------------------------
# Interactive Menu
# ----------------------------------------------------------------------------
interactive_menu() {
    echo "Select Scan Mode"
    echo "--------------------------------------------------------------"
    echo " 1) Vulnerability Scan"
    echo " 2) Docker CIS Compliance Scan"
    echo " 3) Full Security Assessment (Recommended)"
    echo "--------------------------------------------------------------"
    echo

    read -rp "Select option [3]: " choice
    choice="${choice:-3}"

    case "$choice" in
        1) SCAN_MODE="vulnerability-scan" ;;
        2) SCAN_MODE="docker-cis" ;;
        3) SCAN_MODE="full-assessment" ;;
        *)
            echo "[!] Invalid selection."
            exit 1
            ;;
    esac
}

# ----------------------------------------------------------------------------
# Parse Arguments
# ----------------------------------------------------------------------------
SCAN_MODE=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -V|--vulnerability-scan)
                SCAN_MODE="vulnerability-scan"
                ;;
            -C|--docker-cis)
                SCAN_MODE="docker-cis"
                ;;
            -A|--full-assessment)
                SCAN_MODE="full-assessment"
                ;;
            -q|--quiet)
                QUIET=true
                ;;
            -v|--verbose)
                VERBOSE=true
                ;;
            -H|-h|--help)
                usage
                exit 0
                ;;
            *)
                echo "[!] Unknown option: $1"
                echo
                usage
                exit 1
                ;;
        esac
        shift
    done
}

# ----------------------------------------------------------------------------
# Engine Dispatcher
# ----------------------------------------------------------------------------
run_selected_engines() {
    case "$SCAN_MODE" in
        vulnerability-scan)
            run_trivy_engine
            ;;

        docker-cis)
            if [[ -f "$MODULES_DIR/engine_docker_cis.sh" ]]; then
                # shellcheck disable=SC1090
                source "$MODULES_DIR/engine_docker_cis.sh"
                run_docker_cis_engine
            else
                echo "[!] Docker CIS engine not available."
                exit 1
            fi
            ;;

        full-assessment)
            # Step 1: Run vulnerability assessment
            run_trivy_engine || true

            # Preserve the shared assessment directory created by Trivy
            local saved_assessment_dir="${CURRENT_ASSESSMENT_DIR:-}"
            local saved_assessment_name="${CURRENT_ASSESSMENT_NAME:-}"

            # Debug output only when --verbose is enabled
            debug "Saved assessment directory: $saved_assessment_dir"
            debug "Saved assessment name: $saved_assessment_name"

            # Step 2: Run Docker CIS compliance assessment
            if [[ -f "$MODULES_DIR/engine_docker_cis.sh" ]]; then
                # shellcheck disable=SC1090
                source "$MODULES_DIR/engine_docker_cis.sh"

                # Restore assessment variables after sourcing
                CURRENT_ASSESSMENT_DIR="$saved_assessment_dir"
                CURRENT_ASSESSMENT_NAME="$saved_assessment_name"

                # Debug output only when --verbose is enabled
                debug "Restored assessment directory: $CURRENT_ASSESSMENT_DIR"
                debug "Restored assessment name: $CURRENT_ASSESSMENT_NAME"

                # Run compliance assessment
                run_docker_cis_engine
            else
                echo "[!] Docker CIS engine not available."
                exit 1
            fi
            ;;

        *)
            echo "[!] No scan mode selected."
            exit 1
            ;;
    esac
}



# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
    # Parse command-line arguments FIRST so QUIET and VERBOSE are set
    parse_args "$@"

    # Show banner unless quiet mode is enabled
    show_banner

    # If no scan mode was specified, show interactive menu
    if [[ -z "${SCAN_MODE:-}" ]]; then
        interactive_menu
    fi

    # Ask once which report format to generate
    # (Menus remain visible even in quiet mode)
    select_report_format

    # Run the selected scan engine(s)
    run_selected_engines



    # Rebuild Assessment Directory List
    # ------------------------------------------------------------------------
    # engine_trivy.sh runs as a subprocess, so arrays created there are not
    # available in this parent shell. Reconstruct the list from REPORTS_DIR.
    ALL_ASSESSMENT_DIRS=()

    if [[ -d "$REPORTS_DIR" ]]; then
        while IFS= read -r dir; do
            ALL_ASSESSMENT_DIRS+=("$dir")
        done < <(
            find "$REPORTS_DIR" \
                -mindepth 1 \
                -maxdepth 1 \
                -type d \
                ! -name 'compliance' \
                | sort
        )
    fi

    # Recover the newest report directory if needed
    if [[ -z "${CURRENT_ASSESSMENT_DIR:-}" || ! -d "${CURRENT_ASSESSMENT_DIR:-}" ]]; then
        CURRENT_ASSESSMENT_DIR="$(
            ls -1dt "$REPORTS_DIR"/*/ 2>/dev/null | head -1 | sed 's:/$::'
        )"
    fi

    # ------------------------------------------------------------------------
    # Generate Excel Workbook(s)
    # ------------------------------------------------------------------------
    if [[ -n "${ALL_ASSESSMENT_DIRS+x}" && ${#ALL_ASSESSMENT_DIRS[@]} -gt 0 ]]; then
        # Multiple image scans: generate one workbook per assessment directory
        for dir in "${ALL_ASSESSMENT_DIRS[@]}"; do
            if [[ -d "$dir" ]]; then
                log "[*] Generating consolidated Excel workbook for $(basename "$dir")..."

                if [[ "${QUIET:-false}" == true && "${VERBOSE:-false}" != true ]]; then
                    generate_excel_report "$dir" >/dev/null 2>&1
                else
                    generate_excel_report "$dir"
                fi
            fi
        done

    elif [[ -n "${CURRENT_ASSESSMENT_DIR:-}" && -d "${CURRENT_ASSESSMENT_DIR}" ]]; then
        # Single-image scan fallback
        log "[*] Generating consolidated Excel workbook..."

        if [[ "${QUIET:-false}" == true && "${VERBOSE:-false}" != true ]]; then
            generate_excel_report "$CURRENT_ASSESSMENT_DIR" >/dev/null 2>&1
        else
            generate_excel_report "$CURRENT_ASSESSMENT_DIR"
        fi

    else
        echo "[!] Unable to determine assessment directory."
        echo "[!] Excel workbook generation skipped."
    fi

    # ------------------------------------------------------------------------
    # Final Report Location (Always Shown)
    # ------------------------------------------------------------------------
    echo
    echo "Reports are stored under: $REPORTS_DIR"
    echo
}

# ----------------------------------------------------------------------------
# Script Entry Point
# ----------------------------------------------------------------------------
main "$@"