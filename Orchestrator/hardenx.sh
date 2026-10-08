#!/usr/bin/env bash
# =============================================================================
# HardenX — CIS Compliance & Infrastructure Hardening Engine
# Component : hardenx.sh (Orchestrator)
# Version   : 0.1
# =============================================================================

set -euo pipefail

# =============================================================================
# TRAP — registered first, before anything else runs
# =============================================================================

cleanup() {
    echo ""
    echo "[INTERRUPTED] Scan interrupted by operator."
    echo "[TEARDOWN]    Running cleanup..."
    # Orchestrator-level cleanup only.
    # Engine-level teardown (e.g. Docker registry logout) is handled by each
    # engine's own SIGINT/SIGTERM trap, which fires independently.
    if [[ -n "${OUTPUT_DIR:-}" ]]; then
        echo ""
        echo "Partial output files may exist in: ${OUTPUT_DIR}"
    fi
    echo "[TEARDOWN]    Done."
    echo "HardenX exited."
    exit 1
}

trap cleanup SIGINT SIGTERM

# =============================================================================
# CONSTANTS
# =============================================================================

readonly HARDENX_VERSION="0.1"
readonly DIVIDER="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Paths are resolved relative to the Orchestrator directory hardenx.sh lives in.
# The project root sits one level up.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

readonly RESEARCHER="${PROJECT_ROOT}/Researcher/researcher.sh"

declare -A ENGINE_SCRIPTS=(
    [ubuntu]="${PROJECT_ROOT}/Engine/ubuntu/cis_checks.sh"
    [rocky]="${PROJECT_ROOT}/Engine/rocky-linux/cis_checks.sh"
    [postgresql]="${PROJECT_ROOT}/Engine/postgres/postgres_cis_checks.sh"
    [docker]="${PROJECT_ROOT}/Engine/docker/cis_checks.sh"
    [kubernetes]="${PROJECT_ROOT}/Engine/kubernetes/cis_checks.sh"
)

# Fixed engine invocation priority order
readonly ENGINE_PRIORITY_ORDER=("ubuntu" "rocky" "postgresql" "docker" "kubernetes")

# Valid --tech values
readonly VALID_TECH_VALUES=("ubuntu" "rocky" "postgresql" "docker" "kubernetes")

# Engines that carry OS_DEPENDENT checks — used for the footer Note line
readonly OS_DEPENDENT_ENGINES=("docker" "kubernetes")

# Flags each engine currently accepts. Engines reject flags they do not know,
# so only the supported subset is forwarded.
declare -A ENGINE_FLAGS=(
    [ubuntu]="level output-dir scan-id"
    [rocky]=""
    [postgresql]="output-dir"
    [docker]="level output-dir scan-id image sbom-format"
    [kubernetes]="level output-dir scan-id"
)

# Report file each engine writes to the output directory, for the footer.
# Empty means the engine does not write a report there yet.
declare -A ENGINE_REPORT_GLOBS=(
    [ubuntu]="hardenx_ubuntu_*.csv"
    [rocky]=""
    [postgresql]="postgres_compliance_*.csv"
    [docker]=""
    [kubernetes]="hardenx_kubernetes_*.csv"
)

# =============================================================================
# DEFAULTS
# =============================================================================

LEVEL=1
TECH=""
IMAGE=""
SBOM_FORMAT="cyclonedx"
OUTPUT_DIR="."

# =============================================================================
# RUNTIME STATE
# =============================================================================

SCAN_ID=""
SCAN_START_EPOCH=""
HOSTNAME_TARGET=""
SCAN_HAS_ENGINE_FAILURE=false
SCAN_HAS_MID_SCAN_STOP=false

# Associative array to track per-engine outcomes for the footer
# Values: "ok" | "failed" | "stopped" | "skipped"
declare -A ENGINE_OUTCOMES=()

# Ordered list of engines actually invoked, for footer output
ENGINES_INVOKED=()

