#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------------------------------------------
# Resolve Paths
# ----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config.sh"

# ----------------------------------------------------------------------------
# Load Configuration
# ----------------------------------------------------------------------------
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[!] config.sh not found:"
    echo "    $CONFIG_FILE"
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

# shellcheck disable=SC1090
source "$SCRIPT_DIR/reporter.sh"

# shellcheck disable=SC1090
source "$SCRIPT_DIR/utils.sh"

# ----------------------------------------------------------------------------
# Run Docker CIS Compliance Scan
# ----------------------------------------------------------------------------
run_docker_cis_engine() {
    # Validate configuration
    if [[ -z "${DOCKER_BENCH_DIR:-}" ]]; then
        echo "[!] DOCKER_BENCH_DIR is not defined in config.sh"
        exit 1
    fi

    if [[ ! -d "$DOCKER_BENCH_DIR" ]]; then
        echo "[!] Docker Bench for Security not found:"
        echo "    $DOCKER_BENCH_DIR"
        exit 1
    fi

    # Reuse existing assessment directory during full assessment
    if [[ -n "${CURRENT_ASSESSMENT_DIR:-}" && -d "${CURRENT_ASSESSMENT_DIR}" ]]; then
        debug "Reusing assessment directory: $CURRENT_ASSESSMENT_DIR"
    else
        local standalone_name="docker-cis-$(date +'%Y%m%d-%H%M%S')"
        init_assessment_dir "$standalone_name"
    fi

    local project_dir="$CURRENT_ASSESSMENT_DIR"
    # ------------------------------------------------------------------------
# Rebuild Assessment Directory List
# ------------------------------------------------------------------------
# engine_trivy.sh runs as a subprocess, so ALL_ASSESSMENT_DIRS does not
# survive into this shell. Reconstruct it from REPORTS_DIR.
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

debug "Detected ${#ALL_ASSESSMENT_DIRS[@]} assessment directories for compliance replication."
    local image_name="${CURRENT_ASSESSMENT_NAME%-security-assessment}"

    # Report file names
    local controls_file="$SCRIPT_DIR/../data/docker-cis-controls.csv"

    local log_report="$project_dir/${image_name}-compliance-report.log"
    local csv_report="$project_dir/${image_name}-compliance-report.csv"
    local summary_report="$project_dir/${image_name}-compliance-summary.csv"
    local json_report="$project_dir/${image_name}-compliance-report.json"
    local html_report="$project_dir/${image_name}-compliance-report.html"
    local zip_report="$project_dir/${image_name}-compliance-report.zip"

    # Banner (not shown in quiet mode)
    if [[ "${QUIET:-false}" != true || "${VERBOSE:-false}" == true ]]; then
        echo
        echo "=============================================================="
        echo " Docker CIS Compliance Scan"
        echo "=============================================================="
        echo " Benchmark  : CIS Docker Benchmark"
        echo " Engine     : Docker Bench for Security"
        echo " Output Dir : $project_dir"
        echo "=============================================================="
        echo
        echo "[*] Running Docker Bench for Security..."
        echo "[*] Sudo privileges may be required."
        echo
    fi

    # Run Docker Bench
    if [[ "${QUIET:-false}" == true && "${VERBOSE:-false}" != true ]]; then
        (
            cd "$DOCKER_BENCH_DIR"
            sudo bash docker-bench-security.sh
        ) > "$log_report" 2>&1
    else
        (
            cd "$DOCKER_BENCH_DIR"
            sudo bash docker-bench-security.sh
        ) | tee "$log_report"
    fi

    # Generate CSV, Summary CSV, and JSON
    if [[ -f "$controls_file" ]]; then
        if [[ "${QUIET:-false}" == true && "${VERBOSE:-false}" != true ]]; then
            python3 "$SCRIPT_DIR/generate_docker_cis_csv.py" \
                "$controls_file" \
                "$log_report" \
                "$csv_report" \
                "$summary_report" >/dev/null 2>&1
        else
            python3 "$SCRIPT_DIR/generate_docker_cis_csv.py" \
                "$controls_file" \
                "$log_report" \
                "$csv_report" \
                "$summary_report"
        fi
    else
        echo "[!] Control library not found:"
        echo "    $controls_file"
        return 1
    fi

    # Ensure enterprise JSON filename
    if [[ -f "$csv_report" ]]; then
        local generated_json="${csv_report%.csv}.json"
        if [[ -f "$generated_json" && "$generated_json" != "$json_report" ]]; then
            mv "$generated_json" "$json_report"
        fi
    fi

    # Generate HTML report
    if [[ -f "$csv_report" && -f "$summary_report" ]]; then
        if [[ "${QUIET:-false}" == true && "${VERBOSE:-false}" != true ]]; then
            python3 "$SCRIPT_DIR/generate_docker_cis_html.py" \
                "$csv_report" \
                "$summary_report" \
                "$html_report" >/dev/null 2>&1
        else
            python3 "$SCRIPT_DIR/generate_docker_cis_html.py" \
                "$csv_report" \
                "$summary_report" \
                "$html_report"
        fi
    fi

    # Package artifacts
    (
        cd "$project_dir"
        zip -q "$(basename "$zip_report")" \
            "$(basename "$log_report")" \
            "$(basename "$csv_report")" \
            "$(basename "$summary_report")" \
            "$(basename "$json_report")" \
            "$(basename "$html_report")" 2>/dev/null || true
    )

    # ------------------------------------------------------------------------
# Replicate Compliance Artifacts to All Assessment Directories
# ------------------------------------------------------------------------
if [[ -n "${ALL_ASSESSMENT_DIRS+x}" && ${#ALL_ASSESSMENT_DIRS[@]} -gt 1 ]]; then
    for target_dir in "${ALL_ASSESSMENT_DIRS[@]}"; do
        # Skip the directory where the compliance scan was originally generated
        if [[ "$target_dir" == "$project_dir" ]]; then
            continue
        fi

        # Ensure target directory exists
        if [[ ! -d "$target_dir" ]]; then
            continue
        fi

        # Derive the target image name from the directory name
        # Example:
        #   om-master-security-assessment
        #   -> om-master
        local target_image
        target_image="$(basename "$target_dir" | sed 's/-security-assessment$//')"

        # Destination file names using enterprise naming convention
        local target_log="$target_dir/${target_image}-compliance-report.log"
        local target_csv="$target_dir/${target_image}-compliance-report.csv"
        local target_summary="$target_dir/${target_image}-compliance-summary.csv"
        local target_json="$target_dir/${target_image}-compliance-report.json"
        local target_html="$target_dir/${target_image}-compliance-report.html"
        local target_zip="$target_dir/${target_image}-compliance-report.zip"

        # Copy and rename compliance artifacts
        cp -f "$log_report" "$target_log"
        cp -f "$csv_report" "$target_csv"
        cp -f "$summary_report" "$target_summary"
        cp -f "$json_report" "$target_json"

        if [[ -f "$html_report" ]]; then
            cp -f "$html_report" "$target_html"
        fi

        if [[ -f "$zip_report" ]]; then
            cp -f "$zip_report" "$target_zip"
        fi

        debug "Replicated compliance artifacts to: $target_dir"
    done
fi

    # Completion banner (not shown in quiet mode)
    if [[ "${QUIET:-false}" != true || "${VERBOSE:-false}" == true ]]; then
        echo
        echo "=============================================================="
        echo " Compliance Scan Completed Successfully"
        echo "=============================================================="
        echo "Log Report  : $log_report"
        echo "ZIP Package : $zip_report"
        echo "=============================================================="
        echo
    fi
}