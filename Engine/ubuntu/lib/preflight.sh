#!/usr/bin/env bash
# Adhiambo Ubuntu Engine — Pre-flight Checks
# Phase 1: OS verification  Phase 2: Privilege  Phase 3: Desktop  Phase 4: Host profile

# ─── Phase 1: OS Version Verification ────────────────────────────────────────
preflight_os() {
    if [[ ! -f /etc/os-release ]]; then
        echo "[ERROR] /etc/os-release not found. Cannot determine OS."
        echo "        This engine targets Ubuntu 24.04 LTS only."
        echo "        No checks were run. No report has been generated."
        exit 1
    fi

    local os_id os_version
    os_id=$(grep -Po '(?<=^ID=)\S+' /etc/os-release | tr -d '"')
    os_version=$(grep -Po '(?<=^VERSION_ID=)\S+' /etc/os-release | tr -d '"')

    if [[ "$os_id" != "ubuntu" ]]; then
        echo "[ERROR] This engine targets Ubuntu 24.04 LTS only."
        printf "        Detected OS: %s\n" "${os_id:-unknown}"
        echo "        No checks were run. No report has been generated."
        exit 1
    fi

    if [[ "$os_version" != "24.04" ]]; then
        echo "[ERROR] This engine targets Ubuntu 24.04 LTS only."
        printf "        Detected : Ubuntu %s\n" "$os_version"
        echo "        Supported : Ubuntu 24.04 LTS"
        echo ""
        echo "        Running this engine against a different Ubuntu version may"
        echo "        produce incorrect results."
        echo "        No checks were run. No report has been generated."
        exit 1
    fi
}

# ─── Phase 2: Privilege Check ─────────────────────────────────────────────────
preflight_privilege() {
    if [[ "$EUID" -ne 0 ]]; then
        print_warn "Adhiambo is not running as root."
        print_warn "Checks requiring elevated privileges will be marked"
        print_warn "SKIPPED: Insufficient privileges rather than FAIL."
        print_warn "For a complete scan, re-run with sudo or as root."
        echo ""
        RUNNING_AS_ROOT=false
    else
        RUNNING_AS_ROOT=true
    fi
    export RUNNING_AS_ROOT
}