# Researcher JSON output path (set once the Researcher runs)
RESEARCHER_JSON=""

# =============================================================================
# HELP
# =============================================================================

print_help() {
    echo "${DIVIDER}"
    echo " HardenX — CIS Compliance & Infrastructure Hardening Engine"
    echo "${DIVIDER}"
    echo ""
    echo "USAGE"
    echo "  bash hardenx.sh [OPTIONS]"
    echo ""
    echo "OPTIONS"
    echo "  --level <1|2>"
    echo "      Scan level to run."
    echo "      Level 1 — Essential, foundational CIS controls. (default)"
    echo "      Level 2 — Defence-in-depth controls. Includes all Level 1 checks."
    echo ""
    echo "  --tech <technology>"
    echo "      Run a single-technology scan, bypassing the Researcher."
    echo "      Valid values: ubuntu | rocky | postgresql | docker | kubernetes"
    echo "      If omitted, the Researcher auto-detects all active technologies."
    echo ""
    echo "  --image <image:tag>"
    echo "      Target container image for Docker and Kubernetes image-level checks."
    echo "      Passed through to the relevant Engine(s)."
    echo "      Example: myrepo/myapp:latest"
    echo "      Example: 123456789.dkr.ecr.eu-west-1.amazonaws.com/myapp:v1.2"
    echo ""
    echo "  --sbom-format <cyclonedx|spdx>"
    echo "      SBOM output format for Docker Scout."
    echo "      Defaults to cyclonedx if not specified."
    echo ""
    echo "  --output-dir <path>"
    echo "      Directory to write all output files."
    echo "      Defaults to the current directory if not specified."
    echo ""
    echo "  --help"
    echo "      Display this help menu and exit."
    echo ""
    echo "DEFAULTS"
    echo "  If invoked with no arguments:"
    echo "    --level 1  --output-dir .  --sbom-format cyclonedx  (Researcher auto-detection)"
    echo ""
    echo "EXAMPLES"
    echo "  Full auto-detected scan at Level 1 (default):"
    echo "    bash hardenx.sh"
    echo ""
    echo "  Full auto-detected scan at Level 2:"
    echo "    bash hardenx.sh --level 2"
    echo ""
    echo "  Single-technology scan — Docker at Level 2 with an image:"
    echo "    bash hardenx.sh --tech docker --level 2 --image myrepo/myapp:latest"
    echo ""
    echo "  Full scan with a specific output directory:"
    echo "    bash hardenx.sh --output-dir /opt/hardenx/output"
    echo ""
    echo "NOTES"
    echo "  - sudo or root access is required for OS-level and daemon-level checks."
    echo "  - All output files are written to the directory specified by --output-dir."
    echo "  - Using --tech bypasses the Researcher and runs the engine script only."
    echo "    Engines with OS-dependent checks (e.g. docker, kubernetes) will mark"
    echo "    those checks SKIPPED when no OS engine report is present. Use"
    echo "    auto-detection mode for a complete scan."
    echo "  - See the individual engine documentation for technology-specific requirements."
    echo ""
    echo "${DIVIDER}"
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --level)
                if [[ -z "${2:-}" ]]; then
                    echo "[ERROR] --level requires a value: 1 or 2." >&2
                    exit 2
                fi
                if [[ "$2" != "1" && "$2" != "2" ]]; then
                    echo "[ERROR] Invalid value for --level: \"$2\"" >&2
                    echo "        Valid values: 1 | 2" >&2
                    exit 2
                fi
                LEVEL="$2"
                shift 2
                ;;
            --tech)
                if [[ -z "${2:-}" ]]; then
                    echo "[ERROR] --tech requires a value." >&2
                    echo "        Valid values: ubuntu | rocky | postgresql | docker | kubernetes" >&2
                    exit 2
                fi
                TECH="$2"
                shift 2
                ;;
            --image)
                if [[ -z "${2:-}" ]]; then
                    echo "[ERROR] --image requires a value (e.g. myrepo/myapp:latest)." >&2
                    exit 2
                fi
                IMAGE="$2"
                shift 2
                ;;
            --sbom-format)
                if [[ -z "${2:-}" ]]; then
                    echo "[ERROR] --sbom-format requires a value: cyclonedx or spdx." >&2
                    exit 2
                fi
                if [[ "$2" != "cyclonedx" && "$2" != "spdx" ]]; then
                    echo "[ERROR] Invalid value for --sbom-format: \"$2\"" >&2
                    echo "        Valid values: cyclonedx | spdx" >&2
                    exit 2
                fi
                SBOM_FORMAT="$2"
                shift 2
                ;;
            --output-dir)
                if [[ -z "${2:-}" ]]; then
                    echo "[ERROR] --output-dir requires a path." >&2
                    exit 2
                fi
                OUTPUT_DIR="$2"
                shift 2
                ;;
            --help)
                print_help
                exit 0
                ;;
            *)
                echo "[ERROR] Unrecognised option: \"$1\"" >&2
                echo "        Run 'bash hardenx.sh --help' for usage information." >&2
                exit 2
                ;;
        esac
    done
}

