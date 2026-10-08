#!/usr/bin/env bash
# HardenX Ubuntu Engine — Section 3: Network Configuration

section3_run() {
    print_section "3" "Network"

    # ── 3.1 Configure Network Devices ────────────────────────────────────────
    print_subsection "3.1" "Configure Network Devices"

    # 3.1.1 IPv6 status — Manual (informational)
    if [[ "$HOST_IPV6_IN_USE" == "true" ]]; then
        local ipv6_addrs
        ipv6_addrs=$(ip -6 addr show 2>/dev/null | grep "inet6" | head -10)
        record "3.1.1" "N/A: IPv6 in active use" \
            "Ensure IPv6 status is identified" \
            "IPv6 is in active use on this host — disabling it would disrupt network connectivity.
Active IPv6 addresses:
${ipv6_addrs}
This is expected if IPv6 is part of your network design. Document this exception."
    else
        record "3.1.1" "MANUAL_REVIEW" \
            "Ensure IPv6 status is identified" \
            "IPv6 appears disabled or no addresses assigned. Verify this is intentional.
Run: ip -6 addr show
Run: sysctl net.ipv6.conf.all.disable_ipv6
If IPv6 is not required, confirm: net.ipv6.conf.all.disable_ipv6=1 and
net.ipv6.conf.default.disable_ipv6=1 are set in /etc/sysctl.d/"
    fi

    # 3.1.2 Wireless interfaces
    local wireless_ifaces
    wireless_ifaces=$(find /sys/class/net -type l 2>/dev/null | \
        xargs -I{} bash -c '[[ -d "{}"/wireless ]] && basename "{}"' 2>/dev/null)
    if [[ -z "$wireless_ifaces" ]]; then
        record "3.1.2" "PASS" "Ensure wireless interfaces are not available" ""
    else
        record "3.1.2" "FAIL" "Ensure wireless interfaces are not available" \
            "Wireless interfaces found: ${wireless_ifaces}
  Disable wireless: nmcli radio wifi off
  Or unload the driver and blacklist: modprobe -r <driver>
  Add to /etc/modprobe.d/blacklist-wireless.conf: blacklist <driver>"
    fi

    # 3.1.3 Bluetooth
    if ! dpkg-query -s bluez &>/dev/null 2>&1 && \
       ! systemctl is-active bluetooth &>/dev/null; then
        record "3.1.3" "PASS" "Ensure bluetooth services are not in use" ""
    else
        record "3.1.3" "FAIL" "Ensure bluetooth services are not in use" \
            "Disable Bluetooth:
  systemctl stop bluetooth && systemctl disable bluetooth
  apt purge bluez
  Blacklist module: echo 'blacklist bluetooth' >> /etc/modprobe.d/blacklist.conf"
    fi

    flush_manual_block "SECTION 3.1"

    # ── 3.2 Configure Network Kernel Modules ──────────────────────────────────
    print_subsection "3.2" "Configure Network Kernel Modules"

    local net_modules=(
        "3.2.1:atm:atm"
        "3.2.2:can:net"
        "3.2.3:dccp:net"
        "3.2.4:rds:net"
        "3.2.5:sctp:net"
        "3.2.6:tipc:net"
    )
    for entry in "${net_modules[@]}"; do
        IFS=':' read -r id mod modtype <<< "$entry"
        local desc="Ensure ${mod} kernel module is not available"
        if check_kernel_module "$mod" "$modtype"; then
            record "$id" "PASS" "$desc" ""
        else
            record "$id" "FAIL" "$desc" \
                "Disable ${mod}: add to /etc/modprobe.d/${mod}.conf:
  install ${mod} /bin/false
  blacklist ${mod}
  Then: rmmod ${mod} 2>/dev/null"
        fi
    done

    # ── 3.3 Configure Network Kernel Parameters ───────────────────────────────
    print_subsection "3.3.1" "Configure IPv4 Parameters"

    # Helper for sysctl checks with persistent file verification
    _sysctl_check() {
        local id="$1" param="$2" expected="$3" desc="$4"
        local live_val
        live_val=$(sysctl -n "$param" 2>/dev/null)
        if [[ "$live_val" == "$expected" ]]; then
            record "$id" "PASS" "$desc" ""
        else
            record "$id" "FAIL" "$desc" \
                "Set ${param}=${expected} in /etc/sysctl.d/60-netparams.conf
  sysctl -w ${param}=${expected}
  Current value: ${live_val:-not set}"
        fi
    }

    # 3.3.1.1 ip_forward — L2, skip for cluster nodes
    if [[ "$SCAN_LEVEL" -ge 2 ]]; then
        if [[ "$HOST_CLUSTER_NODE" == "true" ]]; then
            record "3.3.1.1" "N/A: cluster node" \
                "Ensure net.ipv4.ip_forward is configured" \
                "Host is a cluster node; IP forwarding is required for cluster networking."
        else
            _sysctl_check "3.3.1.1" "net.ipv4.ip_forward" "0" \
                "Ensure net.ipv4.ip_forward is configured"
        fi
    fi

    _sysctl_check "3.3.1.2" "net.ipv4.conf.all.forwarding" "0" \
        "Ensure net.ipv4.conf.all.forwarding is configured"
    _sysctl_check "3.3.1.3" "net.ipv4.conf.default.forwarding" "0" \
        "Ensure net.ipv4.conf.default.forwarding is configured"
    _sysctl_check "3.3.1.4" "net.ipv4.conf.all.send_redirects" "0" \
        "Ensure net.ipv4.conf.all.send_redirects is configured"
    _sysctl_check "3.3.1.5" "net.ipv4.conf.default.send_redirects" "0" \
        "Ensure net.ipv4.conf.default.send_redirects is configured"
    _sysctl_check "3.3.1.6" "net.ipv4.icmp_ignore_bogus_error_responses" "1" \
        "Ensure net.ipv4.icmp_ignore_bogus_error_responses is configured"
    _sysctl_check "3.3.1.7" "net.ipv4.icmp_echo_ignore_broadcasts" "1" \
        "Ensure net.ipv4.icmp_echo_ignore_broadcasts is configured"
    _sysctl_check "3.3.1.8" "net.ipv4.conf.all.accept_redirects" "0" \
        "Ensure net.ipv4.conf.all.accept_redirects is configured"
    _sysctl_check "3.3.1.9" "net.ipv4.conf.default.accept_redirects" "0" \
        "Ensure net.ipv4.conf.default.accept_redirects is configured"
    _sysctl_check "3.3.1.10" "net.ipv4.conf.all.secure_redirects" "0" \
        "Ensure net.ipv4.conf.all.secure_redirects is configured"
    _sysctl_check "3.3.1.11" "net.ipv4.conf.default.secure_redirects" "0" \
        "Ensure net.ipv4.conf.default.secure_redirects is configured"
    _sysctl_check "3.3.1.12" "net.ipv4.conf.all.rp_filter" "1" \
        "Ensure net.ipv4.conf.all.rp_filter is configured"
    _sysctl_check "3.3.1.13" "net.ipv4.conf.default.rp_filter" "1" \
        "Ensure net.ipv4.conf.default.rp_filter is configured"
    _sysctl_check "3.3.1.14" "net.ipv4.conf.all.accept_source_route" "0" \
        "Ensure net.ipv4.conf.all.accept_source_route is configured"
    _sysctl_check "3.3.1.15" "net.ipv4.conf.default.accept_source_route" "0" \
        "Ensure net.ipv4.conf.default.accept_source_route is configured"
    _sysctl_check "3.3.1.16" "net.ipv4.conf.all.log_martians" "1" \
        "Ensure net.ipv4.conf.all.log_martians is configured"
    _sysctl_check "3.3.1.17" "net.ipv4.conf.default.log_martians" "1" \
        "Ensure net.ipv4.conf.default.log_martians is configured"
    _sysctl_check "3.3.1.18" "net.ipv4.tcp_syncookies" "1" \
        "Ensure net.ipv4.tcp_syncookies is configured"

    # IPv6 parameters — only if IPv6 is in use
    if [[ "$HOST_IPV6_IN_USE" == "true" ]]; then
        print_subsection "3.3.2" "Configure IPv6 Parameters"
        _sysctl_check "3.3.2.1" "net.ipv6.conf.all.forwarding" "0" \
            "Ensure net.ipv6.conf.all.forwarding is configured"
        _sysctl_check "3.3.2.2" "net.ipv6.conf.default.forwarding" "0" \
            "Ensure net.ipv6.conf.default.forwarding is configured"
        _sysctl_check "3.3.2.3" "net.ipv6.conf.all.accept_redirects" "0" \
            "Ensure net.ipv6.conf.all.accept_redirects is configured"
        _sysctl_check "3.3.2.4" "net.ipv6.conf.default.accept_redirects" "0" \
            "Ensure net.ipv6.conf.default.accept_redirects is configured"
        _sysctl_check "3.3.2.5" "net.ipv6.conf.all.accept_source_route" "0" \
            "Ensure net.ipv6.conf.all.accept_source_route is configured"
        _sysctl_check "3.3.2.6" "net.ipv6.conf.default.accept_source_route" "0" \
            "Ensure net.ipv6.conf.default.accept_source_route is configured"
        _sysctl_check "3.3.2.7" "net.ipv6.conf.all.accept_ra" "0" \
            "Ensure net.ipv6.conf.all.accept_ra is configured"
        _sysctl_check "3.3.2.8" "net.ipv6.conf.default.accept_ra" "0" \
            "Ensure net.ipv6.conf.default.accept_ra is configured"
    else
        # Skip IPv6 params with note
        for id in 3.3.2.1 3.3.2.2 3.3.2.3 3.3.2.4 3.3.2.5 3.3.2.6 3.3.2.7 3.3.2.8; do
            record "$id" "N/A: IPv6 not in use" \
                "IPv6 kernel parameter check (${id})" \
                "IPv6 is not in active use. This parameter is not applicable."
        done
    fi
}