# ─── Phase 3: Desktop Environment Detection ───────────────────────────────────
preflight_desktop() {
    local desktop_pkgs=("ubuntu-desktop" "gdm3" "gnome-shell" "xorg")
    local found_pkgs=()

    for pkg in "${desktop_pkgs[@]}"; do
        if dpkg-query -s "$pkg" &>/dev/null 2>&1; then
            found_pkgs+=("$pkg")
        fi
    done

    if [[ ${#found_pkgs[@]} -gt 0 ]]; then
        HOST_DESKTOP_ENV_DETECTED=true
        print_warn "Desktop environment packages detected on this host:"
        print_warn "  Found: ${found_pkgs[*]}"
        print_warn "This engine is designed for Ubuntu Server deployments only."
        print_warn "GDM and desktop packages increase the attack surface of a server."
        print_warn "Recommendation: remove GDM and desktop packages after the scan."
        print_warn "Section 1.7 benchmark checks will run normally since GDM is"
        print_warn "present. A custom advisory (SERVER-GDM-01) will be recorded"
        print_warn "recommending removal. Proceeding with server-scoped scan."
        echo ""
    else
        HOST_DESKTOP_ENV_DETECTED=false
    fi
    export HOST_DESKTOP_ENV_DETECTED
}

# ─── Phase 4: Host Profile Detection ─────────────────────────────────────────
preflight_host_profile() {

    # ── Infrastructure: cloud provider ──────────────────────────────────────
    local vendor
    vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null | tr '[:upper:]' '[:lower:]')

    if echo "$vendor" | grep -qi "microsoft"; then
        HOST_CLOUD_PROVIDER="azure"; HOST_CLOUD_HOSTED=true
    elif echo "$vendor" | grep -qi "amazon"; then
        HOST_CLOUD_PROVIDER="aws"; HOST_CLOUD_HOSTED=true
    elif echo "$vendor" | grep -qi "google"; then
        HOST_CLOUD_PROVIDER="gcp"; HOST_CLOUD_HOSTED=true
    else
        # Probe metadata endpoints (2s timeout)
        if curl -sf -m 2 -H "Metadata: true" \
           "http://169.254.169.254/metadata/instance" &>/dev/null 2>&1; then
            HOST_CLOUD_PROVIDER="azure"; HOST_CLOUD_HOSTED=true
        elif curl -sf -m 2 \
           "http://169.254.169.254/latest/meta-data/" &>/dev/null 2>&1; then
            HOST_CLOUD_PROVIDER="aws"; HOST_CLOUD_HOSTED=true
        elif curl -sf -m 2 -H "Metadata-Flavor: Google" \
           "http://169.254.169.254/computeMetadata/v1/" &>/dev/null 2>&1; then
            HOST_CLOUD_PROVIDER="gcp"; HOST_CLOUD_HOSTED=true
        elif curl -sf -m 2 "http://169.254.169.254/" &>/dev/null 2>&1; then
            HOST_CLOUD_PROVIDER="other"; HOST_CLOUD_HOSTED=true
        else
            HOST_CLOUD_PROVIDER="none"; HOST_CLOUD_HOSTED=false
        fi
    fi

    # ── Infrastructure: hypervisor ──────────────────────────────────────────
    local virt_type
    virt_type=$(systemd-detect-virt --vm 2>/dev/null)
    if [[ "$virt_type" != "none" && -n "$virt_type" ]]; then
        HOST_HYPERVISOR_DETECTED=true
        HOST_HYPERVISOR_TYPE="$virt_type"
    else
        HOST_HYPERVISOR_DETECTED=false
        HOST_HYPERVISOR_TYPE="none"
    fi

    # ── Active services ──────────────────────────────────────────────────────
    # Containerised services
    if systemctl is-active docker &>/dev/null || \
       pgrep -x containerd &>/dev/null || \
       pgrep -x kubelet &>/dev/null; then
        HOST_CONTAINERIZED_SERVICES=true
    else
        HOST_CONTAINERIZED_SERVICES=false
    fi

    # DHCP server
    if systemctl is-active isc-dhcp-server &>/dev/null || \
       systemctl is-active dhcpd &>/dev/null || \
       systemctl is-active kea-dhcp4 &>/dev/null; then
        HOST_DHCP_SERVER=true
    else
        HOST_DHCP_SERVER=false
    fi

    # LDAP server
    if systemctl is-active slapd &>/dev/null; then
        HOST_LDAP_SERVER=true
    else
        HOST_LDAP_SERVER=false
    fi

    # POP/IMAP server
    if systemctl is-active dovecot &>/dev/null || \
       systemctl is-active cyrus-imap &>/dev/null; then
        HOST_POP_IMAP_SERVER=true
    else
        HOST_POP_IMAP_SERVER=false
    fi

    # Web server
    if systemctl is-active apache2 &>/dev/null || \
       systemctl is-active nginx &>/dev/null; then
        HOST_WEB_SERVER=true
    else
        HOST_WEB_SERVER=false
    fi

    # DNS server
    if systemctl is-active named &>/dev/null || \
       systemctl is-active bind9 &>/dev/null; then
        HOST_DNS_SERVER=true
    else
        HOST_DNS_SERVER=false
    fi

    # Cluster node
    if pgrep -x kubelet &>/dev/null || \
       systemctl is-active kubelet &>/dev/null; then
        HOST_CLUSTER_NODE=true
    else
        HOST_CLUSTER_NODE=false
    fi

    # ── Installed clients ────────────────────────────────────────────────────
    if dpkg-query -s libpam-ldapd &>/dev/null 2>&1 || \
       dpkg-query -s sssd-ldap &>/dev/null 2>&1 || \
       dpkg-query -s libnss-ldap &>/dev/null 2>&1; then
        HOST_LDAP_CLIENT=true
    else
        HOST_LDAP_CLIENT=false
    fi

    if dpkg-query -s sudo-ldap &>/dev/null 2>&1; then
        HOST_SUDO_LDAP_INSTALLED=true
    else
        HOST_SUDO_LDAP_INSTALLED=false
    fi

    # ── Network: IPv6 ────────────────────────────────────────────────────────
    local ipv6_disabled
    ipv6_disabled=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
    if [[ "$ipv6_disabled" == "0" ]] && \
       ip -6 addr show 2>/dev/null | grep -q "inet6"; then
        HOST_IPV6_IN_USE=true
    else
        HOST_IPV6_IN_USE=false
    fi

    # ── Packages and features ────────────────────────────────────────────────
    # snap
    if command -v snap &>/dev/null && \
       snap list 2>/dev/null | tail -n +2 | grep -q .; then
        HOST_SNAP_ACTIVE=true
    else
        HOST_SNAP_ACTIVE=false
    fi

    # squashfs built-in vs module
    if grep -qw "squashfs" /proc/filesystems 2>/dev/null && \
       ! modinfo squashfs &>/dev/null 2>&1; then
        HOST_SQUASHFS_BUILTIN=true
    else
        HOST_SQUASHFS_BUILTIN=false
    fi

    # cron
    if dpkg-query -s cron &>/dev/null 2>&1 || \
       dpkg-query -s cronie &>/dev/null 2>&1; then
        HOST_CRON_INSTALLED=true
    else
        HOST_CRON_INSTALLED=false
    fi

    # at
    if dpkg-query -s at &>/dev/null 2>&1; then
        HOST_AT_INSTALLED=true
    else
        HOST_AT_INSTALLED=false
    fi

    # ── Active firewall ──────────────────────────────────────────────────────
    local active_fw=()
    if dpkg-query -s ufw &>/dev/null 2>&1 && \
       ufw status 2>/dev/null | grep -q "Status: active"; then
        active_fw+=("ufw")
    fi
    if dpkg-query -s nftables &>/dev/null 2>&1 && \
       nft list ruleset 2>/dev/null | grep -q .; then
        active_fw+=("nftables")
    fi
    if dpkg-query -s iptables &>/dev/null 2>&1 && \
       iptables -L 2>/dev/null | grep -qvE "^Chain|^target|^$"; then
        active_fw+=("iptables")
    fi

    if [[ ${#active_fw[@]} -eq 0 ]]; then
        HOST_ACTIVE_FIREWALL="none"
    elif [[ ${#active_fw[@]} -eq 1 ]]; then
        HOST_ACTIVE_FIREWALL="${active_fw[0]}"
    else
        HOST_ACTIVE_FIREWALL="${active_fw[0]}"  # highest precedence
        HOST_MULTIPLE_FIREWALLS="${active_fw[*]}"
    fi

    # ── Export all ────────────────────────────────────────────────────────────
    export HOST_CLOUD_PROVIDER HOST_CLOUD_HOSTED HOST_HYPERVISOR_DETECTED
    export HOST_HYPERVISOR_TYPE HOST_CONTAINERIZED_SERVICES HOST_DHCP_SERVER
    export HOST_LDAP_SERVER HOST_POP_IMAP_SERVER HOST_WEB_SERVER HOST_DNS_SERVER
    export HOST_CLUSTER_NODE HOST_LDAP_CLIENT HOST_SUDO_LDAP_INSTALLED
    export HOST_IPV6_IN_USE HOST_SNAP_ACTIVE HOST_SQUASHFS_BUILTIN
    export HOST_CRON_INSTALLED HOST_AT_INSTALLED HOST_ACTIVE_FIREWALL
    export HOST_MULTIPLE_FIREWALLS
}

# ─── Print host profile summary ───────────────────────────────────────────────
print_host_profile() {
    local infra svc net pkgs

    # Infrastructure
    if [[ "$HOST_CLOUD_HOSTED" == "true" ]]; then
        infra="${HOST_CLOUD_PROVIDER} (cloud-hosted VM"
        [[ "$HOST_HYPERVISOR_DETECTED" == "true" ]] && \
            infra+=", ${HOST_HYPERVISOR_TYPE} hypervisor"
        infra+=")"
    else
        [[ "$HOST_HYPERVISOR_DETECTED" == "true" ]] && \
            infra="bare-metal / VM (${HOST_HYPERVISOR_TYPE})" || \
            infra="bare-metal"
    fi

    # Active services
    local svc_list=()
    [[ "$HOST_CONTAINERIZED_SERVICES" == "true" ]] && svc_list+=("container runtime")
    [[ "$HOST_DHCP_SERVER" == "true" ]]             && svc_list+=("DHCP server")
    [[ "$HOST_LDAP_SERVER" == "true" ]]             && svc_list+=("LDAP server")
    [[ "$HOST_POP_IMAP_SERVER" == "true" ]]         && svc_list+=("POP/IMAP server")
    [[ "$HOST_WEB_SERVER" == "true" ]]              && svc_list+=("web server")
    [[ "$HOST_DNS_SERVER" == "true" ]]              && svc_list+=("DNS server")
    [[ "$HOST_CLUSTER_NODE" == "true" ]]            && svc_list+=("cluster node")
    [[ "$HOST_LDAP_CLIENT" == "true" ]]             && svc_list+=("LDAP client")
    svc="${svc_list[*]:-none detected}"

    # Network
    [[ "$HOST_IPV6_IN_USE" == "true" ]] && net="IPv6 in active use" || net="IPv4 only"

    # Packages
    local pkg_list=()
    [[ "$HOST_SNAP_ACTIVE" == "true" ]]     && pkg_list+=("snap active")
    [[ "$HOST_CRON_INSTALLED" == "true" ]]  && pkg_list+=("cron installed")
    [[ "$HOST_AT_INSTALLED" == "true" ]]    && pkg_list+=("at installed")
    pkgs="${pkg_list[*]:-standard}"

    echo ""
    echo "${SEP}"
    printf " ${BOLD}HOST PROFILE${RESET}\n"
    echo "${SEP}"
    printf "  %-16s : %s\n" "Infrastructure" "$infra"
    printf "  %-16s : %s\n" "Services" "$svc"
    printf "  %-16s : %s\n" "Network" "$net"
    printf "  %-16s : %s\n" "Packages" "$pkgs"
    printf "  %-16s : %s\n" "Firewall" "${HOST_ACTIVE_FIREWALL}"
    echo ""
    echo "  Conditional checks will be applied based on the above profile."
    echo "${SEP}"
    echo ""
}