# =============================================================================
# VALIDATION
# =============================================================================

validate_tech() {
    local tech="$1"
    local valid
    for valid in "${VALID_TECH_VALUES[@]}"; do
        if [[ "$tech" == "$valid" ]]; then
            return 0
        fi
    done
    echo "[ERROR] Unrecognised value for --tech: \"${tech}\""
    echo "        Valid values: ubuntu | rocky | postgresql | docker | kubernetes"
    echo ""
    echo "        No scan was run."
    exit 2
}

validate_output_dir() {
    if [[ ! -d "${OUTPUT_DIR}" ]]; then
        echo "[ERROR] Output directory is not writable or does not exist: ${OUTPUT_DIR}"
        echo ""
        echo "        No scan was run."
        exit 2
    fi
    if [[ ! -w "${OUTPUT_DIR}" ]]; then
        echo "[ERROR] Output directory is not writable or does not exist: ${OUTPUT_DIR}"
        echo ""
        echo "        No scan was run."
        exit 2
    fi
}

# =============================================================================
# ENSURE SCRIPTS ARE EXECUTABLE
# =============================================================================

ensure_scripts_executable() {
    local scripts=("${RESEARCHER}")
    local tech
    for tech in "${VALID_TECH_VALUES[@]}"; do
        scripts+=("${ENGINE_SCRIPTS[$tech]}")
    done

    local script
    for script in "${scripts[@]}"; do
        if [[ -f "$script" && ! -x "$script" ]]; then
            chmod +x "$script"
        fi
    done
}

# =============================================================================
# PRE-FLIGHT: ENGINE SCRIPT CHECKS
# =============================================================================

preflight_engines_auto() {
    # Auto-detection mode: all five engine scripts must be present
    local missing=false
    local tech
    for tech in "${VALID_TECH_VALUES[@]}"; do
        local script="${ENGINE_SCRIPTS[$tech]}"
        if [[ ! -f "$script" || ! -x "$script" ]]; then
            echo "[ERROR] Engine script not found for: ${tech}"
            echo "        The HardenX bundle may be incomplete or corrupted."
            echo ""
            echo "        Expected location : ${script}"
            echo "        Scan ID           : ${SCAN_ID}"
            echo ""
            missing=true
        fi
    done
    if [[ "$missing" == true ]]; then
        echo "        No scan was run."
        exit 5
    fi
}

preflight_engine_single() {
    local tech="$1"
    local script="${ENGINE_SCRIPTS[$tech]}"
    if [[ ! -f "$script" || ! -x "$script" ]]; then
        echo "[ERROR] Engine script not found for: ${tech}"
        echo "        The HardenX bundle may be incomplete or corrupted."
        echo ""
        echo "        Expected location : ${script}"
        echo "        Scan ID           : ${SCAN_ID}"
        echo ""
        echo "        No scan was run."
        exit 5
    fi
}

