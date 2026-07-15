#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Script Version
# ============================================================================
VERSION="1.0.0"

# ============================================================================
# Load Configuration
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config.sh"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[!] config.sh not found at:"
    echo "    $CONFIG_FILE"
    exit 1
fi

# Load main configuration
# shellcheck disable=SC1090
source "$CONFIG_FILE"

# Load shared reporting functions
# shellcheck disable=SC1090
source "$SCRIPT_DIR/reporter.sh"

# Load shared logging helpers (log and debug)
# shellcheck disable=SC1090
source "$SCRIPT_DIR/utils.sh"

# ============================================================================
# Validate Required Variables
# ============================================================================
REQUIRED_VARS=(
    BASE_DIR
    IMAGES_DIR
    IMPORT_DIR
    REPORTS_DIR
    SCANNERS
    SEVERITIES
    IGNORE_UNFIXED
)

for required_var in "${REQUIRED_VARS[@]}"; do
    if [[ ! -v "$required_var" || -z "${!required_var}" ]]; then
        echo "[!] Required variable '$required_var' is missing or empty in config.sh"
        exit 1
    fi
done

# ============================================================================
# Runtime Variables
# ============================================================================
TIMESTAMP="$(date +'%Y%m%d-%H%M%S')"
LOG_FILE="$BASE_DIR/scan.log"

ALL_MODE=false
CLEANUP=false
SEVERITY_OVERRIDE=""

# ============================================================================
# Usage
# ============================================================================
usage() {
    cat <<EOF
Trivy Enterprise Image Scanner v${VERSION}

Usage: ./trivy-scan [options]

Options:
  --all                 Scan all images in images/
  --cleanup             Remove image TAR after successful scan
  --severity LEVELS     Override severity list
                        Example: CRITICAL
                                 HIGH,CRITICAL
                                 CRITICAL,HIGH,MEDIUM,LOW
  -h, --help            Show this help message
EOF
}

# ============================================================================
# Dependency Check and Optional Installation
# ============================================================================
install_missing_dependencies() {
    local missing=()

    for tool in trivy jq zip; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing+=("$tool")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "[!] Missing dependencies: ${missing[*]}"
        read -rp "Install them now? [y/N]: " ans

        if [[ "$ans" =~ ^[Yy]$ ]]; then
            sudo apt update
            sudo apt install -y "${missing[@]}"
        else
            exit 1
        fi
    fi
}

