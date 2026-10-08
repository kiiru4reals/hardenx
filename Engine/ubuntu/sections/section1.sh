#!/usr/bin/env bash
# HardenX Ubuntu Engine — Section 1: Initial Setup

section1_run() {
    print_section "1" "Initial Setup"

    # ── 1.1 Filesystem Kernel Modules ────────────────────────────────────────
    print_subsection "1.1.1" "Configure Filesystem Kernel Modules"

    local fs_modules=(
        "1.1.1.1:cramfs:fs"
        "1.1.1.2:freevxfs:fs"
        "1.1.1.3:hfs:fs"
        "1.1.1.4:hfsplus:fs"
        "1.1.1.5:jffs2:fs"
        "1.1.1.6:overlay:fs"
        "1.1.1.7:squashfs:fs"
        "1.1.1.8:udf:fs"
        "1.1.1.9:firewire-core:drivers"
        "1.1.1.10:usb-storage:drivers"
    )

    for entry in "${fs_modules[@]}"; do
        IFS=':' read -r id mod modtype <<< "$entry"

        # Level 2 only checks
        if [[ "$SCAN_LEVEL" -eq 1 && ( "$id" == "1.1.1.6" || "$id" == "1.1.1.8" ) ]]; then
            continue
        fi

        local desc="Ensure ${mod} kernel module is not available"

        # Conditional overrides
        if [[ "$id" == "1.1.1.6" && "$HOST_CONTAINERIZED_SERVICES" == "true" ]]; then
            record "$id" "N/A: containerised services active" \
                "$desc" \
                "Overlay module may be required by the container runtime."
            continue
        fi

        if [[ "$id" == "1.1.1.7" ]]; then
            if [[ "$HOST_SNAP_ACTIVE" == "true" && "$HOST_SQUASHFS_BUILTIN" == "true" ]]; then
                record "$id" "PASS" "$desc" ""
                printf "  ${CYAN}NOTE:${RESET} squashfs is compiled into the kernel; snap is active — expected.\n"
                continue
            elif [[ "$HOST_SNAP_ACTIVE" == "true" && "$HOST_SQUASHFS_BUILTIN" == "false" ]]; then
                local snap_out
                snap_out=$(snap list 2>/dev/null | tail -n +2 | awk '{print $1}' | tr '\n' ' ')
                record "$id" "MANUAL_REVIEW" "$desc" \
                    "snap is active and requires squashfs. Active snaps: ${snap_out}
Confirm whether snap is an organisational requirement.
If snap is to be removed: snap remove <name> for each snap, then disable squashfs.
Command: snap list"
                continue
            fi
        fi

        if [[ "$id" == "1.1.1.8" && "$HOST_CLOUD_PROVIDER" == "azure" ]]; then
            record "$id" "N/A: Azure cloud host" \
                "$desc" \
                "Azure requires the UDF kernel module for platform operations."
            continue
        fi

        if [[ "$id" == "1.1.1.10" && "$HOST_CLOUD_HOSTED" == "true" ]]; then
            record "$id" "N/A: cloud-hosted" \
                "$desc" \
                "Physical USB access is not available in cloud-hosted environments."
            continue
        fi

        if check_kernel_module "$mod" "$modtype"; then
            record "$id" "PASS" "$desc" ""
        else
            record "$id" "FAIL" "$desc" \
                "Disable the ${mod} module: add 'install ${mod} /bin/false' and
'blacklist ${mod}' to /etc/modprobe.d/${mod}.conf, then run:
  rmmod ${mod} 2>/dev/null; update-initramfs -u"
        fi
    done

    # 1.1.1.11 — Manual: unused filesystem modules
    if [[ "$SCAN_LEVEL" -ge 1 ]]; then
        local unused_mods
        unused_mods=$(ls /usr/lib/modules/**/kernel/fs/ 2>/dev/null | \
            grep -vE "ext4|xfs|btrfs|tmpfs|proc|sysfs|devtmpfs|overlay|squashfs" | \
            sort -u | tr '\n' ' ')
        record "1.1.1.11" "MANUAL_REVIEW" \
            "Ensure unused filesystems kernel modules are not available" \
            "Review the following filesystem modules and disable any not required:
${unused_mods:-none found beyond standard modules}
For each unneeded module: add 'install <mod> /bin/false' and 'blacklist <mod>'
to /etc/modprobe.d/<mod>.conf
Command: ls /usr/lib/modules/\$(uname -r)/kernel/fs/"
    fi

    flush_manual_block "SECTION 1.1.1"

    # ── 1.1.2 Filesystem Partitions ──────────────────────────────────────────
    print_subsection "1.1.2" "Configure Filesystem Partitions"

    # Helper: partition + mount option checks
    _partition_check() {
        local id="$1" mountpoint="$2" option="$3"
        local desc="Ensure ${option} option set on ${mountpoint} partition"
        local ret
        check_mount_option "$mountpoint" "$option"; ret=$?
        case $ret in
            0) record "$id" "PASS" "$desc" "" ;;
            1) record "$id" "FAIL" "$desc" \
                "Edit /etc/fstab and add '${option}' to mount options for ${mountpoint}, then remount:
  mount -o remount ${mountpoint}" ;;
            2) record "$id" "N/A: no separate partition" "$desc" \
                "${mountpoint} is not mounted as a separate partition." ;;
        esac
    }

    _separate_partition_check() {
        local id="$1" mountpoint="$2"
        local desc="Ensure separate partition exists for ${mountpoint}"
        if findmnt -kn "$mountpoint" &>/dev/null; then
            record "$id" "PASS" "$desc" ""
        else
            local level_req="L1"
            [[ "$id" =~ "1.1.2.3.1"|"1.1.2.4.1"|"1.1.2.6.1" ]] && level_req="L2"
            record "$id" "FAIL" "$desc" \
                "Create a separate partition for ${mountpoint}.
For new systems, configure during installation.
For existing systems, use LVM to create and mount a new volume for ${mountpoint}."
        fi
    }

    # /tmp
    print_subsection "1.1.2.1" "Configure /tmp"
    local tmp_type
    tmp_type=$(findmnt -kn -o FSTYPE /tmp 2>/dev/null)
    if [[ "$tmp_type" == "tmpfs" ]] || findmnt -kn /tmp &>/dev/null; then
        record "1.1.2.1.1" "PASS" "Ensure /tmp is tmpfs or a separate partition" ""
    else
        record "1.1.2.1.1" "FAIL" "Ensure /tmp is tmpfs or a separate partition" \
            "Configure /tmp as tmpfs in /etc/fstab:
  tmpfs /tmp tmpfs defaults,rw,nosuid,nodev,noexec,relatime 0 0"
    fi
    _partition_check "1.1.2.1.2" "/tmp" "nodev"
    _partition_check "1.1.2.1.3" "/tmp" "nosuid"
    _partition_check "1.1.2.1.4" "/tmp" "noexec"

    print_subsection "1.1.2.2" "Configure /dev/shm"
    if findmnt -kn /dev/shm &>/dev/null; then
        record "1.1.2.2.1" "PASS" "Ensure /dev/shm is tmpfs or a separate partition" ""
    else
        record "1.1.2.2.1" "FAIL" "Ensure /dev/shm is tmpfs or a separate partition" \
            "Add to /etc/fstab: tmpfs /dev/shm tmpfs defaults,rw,nosuid,nodev,noexec,relatime 0 0"
    fi
    _partition_check "1.1.2.2.2" "/dev/shm" "nodev"
    _partition_check "1.1.2.2.3" "/dev/shm" "nosuid"
    _partition_check "1.1.2.2.4" "/dev/shm" "noexec"

    print_subsection "1.1.2.3" "Configure /home"
    [[ "$SCAN_LEVEL" -ge 2 ]] && _separate_partition_check "1.1.2.3.1" "/home"
    _partition_check "1.1.2.3.2" "/home" "nodev"
    _partition_check "1.1.2.3.3" "/home" "nosuid"

    print_subsection "1.1.2.4" "Configure /var"
    [[ "$SCAN_LEVEL" -ge 2 ]] && _separate_partition_check "1.1.2.4.1" "/var"
    _partition_check "1.1.2.4.2" "/var" "nodev"
    _partition_check "1.1.2.4.3" "/var" "nosuid"

    print_subsection "1.1.2.5" "Configure /var/tmp"
    _separate_partition_check "1.1.2.5.1" "/var/tmp"
    _partition_check "1.1.2.5.2" "/var/tmp" "nodev"
    _partition_check "1.1.2.5.3" "/var/tmp" "nosuid"
    _partition_check "1.1.2.5.4" "/var/tmp" "noexec"

    print_subsection "1.1.2.6" "Configure /var/log"
    [[ "$SCAN_LEVEL" -ge 2 ]] && _separate_partition_check "1.1.2.6.1" "/var/log"
    _partition_check "1.1.2.6.2" "/var/log" "nodev"
    _partition_check "1.1.2.6.3" "/var/log" "nosuid"
    _partition_check "1.1.2.6.4" "/var/log" "noexec"

    print_subsection "1.1.2.7" "Configure /var/log/audit"
    _separate_partition_check "1.1.2.7.1" "/var/log/audit"
    _partition_check "1.1.2.7.2" "/var/log/audit" "nodev"
    _partition_check "1.1.2.7.3" "/var/log/audit" "nosuid"
    _partition_check "1.1.2.7.4" "/var/log/audit" "noexec"

    # ── 1.2 Package Management ────────────────────────────────────────────────
    print_subsection "1.2.1" "Configure Package Repositories"

    # 1.2.1.1 — Manual: Signed-By option in sources
    local sources_out
    sources_out=$(grep -rE "^deb " /etc/apt/sources.list \
        /etc/apt/sources.list.d/*.list 2>/dev/null | \
        grep -v "signed-by" | head -20)
    if [[ -z "$sources_out" ]]; then
        record "1.2.1.1" "PASS" \
            "Ensure the source.list and .source files use the Signed-By option" ""
    else
        record "1.2.1.1" "MANUAL_REVIEW" \
            "Ensure the source.list and .source files use the Signed-By option" \
            "The following sources may be missing the Signed-By option:
${sources_out}
Review each source entry and add 'signed-by=/path/to/keyring.gpg' where appropriate.
Command: grep -rE '^deb ' /etc/apt/sources.list /etc/apt/sources.list.d/"
    fi

    # 1.2.1.2 — L2: weak dependencies
    if [[ "$SCAN_LEVEL" -ge 2 ]]; then
        local apt_conf
        apt_conf=$(apt-config dump 2>/dev/null | grep -i "APT::AutoRemove::SuggestsImportant")
        if echo "$apt_conf" | grep -q "false"; then
            record "1.2.1.2" "PASS" "Ensure weak dependencies are configured" ""
        else
            record "1.2.1.2" "FAIL" "Ensure weak dependencies are configured" \
                "Set APT::AutoRemove::SuggestsImportant to false in /etc/apt/apt.conf.d/
  echo 'APT::AutoRemove::SuggestsImportant \"false\";' > /etc/apt/apt.conf.d/01autoremove"
        fi
    fi

    # GPG key access checks (1.2.1.3 through 1.2.1.9)
    local gpg_checks=(
        "1.2.1.3:/etc/apt/trusted.gpg:640:root:root"
        "1.2.1.4:/etc/apt/trusted.gpg.d:755:root:root"
        "1.2.1.5:/etc/apt/auth.conf.d:700:root:root"
        "1.2.1.7:/usr/share/keyrings:755:root:root"
        "1.2.1.8:/etc/apt/sources.list.d:755:root:root"
    )
    for entry in "${gpg_checks[@]}"; do
        IFS=':' read -r gid gpath gperm gowner ggroup <<< "$entry"
        local gdesc="Ensure access to ${gpath} is configured"
        if [[ ! -e "$gpath" ]]; then
            record "$gid" "N/A: path absent" "$gdesc" \
                "${gpath} does not exist on this system."
            continue
        fi
        if check_file_perms "$gpath" "$gperm" "$gowner" "$ggroup"; then
            record "$gid" "PASS" "$gdesc" ""
        else
            local actual_stat
            actual_stat=$(stat -Lc 'Mode:%#a Owner:%U Group:%G' "$gpath" 2>/dev/null)
            record "$gid" "FAIL" "$gdesc" \
                "Set correct permissions on ${gpath}. Expected: mode ${gperm}, owner ${gowner}, group ${ggroup}.
  Actual: ${actual_stat}
  Run: chmod ${gperm} ${gpath} && chown ${gowner}:${ggroup} ${gpath}"
        fi
    done

    # 1.2.1.6 — files in auth.conf.d
    local bad_authconf
    bad_authconf=$(find /etc/apt/auth.conf.d/ -type f \
        \( -perm /077 -o ! -user root -o ! -group root \) 2>/dev/null)
    if [[ -z "$bad_authconf" ]]; then
        record "1.2.1.6" "PASS" \
            "Ensure access to files in /etc/apt/auth.conf.d/ is configured" ""
    else
        record "1.2.1.6" "FAIL" \
            "Ensure access to files in /etc/apt/auth.conf.d/ is configured" \
            "Fix permissions on files in /etc/apt/auth.conf.d/:
  find /etc/apt/auth.conf.d/ -type f -exec chmod 600 {} \; -exec chown root:root {} \;"
    fi

    # 1.2.1.9 — files in sources.list.d
    local bad_sources
    bad_sources=$(find /etc/apt/sources.list.d/ -type f -name "*.list" \
        \( -perm /133 -o ! -user root -o ! -group root \) 2>/dev/null)
    if [[ -z "$bad_sources" ]]; then
        record "1.2.1.9" "PASS" \
            "Ensure access to files in /etc/apt/sources.list.d are configured" ""
    else
        record "1.2.1.9" "FAIL" \
            "Ensure access to files in /etc/apt/sources.list.d are configured" \
            "Fix permissions: find /etc/apt/sources.list.d/ -type f -exec chmod 644 {} \; -exec chown root:root {} \;"
    fi

    # 1.2.2.1 — Manual: updates installed
    print_subsection "1.2.2" "Configure Package Updates"
    local upgradable
    upgradable=$(apt list --upgradable 2>/dev/null | grep -v "^Listing" | head -20)
    if [[ -z "$upgradable" ]]; then
        record "1.2.2.1" "PASS" \
            "Ensure updates, patches, and additional security software are installed" ""
    else
        record "1.2.2.1" "MANUAL_REVIEW" \
            "Ensure updates, patches, and additional security software are installed" \
            "The following upgradable packages were found:
${upgradable}
Run: apt upgrade  (review changes before applying in production)
Command: apt list --upgradable"
    fi

    flush_manual_block "SECTION 1.2"

    # ── 1.3 Mandatory Access Control (AppArmor) ───────────────────────────────
    print_subsection "1.3.1" "Configure AppArmor"

    # 1.3.1.1
    if dpkg-query -s apparmor &>/dev/null 2>&1; then
        record "1.3.1.1" "PASS" "Ensure apparmor packages are installed" ""
    else
        record "1.3.1.1" "FAIL" "Ensure apparmor packages are installed" \
            "Install AppArmor: apt install apparmor apparmor-utils"
    fi

    # 1.3.1.2
    if grep -qE "^\s*GRUB_CMDLINE_LINUX.*apparmor=1.*security=apparmor" \
       /etc/default/grub /etc/default/grub.d/*.cfg 2>/dev/null || \
       aa-status &>/dev/null 2>&1; then
        record "1.3.1.2" "PASS" "Ensure AppArmor is enabled" ""
    else
        record "1.3.1.2" "FAIL" "Ensure AppArmor is enabled" \
            "Enable AppArmor in GRUB:
  Edit /etc/default/grub and add 'apparmor=1 security=apparmor' to GRUB_CMDLINE_LINUX
  Then run: update-grub && reboot"
    fi

    # 1.3.1.3 — L2
    if [[ "$SCAN_LEVEL" -ge 2 ]]; then
        local aa_unconfined
        aa_unconfined=$(aa-status 2>/dev/null | grep -c "processes are unconfined" || echo "0")
        local aa_complain
        aa_complain=$(aa-status 2>/dev/null | grep -c "profiles are in complain mode" || echo "0")
        if [[ "$aa_complain" -eq 0 && "$aa_unconfined" -eq 0 ]]; then
            record "1.3.1.3" "PASS" "Ensure all AppArmor Profiles are enforcing" ""
        else
            record "1.3.1.3" "FAIL" "Ensure all AppArmor Profiles are enforcing" \
                "Set all profiles to enforce mode:
  aa-enforce /etc/apparmor.d/*
  Profiles in complain mode: ${aa_complain}, Unconfined processes: ${aa_unconfined}"
        fi
    fi

    # 1.3.1.4
    local aa_unpriv
    aa_unpriv=$(sysctl -n kernel.apparmor_restrict_unprivileged_unconfined 2>/dev/null)
    if [[ "$aa_unpriv" == "1" ]]; then
        record "1.3.1.4" "PASS" \
            "Ensure apparmor_restrict_unprivileged_unconfined is enabled" ""
    else
        record "1.3.1.4" "FAIL" \
            "Ensure apparmor_restrict_unprivileged_unconfined is enabled" \
            "Enable restriction:
  echo 'kernel.apparmor_restrict_unprivileged_unconfined = 1' > /etc/sysctl.d/60-apparmor.conf
  sysctl -p /etc/sysctl.d/60-apparmor.conf"
    fi

    # ── 1.4 Configure Bootloader ──────────────────────────────────────────────
    print_subsection "1.4" "Configure Bootloader"

    # 1.4.1 — Bootloader password
    local grub_pw_set=false
    if grep -qE "^set superusers\b|^password_pbkdf2\b" \
       /boot/grub/grub.cfg /boot/grub2/grub.cfg 2>/dev/null; then
        grub_pw_set=true
    fi
    if [[ "$grub_pw_set" == "true" ]]; then
        record "1.4.1" "PASS" "Ensure bootloader password is set" ""
    else
        record "1.4.1" "FAIL" "Ensure bootloader password is set" \
            "Set a GRUB superuser and password:
  1. Run: grub-mkpasswd-pbkdf2  (note the hash)
  2. Create /etc/grub.d/40_custom with:
       set superusers=\"root\"
       password_pbkdf2 root <hash>
  3. Run: update-grub
WARNING: Setting a bootloader password that is subsequently forgotten may prevent
the system from completing a reboot without physical console access or rescue media.
Before making this change, store the password securely in a password manager or
documented recovery procedure, and confirm a tested recovery path exists.
A forgotten bootloader password on a remote or unattended server may result in
prolonged downtime."
    fi

    # 1.4.2 — Bootloader config access
    local grub_cfg
    grub_cfg=$(find /boot -name "grub.cfg" 2>/dev/null | head -1)
    if [[ -n "$grub_cfg" ]]; then
        if check_file_perms "$grub_cfg" "600" "root" "root"; then
            record "1.4.2" "PASS" "Ensure access to bootloader config is configured" ""
        else
            local grub_stat
            grub_stat=$(stat -Lc 'Mode:%#a Owner:%U Group:%G' "$grub_cfg")
            record "1.4.2" "FAIL" "Ensure access to bootloader config is configured" \
                "Fix bootloader config permissions. Actual: ${grub_stat}
  chmod 600 ${grub_cfg} && chown root:root ${grub_cfg}"
        fi
    else
        record "1.4.2" "SKIPPED: grub.cfg not found" \
            "Ensure access to bootloader config is configured" \
            "grub.cfg not found in /boot — verify bootloader configuration manually."
    fi

    # ── 1.5 Additional Process Hardening ──────────────────────────────────────
    print_subsection "1.5" "Additional Process Hardening"

    local sysctl_checks_l1=(
        "1.5.1:fs.protected_hardlinks:1:Set fs.protected_hardlinks=1 in /etc/sysctl.d/60-kernel_sysctl.conf"
        "1.5.4:fs.suid_dumpable:0:Set fs.suid_dumpable=0 in /etc/sysctl.d/60-kernel_sysctl.conf"
        "1.5.5:kernel.dmesg_restrict:1:Set kernel.dmesg_restrict=1 in /etc/sysctl.d/60-kernel_sysctl.conf"
        "1.5.8:kernel.kptr_restrict:2:Set kernel.kptr_restrict=2 in /etc/sysctl.d/60-kernel_sysctl.conf"
        "1.5.9:kernel.randomize_va_space:2:Set kernel.randomize_va_space=2 in /etc/sysctl.d/60-kernel_sysctl.conf"
        "1.5.3:kernel.yama.ptrace_scope:1:Set kernel.yama.ptrace_scope=1 in /etc/sysctl.d/60-kernel_sysctl.conf"
        "1.5.11:kernel.core_uses_pid:1:Set kernel.core_uses_pid=1 via systemd-coredump ProcessSizeMax config"
    )

    local sysctl_checks_l2=(
        "1.5.2:fs.protected_symlinks:1:Set fs.protected_symlinks=1 in /etc/sysctl.d/60-kernel_sysctl.conf"
    )

    for entry in "${sysctl_checks_l1[@]}"; do
        IFS=':' read -r sid sparam sexpect srem <<< "$entry"
        local sdesc="Ensure ${sparam} is configured"
        if check_sysctl "$sparam" "$sexpect"; then
            record "$sid" "PASS" "$sdesc" ""
        else
            local sactual
            sactual=$(sysctl -n "$sparam" 2>/dev/null)
            record "$sid" "FAIL" "$sdesc" \
                "${srem}
  sysctl -w ${sparam}=${sexpect}
  Current value: ${sactual:-not set}"
        fi
    done

    if [[ "$SCAN_LEVEL" -ge 2 ]]; then
        for entry in "${sysctl_checks_l2[@]}"; do
            IFS=':' read -r sid sparam sexpect srem <<< "$entry"
            local sdesc="Ensure ${sparam} is configured"
            if check_sysctl "$sparam" "$sexpect"; then
                record "$sid" "PASS" "$sdesc" ""
            else
                record "$sid" "FAIL" "$sdesc" \
                    "${srem}
  sysctl -w ${sparam}=${sexpect}"
            fi
        done
    fi

    # 1.5.6 prelink
    if ! dpkg-query -s prelink &>/dev/null 2>&1; then
        record "1.5.6" "PASS" "Ensure prelink is not installed" ""
    else
        record "1.5.6" "FAIL" "Ensure prelink is not installed" \
            "Remove prelink: prelink -ua && apt purge prelink"
    fi

    # 1.5.7 Automatic Error Reporting (apport)
    local apport_enabled
    apport_enabled=$(grep -Po '(?<=^enabled=)\d' /etc/default/apport 2>/dev/null)
    if [[ "$apport_enabled" == "0" ]] || ! dpkg-query -s apport &>/dev/null 2>&1; then
        record "1.5.7" "PASS" "Ensure Automatic Error Reporting is configured" ""
    else
        record "1.5.7" "FAIL" "Ensure Automatic Error Reporting is configured" \
            "Disable apport: edit /etc/default/apport and set enabled=0
  systemctl stop apport && systemctl disable apport"
    fi

    # 1.5.11 / 1.5.12 systemd-coredump
    local coredump_size coredump_storage
    coredump_size=$(grep -Po '(?<=^ProcessSizeMax=)\S+' \
        /etc/systemd/coredump.conf /etc/systemd/coredump.conf.d/*.conf 2>/dev/null | \
        tail -1)
    coredump_storage=$(grep -Po '(?<=^Storage=)\S+' \
        /etc/systemd/coredump.conf /etc/systemd/coredump.conf.d/*.conf 2>/dev/null | \
        tail -1)
    [[ "$coredump_size" == "0" ]] && \
        record "1.5.11" "PASS" "Ensure systemd-coredump ProcessSizeMax is configured" "" || \
        record "1.5.11" "FAIL" "Ensure systemd-coredump ProcessSizeMax is configured" \
            "Set ProcessSizeMax=0 in /etc/systemd/coredump.conf.d/99-policy.conf"
    [[ "$coredump_storage" == "none" ]] && \
        record "1.5.12" "PASS" "Ensure systemd-coredump Storage is configured" "" || \
        record "1.5.12" "FAIL" "Ensure systemd-coredump Storage is configured" \
            "Set Storage=none in /etc/systemd/coredump.conf.d/99-policy.conf"

    # ── 1.6 Command Line Warning Banners ──────────────────────────────────────
    print_subsection "1.6" "Configure Command Line Warning Banners"

    local banner_checks=(
        "1.6.1:/etc/motd:configure MOTD with organisation banner"
        "1.6.2:/etc/issue:configure local login banner"
        "1.6.3:/etc/issue.net:configure pre-login network banner"
    )
    for entry in "${banner_checks[@]}"; do
        IFS=':' read -r bid bfile brem <<< "$entry"
        local bdesc="Ensure ${bfile} is configured"
        if [[ -s "$bfile" ]] && ! grep -qiE "\\\v|\\\r|\\\m|\\\s" "$bfile" 2>/dev/null; then
            record "$bid" "PASS" "$bdesc" ""
        else
            local bactual
            bactual=$(cat "$bfile" 2>/dev/null || echo "(empty)")
            record "$bid" "FAIL" "$bdesc" \
                "File: ${bfile} — ${brem}
Replace content with an appropriate warning banner. Remove escape sequences (\v \r \m \s).
Current content: ${bactual}"
        fi
    done

    # 1.6.4 pam_motd
    local pam_motd_conf
    pam_motd_conf=$(find /etc/pam.d/ -name "login" -o -name "sshd" 2>/dev/null | \
        xargs grep -l "pam_motd" 2>/dev/null)
    if [[ -n "$pam_motd_conf" ]]; then
        record "1.6.4" "PASS" "Ensure pam_motd is configured" ""
    else
        record "1.6.4" "FAIL" "Ensure pam_motd is configured" \
            "Add 'session optional pam_motd.so motd=/run/motd.dynamic' to /etc/pam.d/login and /etc/pam.d/sshd"
    fi

    # 1.6.5 sshd warning Banner
    local sshd_banner
    sshd_banner=$(sshd -T 2>/dev/null | grep -i "^banner" | awk '{print $2}')
    if [[ -n "$sshd_banner" && "$sshd_banner" != "none" ]]; then
        record "1.6.5" "PASS" "Ensure sshd warning Banner is configured" ""
    else
        record "1.6.5" "FAIL" "Ensure sshd warning Banner is configured" \
            "Set Banner in /etc/ssh/sshd_config:
  Banner /etc/issue.net
  Then: systemctl reload sshd"
    fi

    # 1.6.6 - 1.6.10: file access on banner files
    local banner_access_checks=(
        "1.6.6:/etc/motd:644:root:root"
        "1.6.7:/etc/issue:644:root:root"
        "1.6.8:/etc/issue.net:644:root:root"
    )
    for entry in "${banner_access_checks[@]}"; do
        IFS=':' read -r bid bfile bperm bowner bgroup <<< "$entry"
        local bdesc="Ensure access to ${bfile} is configured"
        if [[ ! -f "$bfile" ]]; then
            record "$bid" "N/A: file absent" "$bdesc" "${bfile} does not exist."
            continue
        fi
        if check_file_perms "$bfile" "$bperm" "$bowner" "$bgroup"; then
            record "$bid" "PASS" "$bdesc" ""
        else
            local bstat
            bstat=$(stat -Lc 'Mode:%#a Owner:%U Group:%G' "$bfile")
            record "$bid" "FAIL" "$bdesc" \
                "Fix permissions on ${bfile}. Actual: ${bstat}
  chmod ${bperm} ${bfile} && chown ${bowner}:${bgroup} ${bfile}"
        fi
    done

    # 1.6.9 pam_motd file access
    local pam_motd_file="/usr/lib/x86_64-linux-gnu/security/pam_motd.so"
    [[ ! -f "$pam_motd_file" ]] && \
        pam_motd_file=$(find /usr/lib -name "pam_motd.so" 2>/dev/null | head -1)
    if [[ -n "$pam_motd_file" ]]; then
        if check_file_perms "$pam_motd_file" "644" "root" "root"; then
            record "1.6.9" "PASS" "Ensure access to pam_motd file is configured" ""
        else
            record "1.6.9" "FAIL" "Ensure access to pam_motd file is configured" \
                "Fix: chmod 644 ${pam_motd_file} && chown root:root ${pam_motd_file}"
        fi
    fi

    # 1.6.10 sshd warning banner file access
    if [[ -n "$sshd_banner" && -f "$sshd_banner" ]]; then
        if check_file_perms "$sshd_banner" "644" "root" "root"; then
            record "1.6.10" "PASS" "Ensure access to sshd warning banner is configured" ""
        else
            local banner_stat
            banner_stat=$(stat -Lc 'Mode:%#a Owner:%U Group:%G' "$sshd_banner")
            record "1.6.10" "FAIL" "Ensure access to sshd warning banner is configured" \
                "Fix: chmod 644 ${sshd_banner} && chown root:root ${sshd_banner}. Actual: ${banner_stat}"
        fi
    fi

    flush_manual_block "SECTION 1.6"

    # ── 1.7 GNOME Display Manager ─────────────────────────────────────────────
    print_subsection "1.7" "GNOME Display Manager"

    local gdm_installed=false
    dpkg-query -s gdm3 &>/dev/null 2>&1 && gdm_installed=true

    if [[ "$gdm_installed" == "false" ]]; then
        print_info "GDM is not installed. Section 1.7 skipped per benchmark skip instruction."
        local gdm_checks=(
            "1.7.1:Ensure GDM login banner is configured"
            "1.7.2:Ensure GDM disable-user-list is configured"
            "1.7.3:Ensure GDM screen lock is configured"
            "1.7.4:Ensure GDM automount is configured"
            "1.7.5:Ensure GDM autorun-never is configured"
            "1.7.6:Ensure XDMCP is not enabled"
        )
        for entry in "${gdm_checks[@]}"; do
            IFS=':' read -r gid gdesc <<< "$entry"
            record "$gid" "N/A: GDM not installed" "$gdesc" \
                "GDM is not installed on this host. Section 1.7 skipped per benchmark."
        done
        if [[ "$SCAN_LEVEL" -ge 2 ]]; then
            record "1.7.7" "N/A: GDM not installed" "Ensure Xwayland is configured" \
                "GDM is not installed on this host. Section 1.7 skipped per benchmark."
        fi
    else
        # GDM present on server — record advisory and run checks
        record "SERVER-GDM-01" "MANUAL_REVIEW" \
            "GDM is installed on a server deployment — removal recommended" \
            "GDM and desktop packages increase the attack surface of a server.
Remove GDM to resolve: apt remove gdm3 ubuntu-desktop && apt autoremove
Review installed desktop packages: dpkg -l | grep -E 'gdm|gnome|xorg|ubuntu-desktop'"

        # 1.7.1 GDM login banner
        local gdm_banner
        gdm_banner=$(grep -rh "banner-message-enable\|banner-message-text" \
            /etc/dconf/db/ 2>/dev/null | head -5)
        if echo "$gdm_banner" | grep -q "true"; then
            record "1.7.1" "PASS" "Ensure GDM login banner is configured" ""
        else
            record "1.7.1" "FAIL" "Ensure GDM login banner is configured" \
                "Configure GDM banner in /etc/dconf/db/gdm.d/01-banner-message:
  [org/gnome/login-screen]
  banner-message-enable=true
  banner-message-text='<your banner>'
  Then: dconf update"
        fi

        # 1.7.2 disable-user-list
        local gdm_userlist
        gdm_userlist=$(grep -rh "disable-user-list" \
            /etc/dconf/db/ 2>/dev/null | head -2)
        if echo "$gdm_userlist" | grep -q "true"; then
            record "1.7.2" "PASS" "Ensure GDM disable-user-list is configured" ""
        else
            record "1.7.2" "FAIL" "Ensure GDM disable-user-list is configured" \
                "Set in /etc/dconf/db/gdm.d/00-login-screen:
  [org/gnome/login-screen]
  disable-user-list=true
  Then: dconf update"
        fi

        # 1.7.3 screen lock
        local gdm_lock
        gdm_lock=$(grep -rh "lock-enabled\|lock-delay" \
            /etc/dconf/db/ 2>/dev/null | head -5)
        if echo "$gdm_lock" | grep -q "lock-enabled=true"; then
            record "1.7.3" "PASS" "Ensure GDM screen lock is configured" ""
        else
            record "1.7.3" "FAIL" "Ensure GDM screen lock is configured" \
                "Configure screen lock via dconf: lock-enabled=true, lock-delay=uint32 0"
        fi

        # 1.7.4 automount disabled
        local gdm_automount
        gdm_automount=$(grep -rh "automount" /etc/dconf/db/ 2>/dev/null | head -5)
        if echo "$gdm_automount" | grep -q "false"; then
            record "1.7.4" "PASS" "Ensure GDM automount is configured" ""
        else
            record "1.7.4" "FAIL" "Ensure GDM automount is configured" \
                "Disable automount in dconf: org/gnome/desktop/media-handling/automount=false"
        fi

        # 1.7.5 autorun-never
        local gdm_autorun
        gdm_autorun=$(grep -rh "autorun-never" /etc/dconf/db/ 2>/dev/null)
        if echo "$gdm_autorun" | grep -q "true"; then
            record "1.7.5" "PASS" "Ensure GDM autorun-never is configured" ""
        else
            record "1.7.5" "FAIL" "Ensure GDM autorun-never is configured" \
                "Set autorun-never=true in dconf: org/gnome/desktop/media-handling/autorun-never=true"
        fi

        # 1.7.6 XDMCP disabled
        if ! grep -qE "^\s*Enable\s*=\s*true" /etc/gdm3/custom.conf 2>/dev/null; then
            record "1.7.6" "PASS" "Ensure XDMCP is not enabled" ""
        else
            record "1.7.6" "FAIL" "Ensure XDMCP is not enabled" \
                "In /etc/gdm3/custom.conf, under [xdmcp], set Enable=false"
        fi

        # 1.7.7 Xwayland — L2
        if [[ "$SCAN_LEVEL" -ge 2 ]]; then
            if grep -qE "^\s*WaylandEnable\s*=\s*true" /etc/gdm3/custom.conf 2>/dev/null; then
                record "1.7.7" "PASS" "Ensure Xwayland is configured" ""
            else
                record "1.7.7" "FAIL" "Ensure Xwayland is configured" \
                    "Enable Wayland in /etc/gdm3/custom.conf: WaylandEnable=true"
            fi
        fi

        flush_manual_block "SECTION 1.7"
    fi
}