preflight_researcher() {
    if [[ ! -f "${RESEARCHER}" || ! -x "${RESEARCHER}" ]]; then
        echo "[ERROR] Researcher script not found: researcher.sh"
        echo "        The HardenX bundle may be incomplete or corrupted."
        echo ""
        echo "        Expected location : ${RESEARCHER}"
        echo "        Scan ID           : ${SCAN_ID}"
        echo ""
        echo "        No scan was run."
        exit 5
    fi
}

# =============================================================================
# SCAN HEADER
# =============================================================================

print_scan_header() {
    local mode="$1"
    HOSTNAME_TARGET="$(hostname)"
    echo "${DIVIDER}"
    echo " HardenX — CIS Compliance & Infrastructure Hardening Engine"
    echo " Scan ID  : ${SCAN_ID}"
    echo " Host     : ${HOSTNAME_TARGET}"
    echo " Level    : ${LEVEL}"
    echo " Mode     : ${mode}"
    echo "${DIVIDER}"
}

# =============================================================================
# ENGINE INVOCATION
# =============================================================================

join_by() {
    # join_by <separator> <item>...
    local sep="$1"
    shift
    local out="${1:-}"
    shift || true
    local item
    for item in "$@"; do
        out+="${sep}${item}"
    done
    echo "$out"
}

build_engine_args() {
    # Populate ENGINE_ARGS with the flags the given engine accepts
    local tech="$1"
    local flag
    ENGINE_ARGS=()
    for flag in ${ENGINE_FLAGS[$tech]}; do
        case "$flag" in
            level)       ENGINE_ARGS+=("--level" "${LEVEL}") ;;
            output-dir)  ENGINE_ARGS+=("--output-dir" "${OUTPUT_DIR}") ;;
            scan-id)     ENGINE_ARGS+=("--scan-id" "${SCAN_ID}") ;;
            image)       [[ -n "${IMAGE}" ]] && ENGINE_ARGS+=("--image" "${IMAGE}") ;;
            sbom-format) ENGINE_ARGS+=("--sbom-format" "${SBOM_FORMAT}") ;;
        esac
    done
    return 0
}

invoke_engine() {
    local tech="$1"
    local script="${ENGINE_SCRIPTS[$tech]}"
    local exit_code=0

    echo ""
    echo "[INFO] Invoking engine: ${tech}"

    build_engine_args "$tech"
    bash "${script}" "${ENGINE_ARGS[@]}" || exit_code=$?

    ENGINES_INVOKED+=("$tech")

    case "$exit_code" in
        0)
            ENGINE_OUTCOMES[$tech]="ok"
            echo "[INFO] Engine complete: ${tech}"
            ;;
        4)
            ENGINE_OUTCOMES[$tech]="stopped"
            SCAN_HAS_MID_SCAN_STOP=true
            echo ""
            echo "[ERROR] Technology unavailable: ${tech}"
            echo "        The ${tech} service stopped or became unreachable during the scan."
            echo "        The ${tech} engine has exited. Remaining engines will still run."
            echo "        Partial findings up to the point of failure have been retained."
            echo "        Scan ID: ${SCAN_ID}"
            ;;
        *)
            ENGINE_OUTCOMES[$tech]="failed"
            SCAN_HAS_ENGINE_FAILURE=true
            echo ""
            echo "[ERROR] Engine failed: ${tech} (exit code ${exit_code})"
            echo "        The ${tech} engine encountered an unexpected error and did not complete."
            echo "        Remaining engines will still run."
            echo "        Please report this issue with the scan_id: ${SCAN_ID}"
            ;;
    esac
}

# =============================================================================
# AUTO-DETECTION MODE
# =============================================================================

