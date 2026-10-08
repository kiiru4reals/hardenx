#!/usr/bin/env bash
# HardenX Ubuntu Engine — Section 7: System Maintenance

section7_run() {
    print_section "7" "System Maintenance"

    # ── 7.1 System File Permissions ───────────────────────────────────────────
    print_subsection "7.1" "System File Permissions"

    # Helper: check a single system file's perms
    _sys_file_check() {
        local id="$1" file="$2" max_perm="$3" owner="$4" group="$5" desc="$6"
        if [[ ! -e "$file" ]]; then
            record "$id" "N/A: file absent" "$desc" "${file} does not exist on this system."
            return
        fi
        if check_file_perms "$file" "$max_perm" "$owner" "$group"; then
            record "$id" "PASS" "$desc" ""
        else
            local actual_stat
            actual_stat=$(stat -Lc 'Mode:%#a Owner:%U Group:%G' "$file" 2>/dev/null)
            record "$id" "FAIL" "$desc" \
                "Fix permissions on ${file}. Expected: mode ${max_perm}, owner ${owner}, group ${group}.
  Actual: ${actual_stat}
  Run: chmod ${max_perm} ${file} && chown ${owner}:${group} ${file}"
        fi
    }

    # Core config files
    _sys_file_check "7.1.1" "/etc/passwd" "644" "root" "root" \
        "Ensure permissions on /etc/passwd are configured"
    _sys_file_check "7.1.2" "/etc/passwd-" "644" "root" "root" \
        "Ensure permissions on /etc/passwd- are configured"
    _sys_file_check "7.1.3" "/etc/group" "644" "root" "root" \
        "Ensure permissions on /etc/group are configured"
    _sys_file_check "7.1.4" "/etc/group-" "644" "root" "root" \
        "Ensure permissions on /etc/group- are configured"

    # Shadow files — allow group shadow
    local shadow_group
    shadow_group=$(stat -Lc '%G' /etc/shadow 2>/dev/null)
    if [[ ! -e "/etc/shadow" ]]; then
        record "7.1.5" "N/A: file absent" \
            "Ensure permissions on /etc/shadow are configured" "/etc/shadow does not exist."
    elif check_file_perms "/etc/shadow" "640" "root" "root" || \
         check_file_perms "/etc/shadow" "640" "root" "shadow"; then
        record "7.1.5" "PASS" "Ensure permissions on /etc/shadow are configured" ""
    else
        local shadow_stat
        shadow_stat=$(stat -Lc 'Mode:%#a Owner:%U Group:%G' /etc/shadow)
        record "7.1.5" "FAIL" "Ensure permissions on /etc/shadow are configured" \
            "Fix: chmod 640 /etc/shadow && chown root:shadow /etc/shadow
  Actual: ${shadow_stat}"
    fi

    if [[ ! -e "/etc/shadow-" ]]; then
        record "7.1.6" "N/A: file absent" \
            "Ensure permissions on /etc/shadow- are configured" "/etc/shadow- does not exist."
    elif check_file_perms "/etc/shadow-" "640" "root" "root" || \
         check_file_perms "/etc/shadow-" "640" "root" "shadow"; then
        record "7.1.6" "PASS" "Ensure permissions on /etc/shadow- are configured" ""
    else
        local shadow_bak_stat
        shadow_bak_stat=$(stat -Lc 'Mode:%#a Owner:%U Group:%G' /etc/shadow-)
        record "7.1.6" "FAIL" "Ensure permissions on /etc/shadow- are configured" \
            "Fix: chmod 640 /etc/shadow- && chown root:shadow /etc/shadow-
  Actual: ${shadow_bak_stat}"
    fi

    # gshadow files
    if [[ ! -e "/etc/gshadow" ]]; then
        record "7.1.7" "N/A: file absent" \
            "Ensure permissions on /etc/gshadow are configured" "/etc/gshadow does not exist."
    elif check_file_perms "/etc/gshadow" "640" "root" "root" || \
         check_file_perms "/etc/gshadow" "640" "root" "shadow"; then
        record "7.1.7" "PASS" "Ensure permissions on /etc/gshadow are configured" ""
    else
        record "7.1.7" "FAIL" "Ensure permissions on /etc/gshadow are configured" \
            "Fix: chmod 640 /etc/gshadow && chown root:shadow /etc/gshadow"
    fi

    if [[ ! -e "/etc/gshadow-" ]]; then
        record "7.1.8" "N/A: file absent" \
            "Ensure permissions on /etc/gshadow- are configured" "/etc/gshadow- does not exist."
    elif check_file_perms "/etc/gshadow-" "640" "root" "root" || \
         check_file_perms "/etc/gshadow-" "640" "root" "shadow"; then
        record "7.1.8" "PASS" "Ensure permissions on /etc/gshadow- are configured" ""
    else
        record "7.1.8" "FAIL" "Ensure permissions on /etc/gshadow- are configured" \
            "Fix: chmod 640 /etc/gshadow- && chown root:shadow /etc/gshadow-"
    fi

    _sys_file_check "7.1.9" "/etc/shells" "644" "root" "root" \
        "Ensure permissions on /etc/shells are configured"

    # 7.1.10 opasswd
    local opasswd_issues=""
    for ofile in "/etc/security/opasswd" "/etc/security/opasswd.old"; do
        if [[ -e "$ofile" ]]; then
            if ! check_file_perms "$ofile" "600" "root" "root"; then
                opasswd_issues+="${ofile} ($(stat -Lc 'Mode:%#a Owner:%U Group:%G' "$ofile"))\n"
            fi
        fi
    done
    if [[ -z "$opasswd_issues" ]]; then
        record "7.1.10" "PASS" "Ensure permissions on /etc/security/opasswd are configured" ""
    else
        record "7.1.10" "FAIL" "Ensure permissions on /etc/security/opasswd are configured" \
            "Fix permission issues:
$(printf "$opasswd_issues")
Run: chmod 600 /etc/security/opasswd && chown root:root /etc/security/opasswd"
    fi

    # 7.1.11 World-writable files — Manual
    print_info "Scanning for world-writable files (this may take a moment)..."
    local ww_files
    ww_files=$(find / -xdev -type f -perm -0002 \
        ! -path "/proc/*" ! -path "/sys/*" ! -path "/run/*" \
        2>/dev/null | head -30)
    if [[ -z "$ww_files" ]]; then
        record "7.1.11" "PASS" "Ensure world-writable files do not exist" ""
    else
        record "7.1.11" "MANUAL_REVIEW" "Ensure world-writable files do not exist" \
            "World-writable files found (first 30):
${ww_files}

Review each file. Remove world-write permission where not required:
  chmod o-w <file>
This is often a FAIL unless the files are intentional sticky-bit directories.
Command: find / -xdev -type f -perm -0002"
    fi

    # 7.1.12 Unowned files — Manual
    print_info "Scanning for unowned/ungrouped files (this may take a moment)..."
    local unowned_files
    unowned_files=$(find / -xdev \( -nouser -o -nogroup \) \
        ! -path "/proc/*" ! -path "/sys/*" \
        2>/dev/null | head -20)
    if [[ -z "$unowned_files" ]]; then
        record "7.1.12" "PASS" "Ensure no files or directories without an owner and a group exist" ""
    else
        record "7.1.12" "MANUAL_REVIEW" \
            "Ensure no files or directories without an owner and a group exist" \
            "Files/dirs with no valid owner or group:
${unowned_files}

Investigate each file and either:
  - Assign an owner: chown <owner>:<group> <file>
  - Remove if orphaned and unneeded: rm <file>
Command: find / -xdev \( -nouser -o -nogroup \)"
    fi

    # 7.1.13 SUID/SGID files — Manual
    print_info "Scanning for SUID/SGID binaries (this may take a moment)..."
    local suid_files
    suid_files=$(find / -xdev \( -perm -4000 -o -perm -2000 \) -type f \
        ! -path "/proc/*" ! -path "/sys/*" \
        2>/dev/null | sort)
    record "7.1.13" "MANUAL_REVIEW" \
        "Ensure SUID and SGID files are reviewed" \
        "SUID/SGID files found:
${suid_files}

Review each binary. Remove SUID/SGID bit from any that do not require elevated privileges:
  chmod u-s <file>   (remove SUID)
  chmod g-s <file>   (remove SGID)
Retain only binaries that legitimately require privilege escalation (e.g. passwd, su, ping).
Command: find / -xdev \( -perm -4000 -o -perm -2000 \) -type f"

    flush_manual_block "SECTION 7.1"

    # ── 7.2 Local User and Group Settings ─────────────────────────────────────
    print_subsection "7.2" "Local User and Group Settings"

    # 7.2.1 password hashes in /etc/shadow — not in /etc/passwd
    local passwd_hashes
    passwd_hashes=$(awk -F: '($2 != "x" && $2 != "*" && $2 != "!" && $2 != "") \
        {print $1}' /etc/passwd 2>/dev/null)
    if [[ -z "$passwd_hashes" ]]; then
        record "7.2.1" "PASS" "Ensure accounts in /etc/passwd use shadowed passwords" ""
    else
        record "7.2.1" "FAIL" "Ensure accounts in /etc/passwd use shadowed passwords" \
            "Accounts with passwords in /etc/passwd instead of /etc/shadow:
${passwd_hashes}
Convert: pwconv"
    fi

    # 7.2.2 /etc/shadow password fields not empty
    local empty_pw_shadow
    empty_pw_shadow=$(awk -F: '($2 == "") {print $1}' /etc/shadow 2>/dev/null)
    if [[ -z "$empty_pw_shadow" ]]; then
        record "7.2.2" "PASS" \
            "Ensure /etc/shadow password fields are not empty" ""
    else
        record "7.2.2" "FAIL" \
            "Ensure /etc/shadow password fields are not empty" \
            "Accounts with empty passwords:
${empty_pw_shadow}
Lock these accounts: passwd -l <user>
  OR set a password: passwd <user>"
    fi

    # 7.2.3 all groups in /etc/passwd exist in /etc/group
    local missing_groups
    missing_groups=$(awk -F: '{print $4}' /etc/passwd 2>/dev/null | sort -u | \
        while read -r gid; do
            if ! awk -F: '{print $3}' /etc/group 2>/dev/null | grep -qw "$gid"; then
                echo "GID ${gid} (referenced in /etc/passwd but not in /etc/group)"
            fi
        done)
    if [[ -z "$missing_groups" ]]; then
        record "7.2.3" "PASS" \
            "Ensure all groups in /etc/passwd exist in /etc/group" ""
    else
        record "7.2.3" "FAIL" \
            "Ensure all groups in /etc/passwd exist in /etc/group" \
            "Groups referenced in /etc/passwd but missing from /etc/group:
${missing_groups}
Create missing groups: groupadd -g <gid> <name>
  OR update /etc/passwd to use a valid GID."
    fi

    # 7.2.4 shadow group is empty
    local shadow_members
    shadow_members=$(getent group shadow 2>/dev/null | cut -d: -f4)
    if [[ -z "$shadow_members" ]]; then
        record "7.2.4" "PASS" "Ensure shadow group is empty" ""
    else
        record "7.2.4" "FAIL" "Ensure shadow group is empty" \
            "Users in the shadow group (should be empty):
${shadow_members}
Remove users: gpasswd -d <user> shadow"
    fi

    # 7.2.5 no duplicate UIDs
    local dup_uids
    dup_uids=$(awk -F: '{print $3}' /etc/passwd 2>/dev/null | \
        sort | uniq -d | \
        while read -r uid; do
            awk -F: -v uid="$uid" '$3 == uid {print $1": UID "uid}' /etc/passwd
        done)
    if [[ -z "$dup_uids" ]]; then
        record "7.2.5" "PASS" "Ensure no duplicate UIDs exist" ""
    else
        record "7.2.5" "FAIL" "Ensure no duplicate UIDs exist" \
            "Duplicate UIDs found:
${dup_uids}
Assign unique UIDs using usermod -u <new_uid> <user>"
    fi

    # 7.2.6 no duplicate GIDs
    local dup_gids
    dup_gids=$(awk -F: '{print $3}' /etc/group 2>/dev/null | \
        sort | uniq -d | \
        while read -r gid; do
            awk -F: -v gid="$gid" '$3 == gid {print $1": GID "gid}' /etc/group
        done)
    if [[ -z "$dup_gids" ]]; then
        record "7.2.6" "PASS" "Ensure no duplicate GIDs exist" ""
    else
        record "7.2.6" "FAIL" "Ensure no duplicate GIDs exist" \
            "Duplicate GIDs found:
${dup_gids}
Assign unique GIDs using groupmod -g <new_gid> <group>"
    fi

    # 7.2.7 no duplicate user names
    local dup_users
    dup_users=$(awk -F: '{print $1}' /etc/passwd 2>/dev/null | \
        sort | uniq -d)
    if [[ -z "$dup_users" ]]; then
        record "7.2.7" "PASS" "Ensure no duplicate user names exist" ""
    else
        record "7.2.7" "FAIL" "Ensure no duplicate user names exist" \
            "Duplicate usernames: ${dup_users}
Remove or rename duplicate user accounts."
    fi

    # 7.2.8 no duplicate group names
    local dup_groups
    dup_groups=$(awk -F: '{print $1}' /etc/group 2>/dev/null | \
        sort | uniq -d)
    if [[ -z "$dup_groups" ]]; then
        record "7.2.8" "PASS" "Ensure no duplicate group names exist" ""
    else
        record "7.2.8" "FAIL" "Ensure no duplicate group names exist" \
            "Duplicate group names: ${dup_groups}
Remove or rename duplicate groups."
    fi

    # 7.2.9 local interactive user home directories
    local uid_min
    uid_min=$(awk '/^\s*UID_MIN/{print $2}' /etc/login.defs 2>/dev/null)
    uid_min=${uid_min:-1000}
    local home_issues=""

    while IFS=: read -r user _ uid _ _ homedir _; do
        [[ "$uid" -lt "$uid_min" ]] && continue
        [[ "$user" == "nobody" ]] && continue

        # Check home directory exists
        if [[ ! -d "$homedir" ]]; then
            home_issues+="${user}: home directory ${homedir} does not exist\n"
            continue
        fi

        # Check home directory permissions
        local hperm howner
        hperm=$(stat -Lc '%#a' "$homedir" 2>/dev/null)
        howner=$(stat -Lc '%U' "$homedir" 2>/dev/null)

        if [[ "$howner" != "$user" ]]; then
            home_issues+="${user}: home directory ${homedir} not owned by user (owner: ${howner})\n"
        fi

        # Mode should be 750 or more restrictive
        local hperm_num
        hperm_num=$(printf '%d' "$hperm" 2>/dev/null) || hperm_num=999
        if (( hperm_num > 750 )); then
            home_issues+="${user}: home directory ${homedir} has permissive mode ${hperm}\n"
        fi
    done < /etc/passwd

    if [[ -z "$home_issues" ]]; then
        record "7.2.9" "PASS" \
            "Ensure local interactive user home directories are configured" ""
    else
        record "7.2.9" "FAIL" \
            "Ensure local interactive user home directories are configured" \
            "Home directory issues:
$(printf "$home_issues")
Fix ownership: chown <user>:<user> <homedir>
Fix permissions: chmod 750 <homedir>"
    fi

    # 7.2.10 local interactive user dot files access
    local dot_issues=""
    while IFS=: read -r user _ uid _ _ homedir _; do
        [[ "$uid" -lt "$uid_min" ]] && continue
        [[ "$user" == "nobody" ]] && continue
        [[ ! -d "$homedir" ]] && continue

        while IFS= read -r -d '' dotfile; do
            local dperm
            dperm=$(stat -Lc '%#a' "$dotfile" 2>/dev/null)
            local dperm_num
            dperm_num=$(printf '%d' "$dperm" 2>/dev/null) || dperm_num=999
            # Dot files should not be world-writable or group-writable
            if (( dperm_num & 0022 )); then
                dot_issues+="${user}: ${dotfile} has permissive mode ${dperm}\n"
            fi
        done < <(find "$homedir" -maxdepth 1 -name ".*" -type f -print0 2>/dev/null)

        # .netrc and .rhosts must not exist at all
        for bad_file in ".netrc" ".rhosts"; do
            if [[ -f "${homedir}/${bad_file}" ]]; then
                dot_issues+="${user}: ${homedir}/${bad_file} must be removed (legacy auth file)\n"
            fi
        done

        # .forward should not exist
        if [[ -f "${homedir}/.forward" ]]; then
            dot_issues+="${user}: ${homedir}/.forward should be reviewed\n"
        fi
    done < /etc/passwd

    if [[ -z "$dot_issues" ]]; then
        record "7.2.10" "PASS" \
            "Ensure local interactive user dot files access is configured" ""
    else
        record "7.2.10" "MANUAL_REVIEW" \
            "Ensure local interactive user dot files access is configured" \
            "Dot file issues found:
$(printf "$dot_issues")
Remove .netrc and .rhosts, fix permissions on remaining dot files:
  chmod go-w <dotfile>
Command: find /home -maxdepth 2 -name '.*' | xargs stat -c '%n %a'"
    fi

    flush_manual_block "SECTION 7.2"
}