# ----------------------------------------------------------------------------
# Parse Command-Line Arguments
# ----------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)
                ALL_MODE=true
                ;;
            --cleanup)
                CLEANUP=true
                ;;
            --severity)
                shift
                if [[ $# -eq 0 ]]; then
                    echo "[!] --severity requires a value"
                    exit 1
                fi
                SEVERITY_OVERRIDE="$1"
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "[!] Unknown option: $1"
                usage
                exit 1
                ;;
        esac
        shift
    done
}

# ----------------------------------------------------------------------------
# Ensure Required Directories Exist
# ----------------------------------------------------------------------------
ensure_directories() {
    mkdir -p "$BASE_DIR"
    mkdir -p "$IMAGES_DIR"
    mkdir -p "$REPORTS_DIR"
}

# ----------------------------------------------------------------------------
# Import TAR Images from a User-Specified Directory
# ----------------------------------------------------------------------------
import_images() {
    local source_dir="${1:-}"

    # Validate input
    if [[ -z "$source_dir" ]]; then
        echo "[!] No import directory specified."
        return 1
    fi

    if [[ ! -d "$source_dir" ]]; then
        echo "[!] Import directory does not exist: $source_dir"
        return 1
    fi

    # Ensure local images directory exists
    mkdir -p "$IMAGES_DIR"

    log "[*] Checking for images in $source_dir"

    # Copy TAR archives into the local images directory
    if [[ "${QUIET:-false}" == true && "${VERBOSE:-false}" != true ]]; then
        rsync -a --ignore-existing \
            --include='*.tar' \
            --exclude='*' \
            "$source_dir"/ "$IMAGES_DIR"/ >/dev/null 2>&1
    else
        rsync -av --ignore-existing \
            --include='*.tar' \
            --exclude='*' \
            "$source_dir"/ "$IMAGES_DIR"/
    fi

    log "[+] Image import completed"
}

# ----------------------------------------------------------------------------
# Load Available Images
# Supports:
#   - Docker images already pulled locally
#   - TAR files in images/
# ----------------------------------------------------------------------------
load_images() {
    IMAGE_FILES=()
    IMAGE_TYPES=()
    IMAGE_LABELS=()

    # ------------------------------------------------------------------------
    # 1. Load Docker Images Already Pulled Locally
    # ------------------------------------------------------------------------
    if command -v docker >/dev/null 2>&1; then
        while IFS= read -r image; do
            [[ -z "$image" ]] && continue
            IMAGE_FILES+=("$image")
            IMAGE_TYPES+=("docker")
            IMAGE_LABELS+=("docker:$image")
        done < <(
            docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
            | sort -u
        )
    fi

    # ------------------------------------------------------------------------
    # 2. Load TAR Files from images/
    # ------------------------------------------------------------------------
    while IFS= read -r file; do
        IMAGE_FILES+=("$file")
        IMAGE_TYPES+=("tar")
        IMAGE_LABELS+=("tar:$(basename "$file")")
    done < <(
        find "$IMAGES_DIR" -maxdepth 1 -type f -name "*.tar" | sort
    )

    # ------------------------------------------------------------------------
    # 3. Ensure at Least One Image Exists
    # ------------------------------------------------------------------------
    if [[ ${#IMAGE_FILES[@]} -eq 0 ]]; then
        echo "[!] No Docker images or TAR files found."
        echo
        echo "Options:"
        echo "  1. Pull images using Docker:"
        echo "     docker pull nginx:latest"
        echo
        echo "  2. Save images to TAR files:"
        echo "     docker save -o images/nginx.tar nginx:latest"
        echo
        echo "  3. Place TAR files in:"
        echo "     $IMAGES_DIR"
        exit 1
    fi
}

# ----------------------------------------------------------------------------
# Interactive Image Selection (supports multiple selections)
# ----------------------------------------------------------------------------
select_images() {
    # Reset selection arrays
    SELECTED_IMAGES=()
    SELECTED_TYPES=()

    local allow_multiple=true

# Full Security Assessment supports only one image
if [[ "${SCAN_MODE:-}" == "full-assessment" ]]; then
    allow_multiple=false
fi

# Prevent multiple selections in Full Assessment mode
if [[ "$allow_multiple" == false ]]; then
    if [[ "$choice" == *","* || "$choice" =~ [[:space:]] ]]; then
        echo "[!] Full Security Assessment supports only one image."
        echo "[!] Use Vulnerability Scan (-V) to scan multiple images."
        continue
    fi
fi

    # ------------------------------------------------------------------------
    # Command-Line --all Support
    # ------------------------------------------------------------------------
    if [[ "$ALL_MODE" == true ]]; then
        SELECTED_IMAGES=("${IMAGE_FILES[@]}")
        SELECTED_TYPES=("${IMAGE_TYPES[@]}")
        return
    fi
# ------------------------------------------------------------------------
# Display Available Images
# ------------------------------------------------------------------------
echo
echo " 1) Pull image from registry"
echo " 2) Scan ALL images"

for i in "${!IMAGE_FILES[@]}"; do
    printf "%2d) %s\n" $((i + 3)) "${IMAGE_LABELS[$i]}"
done

# ------------------------------------------------------------------------
# Prompt Until Valid Selection Is Made
# ------------------------------------------------------------------------
while true; do
    read -rp "Select image number(s) [2]: " choice
    choice="${choice:-2}"

    # ------------------------------------------------------------
    # Option 1: Pull Image from Registry
    # ------------------------------------------------------------
    if [[ "$choice" == "1" ]]; then
        echo
        read -rp "Enter image name (e.g. nginx:latest): " registry_image

        if [[ -z "$registry_image" ]]; then
            echo "[!] Image name cannot be empty."
            echo
            continue
        fi

        log "[*] Pulling image: $registry_image"

        if ! docker pull "$registry_image"; then
            echo "[!] Failed to pull image: $registry_image"
            echo
            continue
        fi

        # Add the pulled image directly to the selection arrays
        SELECTED_IMAGES=("$registry_image")
        SELECTED_TYPES=("docker")

        log "[+] Successfully pulled: $registry_image"
        return
    fi

    # --------------------------------------------------------------------
    # Full Security Assessment supports only one image
    # --------------------------------------------------------------------
    if [[ "${SCAN_MODE:-}" == "full-assessment" ]]; then
        if [[ "$choice" == "2" || "$choice" == *","* || "$choice" =~ [[:space:]] ]]; then
            echo "[!] Full Security Assessment supports only one image."
            echo "[!] Please select a single image number."
            echo "[!] Use Vulnerability Scan (-V) to scan multiple images."
            echo
            continue
        fi
    fi

    # ------------------------------------------------------------
    # Option 2: Scan ALL Images
    # ------------------------------------------------------------
    if [[ "$choice" == "2" ]]; then
        SELECTED_IMAGES=("${IMAGE_FILES[@]}")
        SELECTED_TYPES=("${IMAGE_TYPES[@]}")
        debug "Selected ALL images (${#SELECTED_IMAGES[@]})"
        return
    fi

    # Convert commas to spaces
    choice="${choice//,/ }"

    # Temporary arrays
    local temp_images=()
    local temp_types=()
    local valid=true

    # Process each selected number
    for token in $choice; do
        # Must be numeric
        if ! [[ "$token" =~ ^[0-9]+$ ]]; then
            valid=false
            break
        fi

        # Option 2 anywhere means scan all
        if [[ "$token" == "2" ]]; then
            temp_images=("${IMAGE_FILES[@]}")
            temp_types=("${IMAGE_TYPES[@]}")
            valid=true
            break
        fi

        # Convert menu number to array index
        local idx=$((token - 3))

        # Validate range
        if [[ "$idx" -lt 0 || "$idx" -ge "${#IMAGE_FILES[@]}" ]]; then
            valid=false
            break
        fi

        # Add selected image
        temp_images+=("${IMAGE_FILES[$idx]}")
        temp_types+=("${IMAGE_TYPES[$idx]}")
    done

    # If valid and at least one selection was made
    if [[ "$valid" == true && "${#temp_images[@]}" -gt 0 ]]; then
        SELECTED_IMAGES=("${temp_images[@]}")
        SELECTED_TYPES=("${temp_types[@]}")

        debug "Selected ${#SELECTED_IMAGES[@]} image(s)"
        return
    fi
    echo "[!] Invalid selection. Use examples like:"
    echo "    1                # Pull image from registry"
    echo "    2                # Scan ALL images"
    echo "    3                # First listed image"
    echo "    3,4,5            # Multiple listed images"
    echo
done
}
# ----------------------------------------------------------------------------
# Generate Detailed Enterprise CSV from Trivy JSON
# ----------------------------------------------------------------------------
generate_csv() {
    local json_report="$1"
    local csv_report="$2"

    jq -r '
    [
      "Finding Type",
      "Target",
      "Component Type",
      "Severity",
      "Finding ID",
      "Package",
      "Installed Version",
      "Fixed Version",
      "Title",
      "Reference URL",
      "Description"
    ],

    (
      .Results[]? as $r
      | $r.Vulnerabilities[]?
      | [
          "Vulnerability",
          $r.Target,
          ($r.Type // ""),
          (.Severity // ""),
          (.VulnerabilityID // ""),
          (.PkgName // ""),
          (.InstalledVersion // ""),
          (.FixedVersion // ""),
          ((.Title // "") | gsub("[\r\n]"; " ")),
          (.PrimaryURL // ""),
          ((.Description // "") | gsub("[\r\n]"; " ") | .[0:1000])
        ]
    ),

    (
      .Results[]? as $r
      | $r.Secrets[]?
      | [
          "Secret",
          $r.Target,
          ($r.Type // ""),
          (.Severity // "HIGH"),
          (.RuleID // ""),
          "",
          "",
          "",
          ((.Title // .RuleID // "Secret Detected") | gsub("[\r\n]"; " ")),
          "",
          ((.Match // "") | gsub("[\r\n]"; " ") | .[0:1000])
        ]
    ),

    (
      .Results[]? as $r
      | $r.Misconfigurations[]?
      | [
          "Misconfiguration",
          $r.Target,
          ($r.Type // ""),
          (.Severity // ""),
          (.ID // ""),
          "",
          "",
          "",
          ((.Title // "") | gsub("[\r\n]"; " ")),
          (.PrimaryURL // ""),
          ((.Description // "") | gsub("[\r\n]"; " ") | .[0:1000])
        ]
    )

    | @csv
    ' "$json_report" > "$csv_report"
}

# ----------------------------------------------------------------------------
# Generate Executive Summary CSV
# ----------------------------------------------------------------------------
generate_summary() {
    local image_name="$1"
    local csv_report="$2"
    local summary_report="$3"

    local critical_count high_count medium_count low_count
    local secret_count misconfig_count total_findings

    critical_count=$(grep -c ',"CRITICAL",' "$csv_report" || true)
    high_count=$(grep -c ',"HIGH",' "$csv_report" || true)
    medium_count=$(grep -c ',"MEDIUM",' "$csv_report" || true)
    low_count=$(grep -c ',"LOW",' "$csv_report" || true)

    secret_count=$(grep -c '^"Secret"' "$csv_report" || true)
    misconfig_count=$(grep -c '^"Misconfiguration"' "$csv_report" || true)

    total_findings=$(( $(wc -l < "$csv_report") - 1 ))
    if [[ "$total_findings" -lt 0 ]]; then
        total_findings=0
    fi

    {
        echo "Image,Critical,High,Medium,Low,Secrets,Misconfigurations,TotalFindings,ScanDate"
        printf "%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
            "$image_name" \
            "$critical_count" \
            "$high_count" \
            "$medium_count" \
            "$low_count" \
            "$secret_count" \
            "$misconfig_count" \
            "$total_findings" \
            "$(date '+%F %T')"
    } > "$summary_report"
}

# ----------------------------------------------------------------------------
# Optional HTML Report
# ----------------------------------------------------------------------------
generate_html() {
    local input="$1"
    local severities="$2"
    local html_report="$3"

    if [[ -n "${HTML_TEMPLATE:-}" && -f "$HTML_TEMPLATE" ]]; then
        trivy image \
            --input "$input" \
            --severity "$severities" \
            --format template \
            --template "@$HTML_TEMPLATE" \
            --output "$html_report" || true
    fi
}

# ----------------------------------------------------------------------------
# ZIP All Reports
# ----------------------------------------------------------------------------
package_reports() {
    local project_dir="$1"
    local zip_report="$2"

    (
        cd "$project_dir"
        zip -q "$(basename "$zip_report")" ./* || true
    )
}

# ----------------------------------------------------------------------------
# Scan a Single Image
# ----------------------------------------------------------------------------
run_scan() {
    local input="$1"
    local input_type="${2:-tar}"
    local severities="${SEVERITY_OVERRIDE:-$SEVERITIES}"

    # ------------------------------------------------------------------------
    # Determine a Filesystem-Safe Image Name
    # ------------------------------------------------------------------------
    local image_name
    if [[ "$input_type" == "docker" ]]; then
        image_name="$(echo "$input" | sed 's|[/:]|-|g')"
    else
        image_name="$(basename "$input" .tar)"
    fi

    # ------------------------------------------------------------------------
    # Validate TAR Archive Integrity
    # ------------------------------------------------------------------------
    if [[ "$input_type" == "tar" ]]; then
        if ! tar -tf "$input" >/dev/null 2>&1; then
            log "[!] Invalid or corrupted TAR archive: $input"
            return 1
        fi
    fi

    # ------------------------------------------------------------------------
    # Create a Dedicated Assessment Directory for This Image
    # ------------------------------------------------------------------------
    local assessment_name="${image_name}-security-assessment"
    init_assessment_dir "$assessment_name"

    local project_dir="$CURRENT_ASSESSMENT_DIR"

    # ------------------------------------------------------------------------
    # Report Paths (Enterprise Naming Convention)
    # ------------------------------------------------------------------------
    local vuln_base="${image_name}-vulnerability-report"

    local json_report="$project_dir/${vuln_base}.json"
    local csv_report="$project_dir/${vuln_base}.csv"
    local summary_report="$project_dir/${image_name}-vulnerability-summary.csv"
    local html_report="$project_dir/${vuln_base}.html"
    local zip_report="$project_dir/${vuln_base}.zip"

    log "[*] Scanning $image_name"
    log "[*] Severity filter: $severities"

    # ------------------------------------------------------------------------
    # Build Trivy Command
    # ------------------------------------------------------------------------
    local trivy_cmd=(trivy image --quiet)

    if [[ "$input_type" == "docker" ]]; then
        trivy_cmd+=("$input")
    else
        trivy_cmd+=(--input "$input")
    fi

    trivy_cmd+=(
        --scanners "$SCANNERS"
        --severity "$severities"
        --format json
        --output "$json_report"
    )

    if [[ "$IGNORE_UNFIXED" == "true" ]]; then
        trivy_cmd+=(--ignore-unfixed)
    fi
    # ------------------------------------------------------------------------
    # Execute Trivy
    # ------------------------------------------------------------------------
    if ! "${trivy_cmd[@]}"; then
        echo "[!] Trivy scan failed."
        return 1
    fi

    # Ensure JSON report was created successfully
    if [[ ! -f "$json_report" ]]; then
        echo "[!] Trivy failed to generate JSON report:"
        echo "    $json_report"
        return 1
    fi

    # ------------------------------------------------------------------------


# ------------------------------------------------------------------------
# Generate Reports
# ------------------------------------------------------------------------
generate_csv "$json_report" "$csv_report"
generate_summary "$image_name" "$csv_report" "$summary_report"

# ------------------------------------------------------------------------
# Generate HTML Vulnerability Report
# ------------------------------------------------------------------------
if [[ -f "$SCRIPT_DIR/generate_vulnerability_html.py" ]]; then
    if [[ "${QUIET:-false}" == true && "${VERBOSE:-false}" != true ]]; then
        python3 "$SCRIPT_DIR/generate_vulnerability_html.py" \
            "$csv_report" \
            "$summary_report" \
            "$html_report" >/dev/null 2>&1
    else
        python3 "$SCRIPT_DIR/generate_vulnerability_html.py" \
            "$csv_report" \
            "$summary_report" \
            "$html_report"
    fi
else
    # Fallback to Trivy template-based HTML if custom generator is unavailable
    generate_html "$json_report" "$severities" "$html_report"
fi

    # ------------------------------------------------------------------------
    # Display Scan Results (suppressed in quiet mode)
    # ------------------------------------------------------------------------
    if [[ "${QUIET:-false}" != true || "${VERBOSE:-false}" == true ]]; then
        echo
        echo "Image       : $(basename "$input")"
        echo "Reports Dir : $project_dir"
    fi

    # ------------------------------------------------------------------------
    # Count CRITICAL Findings
    # ------------------------------------------------------------------------
    local critical_count
    critical_count=$(grep -c ',"CRITICAL",' "$csv_report" || true)

    # ------------------------------------------------------------------------
    # Package Reports
    # ------------------------------------------------------------------------
    package_reports "$project_dir" "$zip_report"

    if [[ "$critical_count" -gt 0 ]]; then
        return 10
    fi

    return 0
}
main() {
    echo

    parse_args "$@"
    install_missing_dependencies
    ensure_directories

    # ------------------------------------------------------------------------
    # Optional Image Import
    # ------------------------------------------------------------------------
    # Allows the user to import TAR archives from any directory into the local
    # images/ folder. Press Enter or choose No to skip.
    if [[ "${QUIET:-false}" != true || "${VERBOSE:-false}" == true ]]; then
        echo
        read -rp "Would you like to import image archives from another directory? [y/N]: " import_choice
        import_choice="${import_choice:-N}"

        if [[ "$import_choice" =~ ^[Yy]$ ]]; then
            read -rp "Enter directory path: " IMAGE_IMPORT_DIR

            if [[ -n "$IMAGE_IMPORT_DIR" && -d "$IMAGE_IMPORT_DIR" ]]; then
                log "[*] Importing image archives from: $IMAGE_IMPORT_DIR"
                import_images "$IMAGE_IMPORT_DIR"
            else
                echo "[!] Directory not found: $IMAGE_IMPORT_DIR"
            fi
        fi
    fi

    # ------------------------------------------------------------------------
    # Load Available Images and Prompt for Selection
    # ------------------------------------------------------------------------
    load_images
    select_images

    local exit_code=0

    # ------------------------------------------------------------------------
    # Scan All Selected Images
    # ------------------------------------------------------------------------
    for i in "${!SELECTED_IMAGES[@]}"; do
        local image="${SELECTED_IMAGES[$i]}"
        local image_type="${SELECTED_TYPES[$i]}"

        debug "Processing image $((i + 1)) of ${#SELECTED_IMAGES[@]}: $image"

        # Run scan without allowing set -e to terminate the script
        local scan_rc=0

        if run_scan "$image" "$image_type"; then
            scan_rc=0
        else
            scan_rc=$?
        fi

        case "$scan_rc" in
            0)
                ;;
            10)
                log "[!] CRITICAL vulnerabilities detected in: $image"
                if [[ "$exit_code" -eq 0 ]]; then
                    exit_code=10
                fi
                ;;
            *)
                log "[!] Scan failed for: $image"
                exit_code=1
                ;;
        esac
    done

    return "$exit_code"
}

# ----------------------------------------------------------------------------
# Execute Only When Run Directly
# ----------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

# ----------------------------------------------------------------------------
# Save Reports Menu
# ----------------------------------------------------------------------------
save_reports_menu() {
    local project_dir="${1:-}"

    echo
    echo " Reports are automatically stored in:"
    echo "   $REPORTS_DIR"
    echo
}