run_auto_detection() {
    echo ""
    echo "[INFO] Starting Researcher..."

    local researcher_exit=0
    bash "${RESEARCHER}" --output-dir "${OUTPUT_DIR}" --scan-id "${SCAN_ID}" || researcher_exit=$?

    if [[ "$researcher_exit" -eq 3 ]]; then
        echo ""
        echo "[INFO] No supported technologies detected. Nothing to scan. HardenX will exit."
        exit 3
    fi

    if [[ "$researcher_exit" -ne 0 ]]; then
        echo "[ERROR] Researcher exited with code ${researcher_exit}. Cannot determine which engines to invoke."
        echo "        Scan ID: ${SCAN_ID}"
        exit 2
    fi

    # Locate the researcher JSON output for this scan (matched on scan_id so a
    # stale file from an earlier run is never picked up)
    RESEARCHER_JSON=$(grep -l "\"scan_id\": \"${SCAN_ID}\"" \
        "${OUTPUT_DIR}"/hardenx_researcher_*.json 2>/dev/null | sort | tail -n 1 || true)

    if [[ -z "${RESEARCHER_JSON}" ]]; then
        echo "[ERROR] Researcher completed but no output JSON was found in: ${OUTPUT_DIR}"
        echo "        Scan ID: ${SCAN_ID}"
        exit 2
    fi

    # Parse engines_to_invoke from the JSON
    # Uses grep/sed to avoid a hard dependency on jq
    local engines_raw
    engines_raw=$(grep -o '"engines_to_invoke"[[:space:]]*:[[:space:]]*\[[^]]*\]' "${RESEARCHER_JSON}" \
        | sed 's/^[^[]*//' | grep -o '"[a-z_]*"' | tr -d '"' || true)

    # The Researcher reports Rocky Linux as "rocky_linux"; the engine key is "rocky"
    engines_raw="${engines_raw//rocky_linux/rocky}"

    if [[ -z "$engines_raw" ]]; then
        echo ""
        echo "[INFO] No supported technologies detected. Nothing to scan. HardenX will exit."
        exit 3
    fi

    # Build the ordered invocation list from the fixed priority order
    local ordered_engines=()
    local tech
    for tech in "${ENGINE_PRIORITY_ORDER[@]}"; do
        if echo "$engines_raw" | grep -qw "$tech"; then
            ordered_engines+=("$tech")
        fi
    done

    local detected_list
    detected_list=$(join_by ", " "${ordered_engines[@]}")
    local arrow_list
    arrow_list=$(join_by " → " "${ordered_engines[@]}")

    echo "[INFO] Researcher complete. Technologies detected: ${detected_list}"
    echo "[INFO] Invoking engines in order: ${arrow_list}"

    for tech in "${ordered_engines[@]}"; do
        invoke_engine "$tech"
    done

    echo ""
    echo "[INFO] All engines complete."
}

# =============================================================================
# SINGLE-TECHNOLOGY MODE
# =============================================================================

run_single_tech() {
    local tech="$1"
    invoke_engine "$tech"
    echo ""
    echo "[INFO] Engine complete."
}

# =============================================================================
# SCAN FOOTER
# =============================================================================

is_os_dependent_engine() {
    local tech="$1"
    local e
    for e in "${OS_DEPENDENT_ENGINES[@]}"; do
        [[ "$e" == "$tech" ]] && return 0
    done
    return 1
}

