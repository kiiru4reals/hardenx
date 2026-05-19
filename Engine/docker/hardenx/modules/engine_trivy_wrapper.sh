#!/usr/bin/env bash

# ----------------------------------------------------------------------------
# HardenX Vulnerability Scan Engine Wrapper
# ----------------------------------------------------------------------------
run_trivy_engine() {
    # Show launch message unless quiet mode is enabled.
    if [[ "${QUIET:-false}" != true || "${VERBOSE:-false}" == true ]]; then
        echo "[*] Launching Vulnerability Scan Engine..."
        echo
    fi

    # IMPORTANT:
    # Do NOT redirect stdout/stderr here.
    # engine_trivy.sh contains interactive menus, including image selection.
    # Quiet mode is handled internally by log() and debug().
    "$SCRIPT_DIR/modules/engine_trivy.sh"

    # Preserve the vulnerability assessment directory by selecting the
    # most recently modified report directory that is NOT docker-cis-*.
    CURRENT_ASSESSMENT_DIR="$(
        find "$REPORTS_DIR" -mindepth 1 -maxdepth 1 -type d \
            ! -name 'docker-cis-*' \
            -printf '%T@ %p\n' \
        | sort -nr \
        | head -1 \
        | cut -d' ' -f2-
    )"

    # Ensure a directory was found
    if [[ -z "${CURRENT_ASSESSMENT_DIR:-}" || ! -d "$CURRENT_ASSESSMENT_DIR" ]]; then
        echo "[!] Failed to determine assessment directory."
        return 1
    fi

    # Store the assessment directory name
    CURRENT_ASSESSMENT_NAME="$(basename "$CURRENT_ASSESSMENT_DIR")"

    # Debug output only when verbose mode is enabled
    debug "Preserved assessment directory: $CURRENT_ASSESSMENT_DIR"
    debug "Preserved assessment name: $CURRENT_ASSESSMENT_NAME"
}