#!/usr/bin/env bash
# HardenX Ubuntu Engine — Section 5: Access Control

section5_run() {
    print_section "5" "Access Control"

    # ── 5.1 Configure SSH Server ──────────────────────────────────────────────
    print_subsection "5.1" "Configure SSH Server"

    # Helper: get effective sshd config value
    _sshd_val() { sshd -T 2>/dev/null | grep -i "^${1}\b" | awk '{print $2}' | head -1; }

    # 5.1.1 sshd_config access
    local sshd_conf_bad
    sshd_conf_bad=$(find /etc/ssh/sshd_config.d/ -type f -name "*.conf" \
        \( -perm /077 -o ! -user root -o ! -group root \) 2>/dev/null)
    if check_file_perms "/etc/ssh/sshd_config" "600" "root" "root" && \
       [[ -z "$sshd_conf_bad" ]]; then
        record "5.1.1" "PASS" "Ensure access to /etc/ssh/sshd_config is configured" ""
    else
        local sshd_stat
        sshd_stat=$(stat -Lc 'Mode:%#a Owner:%U Group:%G' /etc/ssh/sshd_config 2>/dev/null)
        record "5.1.1" "FAIL" "Ensure access to /etc/ssh/sshd_config is configured" \
            "Fix sshd_config permissions:
  chmod 600 /etc/ssh/sshd_config && chown root:root /etc/ssh/sshd_config
  Actual: ${sshd_stat}
  Also fix any files in /etc/ssh/sshd_config.d/ with permissions wider than 600."
    fi

    # 5.1.2 SSH private host keys
    local bad_priv_keys
    bad_priv_keys=$(find /etc/ssh -type f -name "ssh_host_*_key" \
        \( -perm /177 -o ! -user root \) 2>/dev/null)
    if [[ -z "$bad_priv_keys" ]]; then
        record "5.1.2" "PASS" \
            "Ensure access to SSH private host key files is configured" ""
    else
        record "5.1.2" "FAIL" \
            "Ensure access to SSH private host key files is configured" \
            "Fix private key permissions:
  find /etc/ssh -type f -name 'ssh_host_*_key' -exec chmod 600 {} \; -exec chown root:root {} \;
  Files with wrong permissions: ${bad_priv_keys}"
    fi

    # 5.1.3 SSH public host keys
    local bad_pub_keys
    bad_pub_keys=$(find /etc/ssh -type f -name "ssh_host_*_key.pub" \
        \( -perm /133 -o ! -user root \) 2>/dev/null)
    if [[ -z "$bad_pub_keys" ]]; then
        record "5.1.3" "PASS" \
            "Ensure access to SSH public host key files is configured" ""
    else
        record "5.1.3" "FAIL" \
            "Ensure access to SSH public host key files is configured" \
            "Fix public key permissions:
  find /etc/ssh -type f -name 'ssh_host_*_key.pub' -exec chmod 644 {} \; -exec chown root:root {} \;"
    fi

    # 5.1.4 sshd access (AllowUsers/AllowGroups or DenyUsers/DenyGroups)
    local sshd_access
    sshd_access=$(sshd -T 2>/dev/null | grep -iE "^(allowusers|allowgroups|denyusers|denygroups)\b")
    if [[ -n "$sshd_access" ]]; then
        record "5.1.4" "PASS" "Ensure sshd access is configured" ""
    else
        record "5.1.4" "FAIL" "Ensure sshd access is configured" \
            "Restrict SSH access in /etc/ssh/sshd_config:
  AllowGroups <group>   (only allow specific group)
  OR DenyUsers <user>   (deny specific users)
  Then: systemctl reload sshd"
    fi

    # 5.1.5 Banner
    local sshd_banner
    sshd_banner=$(_sshd_val "banner")
    if [[ -n "$sshd_banner" && "$sshd_banner" != "none" ]]; then
        record "5.1.5" "PASS" "Ensure sshd Banner is configured" ""
    else
        record "5.1.5" "FAIL" "Ensure sshd Banner is configured" \
            "Set Banner in /etc/ssh/sshd_config: Banner /etc/issue.net
  Then: systemctl reload sshd"
    fi

    # 5.1.6 Ciphers
    local sshd_ciphers
    sshd_ciphers=$(_sshd_val "ciphers")
    # Weak ciphers to check for absence
    local weak_ciphers="3des-cbc|aes128-cbc|aes192-cbc|aes256-cbc|arcfour|blowfish|cast128|rc4"
    if [[ -n "$sshd_ciphers" ]] && ! echo "$sshd_ciphers" | grep -qiE "$weak_ciphers"; then
        record "5.1.6" "PASS" "Ensure sshd Ciphers are configured" ""
    else
        record "5.1.6" "FAIL" "Ensure sshd Ciphers are configured" \
            "Configure strong ciphers in /etc/ssh/sshd_config:
  Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
  Current: ${sshd_ciphers:-not set}
  Then: systemctl reload sshd"
    fi

    # 5.1.7 ClientAliveInterval / ClientAliveCountMax
    local sshd_interval sshd_count
    sshd_interval=$(_sshd_val "clientaliveinterval")
    sshd_count=$(_sshd_val "clientalivecountmax")
    if [[ "${sshd_interval:-0}" -gt 0 && "${sshd_count:-0}" -gt 0 ]]; then
        record "5.1.7" "PASS" \
            "Ensure sshd ClientAliveInterval and ClientAliveCountMax are configured" ""
    else
        record "5.1.7" "FAIL" \
            "Ensure sshd ClientAliveInterval and ClientAliveCountMax are configured" \
            "Set in /etc/ssh/sshd_config:
  ClientAliveInterval 15
  ClientAliveCountMax 3
  Current: ClientAliveInterval=${sshd_interval:-0}, ClientAliveCountMax=${sshd_count:-0}
  Then: systemctl reload sshd"
    fi

    # 5.1.8 DisableForwarding — L2
    if [[ "$SCAN_LEVEL" -ge 2 ]]; then
        local sshd_fwd
        sshd_fwd=$(_sshd_val "disableforwarding")
        if [[ "$sshd_fwd" == "yes" ]]; then
            record "5.1.8" "PASS" "Ensure sshd DisableForwarding is enabled" ""
        else
            record "5.1.8" "FAIL" "Ensure sshd DisableForwarding is enabled" \
                "Set DisableForwarding yes in /etc/ssh/sshd_config
  Then: systemctl reload sshd"
        fi
    fi

    # 5.1.9 GSSAPIAuthentication — L2
    if [[ "$SCAN_LEVEL" -ge 2 ]]; then
        local sshd_gss
        sshd_gss=$(_sshd_val "gssapiauthentication")
        if [[ "$sshd_gss" == "no" ]]; then
            record "5.1.9" "PASS" "Ensure sshd GSSAPIAuthentication is disabled" ""
        else
            record "5.1.9" "FAIL" "Ensure sshd GSSAPIAuthentication is disabled" \
                "Set GSSAPIAuthentication no in /etc/ssh/sshd_config
  Then: systemctl reload sshd"
        fi
    fi

    # 5.1.10 HostbasedAuthentication
    local sshd_hba
    sshd_hba=$(_sshd_val "hostbasedauthentication")
    if [[ "$sshd_hba" == "no" ]]; then
        record "5.1.10" "PASS" "Ensure sshd HostbasedAuthentication is disabled" ""
    else
        record "5.1.10" "FAIL" "Ensure sshd HostbasedAuthentication is disabled" \
            "Set HostbasedAuthentication no in /etc/ssh/sshd_config
  Then: systemctl reload sshd"
    fi

    # 5.1.11 IgnoreRhosts
    local sshd_rhosts
    sshd_rhosts=$(_sshd_val "ignorerhosts")
    if [[ "$sshd_rhosts" == "yes" ]]; then
        record "5.1.11" "PASS" "Ensure sshd IgnoreRhosts is enabled" ""
    else
        record "5.1.11" "FAIL" "Ensure sshd IgnoreRhosts is enabled" \
            "Set IgnoreRhosts yes in /etc/ssh/sshd_config
  Then: systemctl reload sshd"
    fi

    # 5.1.12 KexAlgorithms
    local sshd_kex
    sshd_kex=$(_sshd_val "kexalgorithms")
    local weak_kex="diffie-hellman-group1\|diffie-hellman-group14-sha1\|diffie-hellman-group-exchange-sha1"
    if [[ -n "$sshd_kex" ]] && ! echo "$sshd_kex" | grep -q "$weak_kex"; then
        record "5.1.12" "PASS" "Ensure sshd KexAlgorithms is configured" ""
    else
        record "5.1.12" "FAIL" "Ensure sshd KexAlgorithms is configured" \
            "Configure strong KexAlgorithms in /etc/ssh/sshd_config — remove weak DH variants.
  Current: ${sshd_kex:-not set}"
    fi

    # 5.1.13 LoginGraceTime
    local sshd_grace
    sshd_grace=$(_sshd_val "logingracetime")
    if [[ "${sshd_grace:-0}" -gt 0 && "${sshd_grace:-61}" -le 60 ]]; then
        record "5.1.13" "PASS" "Ensure sshd LoginGraceTime is configured" ""
    else
        record "5.1.13" "FAIL" "Ensure sshd LoginGraceTime is configured" \
            "Set LoginGraceTime to 60 or less in /etc/ssh/sshd_config:
  LoginGraceTime 60
  Current: ${sshd_grace:-not set}
  Then: systemctl reload sshd"
    fi

    # 5.1.14 LogLevel
    local sshd_loglevel
    sshd_loglevel=$(_sshd_val "loglevel")
    if echo "$sshd_loglevel" | grep -qiE "^(VERBOSE|INFO)$"; then
        record "5.1.14" "PASS" "Ensure sshd LogLevel is configured" ""
    else
        record "5.1.14" "FAIL" "Ensure sshd LogLevel is configured" \
            "Set LogLevel VERBOSE in /etc/ssh/sshd_config
  Current: ${sshd_loglevel:-not set}
  Then: systemctl reload sshd"
    fi

    # 5.1.15 MACs
    local sshd_macs
    sshd_macs=$(_sshd_val "macs")
    local weak_macs="hmac-md5\|hmac-sha1\|umac-64\|hmac-ripemd"
    if [[ -n "$sshd_macs" ]] && ! echo "$sshd_macs" | grep -q "$weak_macs"; then
        record "5.1.15" "PASS" "Ensure sshd MACs are configured" ""
    else
        record "5.1.15" "FAIL" "Ensure sshd MACs are configured" \
            "Configure strong MACs — remove weak HMAC variants.
  Recommended: hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
  Current: ${sshd_macs:-not set}"
    fi

    # 5.1.16 MaxAuthTries
    local sshd_maxauth
    sshd_maxauth=$(_sshd_val "maxauthtries")
    if [[ "${sshd_maxauth:-0}" -gt 0 && "${sshd_maxauth:-5}" -le 4 ]]; then
        record "5.1.16" "PASS" "Ensure sshd MaxAuthTries is configured" ""
    else
        record "5.1.16" "FAIL" "Ensure sshd MaxAuthTries is configured" \
            "Set MaxAuthTries 4 or lower in /etc/ssh/sshd_config
  Current: ${sshd_maxauth:-not set}
  Then: systemctl reload sshd"
    fi

    # 5.1.17 MaxStartups
    local sshd_maxstart
    sshd_maxstart=$(_sshd_val "maxstartups")
    # Expect 10:30:60 or lower
    if [[ -n "$sshd_maxstart" ]]; then
        record "5.1.17" "PASS" "Ensure sshd MaxStartups is configured" ""
    else
        record "5.1.17" "FAIL" "Ensure sshd MaxStartups is configured" \
            "Set MaxStartups 10:30:60 in /etc/ssh/sshd_config
  Then: systemctl reload sshd"
    fi

    # 5.1.18 MaxSessions
    local sshd_maxsess
    sshd_maxsess=$(_sshd_val "maxsessions")
    if [[ "${sshd_maxsess:-0}" -gt 0 && "${sshd_maxsess:-11}" -le 10 ]]; then
        record "5.1.18" "PASS" "Ensure sshd MaxSessions is configured" ""
    else
        record "5.1.18" "FAIL" "Ensure sshd MaxSessions is configured" \
            "Set MaxSessions 10 or lower in /etc/ssh/sshd_config
  Current: ${sshd_maxsess:-not set}
  Then: systemctl reload sshd"
    fi

    # 5.1.19 PermitEmptyPasswords
    local sshd_empty
    sshd_empty=$(_sshd_val "permitemptypasswords")
    if [[ "$sshd_empty" == "no" ]]; then
        record "5.1.19" "PASS" "Ensure sshd PermitEmptyPasswords is disabled" ""
    else
        record "5.1.19" "FAIL" "Ensure sshd PermitEmptyPasswords is disabled" \
            "Set PermitEmptyPasswords no in /etc/ssh/sshd_config
  Then: systemctl reload sshd"
    fi

    # 5.1.20 PermitRootLogin
    local sshd_rootlogin
    sshd_rootlogin=$(_sshd_val "permitrootlogin")
    if [[ "$sshd_rootlogin" == "no" ]]; then
        record "5.1.20" "PASS" "Ensure sshd PermitRootLogin is disabled" ""
    else
        record "5.1.20" "FAIL" "Ensure sshd PermitRootLogin is disabled" \
            "Set PermitRootLogin no in /etc/ssh/sshd_config
  Current: ${sshd_rootlogin:-not set}
  Then: systemctl reload sshd"
    fi

    # 5.1.21 PermitUserEnvironment
    local sshd_userenv
    sshd_userenv=$(_sshd_val "permituserenvironment")
    if [[ "$sshd_userenv" == "no" ]]; then
        record "5.1.21" "PASS" "Ensure sshd PermitUserEnvironment is disabled" ""
    else
        record "5.1.21" "FAIL" "Ensure sshd PermitUserEnvironment is disabled" \
            "Set PermitUserEnvironment no in /etc/ssh/sshd_config
  Then: systemctl reload sshd"
    fi

    # 5.1.22 UsePAM
    local sshd_pam
    sshd_pam=$(_sshd_val "usepam")
    if [[ "$sshd_pam" == "yes" ]]; then
        record "5.1.22" "PASS" "Ensure sshd UsePAM is enabled" ""
    else
        record "5.1.22" "FAIL" "Ensure sshd UsePAM is enabled" \
            "Set UsePAM yes in /etc/ssh/sshd_config
  Then: systemctl reload sshd"
    fi

    # 5.1.23 Post-quantum KexAlgorithms
    local sshd_pq
    sshd_pq=$(_sshd_val "kexalgorithms")
    if echo "$sshd_pq" | grep -qiE "mlkem|sntrup|kyber"; then
        record "5.1.23" "PASS" \
            "Ensure sshd post-quantum cryptography key exchange algorithms are configured" ""
    else
        record "5.1.23" "FAIL" \
            "Ensure sshd post-quantum cryptography key exchange algorithms are configured" \
            "Add a post-quantum KexAlgorithm such as sntrup761x25519-sha512@openssh.com
  to the KexAlgorithms list in /etc/ssh/sshd_config
  Current KexAlgorithms: ${sshd_pq:-not set}"
    fi

    # 5.1.24 ListenAddress — L2
    if [[ "$SCAN_LEVEL" -ge 2 ]]; then
        local sshd_listen
        sshd_listen=$(sshd -T 2>/dev/null | grep -i "^listenaddress" | awk '{print $2}')
        if [[ -n "$sshd_listen" && "$sshd_listen" != "0.0.0.0" && "$sshd_listen" != "::" ]]; then
            record "5.1.24" "PASS" "Ensure sshd ListenAddress is configured" ""
        else
            record "5.1.24" "MANUAL_REVIEW" "Ensure sshd ListenAddress is configured" \
                "sshd is listening on all interfaces (${sshd_listen:-not set}).
Confirm whether a specific ListenAddress should be configured:
  ListenAddress <specific-ip>
in /etc/ssh/sshd_config.
Command: sshd -T | grep listenaddress"
        fi
    fi

    flush_manual_block "SECTION 5.1"

    # ── 5.2 Configure Privilege Escalation ───────────────────────────────────
    print_subsection "5.2" "Configure Privilege Escalation"

    # sudo-ldap check (LDAP environments)
    if [[ "$HOST_LDAP_SERVER" == "true" || "$HOST_LDAP_CLIENT" == "true" ]]; then
        if [[ "$HOST_SUDO_LDAP_INSTALLED" == "true" ]]; then
            record "5.2.LDAP" "PASS" \
                "Ensure sudo-ldap is installed in LDAP environment" ""
        elif dpkg-query -s sudo &>/dev/null 2>&1; then
            record "5.2.LDAP" "FAIL" \
                "Ensure sudo-ldap is installed in LDAP environment" \
                "This host uses LDAP but has standard sudo instead of sudo-ldap.
  sudo-ldap allows sudo policy to be managed centrally via the directory.
  Install: apt install sudo-ldap && apt remove sudo"
        else
            record "5.2.LDAP" "FAIL" \
                "Ensure sudo-ldap is installed in LDAP environment" \
                "Neither sudo nor sudo-ldap is installed. Install: apt install sudo-ldap"
        fi
    fi

    # 5.2.1 sudo installed
    if dpkg-query -s sudo &>/dev/null 2>&1 || \
       dpkg-query -s sudo-ldap &>/dev/null 2>&1; then
        record "5.2.1" "PASS" "Ensure sudo is installed" ""
    else
        record "5.2.1" "FAIL" "Ensure sudo is installed" \
            "Install sudo: apt install sudo"
    fi

    # 5.2.2 sudo pty
    if grep -rqE "^\s*Defaults\s+.*use_pty\b" \
       /etc/sudoers /etc/sudoers.d/ 2>/dev/null; then
        record "5.2.2" "PASS" "Ensure sudo commands use pty" ""
    else
        record "5.2.2" "FAIL" "Ensure sudo commands use pty" \
            "Add to /etc/sudoers.d/99-cis-sudo: Defaults use_pty"
    fi

    # 5.2.3 sudo log file
    if grep -rqE "^\s*Defaults\s+.*logfile\s*=" \
       /etc/sudoers /etc/sudoers.d/ 2>/dev/null; then
        record "5.2.3" "PASS" "Ensure sudo log file exists" ""
    else
        record "5.2.3" "FAIL" "Ensure sudo log file exists" \
            "Add to /etc/sudoers.d/99-cis-sudo: Defaults logfile=\"/var/log/sudo.log\""
    fi

    # 5.2.4 users must provide password
    local nopasswd_check
    nopasswd_check=$(grep -rE "^\s*[^#].*NOPASSWD" \
        /etc/sudoers /etc/sudoers.d/ 2>/dev/null | head -5)
    if [[ -z "$nopasswd_check" ]]; then
        record "5.2.4" "PASS" "Ensure users must provide password for escalation" ""
    else
        record "5.2.4" "FAIL" "Ensure users must provide password for escalation" \
            "NOPASSWD found in sudoers — remove or restrict:
${nopasswd_check}"
    fi

    # 5.2.5 re-authentication not disabled globally
    local noauthenticate
    noauthenticate=$(grep -rE "^\s*Defaults\s+.*\!authenticate\b" \
        /etc/sudoers /etc/sudoers.d/ 2>/dev/null | head -3)
    if [[ -z "$noauthenticate" ]]; then
        record "5.2.5" "PASS" \
            "Ensure re-authentication for privilege escalation is not disabled globally" ""
    else
        record "5.2.5" "FAIL" \
            "Ensure re-authentication for privilege escalation is not disabled globally" \
            "Remove '!authenticate' from sudoers global Defaults:
${noauthenticate}"
    fi

    # 5.2.6 timestamp_timeout
    local sudo_timeout
    sudo_timeout=$(grep -rEo "timestamp_timeout\s*=\s*[0-9]+" \
        /etc/sudoers /etc/sudoers.d/ 2>/dev/null | \
        awk -F= '{print $2}' | sort -n | head -1)
    if [[ -n "$sudo_timeout" && "$sudo_timeout" -le 15 ]]; then
        record "5.2.6" "PASS" "Ensure sudo timestamp_timeout is configured" ""
    else
        record "5.2.6" "FAIL" "Ensure sudo timestamp_timeout is configured" \
            "Set timestamp_timeout to 15 or lower in /etc/sudoers.d/99-cis-sudo:
  Defaults timestamp_timeout=15
  Current: ${sudo_timeout:-not set}"
    fi

    # 5.2.7 su command restricted
    if grep -qE "^\s*auth\s+required\s+pam_wheel\.so" \
       /etc/pam.d/su 2>/dev/null; then
        record "5.2.7" "PASS" "Ensure access to the su command is restricted" ""
    else
        record "5.2.7" "FAIL" "Ensure access to the su command is restricted" \
            "Restrict su to wheel group. Add to /etc/pam.d/su:
  auth required pam_wheel.so use_uid
  Create wheel group and add only authorised users: usermod -aG wheel <user>"
    fi

    # ── 5.3 Pluggable Authentication Modules ──────────────────────────────────
    print_subsection "5.3.1" "Configure PAM Software Packages"

    local pam_pkgs=("5.3.1.1:pam" "5.3.1.2:libpam-modules" "5.3.1.3:libpam-pwquality" "5.3.1.4:cracklib-runtime")
    for entry in "${pam_pkgs[@]}"; do
        IFS=':' read -r pid ppkg <<< "$entry"
        local pdesc
        if [[ "$pid" == "5.3.1.1" ]]; then
            pdesc="Ensure latest version of pam is installed"
        else
            pdesc="Ensure latest version of ${ppkg} is installed"
        fi
        if dpkg-query -s "$ppkg" &>/dev/null 2>&1; then
            local upgradable
            upgradable=$(apt list --upgradable 2>/dev/null | grep "^${ppkg}/")
            if [[ -z "$upgradable" ]]; then
                record "$pid" "PASS" "$pdesc" ""
            else
                record "$pid" "FAIL" "$pdesc" \
                    "${ppkg} has an upgrade available. Run: apt install ${ppkg}"
            fi
        else
            record "$pid" "FAIL" "$pdesc" "Install ${ppkg}: apt install ${ppkg}"
        fi
    done

    print_subsection "5.3.2" "Configure pam-auth-update Profiles"

    # 5.3.2.1 pam_unix
    if grep -qE "pam_unix\.so" /etc/pam.d/common-password 2>/dev/null; then
        record "5.3.2.1" "PASS" "Ensure pam_unix module is enabled" ""
    else
        record "5.3.2.1" "FAIL" "Ensure pam_unix module is enabled" \
            "Enable pam_unix via pam-auth-update: pam-auth-update --enable unix"
    fi

    # 5.3.2.2 pam_faillock
    if grep -qE "pam_faillock\.so" /etc/pam.d/common-auth 2>/dev/null && \
       grep -qE "pam_faillock\.so" /etc/pam.d/common-account 2>/dev/null; then
        record "5.3.2.2" "PASS" "Ensure pam_faillock module is enabled" ""
    else
        record "5.3.2.2" "FAIL" "Ensure pam_faillock module is enabled" \
            "Enable pam_faillock via pam-auth-update.
  Create profiles in /usr/share/pam-configs/ for faillock and faillock_notify,
  then run: pam-auth-update --enable faillock faillock_notify"
    fi

    # 5.3.2.3 pam_pwquality
    if grep -qE "pam_pwquality\.so" /etc/pam.d/common-password 2>/dev/null; then
        record "5.3.2.3" "PASS" "Ensure pam_pwquality module is enabled" ""
    else
        record "5.3.2.3" "FAIL" "Ensure pam_pwquality module is enabled" \
            "Enable pam_pwquality: pam-auth-update --enable pwquality"
    fi

    # 5.3.2.4 pam_pwhistory
    if grep -qE "pam_pwhistory\.so" /etc/pam.d/common-password 2>/dev/null; then
        record "5.3.2.4" "PASS" "Ensure pam_pwhistory module is enabled" ""
    else
        record "5.3.2.4" "FAIL" "Ensure pam_pwhistory module is enabled" \
            "Enable pam_pwhistory: pam-auth-update --enable pwhistory"
    fi

    print_subsection "5.3.3" "Configure PAM Arguments"

    # Helper: get pwquality config value
    _pwq_val() {
        grep -Erh "^\s*${1}\s*=" \
            /etc/security/pwquality.conf \
            /etc/security/pwquality.conf.d/*.conf 2>/dev/null | \
            awk -F= '{gsub(/[[:space:]]/,"",$2); print $2}' | tail -1
    }

    # 5.3.3.1.1 failed attempts lockout (deny <= 5)
    local fl_deny
    fl_deny=$(grep -rEh "^\s*deny\s*=" /etc/security/faillock.conf \
        /etc/security/faillock.conf.d/*.conf 2>/dev/null | \
        awk -F= '{print $2}' | tr -d ' ' | tail -1)
    if [[ -n "$fl_deny" && "$fl_deny" -le 5 ]]; then
        record "5.3.3.1.1" "PASS" "Ensure password failed attempts lockout is configured" ""
    else
        record "5.3.3.1.1" "FAIL" "Ensure password failed attempts lockout is configured" \
            "Set deny = 5 or lower in /etc/security/faillock.conf
  Current deny: ${fl_deny:-not set}"
    fi

    # 5.3.3.1.2 unlock_time >= 900
    local fl_unlock
    fl_unlock=$(grep -rEh "^\s*unlock_time\s*=" /etc/security/faillock.conf \
        /etc/security/faillock.conf.d/*.conf 2>/dev/null | \
        awk -F= '{print $2}' | tr -d ' ' | tail -1)
    if [[ -n "$fl_unlock" && "$fl_unlock" -ge 900 ]]; then
        record "5.3.3.1.2" "PASS" "Ensure password unlock time is configured" ""
    else
        record "5.3.3.1.2" "FAIL" "Ensure password unlock time is configured" \
            "Set unlock_time = 900 or higher in /etc/security/faillock.conf
  Current unlock_time: ${fl_unlock:-not set}"
    fi

    # 5.3.3.1.3 root account lockout
    local fl_root
    fl_root=$(grep -rEh "^\s*even_deny_root\b" /etc/security/faillock.conf \
        /etc/security/faillock.conf.d/*.conf 2>/dev/null)
    if [[ -n "$fl_root" ]]; then
        record "5.3.3.1.3" "PASS" \
            "Ensure password failed attempts lockout includes root account" ""
    else
        record "5.3.3.1.3" "FAIL" \
            "Ensure password failed attempts lockout includes root account" \
            "Add 'even_deny_root' to /etc/security/faillock.conf"
    fi

    # 5.3.3.2.1 difok >= 2
    local pwq_difok
    pwq_difok=$(_pwq_val "difok")
    if [[ -n "$pwq_difok" && "$pwq_difok" -ge 2 ]]; then
        record "5.3.3.2.1" "PASS" \
            "Ensure password number of changed characters is configured" ""
    else
        record "5.3.3.2.1" "FAIL" \
            "Ensure password number of changed characters is configured" \
            "Set difok = 2 or higher in /etc/security/pwquality.conf.d/50-pwconfig.conf
  Current difok: ${pwq_difok:-not set}"
    fi

    # 5.3.3.2.2 minlen >= 14
    local pwq_minlen
    pwq_minlen=$(_pwq_val "minlen")
    if [[ -n "$pwq_minlen" && "$pwq_minlen" -ge 14 ]]; then
        record "5.3.3.2.2" "PASS" "Ensure password length is configured" ""
    else
        record "5.3.3.2.2" "FAIL" "Ensure password length is configured" \
            "Set minlen = 14 or higher in /etc/security/pwquality.conf.d/50-pwlength.conf:
  minlen = 14
  Current minlen: ${pwq_minlen:-not set}"
    fi

    # 5.3.3.2.3 complexity — Manual
    local pwq_complexity
    pwq_complexity=$(grep -Erh "^\s*(minclass|dcredit|ucredit|lcredit|ocredit)\s*=" \
        /etc/security/pwquality.conf \
        /etc/security/pwquality.conf.d/*.conf 2>/dev/null | head -10)
    record "5.3.3.2.3" "MANUAL_REVIEW" "Ensure password complexity is configured" \
        "Review password complexity settings and verify they meet organisational policy.
Current settings:
${pwq_complexity:-none found}
Required: set minclass=4 or individual dcredit=-1 ucredit=-1 lcredit=-1 ocredit=-1
in /etc/security/pwquality.conf.d/50-pwcomplexity.conf
Command: grep -Erh '(minclass|dcredit|ucredit|lcredit|ocredit)' /etc/security/pwquality.conf*"

    # 5.3.3.2.4 maxrepeat <= 3
    local pwq_maxrepeat
    pwq_maxrepeat=$(_pwq_val "maxrepeat")
    if [[ -n "$pwq_maxrepeat" && "$pwq_maxrepeat" -le 3 ]]; then
        record "5.3.3.2.4" "PASS" \
            "Ensure password same consecutive characters is configured" ""
    else
        record "5.3.3.2.4" "FAIL" \
            "Ensure password same consecutive characters is configured" \
            "Set maxrepeat = 3 or lower in /etc/security/pwquality.conf
  Current maxrepeat: ${pwq_maxrepeat:-not set}"
    fi

    # 5.3.3.2.5 maxsequence <= 3
    local pwq_maxseq
    pwq_maxseq=$(_pwq_val "maxsequence")
    if [[ -n "$pwq_maxseq" && "$pwq_maxseq" -le 3 ]]; then
        record "5.3.3.2.5" "PASS" \
            "Ensure password maximum sequential characters is configured" ""
    else
        record "5.3.3.2.5" "FAIL" \
            "Ensure password maximum sequential characters is configured" \
            "Set maxsequence = 3 or lower in /etc/security/pwquality.conf
  Current maxsequence: ${pwq_maxseq:-not set}"
    fi

    # 5.3.3.2.6 dictcheck = 1
    local pwq_dict
    pwq_dict=$(_pwq_val "dictcheck")
    if [[ "${pwq_dict:-1}" -eq 1 ]]; then
        record "5.3.3.2.6" "PASS" "Ensure password dictionary check is enabled" ""
    else
        record "5.3.3.2.6" "FAIL" "Ensure password dictionary check is enabled" \
            "Set dictcheck = 1 in /etc/security/pwquality.conf"
    fi

    # 5.3.3.2.7 enforcing = 1
    if grep -qE "^\s*enforce_for_root\b\|^\s*enforcing\s*=\s*1" \
       /etc/security/pwquality.conf \
       /etc/security/pwquality.conf.d/*.conf 2>/dev/null || \
       grep -qE "pam_pwquality\.so.*enforce_for_root" /etc/pam.d/common-password 2>/dev/null; then
        record "5.3.3.2.7" "PASS" "Ensure password quality checking is enforced" ""
    else
        record "5.3.3.2.7" "FAIL" "Ensure password quality checking is enforced" \
            "Add 'enforcing = 1' to /etc/security/pwquality.conf
  Ensure pam_pwquality.so line in /etc/pam.d/common-password does not have 'enforce=0'"
    fi

    # 5.3.3.2.8 enforce for root
    if grep -rqE "^\s*enforce_for_root\b" \
       /etc/security/pwquality.conf \
       /etc/security/pwquality.conf.d/*.conf 2>/dev/null; then
        record "5.3.3.2.8" "PASS" \
            "Ensure password quality is enforced for the root user" ""
    else
        record "5.3.3.2.8" "FAIL" \
            "Ensure password quality is enforced for the root user" \
            "Add 'enforce_for_root' to /etc/security/pwquality.conf"
    fi

    # 5.3.3.3.x password history
    local ph_remember
    ph_remember=$(grep -rEh "^\s*remember\s*=\s*[0-9]+" \
        /etc/security/pwhistory.conf 2>/dev/null | \
        awk -F= '{print $2}' | tr -d ' ' | tail -1)
    if [[ -n "$ph_remember" && "$ph_remember" -ge 24 ]]; then
        record "5.3.3.3.1" "PASS" "Ensure password history remember is configured" ""
    else
        record "5.3.3.3.1" "FAIL" "Ensure password history remember is configured" \
            "Set remember = 24 or higher in /etc/security/pwhistory.conf
  Current remember: ${ph_remember:-not set}"
    fi

    # 5.3.3.3.2 history enforced for root
    if grep -rqE "^\s*enforce_for_root\b" /etc/security/pwhistory.conf 2>/dev/null; then
        record "5.3.3.3.2" "PASS" \
            "Ensure password history is enforced for the root user" ""
    else
        record "5.3.3.3.2" "FAIL" \
            "Ensure password history is enforced for the root user" \
            "Add 'enforce_for_root' to /etc/security/pwhistory.conf"
    fi

    # 5.3.3.3.3 use_authtok in pwhistory
    if grep -qE "pam_pwhistory\.so.*use_authtok" /etc/pam.d/common-password 2>/dev/null; then
        record "5.3.3.3.3" "PASS" "Ensure pam_pwhistory includes use_authtok" ""
    else
        record "5.3.3.3.3" "FAIL" "Ensure pam_pwhistory includes use_authtok" \
            "Add 'use_authtok' to pam_pwhistory.so line in /etc/pam.d/common-password"
    fi

    # pam_unix checks
    # 5.3.3.4.1 no nullok
    if grep -qE "pam_unix\.so.*nullok" /etc/pam.d/common-auth 2>/dev/null || \
       grep -qE "pam_unix\.so.*nullok" /etc/pam.d/common-password 2>/dev/null; then
        record "5.3.3.4.1" "FAIL" "Ensure pam_unix does not include nullok" \
            "Remove 'nullok' from all pam_unix.so lines in /etc/pam.d/common-auth and /etc/pam.d/common-password"
    else
        record "5.3.3.4.1" "PASS" "Ensure pam_unix does not include nullok" ""
    fi

    # 5.3.3.4.2 no remember in pam_unix
    if grep -qE "pam_unix\.so.*remember\s*=" /etc/pam.d/common-password 2>/dev/null; then
        record "5.3.3.4.2" "FAIL" "Ensure pam_unix does not include remember" \
            "Remove 'remember=' from pam_unix.so line in /etc/pam.d/common-password
  (password history should be managed via pam_pwhistory instead)"
    else
        record "5.3.3.4.2" "PASS" "Ensure pam_unix does not include remember" ""
    fi

    # 5.3.3.4.3 strong hashing
    local pam_hash
    pam_hash=$(grep -E "pam_unix\.so" /etc/pam.d/common-password 2>/dev/null | \
        grep -oE "sha512|sha256|yescrypt|blowfish" | head -1)
    if echo "$pam_hash" | grep -qiE "yescrypt|sha512|sha256"; then
        record "5.3.3.4.3" "PASS" \
            "Ensure pam_unix includes a strong password hashing algorithm" ""
    else
        record "5.3.3.4.3" "FAIL" \
            "Ensure pam_unix includes a strong password hashing algorithm" \
            "Add 'yescrypt' or 'sha512' to pam_unix.so line in /etc/pam.d/common-password
  Current hashing: ${pam_hash:-not set}"
    fi

    # 5.3.3.4.4 use_authtok in pam_unix
    if grep -qE "pam_unix\.so.*use_authtok" /etc/pam.d/common-password 2>/dev/null; then
        record "5.3.3.4.4" "PASS" "Ensure pam_unix includes use_authtok" ""
    else
        record "5.3.3.4.4" "FAIL" "Ensure pam_unix includes use_authtok" \
            "Add 'use_authtok' to pam_unix.so line in /etc/pam.d/common-password"
    fi

    flush_manual_block "SECTION 5.3"

    # ── 5.4 User Accounts and Environment ─────────────────────────────────────
    print_subsection "5.4.1" "Configure shadow password suite parameters"

    _logindefs_val() {
        grep -E "^\s*${1}\s" /etc/login.defs 2>/dev/null | awk '{print $2}' | tail -1
    }

    # 5.4.1.1 PASS_MAX_DAYS <= 365
    local max_days
    max_days=$(_logindefs_val "PASS_MAX_DAYS")
    if [[ -n "$max_days" && "$max_days" -le 365 ]]; then
        record "5.4.1.1" "PASS" "Ensure password expiration is configured" ""
    else
        record "5.4.1.1" "FAIL" "Ensure password expiration is configured" \
            "Set PASS_MAX_DAYS 365 or lower in /etc/login.defs
  Current: ${max_days:-not set}
  Also apply to existing users: chage --maxdays 365 <user>"
    fi

    # 5.4.1.2 PASS_MIN_DAYS >= 1 — L2, Manual
    if [[ "$SCAN_LEVEL" -ge 2 ]]; then
        local min_days
        min_days=$(_logindefs_val "PASS_MIN_DAYS")
        record "5.4.1.2" "MANUAL_REVIEW" \
            "Ensure minimum password days is configured" \
            "Verify PASS_MIN_DAYS is set to 1 or more in /etc/login.defs.
Current value: ${min_days:-not set}
Setting PASS_MIN_DAYS prevents users from immediately changing their password again
after a forced change, which would circumvent password history controls.
Recommended: PASS_MIN_DAYS 1
Command: grep PASS_MIN_DAYS /etc/login.defs"
    fi

    # 5.4.1.3 PASS_WARN_AGE >= 7
    local warn_age
    warn_age=$(_logindefs_val "PASS_WARN_AGE")
    if [[ -n "$warn_age" && "$warn_age" -ge 7 ]]; then
        record "5.4.1.3" "PASS" "Ensure password expiration warning days is configured" ""
    else
        record "5.4.1.3" "FAIL" "Ensure password expiration warning days is configured" \
            "Set PASS_WARN_AGE 7 or higher in /etc/login.defs
  Current: ${warn_age:-not set}"
    fi

    # 5.4.1.4 strong hashing in login.defs
    local hash_algo
    hash_algo=$(_logindefs_val "ENCRYPT_METHOD")
    if echo "$hash_algo" | grep -qiE "YESCRYPT|SHA512"; then
        record "5.4.1.4" "PASS" "Ensure strong password hashing algorithm is configured" ""
    else
        record "5.4.1.4" "FAIL" "Ensure strong password hashing algorithm is configured" \
            "Set ENCRYPT_METHOD YESCRYPT in /etc/login.defs
  Current: ${hash_algo:-not set}"
    fi

    # 5.4.1.5 inactive password lock <= 45
    local inactive_days
    inactive_days=$(useradd -D 2>/dev/null | grep INACTIVE | cut -d= -f2)
    if [[ -n "$inactive_days" && "$inactive_days" -ge 0 && "$inactive_days" -le 45 ]]; then
        record "5.4.1.5" "PASS" "Ensure inactive password lock is configured" ""
    else
        record "5.4.1.5" "FAIL" "Ensure inactive password lock is configured" \
            "Set default inactive period: useradd -D -f 45
  Also apply to existing users: chage --inactive 45 <user>
  Current INACTIVE default: ${inactive_days:-not set}"
    fi

    # 5.4.1.6 all users last password change in the past
    local future_pwchange
    future_pwchange=$(awk -F: '$3 > 0 {print $1, $3}' /etc/shadow 2>/dev/null | \
        while read -r user last_change; do
            local today_epoch
            today_epoch=$(date +%s)
            local today_days=$(( today_epoch / 86400 ))
            if (( last_change > today_days )); then
                echo "$user (last change: $last_change days, today: $today_days days)"
            fi
        done)
    if [[ -z "$future_pwchange" ]]; then
        record "5.4.1.6" "PASS" \
            "Ensure all users last password change date is in the past" ""
    else
        record "5.4.1.6" "FAIL" \
            "Ensure all users last password change date is in the past" \
            "Users with future-dated password changes:
${future_pwchange}
Investigate: chage -l <user> — set correct date with: chage -d <date> <user>"
    fi

    print_subsection "5.4.2" "Configure root and system accounts and environment"

    # 5.4.2.1 root only UID 0
    local uid0_users
    uid0_users=$(awk -F: '$3 == 0 && $1 != "root" {print $1}' /etc/passwd 2>/dev/null)
    if [[ -z "$uid0_users" ]]; then
        record "5.4.2.1" "PASS" "Ensure root is the only UID 0 account" ""
    else
        record "5.4.2.1" "FAIL" "Ensure root is the only UID 0 account" \
            "Non-root accounts with UID 0: ${uid0_users}
  Assign a proper UID or remove these accounts."
    fi

    # 5.4.2.2 root only GID 0 account
    local gid0_users
    gid0_users=$(awk -F: '$4 == 0 && $1 != "root" {print $1}' /etc/passwd 2>/dev/null)
    if [[ -z "$gid0_users" ]]; then
        record "5.4.2.2" "PASS" "Ensure root is the only GID 0 account" ""
    else
        record "5.4.2.2" "FAIL" "Ensure root is the only GID 0 account" \
            "Accounts with GID 0 other than root: ${gid0_users}"
    fi

    # 5.4.2.3 group root only GID 0 group
    local gid0_groups
    gid0_groups=$(awk -F: '$3 == 0 && $1 != "root" {print $1}' /etc/group 2>/dev/null)
    if [[ -z "$gid0_groups" ]]; then
        record "5.4.2.3" "PASS" "Ensure group root is the only GID 0 group" ""
    else
        record "5.4.2.3" "FAIL" "Ensure group root is the only GID 0 group" \
            "Groups with GID 0 other than root: ${gid0_groups}"
    fi

    # 5.4.2.4 root account access controlled (locked or has valid shell)
    local root_shell root_passwd_status
    root_shell=$(awk -F: '$1 == "root" {print $7}' /etc/passwd)
    root_passwd_status=$(passwd -S root 2>/dev/null | awk '{print $2}')
    if [[ "$root_shell" != "/usr/sbin/nologin" && "$root_shell" != "/bin/false" ]]; then
        if [[ "$root_passwd_status" == "P" ]] || [[ "$root_passwd_status" == "NP" ]]; then
            record "5.4.2.4" "PASS" "Ensure root account access is controlled" ""
        else
            record "5.4.2.4" "MANUAL_REVIEW" "Ensure root account access is controlled" \
                "Root account status: ${root_passwd_status}. Verify root access is appropriately controlled.
  Commands: passwd -S root; getent passwd root
  Consider locking direct root login: passwd -l root"
        fi
    else
        record "5.4.2.4" "PASS" "Ensure root account access is controlled" ""
    fi

    # 5.4.2.5 root path integrity
    local bad_path_entries
    bad_path_entries=$(echo "$PATH" | tr ':' '\n' | while read -r p; do
        [[ "$p" == "." || "$p" == "" ]] && echo "Empty/dot in PATH"
        [[ -d "$p" ]] && stat -Lc '%#a %U %G %n' "$p" 2>/dev/null | \
            awk '{if ($1+0 > 755 || ($2 != "root" && $2 != "")) print "Bad perms on: "$4}'
    done)
    if [[ -z "$bad_path_entries" ]]; then
        record "5.4.2.5" "PASS" "Ensure root path integrity" ""
    else
        record "5.4.2.5" "FAIL" "Ensure root path integrity" \
            "Issues found in root PATH:
${bad_path_entries}
Remove world-writable directories and '.' from root's PATH."
    fi

    # 5.4.2.6 root umask
    local root_umask
    root_umask=$(grep -E "^\s*umask\s+" /root/.bashrc /root/.bash_profile \
        /root/.profile /etc/profile /etc/profile.d/*.sh 2>/dev/null | \
        awk '{print $2}' | tail -1)
    if [[ "${root_umask:-000}" =~ ^0?[27][27]7$ ]]; then
        record "5.4.2.6" "PASS" "Ensure root user umask is configured" ""
    else
        record "5.4.2.6" "FAIL" "Ensure root user umask is configured" \
            "Set umask 0027 in /root/.bashrc: umask 0027
  Current umask: ${root_umask:-not set}"
    fi

    # 5.4.2.7 system accounts no valid login shell
    local sys_with_shell
    local uid_min
    uid_min=$(awk '/^\s*UID_MIN/{print $2}' /etc/login.defs 2>/dev/null)
    uid_min=${uid_min:-1000}
    sys_with_shell=$(awk -F: -v uid_min="$uid_min" \
        '$3 < uid_min && $1 != "root" && $7 !~ /\/false$|\/nologin$/ {print $1": "$7}' \
        /etc/passwd 2>/dev/null)
    if [[ -z "$sys_with_shell" ]]; then
        record "5.4.2.7" "PASS" \
            "Ensure system accounts do not have a valid login shell" ""
    else
        record "5.4.2.7" "FAIL" \
            "Ensure system accounts do not have a valid login shell" \
            "System accounts with login shells:
${sys_with_shell}
Fix: usermod -s /usr/sbin/nologin <account>"
    fi

    # 5.4.2.8 accounts without valid shell are locked
    local unlocked_nologin
    unlocked_nologin=$(awk -F: '$7 ~ /\/false$|\/nologin$/ {print $1}' /etc/passwd 2>/dev/null | \
        while read -r u; do
            local status
            status=$(passwd -S "$u" 2>/dev/null | awk '{print $2}')
            [[ "$status" != "L" && "$status" != "LK" ]] && echo "$u ($status)"
        done)
    if [[ -z "$unlocked_nologin" ]]; then
        record "5.4.2.8" "PASS" \
            "Ensure accounts without a valid login shell are locked" ""
    else
        record "5.4.2.8" "FAIL" \
            "Ensure accounts without a valid login shell are locked" \
            "Accounts with nologin/false shell but not locked:
${unlocked_nologin}
Lock with: passwd -l <user>"
    fi

    print_subsection "5.4.3" "Configure user default environment"

    # 5.4.3.1 nologin not in /etc/shells — L2
    if [[ "$SCAN_LEVEL" -ge 2 ]]; then
        if grep -qE "^/usr/sbin/nologin$|^/sbin/nologin$" /etc/shells 2>/dev/null; then
            record "5.4.3.1" "FAIL" "Ensure nologin is not listed in /etc/shells" \
                "Remove nologin from /etc/shells:
  sed -i '/nologin/d' /etc/shells"
        else
            record "5.4.3.1" "PASS" "Ensure nologin is not listed in /etc/shells" ""
        fi
    fi

    # 5.4.3.2 default user shell timeout
    local tmout_val
    tmout_val=$(grep -rEh "^\s*TMOUT\s*=" \
        /etc/profile /etc/profile.d/*.sh /etc/bashrc 2>/dev/null | \
        grep -oE "[0-9]+" | head -1)
    if [[ -n "$tmout_val" && "$tmout_val" -le 900 && "$tmout_val" -gt 0 ]]; then
        record "5.4.3.2" "PASS" "Ensure default user shell timeout is configured" ""
    else
        record "5.4.3.2" "FAIL" "Ensure default user shell timeout is configured" \
            "Set TMOUT in /etc/profile.d/99-timeout.sh:
  readonly TMOUT=900 ; export TMOUT
  Current: ${tmout_val:-not set}"
    fi

    # 5.4.3.3 default user umask
    local user_umask
    user_umask=$(grep -rEh "^\s*umask\s+" \
        /etc/profile /etc/profile.d/*.sh /etc/bash.bashrc 2>/dev/null | \
        awk '{print $2}' | tail -1)
    if [[ "${user_umask:-000}" =~ ^0?[027][27]7$ ]]; then
        record "5.4.3.3" "PASS" "Ensure default user umask is configured" ""
    else
        record "5.4.3.3" "FAIL" "Ensure default user umask is configured" \
            "Set umask 027 in /etc/profile.d/99-umask.sh: umask 027
  Current: ${user_umask:-not set}"
    fi
}