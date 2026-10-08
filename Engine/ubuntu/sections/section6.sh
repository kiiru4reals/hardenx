#!/usr/bin/env bash
# HardenX Ubuntu Engine — Section 6: Logging and Auditing

section6_run() {
    print_section "6" "Logging and Auditing"

    # ── 6.1 System Logging ────────────────────────────────────────────────────
    print_subsection "6.1.1.1" "Configure journald"

    # 6.1.1.1.1 journald active
    if systemctl is-active systemd-journald &>/dev/null; then
        record "6.1.1.1.1" "PASS" "Ensure journald service is active" ""
    else
        record "6.1.1.1.1" "FAIL" "Ensure journald service is active" \
            "Enable journald: systemctl enable --now systemd-journald"
    fi

    # 6.1.1.1.2 systemd-journal-remote not in use
    if ! systemctl is-active systemd-journal-remote &>/dev/null && \
       ! systemctl is-enabled systemd-journal-remote &>/dev/null; then
        record "6.1.1.1.2" "PASS" \
            "Ensure systemd-journal-remote service is not in use" ""
    else
        record "6.1.1.1.2" "FAIL" \
            "Ensure systemd-journal-remote service is not in use" \
            "Disable: systemctl stop systemd-journal-remote
  systemctl disable systemd-journal-remote
  systemctl mask systemd-journal-remote"
    fi

    # 6.1.1.1.3 journald sends to rsyslog
    local jd_rsyslog
    jd_rsyslog=$(grep -rEh "^\s*ForwardToSyslog\s*=" \
        /etc/systemd/journald.conf \
        /etc/systemd/journald.conf.d/*.conf 2>/dev/null | \
        awk -F= '{print $2}' | tr -d ' ' | tail -1)
    if [[ "$jd_rsyslog" == "yes" ]]; then
        record "6.1.1.1.3" "PASS" \
            "Ensure journald is configured to send logs to rsyslog" ""
    else
        record "6.1.1.1.3" "FAIL" \
            "Ensure journald is configured to send logs to rsyslog" \
            "Set ForwardToSyslog=yes in /etc/systemd/journald.conf.d/99-cis.conf
  Then: systemctl restart systemd-journald"
    fi

    # 6.1.1.1.4 journald log file access — Manual
    local jd_logfiles
    jd_logfiles=$(find /var/log/journal/ -type f 2>/dev/null | head -5)
    record "6.1.1.1.4" "MANUAL_REVIEW" \
        "Ensure journald log file access is configured" \
        "Review journald log file permissions and ensure they meet your security policy.
Log files found:
${jd_logfiles:-no persistent journal files found}
Command: find /var/log/journal/ -type f | xargs stat -c '%n %a %U %G'
Expected: files owned by root:systemd-journal, mode 640 or more restrictive."

    # 6.1.1.1.5 journald log rotation — Manual
    local jd_rotate
    jd_rotate=$(grep -rEh "^\s*(SystemMaxUse|RuntimeMaxUse|SystemKeepFree|MaxFileSec|MaxRetentionSec)\s*=" \
        /etc/systemd/journald.conf \
        /etc/systemd/journald.conf.d/*.conf 2>/dev/null | head -5)
    record "6.1.1.1.5" "MANUAL_REVIEW" \
        "Ensure journald log file rotation is configured" \
        "Verify journald log rotation settings meet organisational retention policy.
Current rotation settings:
${jd_rotate:-none configured (using defaults)}
Configure in /etc/systemd/journald.conf.d/99-cis.conf:
  SystemMaxUse=<size>
  MaxRetentionSec=<time>
Command: journalctl --disk-usage"

    # 6.1.1.1.6 Storage
    local jd_storage
    jd_storage=$(grep -rEh "^\s*Storage\s*=" \
        /etc/systemd/journald.conf \
        /etc/systemd/journald.conf.d/*.conf 2>/dev/null | \
        awk -F= '{print $2}' | tr -d ' ' | tail -1)
    if [[ "$jd_storage" == "persistent" ]]; then
        record "6.1.1.1.6" "PASS" "Ensure journald Storage is configured" ""
    else
        record "6.1.1.1.6" "FAIL" "Ensure journald Storage is configured" \
            "Set Storage=persistent in /etc/systemd/journald.conf.d/99-cis.conf
  Then: systemctl restart systemd-journald
  Current: ${jd_storage:-not set}"
    fi

    # 6.1.1.1.7 Compress
    local jd_compress
    jd_compress=$(grep -rEh "^\s*Compress\s*=" \
        /etc/systemd/journald.conf \
        /etc/systemd/journald.conf.d/*.conf 2>/dev/null | \
        awk -F= '{print $2}' | tr -d ' ' | tail -1)
    if [[ "$jd_compress" == "yes" ]]; then
        record "6.1.1.1.7" "PASS" "Ensure journald Compress is configured" ""
    else
        record "6.1.1.1.7" "FAIL" "Ensure journald Compress is configured" \
            "Set Compress=yes in /etc/systemd/journald.conf.d/99-cis.conf
  Then: systemctl restart systemd-journald
  Current: ${jd_compress:-not set}"
    fi

    flush_manual_block "SECTION 6.1.1"

    print_subsection "6.1.2" "Configure rsyslog"

    # 6.1.2.1 rsyslog installed
    if dpkg-query -s rsyslog &>/dev/null 2>&1; then
        record "6.1.2.1" "PASS" "Ensure rsyslog is installed" ""
    else
        record "6.1.2.1" "FAIL" "Ensure rsyslog is installed" \
            "Install rsyslog: apt install rsyslog"
    fi

    # 6.1.2.2 rsyslog enabled and active
    if systemctl is-enabled rsyslog &>/dev/null && \
       systemctl is-active rsyslog &>/dev/null; then
        record "6.1.2.2" "PASS" "Ensure rsyslog service is enabled and active" ""
    else
        record "6.1.2.2" "FAIL" "Ensure rsyslog service is enabled and active" \
            "Enable rsyslog: systemctl enable --now rsyslog"
    fi

    # 6.1.2.3 log file creation mode
    local rsyslog_mode
    rsyslog_mode=$(grep -rEh "^\s*\\\$FileCreateMode\s*" \
        /etc/rsyslog.conf /etc/rsyslog.d/*.conf 2>/dev/null | \
        awk '{print $2}' | tail -1)
    if [[ "$rsyslog_mode" == "0640" || "$rsyslog_mode" == "0600" ]]; then
        record "6.1.2.3" "PASS" "Ensure rsyslog log file creation mode is configured" ""
    else
        record "6.1.2.3" "FAIL" "Ensure rsyslog log file creation mode is configured" \
            "Set \$FileCreateMode 0640 in /etc/rsyslog.conf or /etc/rsyslog.d/99-cis.conf
  Then: systemctl restart rsyslog
  Current: ${rsyslog_mode:-not set}"
    fi

    # 6.1.2.4 rsyslog logging configured — Manual
    local rsyslog_rules
    rsyslog_rules=$(grep -rEh "^\s*[a-z\*]\.[a-zA-Z\*]\s+/var/log" \
        /etc/rsyslog.conf /etc/rsyslog.d/*.conf 2>/dev/null | head -10)
    record "6.1.2.4" "MANUAL_REVIEW" "Ensure rsyslog logging is configured" \
        "Verify rsyslog is configured to log all necessary facilities to appropriate files.
Current logging rules:
${rsyslog_rules:-no rules found}
Command: grep -rE '[a-z\*]\.[a-zA-Z\*]' /etc/rsyslog.conf /etc/rsyslog.d/
Ensure at minimum: auth,authpriv.* /var/log/auth.log and *.*;auth,authpriv.none /var/log/syslog"

    # 6.1.2.5 rsyslog remote log host — Manual
    local rsyslog_remote
    rsyslog_remote=$(grep -rEh "^\s*\*\.\*\s+@{1,2}" \
        /etc/rsyslog.conf /etc/rsyslog.d/*.conf 2>/dev/null | head -5)
    record "6.1.2.5" "MANUAL_REVIEW" \
        "Ensure rsyslog is configured to send logs to a remote log host" \
        "Verify rsyslog is forwarding logs to a remote/centralised log host.
Current remote forwarding config:
${rsyslog_remote:-none configured}
Configure remote logging in /etc/rsyslog.d/50-remote.conf:
  *.* @@<remote-log-host>:514   (TCP)
Command: grep -rE '@@' /etc/rsyslog.conf /etc/rsyslog.d/"

    # 6.1.2.6 rsyslog not receiving from remote clients
    local rsyslog_receiving
    rsyslog_receiving=$(grep -rEh "^\s*\\\$ModLoad\s+imudp|\\\$ModLoad\s+imtcp|module.*imudp|module.*imtcp" \
        /etc/rsyslog.conf /etc/rsyslog.d/*.conf 2>/dev/null | head -5)
    if [[ -z "$rsyslog_receiving" ]]; then
        record "6.1.2.6" "PASS" \
            "Ensure rsyslog is not configured to receive logs from a remote client" ""
    else
        record "6.1.2.6" "FAIL" \
            "Ensure rsyslog is not configured to receive logs from a remote client" \
            "Remove or comment out imudp/imtcp module loads in rsyslog config:
${rsyslog_receiving}
Then: systemctl restart rsyslog"
    fi

    # 6.1.2.7 logrotate — Manual
    local logrotate_conf
    logrotate_conf=$(find /etc/logrotate.d/ -type f 2>/dev/null | head -5)
    record "6.1.2.7" "MANUAL_REVIEW" "Ensure logrotate is configured" \
        "Verify logrotate is configured for all relevant log files.
Logrotate configurations found in /etc/logrotate.d/:
$(ls /etc/logrotate.d/ 2>/dev/null | tr '\n' ' ')
Review each config and ensure appropriate rotation frequency, retention, and compression.
Command: logrotate --debug /etc/logrotate.conf"

    # 6.1.2.8 rsyslog-gnutls — L2
    if [[ "$SCAN_LEVEL" -ge 2 ]]; then
        if dpkg-query -s rsyslog-gnutls &>/dev/null 2>&1; then
            record "6.1.2.8" "PASS" "Ensure rsyslog-gnutls is installed" ""
        else
            record "6.1.2.8" "FAIL" "Ensure rsyslog-gnutls is installed" \
                "Install: apt install rsyslog-gnutls"
        fi
    fi

    # 6.1.2.9 rsyslog forwarding uses gtls — L2
    if [[ "$SCAN_LEVEL" -ge 2 ]]; then
        local rsyslog_gtls
        rsyslog_gtls=$(grep -rEh "DefaultNetstreamDriver\s*gtls" \
            /etc/rsyslog.conf /etc/rsyslog.d/*.conf 2>/dev/null)
        if [[ -n "$rsyslog_gtls" ]]; then
            record "6.1.2.9" "PASS" "Ensure rsyslog forwarding uses gtls" ""
        else
            record "6.1.2.9" "FAIL" "Ensure rsyslog forwarding uses gtls" \
                "Configure TLS forwarding in /etc/rsyslog.d/50-tls.conf:
  \$DefaultNetstreamDriver gtls
  \$ActionSendStreamDriverMode 1
  \$ActionSendStreamDriverAuthMode anon"
        fi
    fi

    # 6.1.2.10 rsyslog CA certificates — L2, Manual
    if [[ "$SCAN_LEVEL" -ge 2 ]]; then
        local rsyslog_ca
        rsyslog_ca=$(grep -rEh "DefaultNetstreamDriverCAFile|StreamDriverPermittedPeers" \
            /etc/rsyslog.conf /etc/rsyslog.d/*.conf 2>/dev/null | head -5)
        record "6.1.2.10" "MANUAL_REVIEW" \
            "Ensure rsyslog CA certificates are configured" \
            "Verify CA certificate is configured for TLS log forwarding.
Current TLS cert config:
${rsyslog_ca:-none configured}
Configure in /etc/rsyslog.d/50-tls.conf:
  \$DefaultNetstreamDriverCAFile /etc/ssl/certs/ca.pem
Command: grep -rE 'CA|cert' /etc/rsyslog.conf /etc/rsyslog.d/"
    fi

    flush_manual_block "SECTION 6.1.2"

    # 6.1.3.1 logfile access
    print_subsection "6.1.3" "Configure Logfiles"
    local bad_logfiles
    bad_logfiles=$(find /var/log/ -type f \
        \( -perm /137 \) 2>/dev/null | head -10)
    if [[ -z "$bad_logfiles" ]]; then
        record "6.1.3.1" "PASS" \
            "Ensure access to all logfiles has been configured" ""
    else
        record "6.1.3.1" "FAIL" \
            "Ensure access to all logfiles has been configured" \
            "Log files with permissions wider than 640:
${bad_logfiles}
Fix: find /var/log/ -type f -exec chmod g-wx,o-rwx {} +"
    fi

    # ── 6.2 System Auditing (auditd) ──────────────────────────────────────────
    print_subsection "6.2.1" "Configure auditd Service"

    # GPG key validation (Section 5.10 of README)
    local gpg_keys_out
    gpg_keys_out=$(apt-key list 2>/dev/null || \
        ls -la /etc/apt/trusted.gpg.d/ /usr/share/keyrings/ 2>/dev/null | head -20)
    record "GPG-KEY-01" "MANUAL_REVIEW" \
        "Ensure APT repository GPG keys are from known trusted sources" \
        "Review all installed APT signing keys and verify each corresponds to a trusted repository.
Investigate and remove any unrecognised keys.
${gpg_keys_out}
Commands:
  apt-key list 2>/dev/null
  ls -la /etc/apt/trusted.gpg.d/ /usr/share/keyrings/
  apt-key del <key-id>   (to remove suspicious keys)"

    flush_manual_block "SECTION GPG"

    # L2 check gate for auditd
    if [[ "$SCAN_LEVEL" -lt 2 ]]; then
        for id in 6.2.1.1 6.2.1.2 6.2.1.3 6.2.1.4 \
                  6.2.2.1 6.2.2.2 6.2.2.3 6.2.2.4 \
                  6.2.3.1 6.2.3.2 6.2.3.3 6.2.3.4 6.2.3.5 6.2.3.6 6.2.3.7 6.2.3.8 \
                  6.2.3.9 6.2.3.10 6.2.3.11 6.2.3.12 6.2.3.13 6.2.3.14 6.2.3.15 \
                  6.2.3.16 6.2.3.17 6.2.3.18 6.2.3.19 6.2.3.20 6.2.3.21 6.2.3.22 \
                  6.2.3.23 6.2.3.24 6.2.3.25 6.2.3.26 6.2.3.27 6.2.3.28 6.2.3.29 6.2.3.30 \
                  6.2.4.1 6.2.4.2 6.2.4.3 6.2.4.4 6.2.4.5 6.2.4.6 6.2.4.7 6.2.4.8 6.2.4.9 6.2.4.10; do
            record "$id" "N/A: L2 only" "auditd check (${id})" \
                "This check is Level 2 only. Run with --level 2 to evaluate."
        done
        return
    fi

    # 6.2.1.1 auditd packages
    if dpkg-query -s auditd &>/dev/null 2>&1 && \
       dpkg-query -s audispd-plugins &>/dev/null 2>&1; then
        record "6.2.1.1" "PASS" "Ensure auditd packages are installed" ""
    else
        record "6.2.1.1" "FAIL" "Ensure auditd packages are installed" \
            "Install: apt install auditd audispd-plugins"
    fi

    # 6.2.1.2 auditd service enabled and active
    if systemctl is-enabled auditd &>/dev/null && \
       systemctl is-active auditd &>/dev/null; then
        record "6.2.1.2" "PASS" "Ensure auditd service is enabled and active" ""
    else
        record "6.2.1.2" "FAIL" "Ensure auditd service is enabled and active" \
            "Enable: systemctl unmask auditd && systemctl enable --now auditd"
    fi

    # 6.2.1.3 auditing before auditd starts
    local grub_audit
    grub_audit=$(find /boot -type f -name "grub.cfg" -exec grep -Ph "^\s*linux" {} + 2>/dev/null | \
        grep -v "audit=1")
    if [[ -z "$grub_audit" ]]; then
        record "6.2.1.3" "PASS" \
            "Ensure auditing for processes that start prior to auditd is enabled" ""
    else
        record "6.2.1.3" "FAIL" \
            "Ensure auditing for processes that start prior to auditd is enabled" \
            "Add 'audit=1' to GRUB_CMDLINE_LINUX in /etc/default/grub:
  GRUB_CMDLINE_LINUX=\"audit=1\"
  Then: update-grub"
    fi

    # 6.2.1.4 audit_backlog_limit
    local backlog_limit
    backlog_limit=$(find /boot -name "grub.cfg" -exec grep -Ph "^\s*linux" {} + 2>/dev/null | \
        grep -oE "audit_backlog_limit=[0-9]+" | head -1 | cut -d= -f2)
    if [[ -n "$backlog_limit" && "$backlog_limit" -ge 8192 ]]; then
        record "6.2.1.4" "PASS" "Ensure audit_backlog_limit is configured" ""
    else
        record "6.2.1.4" "FAIL" "Ensure audit_backlog_limit is configured" \
            "Add 'audit_backlog_limit=8192' to GRUB_CMDLINE_LINUX in /etc/default/grub
  Then: update-grub
  Current limit: ${backlog_limit:-not set}"
    fi

    print_subsection "6.2.2" "Configure Data Retention"

    # 6.2.2.1 audit log storage size
    local audit_maxsize
    audit_maxsize=$(grep -Eoh "^max_log_file\s*=\s*[0-9]+" \
        /etc/audit/auditd.conf 2>/dev/null | awk -F= '{print $2}' | tr -d ' ')
    if [[ -n "$audit_maxsize" && "$audit_maxsize" -ge 8 ]]; then
        record "6.2.2.1" "PASS" "Ensure audit log storage size is configured" ""
    else
        record "6.2.2.1" "FAIL" "Ensure audit log storage size is configured" \
            "Set max_log_file = 8 (or higher per site policy) in /etc/audit/auditd.conf
  Then: systemctl restart auditd
  Current: ${audit_maxsize:-not set}"
    fi

    # 6.2.2.2 audit logs not auto deleted
    local audit_keep
    audit_keep=$(grep -Eoh "^max_log_file_action\s*=\s*\S+" \
        /etc/audit/auditd.conf 2>/dev/null | awk -F= '{print $2}' | tr -d ' ')
    if echo "$audit_keep" | grep -qiE "keep_logs|rotate"; then
        record "6.2.2.2" "PASS" "Ensure audit logs are not automatically deleted" ""
    else
        record "6.2.2.2" "FAIL" "Ensure audit logs are not automatically deleted" \
            "Set max_log_file_action = keep_logs in /etc/audit/auditd.conf
  Current: ${audit_keep:-not set}"
    fi

    # 6.2.2.3 system disabled when audit logs full
    local audit_full
    audit_full=$(grep -Eoh "^disk_full_action\s*=\s*\S+" \
        /etc/audit/auditd.conf 2>/dev/null | awk -F= '{print $2}' | tr -d ' ')
    if echo "$audit_full" | grep -qiE "halt|single"; then
        record "6.2.2.3" "PASS" "Ensure system is disabled when audit logs are full" ""
    else
        record "6.2.2.3" "FAIL" "Ensure system is disabled when audit logs are full" \
            "Set disk_full_action = halt in /etc/audit/auditd.conf
  Current: ${audit_full:-not set}"
    fi

    # 6.2.2.4 system warns when audit logs low on space
    local audit_low
    audit_low=$(grep -Eoh "^admin_space_left_action\s*=\s*\S+" \
        /etc/audit/auditd.conf 2>/dev/null | awk -F= '{print $2}' | tr -d ' ')
    if echo "$audit_low" | grep -qiE "single|halt|email|syslog"; then
        record "6.2.2.4" "PASS" \
            "Ensure system warns when audit logs are low on space" ""
    else
        record "6.2.2.4" "FAIL" \
            "Ensure system warns when audit logs are low on space" \
            "Set admin_space_left_action = single in /etc/audit/auditd.conf
  Current: ${audit_low:-not set}"
    fi

    print_subsection "6.2.3" "Configure auditd Rules"

    # Helper: check audit rule exists
    _audit_rule_check() {
        local id="$1" desc="$2" pattern="$3" rem="$4"
        local result
        result=$(auditctl -l 2>/dev/null | grep -E "$pattern" | head -3)
        if [[ -n "$result" ]]; then
            record "$id" "PASS" "$desc" ""
        else
            record "$id" "FAIL" "$desc" "$rem"
        fi
    }

    _audit_rule_check "6.2.3.1" \
        "Ensure changes to system administration scope (sudoers) is collected" \
        "sudoers" \
        "Add to /etc/audit/rules.d/50-sudoers.rules:
  -w /etc/sudoers -p wa -k scope
  -w /etc/sudoers.d/ -p wa -k scope
  Then: augenrules --load"

    _audit_rule_check "6.2.3.2" \
        "Ensure actions as another user are always logged" \
        "use_id\|key.*user_emulation\|\\-a.*arch=b.*\\-F euid" \
        "Add to /etc/audit/rules.d/50-usermod.rules:
  -a always,exit -F arch=b64 -C euid!=uid -F auid!=unset -S execve -k user_emulation
  -a always,exit -F arch=b32 -C euid!=uid -F auid!=unset -S execve -k user_emulation
  Then: augenrules --load"

    _audit_rule_check "6.2.3.3" \
        "Ensure events that modify the sudo log file are collected" \
        "sudo\.log\|sudolog" \
        "Add to /etc/audit/rules.d/50-sudo.rules:
  -w /var/log/sudo.log -p wa -k sudo_log_file
  Then: augenrules --load"

    _audit_rule_check "6.2.3.4" \
        "Ensure events that modify date and time information are collected" \
        "clock_settime\|settimeofday\|adjtimex\|time_change" \
        "Add to /etc/audit/rules.d/50-time.rules:
  -a always,exit -F arch=b64 -S adjtimex,settimeofday,clock_settime -k time-change
  -w /etc/localtime -p wa -k time-change
  Then: augenrules --load"

    _audit_rule_check "6.2.3.5" \
        "Ensure events that modify sethostname and setdomainname are collected" \
        "sethostname\|setdomainname\|system-locale" \
        "Add to /etc/audit/rules.d/50-system-locale.rules:
  -a always,exit -F arch=b64 -S sethostname,setdomainname -k system-locale
  -w /etc/issue -p wa -k system-locale
  -w /etc/issue.net -p wa -k system-locale
  -w /etc/hosts -p wa -k system-locale
  -w /etc/hostname -p wa -k system-locale
  Then: augenrules --load"

    _audit_rule_check "6.2.3.6" \
        "Ensure events that modify /etc/issue and /etc/issue.net are collected" \
        "etc/issue" \
        "Add -w /etc/issue -p wa -k system-locale and -w /etc/issue.net -p wa -k system-locale
  to /etc/audit/rules.d/50-system-locale.rules then: augenrules --load"

    _audit_rule_check "6.2.3.7" \
        "Ensure events that modify /etc/hosts and /etc/hostname are collected" \
        "etc/hosts\|etc/hostname" \
        "Add -w /etc/hosts -p wa -k system-locale and -w /etc/hostname -p wa -k system-locale
  to /etc/audit/rules.d/50-system-locale.rules then: augenrules --load"

    _audit_rule_check "6.2.3.8" \
        "Ensure events that modify /etc/network and /etc/networks are collected" \
        "etc/network" \
        "Add -w /etc/network -p wa -k system-locale to /etc/audit/rules.d/50-system-locale.rules
  then: augenrules --load"

    _audit_rule_check "6.2.3.9" \
        "Ensure events that modify /etc/netplan are collected" \
        "netplan" \
        "Add -w /etc/netplan -p wa -k system-locale to /etc/audit/rules.d/50-system-locale.rules
  then: augenrules --load"

    _audit_rule_check "6.2.3.10" \
        "Ensure use of privileged commands are collected" \
        "privileged\|execve" \
        "Generate rules for all setuid/setgid binaries:
  find / -xdev \( -perm -4000 -o -perm -2000 \) -type f | \
    awk '{print \"-a always,exit -F path=\" \$1 \" -F perm=x -F auid>=1000 -F auid!=unset -k privileged\"}' \
    > /etc/audit/rules.d/50-privileged.rules
  Then: augenrules --load"

    for id_desc in \
        "6.2.3.11:Ensure events that modify /etc/group information are collected:etc/group:Add -w /etc/group -p wa -k identity and -w /etc/gshadow -p wa -k identity" \
        "6.2.3.12:Ensure events that modify /etc/passwd information are collected:etc/passwd:Add -w /etc/passwd -p wa -k identity" \
        "6.2.3.13:Ensure events that modify /etc/shadow are collected:etc/shadow:Add -w /etc/shadow -p wa -k identity and -w /etc/gshadow -p wa -k identity" \
        "6.2.3.14:Ensure events that modify /etc/security/opasswd are collected:opasswd:Add -w /etc/security/opasswd -p wa -k identity" \
        "6.2.3.15:Ensure events that modify /etc/nsswitch.conf are collected:nsswitch:Add -w /etc/nsswitch.conf -p wa -k identity" \
        "6.2.3.16:Ensure events that modify /etc/pam.conf are collected:pam:Add -w /etc/pam.conf -p wa -k identity and -w /etc/pam.d -p wa -k identity"; do
        IFS=':' read -r aid adesc apat arem <<< "$id_desc"
        _audit_rule_check "$aid" "$adesc" "$apat" \
            "${arem} to /etc/audit/rules.d/50-identity.rules then: augenrules --load"
    done

    _audit_rule_check "6.2.3.17" \
        "Ensure unsuccessful file access attempts are collected" \
        "EACCES\|EPERM\|access" \
        "Add to /etc/audit/rules.d/50-access.rules:
  -a always,exit -F arch=b64 -S creat,open,openat,truncate,ftruncate -F exit=-EACCES -F auid>=1000 -F auid!=unset -k access
  -a always,exit -F arch=b64 -S creat,open,openat,truncate,ftruncate -F exit=-EPERM -F auid>=1000 -F auid!=unset -k access
  Then: augenrules --load"

    _audit_rule_check "6.2.3.18" \
        "Ensure discretionary access control permission modification events are collected" \
        "chmod\|chown\|setxattr\|perm_mod" \
        "Add to /etc/audit/rules.d/50-perm_mod.rules:
  -a always,exit -F arch=b64 -S chmod,fchmod,fchmodat -F auid>=1000 -F auid!=unset -k perm_mod
  -a always,exit -F arch=b64 -S chown,fchown,fchownat,lchown -F auid>=1000 -F auid!=unset -k perm_mod
  Then: augenrules --load"

    _audit_rule_check "6.2.3.19" \
        "Ensure successful file system mounts are collected" \
        "mount\|mounts" \
        "Add to /etc/audit/rules.d/50-mounts.rules:
  -a always,exit -F arch=b64 -S mount -F auid>=1000 -F auid!=unset -k mounts
  Then: augenrules --load"

    _audit_rule_check "6.2.3.20" \
        "Ensure session initiation information is collected" \
        "session\|wtmp\|utmp" \
        "Add to /etc/audit/rules.d/50-session.rules:
  -w /var/run/utmp -p wa -k session
  -w /var/log/wtmp -p wa -k session
  -w /var/log/btmp -p wa -k session
  Then: augenrules --load"

    _audit_rule_check "6.2.3.21" \
        "Ensure login and logout events are collected" \
        "logins\|faillog\|lastlog" \
        "Add to /etc/audit/rules.d/50-logins.rules:
  -w /var/log/faillog -p wa -k logins
  -w /var/log/lastlog -p wa -k logins
  Then: augenrules --load"

    _audit_rule_check "6.2.3.22" \
        "Ensure file deletion events by users are collected" \
        "delete\|unlink\|rmdir" \
        "Add to /etc/audit/rules.d/50-delete.rules:
  -a always,exit -F arch=b64 -S unlink,unlinkat,rename,renameat -F auid>=1000 -F auid!=unset -k delete
  Then: augenrules --load"

    _audit_rule_check "6.2.3.23" \
        "Ensure events that modify the system's Mandatory Access Controls are collected" \
        "MAC-policy\|apparmor\|selinux" \
        "Add to /etc/audit/rules.d/50-MAC-policy.rules:
  -w /etc/apparmor -p wa -k MAC-policy
  -w /etc/apparmor.d -p wa -k MAC-policy
  Then: augenrules --load"

    for cmd_check in \
        "6.2.3.24:chcon:Ensure successful and unsuccessful attempts to use the chcon command are collected" \
        "6.2.3.25:setfacl:Ensure successful and unsuccessful attempts to use the setfacl command are collected" \
        "6.2.3.26:chacl:Ensure successful and unsuccessful attempts to use the chacl command are collected" \
        "6.2.3.27:usermod:Ensure successful and unsuccessful attempts to use the usermod command are collected"; do
        IFS=':' read -r cid ccmd cdesc <<< "$cmd_check"
        local cmd_path
        cmd_path=$(command -v "$ccmd" 2>/dev/null)
        if [[ -n "$cmd_path" ]]; then
            _audit_rule_check "$cid" "$cdesc" "$ccmd" \
                "Add to /etc/audit/rules.d/50-${ccmd}.rules:
  -a always,exit -F path=${cmd_path} -F perm=x -F auid>=1000 -F auid!=unset -k ${ccmd}
  Then: augenrules --load"
        else
            record "$cid" "N/A: ${ccmd} not installed" "$cdesc" \
                "${ccmd} is not installed on this host."
        fi
    done

    _audit_rule_check "6.2.3.28" \
        "Ensure kernel module loading unloading and modification is collected" \
        "modules\|insmod\|rmmod\|modprobe\|kmod" \
        "Add to /etc/audit/rules.d/50-modules.rules:
  -a always,exit -F arch=b64 -S init_module,finit_module,delete_module,create_module,query_module -k modules
  -a always,exit -F path=/usr/bin/kmod -F perm=x -F auid!=unset -k modules
  Then: augenrules --load"

    # 6.2.3.29 audit config immutable
    local audit_immutable
    audit_immutable=$(auditctl -l 2>/dev/null | grep -c "^-e 2$")
    if [[ "$audit_immutable" -gt 0 ]] || \
       grep -rqE "^-e 2" /etc/audit/rules.d/*.rules 2>/dev/null; then
        record "6.2.3.29" "PASS" "Ensure the audit configuration is immutable" ""
    else
        record "6.2.3.29" "FAIL" "Ensure the audit configuration is immutable" \
            "Add as the LAST line in /etc/audit/rules.d/99-finalize.rules:
  -e 2
  Then: augenrules --load
  NOTE: This makes audit config immutable until reboot. Test rules thoroughly first."
    fi

    # 6.2.3.30 running and on-disk config same — Manual
    local audit_diff
    audit_diff=$(augenrules --check 2>/dev/null | head -5)
    record "6.2.3.30" "MANUAL_REVIEW" \
        "Ensure the running and on disk configuration is the same" \
        "Verify the running audit rules match the on-disk configuration.
Output of augenrules --check:
${audit_diff:-command unavailable or output empty}
If differences are found, reload: augenrules --load
Command: augenrules --check"

    flush_manual_block "SECTION 6.2.3"

    # ── 6.2.4 auditd File Access ──────────────────────────────────────────────
    print_subsection "6.2.4" "Configure auditd File Access"

    # Audit log directory
    local audit_log_dir
    audit_log_dir=$(grep -Eoh "^log_file\s*=\s*\S+" \
        /etc/audit/auditd.conf 2>/dev/null | awk -F= '{print $2}' | \
        xargs dirname 2>/dev/null)
    audit_log_dir=${audit_log_dir:-/var/log/audit}

    # 6.2.4.1 audit log dir mode
    if check_file_perms "$audit_log_dir" "750" "root" "root"; then
        record "6.2.4.1" "PASS" \
            "Ensure the audit log file directory mode is configured" ""
    else
        record "6.2.4.1" "FAIL" \
            "Ensure the audit log file directory mode is configured" \
            "Fix: chmod 750 ${audit_log_dir} && chown root:root ${audit_log_dir}"
    fi

    local audit_file_checks=(
        "6.2.4.2:${audit_log_dir}:600:root:root:audit log files mode"
        "6.2.4.3:${audit_log_dir}:600:root:root:audit log files owner"
        "6.2.4.4:${audit_log_dir}:600:root:root:audit log files group owner"
        "6.2.4.5:/etc/audit:640:root:root:audit configuration files mode"
        "6.2.4.6:/etc/audit:640:root:root:audit configuration files owner"
        "6.2.4.7:/etc/audit:640:root:root:audit configuration files group owner"
    )

    # 6.2.4.2 log files mode — L2
    local bad_log_files
    bad_log_files=$(find "$audit_log_dir" -type f \( -perm /177 \) 2>/dev/null | head -5)
    if [[ -z "$bad_log_files" ]]; then
        record "6.2.4.2" "PASS" "Ensure audit log files mode is configured" ""
    else
        record "6.2.4.2" "FAIL" "Ensure audit log files mode is configured" \
            "Fix: find ${audit_log_dir} -type f -exec chmod 600 {} +"
    fi

    # 6.2.4.3 log files owner — L2
    local bad_log_owner
    bad_log_owner=$(find "$audit_log_dir" -type f ! -user root 2>/dev/null | head -5)
    if [[ -z "$bad_log_owner" ]]; then
        record "6.2.4.3" "PASS" "Ensure audit log files owner is configured" ""
    else
        record "6.2.4.3" "FAIL" "Ensure audit log files owner is configured" \
            "Fix: find ${audit_log_dir} -type f -exec chown root {} +"
    fi

    # 6.2.4.4 log files group owner — L1
    local bad_log_group
    bad_log_group=$(find "$audit_log_dir" -type f ! -group root 2>/dev/null | head -5)
    if [[ -z "$bad_log_group" ]]; then
        record "6.2.4.4" "PASS" "Ensure audit log files group owner is configured" ""
    else
        record "6.2.4.4" "FAIL" "Ensure audit log files group owner is configured" \
            "Fix: find ${audit_log_dir} -type f -exec chgrp root {} +"
    fi

    # 6.2.4.5-7 config files
    local bad_conf_files
    bad_conf_files=$(find /etc/audit/ -type f \( -perm /177 \) 2>/dev/null | head -5)
    if [[ -z "$bad_conf_files" ]]; then
        record "6.2.4.5" "PASS" "Ensure audit configuration files mode is configured" ""
    else
        record "6.2.4.5" "FAIL" "Ensure audit configuration files mode is configured" \
            "Fix: find /etc/audit/ -type f -exec chmod 640 {} +"
    fi

    local bad_conf_owner
    bad_conf_owner=$(find /etc/audit/ -type f ! -user root 2>/dev/null | head -5)
    if [[ -z "$bad_conf_owner" ]]; then
        record "6.2.4.6" "PASS" "Ensure audit configuration files owner is configured" ""
    else
        record "6.2.4.6" "FAIL" "Ensure audit configuration files owner is configured" \
            "Fix: find /etc/audit/ -type f -exec chown root {} +"
    fi

    local bad_conf_group
    bad_conf_group=$(find /etc/audit/ -type f ! -group root 2>/dev/null | head -5)
    if [[ -z "$bad_conf_group" ]]; then
        record "6.2.4.7" "PASS" "Ensure audit configuration files group owner is configured" ""
    else
        record "6.2.4.7" "FAIL" "Ensure audit configuration files group owner is configured" \
            "Fix: find /etc/audit/ -type f -exec chgrp root {} +"
    fi

    # 6.2.4.8-9 audit tools — L2
    local bad_tools_mode
    bad_tools_mode=$(find /sbin/auditctl /sbin/auditd /sbin/augenrules \
        /sbin/aureport /sbin/ausearch /sbin/autrace 2>/dev/null | \
        xargs stat -Lc '%#a %n' 2>/dev/null | awk '$1+0 > 755 {print $2}')
    if [[ -z "$bad_tools_mode" ]]; then
        record "6.2.4.8" "PASS" "Ensure audit tools mode is configured" ""
    else
        record "6.2.4.8" "FAIL" "Ensure audit tools mode is configured" \
            "Audit tools with wrong permissions:
${bad_tools_mode}
Fix: chmod 755 /sbin/auditctl /sbin/auditd /sbin/augenrules"
    fi

    local bad_tools_owner
    bad_tools_owner=$(find /sbin/auditctl /sbin/auditd /sbin/augenrules \
        /sbin/aureport /sbin/ausearch 2>/dev/null | \
        xargs stat -Lc '%U %n' 2>/dev/null | awk '$1 != "root" {print}')
    if [[ -z "$bad_tools_owner" ]]; then
        record "6.2.4.9" "PASS" "Ensure audit tools owner is configured" ""
    else
        record "6.2.4.9" "FAIL" "Ensure audit tools owner is configured" \
            "Fix: chown root /sbin/auditctl /sbin/auditd /sbin/augenrules"
    fi

    local bad_tools_group
    bad_tools_group=$(find /sbin/auditctl /sbin/auditd /sbin/augenrules \
        /sbin/aureport /sbin/ausearch 2>/dev/null | \
        xargs stat -Lc '%G %n' 2>/dev/null | awk '$1 != "root" {print}')
    if [[ -z "$bad_tools_group" ]]; then
        record "6.2.4.10" "PASS" "Ensure audit tools group owner is configured" ""
    else
        record "6.2.4.10" "FAIL" "Ensure audit tools group owner is configured" \
            "Fix: chgrp root /sbin/auditctl /sbin/auditd /sbin/augenrules"
    fi

    flush_manual_block "SECTION 6.2"

    # ── 6.3 Configure Integrity Checking ──────────────────────────────────────
    print_subsection "6.3" "Configure Integrity Checking"

    # 6.3.1 AIDE installed
    if dpkg-query -s aide &>/dev/null 2>&1 || dpkg-query -s aide-common &>/dev/null 2>&1; then
        record "6.3.1" "PASS" "Ensure AIDE is installed" ""
    else
        record "6.3.1" "FAIL" "Ensure AIDE is installed" \
            "Install AIDE: apt install aide aide-common
  Then initialise the database: aideinit && mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db"
    fi

    # 6.3.2 filesystem integrity regularly checked
    if crontab -l -u root 2>/dev/null | grep -qiE "aide|aideinit" || \
       find /etc/cron* /var/spool/cron/crontabs/root \
           /etc/systemd/system -name "aide*" 2>/dev/null | grep -q .; then
        record "6.3.2" "PASS" "Ensure filesystem integrity is regularly checked" ""
    else
        record "6.3.2" "FAIL" "Ensure filesystem integrity is regularly checked" \
            "Schedule regular AIDE checks. Add to root crontab:
  0 5 * * * /usr/bin/aide.wrapper --config /etc/aide/aide.conf --check
  Or create a systemd timer: /etc/systemd/system/aide.timer"
    fi

    # 6.3.3 cryptographic protection for audit tools
    if aide --check 2>/dev/null | grep -qE "auditctl|auditd|augenrules" || \
       grep -rqE "auditctl|auditd|augenrules" /etc/aide/aide.conf 2>/dev/null; then
        record "6.3.3" "PASS" \
            "Ensure cryptographic mechanisms are used to protect the integrity of audit tools" ""
    else
        record "6.3.3" "FAIL" \
            "Ensure cryptographic mechanisms are used to protect the integrity of audit tools" \
            "Add audit tools to AIDE monitoring in /etc/aide/aide.conf:
  /sbin/auditctl p+i+n+u+g+s+b+acl+xattrs+sha512
  /sbin/auditd p+i+n+u+g+s+b+acl+xattrs+sha512
  /sbin/ausearch p+i+n+u+g+s+b+acl+xattrs+sha512
  /sbin/aureport p+i+n+u+g+s+b+acl+xattrs+sha512
  Then reinitialise: aideinit"
    fi
}