#!/usr/bin/env bash
# Adhiambo Ubuntu Engine — Common Library
# Shared functions for output, result recording, and utilities

# ─── Colour codes ────────────────────────────────────────────────────────────
RED=$'\033[0;31m'; YELLOW=$'\033[1;33m'; GREEN=$'\033[0;32m'
CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'

# ─── Global counters ─────────────────────────────────────────────────────────
COUNT_PASS=0; COUNT_FAIL=0; COUNT_MANUAL=0; COUNT_SKIPPED=0; COUNT_NA=0

# ─── Result accumulator arrays ───────────────────────────────────────────────
declare -a CSV_ROWS=()           # "id|description|status|remediation"
declare -a MANUAL_ENTRIES=()     # full manual review blocks
declare -a MANUAL_INLINE=()      # inline blocks for current section
declare -A OS_FINDINGS=()        # key=check_id, value="status|description[|remediation]"

# ─── Separator ───────────────────────────────────────────────────────────────
SEP="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ─── Section / subsection headers ────────────────────────────────────────────
print_section() {
    echo ""
    echo "${SEP}"
    printf " ${BOLD}SECTION %s — %s${RESET}\n" "$1" "$2"
    echo "${SEP}"
}

print_subsection() {
    echo ""
    printf " ${CYAN}%s — %s${RESET}\n" "$1" "$2"
}

print_info() {
    printf "${CYAN}[INFO]${RESET} %s\n" "$1"
}

print_warn() {
    printf "${YELLOW}[WARN]${RESET} %s\n" "$1"
}

# ─── Record a result ─────────────────────────────────────────────────────────
# Usage: record <id> <status> <description> [remediation]
record() {
    local id="$1" status="$2" desc="$3" rem="${4:-}"
    local label_col width=16

    case "$status" in
        PASS)          ((COUNT_PASS++));    label_col="${GREEN}[PASS]${RESET}" ;;
        FAIL)          ((COUNT_FAIL++));    label_col="${RED}[FAIL]${RESET}" ;;
        MANUAL_REVIEW) ((COUNT_MANUAL++));  label_col="${YELLOW}[MANUAL_REVIEW]${RESET}" ;;
        SKIPPED*)      ((COUNT_SKIPPED++)); label_col="${CYAN}[${status}]${RESET}" ;;
        N/A*)          ((COUNT_NA++));      label_col="${CYAN}[${status}]${RESET}" ;;
        *)             label_col="[${status}]" ;;
    esac

    printf "%-${width}s  %-12s  %s\n" "$label_col" "$id" "$desc"

    # CSV row — escape pipes in fields
    local safe_desc safe_rem
    safe_desc="${desc//|/,}"
    safe_rem="${rem//|/,}"
    CSV_ROWS+=("${id}|${safe_desc}|${status}|${safe_rem}")

    # OS engine report entry
    if [[ -n "$rem" ]]; then
        OS_FINDINGS["$id"]="${status}|${safe_desc}|${safe_rem}"
    else
        OS_FINDINGS["$id"]="${status}|${safe_desc}"
    fi

    # Collect manual review blocks inline for end-of-section print
    if [[ "$status" == "MANUAL_REVIEW" && -n "$rem" ]]; then
        MANUAL_INLINE+=("${id}|${desc}|${rem}")
    fi
}