print_footer() {
    local mode="$1"   # "auto" or "single"
    local has_errors=false

    if [[ "${SCAN_HAS_ENGINE_FAILURE}" == true || "${SCAN_HAS_MID_SCAN_STOP}" == true ]]; then
        has_errors=true
    fi

    echo ""
    echo "${DIVIDER}"
    if [[ "$has_errors" == true ]]; then
        echo " SCAN COMPLETE (with errors)"
    else
        echo " SCAN COMPLETE"
    fi
    echo "${DIVIDER}"

    # Results summary — stubbed until Reporter is in place
    echo "  Results summary:"
    echo ""
    echo "  NOTE: Per-engine status counts (PASS, FAIL, SKIPPED, MANUAL_REVIEW, N/A)"
    echo "        will be displayed here once the Reporter component is available."
    echo ""

    # Output files
    echo "  Output files:"

    if [[ "$mode" == "auto" && -n "${RESEARCHER_JSON}" ]]; then
        echo "    $(basename "${RESEARCHER_JSON}")"
    fi

    local tech
    for tech in "${ENGINES_INVOKED[@]}"; do
        local glob="${ENGINE_REPORT_GLOBS[$tech]}"
        local csv_file=""
        if [[ -n "$glob" ]]; then
            # Only reports written during this scan count
            csv_file=$(find "${OUTPUT_DIR}" -maxdepth 1 -name "$glob" \
                -newermt "@$((SCAN_START_EPOCH - 1))" 2>/dev/null | sort | tail -n 1)
        fi

        local label=""
        case "${ENGINE_OUTCOMES[$tech]:-}" in
            failed)  label="        [FAILED — incomplete]" ;;
            stopped) label="        [INCOMPLETE — technology stopped mid-scan]" ;;
        esac

        if [[ -n "$csv_file" ]]; then
            echo "    $(basename "$csv_file")${label}"
        elif [[ -z "$glob" ]]; then
            echo "    ${tech}: no report file in output directory (see engine output above)${label}"
        else
            echo "    hardenx_${tech}_<not produced>${label}"
        fi
    done

    echo ""
    echo "  Output directory: ${OUTPUT_DIR}"

    # Note for single-tech mode engines that have OS_DEPENDENT checks
    if [[ "$mode" == "single" && -n "${TECH}" ]] && is_os_dependent_engine "${TECH}"; then
        echo ""
        echo "  Note: Scan was run in single-technology mode (--tech ${TECH})."
        echo "        OS-dependent checks were marked SKIPPED — no OS engine report present."
    fi

    echo "${DIVIDER}"
}

# =============================================================================
# FINAL EXIT CODE
# =============================================================================

resolve_exit_code() {
    # Engine failure (2) takes precedence over mid-scan stop (4)
    if [[ "${SCAN_HAS_ENGINE_FAILURE}" == true ]]; then
        exit 2
    elif [[ "${SCAN_HAS_MID_SCAN_STOP}" == true ]]; then
        exit 4
    else
        exit 0
    fi
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    # --- Parse arguments ---
    parse_arguments "$@"

    # --- Validate --tech early if provided ---
    if [[ -n "${TECH}" ]]; then
        validate_tech "${TECH}"
    fi

    # --- Validate output directory ---
    validate_output_dir
    OUTPUT_DIR="$(cd "${OUTPUT_DIR}" && pwd)"
    SCAN_START_EPOCH="$(date +%s)"

    # --- Generate scan ID ---
    if command -v uuidgen &>/dev/null; then
        SCAN_ID="$(uuidgen)"
    else
        # Fallback for hosts without uuidgen
        SCAN_ID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "no-uuid-$(date +%s)")"
    fi

    # --- Ensure all scripts are executable ---
    ensure_scripts_executable

    # --- Pre-flight: verify engine scripts exist ---
    if [[ -n "${TECH}" ]]; then
        preflight_engine_single "${TECH}"
    else
        preflight_researcher
        preflight_engines_auto
    fi

    # --- Scan header ---
    if [[ -n "${TECH}" ]]; then
        print_scan_header "Single-technology — ${TECH}"
    else
        print_scan_header "Auto-detection"
    fi

    # --- Run ---
    if [[ -n "${TECH}" ]]; then
        run_single_tech "${TECH}"
        print_footer "single"
    else
        run_auto_detection
        print_footer "auto"
    fi

    # --- Exit ---
    resolve_exit_code
}

main "$@"