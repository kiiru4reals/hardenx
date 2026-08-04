#!/usr/bin/env bash
# Adhiambo Ubuntu Engine — Section 4: Host Based Firewall

section4_run() {
    print_section "4" "Host Based Firewall"

    # ── Firewall inventory pre-check (Section 5.6 of README) ─────────────────
    local multi_fw_note=""

    if [[ -n "$HOST_MULTIPLE_FIREWALLS" ]]; then
        echo ""
        printf "${YELLOW}[WARN]${RESET} Multiple firewall utilities are installed and active: %s\n" \
            "$HOST_MULTIPLE_FIREWALLS"
        printf "       The CIS Benchmark recommends using only one firewall utility.\n"
        printf "       Running multiple firewall managers simultaneously can produce\n"
        printf "       unexpected rule interactions and inconsistent security state.\n"
        printf "\n"
        printf "       Recommendation: Disable and uninstall all firewall utilities\n"
        printf "       except the one your organisation has standardised on.\n"
        printf "       If using UFW, ensure it is the sole manager of the NFTables backend.\n"
        printf "\n"
        printf "       Section 4 will be evaluated against %s (highest-precedence active utility).\n" \
            "$HOST_ACTIVE_FIREWALL"
        echo ""
        multi_fw_note="NOTE: Multiple firewalls detected (${HOST_MULTIPLE_FIREWALLS}). Evaluated against ${HOST_ACTIVE_FIREWALL}. Consolidate to a single firewall utility."
    fi

    case "$HOST_ACTIVE_FIREWALL" in
        ufw)
            print_info "Active firewall: UFW. Section 4 checks will be evaluated normally."
            _section4_ufw "$multi_fw_note"
            ;;
        nftables|iptables)
            print_info "Active firewall: ${HOST_ACTIVE_FIREWALL}."
            print_info "Benchmark covers UFW. Evaluating equivalent rules."
            _section4_ufw "$multi_fw_note"
            ;;
        none)
            printf "${RED}[WARN]${RESET} No active firewall detected. All Section 4 checks will FAIL.\n"
            echo ""
            local no_fw_rem="No firewall utility is active. Install and configure UFW:
  apt install ufw
  ufw default deny incoming
  ufw default allow outgoing
  ufw enable"
            record "4.1.1" "FAIL" "Ensure ufw is installed" "$no_fw_rem"
            record "4.1.2" "FAIL" "Ensure ufw service is configured" "$no_fw_rem"
            record "4.1.3" "FAIL" "Ensure ufw incoming default is configured" "$no_fw_rem"
            record "4.1.4" "FAIL" "Ensure ufw outgoing default is configured" "$no_fw_rem"
            record "4.1.5" "FAIL" "Ensure ufw routed default is configured" "$no_fw_rem"
            ;;
    esac
}

_section4_ufw() {
    local note="$1"

    _ufw_record() {
        local id="$1" status="$2" desc="$3" rem="$4"
        [[ -n "$note" ]] && rem="${rem}
${note}"
        record "$id" "$status" "$desc" "$rem"
    }

    # 4.1.1 ufw installed
    if dpkg-query -s ufw &>/dev/null 2>&1; then
        _ufw_record "4.1.1" "PASS" "Ensure ufw is installed" ""
    else
        _ufw_record "4.1.1" "FAIL" "Ensure ufw is installed" \
            "Install UFW: apt install ufw"
    fi

    # 4.1.2 ufw service configured (enabled + active)
    local ufw_enabled ufw_active
    ufw_enabled=$(systemctl is-enabled ufw 2>/dev/null)
    ufw_active=$(ufw status 2>/dev/null | grep -c "Status: active")

    if [[ "$ufw_enabled" == "enabled" && "$ufw_active" -gt 0 ]]; then
        _ufw_record "4.1.2" "PASS" "Ensure ufw service is configured" ""
    else
        _ufw_record "4.1.2" "FAIL" "Ensure ufw service is configured" \
            "Enable and start UFW:
  systemctl enable ufw
  ufw enable
  ufw_enabled=${ufw_enabled:-disabled}, ufw_active=${ufw_active}"
    fi

    # 4.1.3 incoming default DENY
    local ufw_default_in
    ufw_default_in=$(ufw status verbose 2>/dev/null | \
        grep -i "^Default:" | grep -i "incoming" | grep -oi "deny\|reject\|disabled" | \
        head -1)
    if echo "$ufw_default_in" | grep -qiE "deny|reject"; then
        _ufw_record "4.1.3" "PASS" "Ensure ufw incoming default is configured" ""
    else
        _ufw_record "4.1.3" "FAIL" "Ensure ufw incoming default is configured" \
            "Set default incoming to deny: ufw default deny incoming
  Current incoming default: ${ufw_default_in:-not set}"
    fi

    # 4.1.4 outgoing default — L2
    if [[ "$SCAN_LEVEL" -ge 2 ]]; then
        local ufw_default_out
        ufw_default_out=$(ufw status verbose 2>/dev/null | \
            grep -i "^Default:" | grep -i "outgoing" | grep -oi "allow\|deny\|reject" | \
            head -1)
        if echo "$ufw_default_out" | grep -qiE "allow|deny|reject"; then
            _ufw_record "4.1.4" "PASS" "Ensure ufw outgoing default is configured" ""
        else
            _ufw_record "4.1.4" "FAIL" "Ensure ufw outgoing default is configured" \
                "Set default outgoing policy: ufw default allow outgoing (or deny if more restrictive posture desired)"
        fi
    fi

    # 4.1.5 routed default
    local ufw_default_routed
    ufw_default_routed=$(ufw status verbose 2>/dev/null | \
        grep -i "^Default:" | grep -i "routed\|forward" | \
        grep -oi "deny\|disabled\|reject" | head -1)
    if echo "$ufw_default_routed" | grep -qiE "deny|disabled|reject"; then
        _ufw_record "4.1.5" "PASS" "Ensure ufw routed default is configured" ""
    else
        _ufw_record "4.1.5" "FAIL" "Ensure ufw routed default is configured" \
            "Set default routed to deny: ufw default deny routed
  Current routed default: ${ufw_default_routed:-not set}"
    fi
}