# ─── Print and clear manual review block for current section ─────────────────
flush_manual_block() {
    local section_label="$1"
    [[ ${#MANUAL_INLINE[@]} -eq 0 ]] && return

    echo ""
    echo "${SEP}"
    printf " ${YELLOW}MANUAL REVIEW REQUIRED — %s${RESET}\n" "$section_label"
    printf " The following checks require operator review.\n"
    printf " Output captured in CSV and in:\n"
    printf "   %s\n" "$MANUAL_TXT"
    echo "${SEP}"

    for entry in "${MANUAL_INLINE[@]}"; do
        IFS='|' read -r mid mdesc mrem <<< "$entry"
        echo ""
        echo "--- ${mid}  ${mdesc} ---"
        # Indent the remediation/output
        while IFS= read -r line; do
            printf "%s\n" "  $line"
        done <<< "$mrem"
        echo "---------------------------------------------------------------------"

        # Accumulate for TXT file
        MANUAL_ENTRIES+=("${entry}")
    done
    MANUAL_INLINE=()
}

# ─── Kernel module check ──────────────────────────────────────────────────────
# Returns 0 if module is unavailable/disabled (PASS state), 1 if available
check_kernel_module() {
    local mod="$1" modtype="${2:-fs}"
    local found=0 subpath="${mod//-/\/}"
    local kernel_ver
    kernel_ver=$(uname -r 2>/dev/null || true)

    # Check if loadable module exists using find (globstar not required)
    while IFS= read -r modpath; do
        if [[ -d "${modpath}/${subpath}" ]] && \
           [[ -n "$(ls -A "${modpath}/${subpath}" 2>/dev/null)" ]]; then
            found=1; break
        fi
    done < <(find /usr/lib/modules /lib/modules -maxdepth 4 \
             -name "kernel" -type d -path "*/${kernel_ver}/*" \
             -path "*/${modtype}" 2>/dev/null | sort -u)

    if [[ $found -eq 0 ]]; then
        # Module not present as loadable — check if built-in
        if grep -qw "$mod" /proc/filesystems 2>/dev/null || \
           grep -qw "$mod" /proc/modules 2>/dev/null; then
            return 1  # built-in and loaded
        fi
        return 0  # not available — pass
    fi

    # Module exists — check if blacklisted and install-disabled
    local blacklisted=0 install_disabled=0
    if grep -rqs "^blacklist[[:space:]]*${mod}\b" \
       /etc/modprobe.d/ /usr/lib/modprobe.d/ 2>/dev/null; then
        blacklisted=1
    fi
    if grep -rqs "^install[[:space:]]*${mod}[[:space:]]*/bin/false\b\|^install[[:space:]]*${mod}[[:space:]]*/bin/true\b" \
       /etc/modprobe.d/ /usr/lib/modprobe.d/ 2>/dev/null; then
        install_disabled=1
    fi

    if [[ $blacklisted -eq 1 && $install_disabled -eq 1 ]]; then
        # Also verify it's not currently loaded
        if lsmod 2>/dev/null | grep -qw "^${mod}"; then
            return 1  # still loaded
        fi
        return 0  # disabled — pass
    fi
    return 1  # available and not disabled — fail
}

# ─── Sysctl check ────────────────────────────────────────────────────────────
# Usage: check_sysctl <param> <expected_value>
# Returns 0 on pass, 1 on fail
check_sysctl() {
    local param="$1" expected="$2"
    local live_val
    live_val=$(sysctl -n "$param" 2>/dev/null)
    [[ "$live_val" == "$expected" ]]
}

# ─── Service not-in-use check ─────────────────────────────────────────────────
# Returns 0 (pass=not installed/active) if service/package absent
check_service_not_in_use() {
    local pkg="$1"
    shift
    local services=("$@")

    # Check package installed
    if dpkg-query -s "$pkg" &>/dev/null 2>&1; then
        # Package present — check if any service is active/enabled
        for svc in "${services[@]}"; do
            if systemctl is-active "$svc" &>/dev/null || \
               systemctl is-enabled "$svc" &>/dev/null; then
                return 1  # fail — active
            fi
        done
        return 1  # installed but not active is still a finding per benchmark
    fi
    return 0  # not installed — pass
}

# ─── File permission check ────────────────────────────────────────────────────
# Usage: check_file_perms <file> <max_octal_perms> <owner> <group>
check_file_perms() {
    local file="$1" max_perm="$2" owner="$3" group="$4"
    [[ ! -e "$file" ]] && return 2  # file absent

    local perms uid gid
    read -r perms uid gid < <(stat -Lc '%#a %U %G' "$file" 2>/dev/null)

    # Numeric permission comparison (octal)
    local actual_num max_num
    actual_num=$(printf '%d' "$perms" 2>/dev/null) || actual_num=999
    max_num=$(printf '%d' "0${max_perm}" 2>/dev/null) || max_num=0

    if (( actual_num > max_num )) || \
       [[ "$uid" != "$owner" ]] || \
       [[ "$gid" != "$group" ]]; then
        return 1
    fi
    return 0
}

# ─── Partition mount option check ─────────────────────────────────────────────
check_mount_option() {
    local mountpoint="$1" option="$2"
    if ! findmnt -kn "$mountpoint" &>/dev/null; then
        return 2  # not mounted as separate partition
    fi
    if findmnt -kn "$mountpoint" | grep -qw "$option"; then
        return 0  # option present
    fi
    return 1
}

# ─── Write CSV report ─────────────────────────────────────────────────────────
write_csv() {
    local outfile="$1"
    {
        printf 'Check Name,Description,Status,Remediation\n'
        for row in "${CSV_ROWS[@]}"; do
            IFS='|' read -r cid desc status rem <<< "$row"
            # Wrap fields that contain commas in double-quotes
            printf '"%s","%s","%s","%s"\n' \
                "$cid" "$desc" "$status" "${rem//\"/\"\"}"
        done
    } > "$outfile"
}

# ─── Write manual review TXT ─────────────────────────────────────────────────
write_manual_txt() {
    local outfile="$1" hostname="$2" scan_id="$3" level="$4" ts="$5"
    local total=${#MANUAL_ENTRIES[@]}

    {
        echo "${SEP}━━━━━━━━━━"
        printf " Adhiambo — Ubuntu Manual Review Workbook\n"
        printf " Host      : %s\n" "$hostname"
        printf " Scan ID   : %s\n" "$scan_id"
        printf " Level     : %s\n" "$level"
        printf " Generated : %s\n" "$ts"
        echo "${SEP}━━━━━━━━━━"
        echo ""
        echo "This file contains all checks that require manual operator review."
        echo "Each entry includes the CIS control reference, the required action,"
        echo "the command that was run, and the output captured at scan time."
        echo ""
        echo "Work through each check, document your conclusion in the space"
        echo "provided, and retain this file as evidence of review."
        echo ""
        printf "Total checks requiring manual review: %d\n" "$total"
        echo "${SEP}━━━━━━━━━━"

        for entry in "${MANUAL_ENTRIES[@]}"; do
            IFS='|' read -r mid mdesc mrem <<< "$entry"
            echo ""
            echo "═══════════════════════════════════════════════════════════════"
            printf "Check   : %s\n" "$mid"
            printf "Title   : %s\n" "$mdesc"
            echo "═══════════════════════════════════════════════════════════════"
            echo ""
            echo "Output captured at scan time:"
            while IFS= read -r line; do
                printf "%s\n" "  $line"
            done <<< "$mrem"
            echo ""
            echo "---------------------------------------------------------------"
            echo "Operator finding:"
            echo "  [ ] PASS"
            echo "  [ ] FAIL"
            echo "  Notes:"
            echo ""
            echo ""
            printf "Reviewed by: ________________________  Date: ________________\n"
            echo "---------------------------------------------------------------"
        done
    } > "$outfile"
}

# ─── Write OS engine report JSON ──────────────────────────────────────────────
write_os_report() {
    local outfile="$1" scan_id="$2" hostname="$3" level="$4" ts="$5"
    local cloud_hosted="${HOST_CLOUD_HOSTED:-false}"
    local cloud_provider="${HOST_CLOUD_PROVIDER:-none}"
    local hypervisor="${HOST_HYPERVISOR_DETECTED:-false}"
    local container_svc="${HOST_CONTAINERIZED_SERVICES:-false}"
    local ipv6="${HOST_IPV6_IN_USE:-false}"
    local firewall="${HOST_ACTIVE_FIREWALL:-none}"

    {
        printf '{\n'
        printf '  "adhiambo_version": "0.1",\n'
        printf '  "engine": "ubuntu",\n'
        printf '  "scan_id": "%s",\n' "$scan_id"
        printf '  "timestamp": "%s",\n' "$ts"
        printf '  "hostname": "%s",\n' "$hostname"
        printf '  "os_version": "24.04",\n'
        printf '  "level": %s,\n' "$level"
        printf '  "host_profile": {\n'
        printf '    "cloud_hosted": %s,\n' "$cloud_hosted"
        printf '    "cloud_provider": "%s",\n' "$cloud_provider"
        printf '    "hypervisor_detected": %s,\n' "$hypervisor"
        printf '    "containerized_services": %s,\n' "$container_svc"
        printf '    "ipv6_in_use": %s,\n' "$ipv6"
        printf '    "active_firewall": "%s"\n' "$firewall"
        printf '  },\n'
        printf '  "findings": {\n'

        local first=1
        for key in "${!OS_FINDINGS[@]}"; do
            local val="${OS_FINDINGS[$key]}"
            IFS='|' read -r fstatus fdesc frem <<< "$val"
            [[ $first -eq 0 ]] && printf ',\n'
            first=0
            printf '    "%s": {\n' "$key"
            printf '      "status": "%s",\n' "$fstatus"
            printf '      "description": "%s"' "${fdesc//\"/\\\"}"
            if [[ -n "$frem" ]]; then
                printf ',\n      "remediation": "%s"\n' "${frem//\"/\\\"}"
            else
                printf '\n'
            fi
            printf '    }'
        done
        printf '\n  }\n'
        printf '}\n'
    } > "$outfile"
}