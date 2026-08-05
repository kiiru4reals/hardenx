#!/usr/bin/env bash
# Adhiambo Ubuntu Engine — Section 2: Services

section2_run() {
    print_section "2" "Services"

    # ── 2.1 Configure Server Services ────────────────────────────────────────
    print_subsection "2.1" "Configure Server Services"

    # Helper: package-not-in-use check
    _svc_not_in_use() {
        local id="$1" desc="$2" rem="$3"; shift 3
        local pkgs=("$@")
        local found_pkg=""
        for pkg in "${pkgs[@]}"; do
            if dpkg-query -s "$pkg" &>/dev/null 2>&1; then
                found_pkg="$pkg"; break
            fi
        done
        if [[ -z "$found_pkg" ]]; then
            record "$id" "PASS" "$desc" ""
        else
            record "$id" "FAIL" "$desc" "$rem"
        fi
    }

    # 2.1.1 autofs
    _svc_not_in_use "2.1.1" "Ensure autofs services are not in use" \
        "Remove autofs: apt purge autofs" "autofs"

    # 2.1.2 MTA local-only — check not listening on non-loopback
    local mta_listening
    mta_listening=$(ss -lntp 2>/dev/null | grep -E ":25\b" | \
        grep -vE "127\.0\.0\.1|::1|127\.0\.1\.1")
    if [[ -z "$mta_listening" ]]; then
        record "2.1.2" "PASS" \
            "Ensure mail transfer agents are configured for local-only mode" ""
    else
        record "2.1.2" "FAIL" \
            "Ensure mail transfer agents are configured for local-only mode" \
            "MTA is listening on non-loopback address. Configure MTA for local delivery only.
For postfix: set 'inet_interfaces = loopback-only' in /etc/postfix/main.cf
Listening: ${mta_listening}"
    fi

    # 2.1.3 avahi
    _svc_not_in_use "2.1.3" "Ensure avahi daemon services are not in use" \
        "Remove avahi: apt purge avahi-daemon" "avahi-daemon"

    # 2.1.4 — Manual: only approved services listening
    local listening_svcs
    listening_svcs=$(ss -lntp 2>/dev/null | grep LISTEN | head -30)
    record "2.1.4" "MANUAL_REVIEW" \
        "Ensure only approved services are listening on a network interface" \
        "Review all listening services and confirm each is approved:
${listening_svcs}
Command: ss -lntp
Investigate any unexpected ports and remove or disable the associated service."

    # 2.1.5 DHCP server
    if [[ "$HOST_DHCP_SERVER" == "true" ]]; then
        record "2.1.5" "N/A: DHCP server" \
            "Ensure dhcp server services are not in use" \
            "This host is a DHCP server. The service is intentionally running."
    else
        _svc_not_in_use "2.1.5" "Ensure dhcp server services are not in use" \
            "Remove DHCP server: apt purge isc-dhcp-server kea" \
            "isc-dhcp-server" "kea-dhcp4-server" "kea"
    fi

    # 2.1.6 Web server
    if [[ "$HOST_WEB_SERVER" == "true" ]]; then
        record "2.1.6" "N/A: web server" \
            "Ensure web server services are not in use" \
            "This host is a web server. The service is intentionally running."
    else
        _svc_not_in_use "2.1.6" "Ensure web server services are not in use" \
            "Remove web server: apt purge apache2 nginx" "apache2" "nginx"
    fi

    # 2.1.7 DNS server
    if [[ "$HOST_DNS_SERVER" == "true" ]]; then
        record "2.1.7" "N/A: DNS server" \
            "Ensure dns server services are not in use" \
            "This host is a DNS server. The service is intentionally running."
    else
        _svc_not_in_use "2.1.7" "Ensure dns server services are not in use" \
            "Remove DNS server: apt purge bind9" "bind9"
    fi

    # 2.1.8 FTP server
    _svc_not_in_use "2.1.8" "Ensure ftp server services are not in use" \
        "Remove FTP server: apt purge vsftpd" "vsftpd"

    # 2.1.9 dnsmasq
    _svc_not_in_use "2.1.9" "Ensure dnsmasq services are not in use" \
        "Remove dnsmasq: apt purge dnsmasq" "dnsmasq"

    # 2.1.10 LDAP server
    if [[ "$HOST_LDAP_SERVER" == "true" ]]; then
        record "2.1.10" "N/A: LDAP server" \
            "Ensure ldap server services are not in use" \
            "This host is an LDAP server. The service is intentionally running."
    else
        _svc_not_in_use "2.1.10" "Ensure ldap server services are not in use" \
            "Remove LDAP server: apt purge slapd" "slapd"
    fi

    # 2.1.11 Message access server (POP/IMAP)
    if [[ "$HOST_POP_IMAP_SERVER" == "true" ]]; then
        record "2.1.11" "N/A: POP/IMAP server" \
            "Ensure message access server services are not in use" \
            "This host provides POP/IMAP services. The service is intentionally running."
    else
        _svc_not_in_use "2.1.11" "Ensure message access server services are not in use" \
            "Remove dovecot: apt purge dovecot-imapd dovecot-pop3d" \
            "dovecot-imapd" "dovecot-pop3d"
    fi

    # 2.1.12 NFS
    _svc_not_in_use "2.1.12" "Ensure network file system services are not in use" \
        "Remove NFS: apt purge nfs-kernel-server" "nfs-kernel-server"

    # 2.1.13 NIS server
    _svc_not_in_use "2.1.13" "Ensure nis server services are not in use" \
        "Remove NIS: apt purge nis" "nis"

    # 2.1.14 Print server
    _svc_not_in_use "2.1.14" "Ensure print server services are not in use" \
        "Remove CUPS: apt purge cups" "cups"

    # 2.1.15 rpcbind
    _svc_not_in_use "2.1.15" "Ensure rpcbind services are not in use" \
        "Remove rpcbind: apt purge rpcbind" "rpcbind"

    # 2.1.16 rsync
    _svc_not_in_use "2.1.16" "Ensure rsync services are not in use" \
        "Remove rsync server: apt purge rsync
Note: rsync client is acceptable; only the rsync daemon is a concern." "rsync"

    # 2.1.17 Samba
    _svc_not_in_use "2.1.17" "Ensure samba file server services are not in use" \
        "Remove Samba: apt purge samba" "samba"

    # 2.1.18 SNMP
    _svc_not_in_use "2.1.18" "Ensure snmp services are not in use" \
        "Remove SNMP: apt purge snmpd" "snmpd"

    # 2.1.19 Telnet server
    _svc_not_in_use "2.1.19" "Ensure telnet server services are not in use" \
        "Remove telnet server: apt purge telnetd" "telnetd"

    # 2.1.20 TFTP
    _svc_not_in_use "2.1.20" "Ensure tftp server services are not in use" \
        "Remove TFTP: apt purge tftpd-hpa atftpd" "tftpd-hpa" "atftpd"

    # 2.1.21 Web proxy
    _svc_not_in_use "2.1.21" "Ensure web proxy server services are not in use" \
        "Remove Squid: apt purge squid" "squid"

    # 2.1.22 xinetd
    _svc_not_in_use "2.1.22" "Ensure xinetd services are not in use" \
        "Remove xinetd: apt purge xinetd" "xinetd"

    # 2.1.23 X window server
    if dpkg-query -s xorg &>/dev/null 2>&1 || dpkg-query -s xserver-xorg &>/dev/null 2>&1; then
        record "2.1.23" "FAIL" "Ensure X window server services are not in use" \
            "Remove X Window Server: apt purge xorg xserver-xorg && apt autoremove"
    else
        record "2.1.23" "PASS" "Ensure X window server services are not in use" ""
    fi

    flush_manual_block "SECTION 2.1"

    # ── 2.2 Configure Client Services ─────────────────────────────────────────
    print_subsection "2.2" "Configure Client Services"

    _svc_not_in_use "2.2.1" "Ensure nis client is not installed" \
        "Remove NIS client: apt purge nis" "nis"

    _svc_not_in_use "2.2.2" "Ensure rsh client is not installed" \
        "Remove rsh client: apt purge rsh-client" "rsh-client"

    _svc_not_in_use "2.2.3" "Ensure talk client is not installed" \
        "Remove talk: apt purge talk" "talk"

    _svc_not_in_use "2.2.4" "Ensure telnet client is not installed" \
        "Remove telnet client: apt purge telnet" "telnet"

    # 2.2.5 LDAP client
    if [[ "$HOST_LDAP_CLIENT" == "true" ]]; then
        record "2.2.5" "N/A: LDAP client" \
            "Ensure ldap client is not installed" \
            "This host is configured as an LDAP client. The client is intentionally installed."
    else
        _svc_not_in_use "2.2.5" "Ensure ldap client is not installed" \
            "Remove LDAP client: apt purge ldap-utils libpam-ldapd" \
            "ldap-utils" "libpam-ldapd"
    fi

    _svc_not_in_use "2.2.6" "Ensure ftp client is not installed" \
        "Remove FTP client: apt purge ftp" "ftp"

    # ── 2.3 Configure Time Synchronization ────────────────────────────────────
    print_subsection "2.3" "Configure Time Synchronization"

    # 2.3.1.1 Single time daemon
    if [[ "$HOST_HYPERVISOR_DETECTED" == "true" ]]; then
        record "2.3.1.1" "N/A: virtualised environment" \
            "Ensure a single time synchronization daemon is in use" \
            "Host is running in a virtualised environment; time synchronization may be handled by the hypervisor."
    else
        local ntp_daemons=()
        systemctl is-active systemd-timesyncd &>/dev/null && ntp_daemons+=("systemd-timesyncd")
        systemctl is-active chronyd &>/dev/null && ntp_daemons+=("chronyd")
        systemctl is-active ntpd &>/dev/null && ntp_daemons+=("ntpd")

        if [[ ${#ntp_daemons[@]} -eq 1 ]]; then
            record "2.3.1.1" "PASS" "Ensure a single time synchronization daemon is in use" ""
        elif [[ ${#ntp_daemons[@]} -eq 0 ]]; then
            record "2.3.1.1" "FAIL" "Ensure a single time synchronization daemon is in use" \
                "No time synchronization daemon is active. Enable one:
  systemctl enable --now systemd-timesyncd  (simplest option)
  OR install chrony: apt install chrony && systemctl enable --now chronyd"
        else
            record "2.3.1.1" "FAIL" "Ensure a single time synchronization daemon is in use" \
                "Multiple time daemons active: ${ntp_daemons[*]}
  Disable all but one. Recommendation: keep chronyd or systemd-timesyncd."
        fi
    fi

    # 2.3.2.x systemd-timesyncd checks
    if systemctl is-active systemd-timesyncd &>/dev/null; then
        print_subsection "2.3.2" "Configure systemd-timesyncd"

        local ts_conf
        ts_conf=$(grep -Eh "^NTP=|^FallbackNTP=" \
            /etc/systemd/timesyncd.conf \
            /etc/systemd/timesyncd.conf.d/*.conf 2>/dev/null)
        if echo "$ts_conf" | grep -q "^NTP="; then
            record "2.3.2.1" "PASS" \
                "Ensure systemd-timesyncd configured with authorized timeserver" ""
        else
            record "2.3.2.1" "FAIL" \
                "Ensure systemd-timesyncd configured with authorized timeserver" \
                "Set NTP= in /etc/systemd/timesyncd.conf (under [Time]):
  NTP=<ntp-server-1> <ntp-server-2>
  Then: systemctl restart systemd-timesyncd"
        fi

        if systemctl is-enabled systemd-timesyncd &>/dev/null; then
            record "2.3.2.2" "PASS" \
                "Ensure systemd-timesyncd is enabled and running" ""
        else
            record "2.3.2.2" "FAIL" \
                "Ensure systemd-timesyncd is enabled and running" \
                "Enable: systemctl enable --now systemd-timesyncd"
        fi
    fi

    # 2.3.3.x chrony checks
    if systemctl is-active chronyd &>/dev/null; then
        print_subsection "2.3.3" "Configure chrony"

        local chrony_servers
        chrony_servers=$(grep -Eh "^server|^pool" /etc/chrony/chrony.conf 2>/dev/null | head -5)
        if [[ -n "$chrony_servers" ]]; then
            record "2.3.3.1" "PASS" "Ensure chrony is configured" ""
        else
            record "2.3.3.1" "FAIL" "Ensure chrony is configured" \
                "Add NTP servers to /etc/chrony/chrony.conf:
  server <ntp-server> iburst
  Then: systemctl restart chronyd"
        fi

        local chrony_user
        chrony_user=$(ps -eo user,comm 2>/dev/null | awk '/chronyd/{print $1}' | head -1)
        if [[ "$chrony_user" == "_chrony" || "$chrony_user" == "chrony" ]]; then
            record "2.3.3.2" "PASS" "Ensure chrony is running as user _chrony" ""
        else
            record "2.3.3.2" "FAIL" "Ensure chrony is running as user _chrony" \
                "Set user in /etc/chrony/chrony.conf: user _chrony"
        fi

        if systemctl is-enabled chronyd &>/dev/null; then
            record "2.3.3.3" "PASS" "Ensure chrony is enabled and running" ""
        else
            record "2.3.3.3" "FAIL" "Ensure chrony is enabled and running" \
                "Enable: systemctl enable --now chronyd"
        fi
    fi

    # ── 2.4 Job Schedulers ────────────────────────────────────────────────────
    print_subsection "2.4" "Job Schedulers"

    # 2.4.1.x cron
    if [[ "$HOST_CRON_INSTALLED" == "false" ]]; then
        for cid in 2.4.1.1 2.4.1.2 2.4.1.3 2.4.1.4 2.4.1.5 2.4.1.6 2.4.1.7 2.4.1.8 2.4.1.9; do
            record "$cid" "N/A: cron not installed" \
                "Cron check (${cid})" "cron is not installed on this host."
        done
    else
        print_subsection "2.4.1" "Configure cron"

        # 2.4.1.1 daemon active
        if systemctl is-enabled cron &>/dev/null && \
           systemctl is-active cron &>/dev/null; then
            record "2.4.1.1" "PASS" "Ensure cron daemon is enabled and active" ""
        else
            record "2.4.1.1" "FAIL" "Ensure cron daemon is enabled and active" \
                "Enable and start cron: systemctl enable --now cron"
        fi

        # cron file permission checks
        local cron_perms=(
            "2.4.1.2:/etc/crontab:600:root:root"
            "2.4.1.3:/etc/cron.hourly:700:root:root"
            "2.4.1.4:/etc/cron.daily:700:root:root"
            "2.4.1.5:/etc/cron.weekly:700:root:root"
            "2.4.1.6:/etc/cron.monthly:700:root:root"
            "2.4.1.7:/etc/cron.yearly:700:root:root"  # may not exist
            "2.4.1.8:/etc/cron.d:700:root:root"
        )
        for entry in "${cron_perms[@]}"; do
            IFS=':' read -r cid cpath cperm cowner cgroup <<< "$entry"
            local cdesc="Ensure access to ${cpath} is configured"
            if [[ ! -e "$cpath" ]]; then
                record "$cid" "N/A: path absent" "$cdesc" "${cpath} does not exist."
                continue
            fi
            if check_file_perms "$cpath" "$cperm" "$cowner" "$cgroup"; then
                record "$cid" "PASS" "$cdesc" ""
            else
                local cstat
                cstat=$(stat -Lc 'Mode:%#a Owner:%U Group:%G' "$cpath")
                record "$cid" "FAIL" "$cdesc" \
                    "Fix: chmod ${cperm} ${cpath} && chown ${cowner}:${cgroup} ${cpath}
  Actual: ${cstat}"
            fi
        done

        # 2.4.1.9 crontab access (cron.allow / cron.deny)
        local cron_allow="/etc/cron.allow"
        local cron_deny="/etc/cron.d/cron.deny"
        if [[ -f "$cron_allow" ]]; then
            if check_file_perms "$cron_allow" "640" "root" "crontab"; then
                record "2.4.1.9" "PASS" "Ensure access to crontab is configured" ""
            else
                record "2.4.1.9" "FAIL" "Ensure access to crontab is configured" \
                    "Fix: chmod 640 ${cron_allow} && chown root:crontab ${cron_allow}"
            fi
        else
            record "2.4.1.9" "FAIL" "Ensure access to crontab is configured" \
                "Create /etc/cron.allow listing only users permitted to use cron.
  touch /etc/cron.allow && chmod 640 /etc/cron.allow && chown root:crontab /etc/cron.allow"
        fi
    fi

    # 2.4.2.1 at
    if [[ "$HOST_AT_INSTALLED" == "false" ]]; then
        record "2.4.2.1" "N/A: at not installed" \
            "Ensure access to at is configured" "at is not installed on this host."
    else
        print_subsection "2.4.2" "Configure at"
        local at_allow="/etc/at.allow"
        if [[ -f "$at_allow" ]]; then
            if check_file_perms "$at_allow" "640" "root" "daemon"; then
                record "2.4.2.1" "PASS" "Ensure access to at is configured" ""
            else
                local at_stat
                at_stat=$(stat -Lc 'Mode:%#a Owner:%U Group:%G' "$at_allow")
                record "2.4.2.1" "FAIL" "Ensure access to at is configured" \
                    "Fix: chmod 640 ${at_allow} && chown root:daemon ${at_allow}
  Actual: ${at_stat}"
            fi
        else
            record "2.4.2.1" "FAIL" "Ensure access to at is configured" \
                "Create /etc/at.allow with permitted users and remove /etc/at.deny:
  touch /etc/at.allow && chmod 640 /etc/at.allow && chown root:daemon /etc/at.allow
  rm -f /etc/at.deny"
        fi
    fi
}