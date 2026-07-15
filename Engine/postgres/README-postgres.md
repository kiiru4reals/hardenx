# Adhiambo — PostgreSQL Engine Design Document
### Component: `engine/postgresql/cis_checks.sh`
**Benchmark Reference:** CIS PostgreSQL 18 Benchmark v1.0.0 (03-27-2026)
**Status:** Design Complete — Ready for Implementation
**Version:** 0.3

---

## 1. Purpose

This document defines the design for the Adhiambo PostgreSQL Engine (`engine/postgresql/cis_checks.sh`). The PostgreSQL Engine is responsible for running CIS Benchmark compliance checks against a PostgreSQL 18 installation and producing structured findings in CSV format, with supplementary TXT and JSON output files for checks that require operator review or downstream tooling integration.

The engine is self-contained. It does not delegate compliance logic to any external tool — all checks are implemented natively in Bash using `psql`, system commands, and file inspection. The engine handles its own OS detection independently and does not rely on the orchestrator for environment context.

---

## 2. Role in the Architecture

```
adhiambo.sh (entrypoint & orchestrator)
        │
        ▼
engine/postgresql/cis_checks.sh
        │
        ├── [Pre-flight]
        │     ├── OS Detection (apt vs rpm)
        │     ├── Pre-scan operator prompts
        │     │     ├── DB credentials
        │     │     ├── User list (space-separated or .txt file)
        │     │     └── Maximum log file size (MB)
        │     └── Validate output directory
        │
        ├── [Section 1 — Installation and Patches]
        ├── [Section 2 — Directory and File Permissions]
        ├── [Section 3 — Logging and Auditing]
        ├── [Section 4 — User Access and Authorization]
        ├── [Section 5 — Connection and Login]
        ├── [Section 6 — PostgreSQL Settings]
        ├── [Section 7 — Replication]
        └── [Section 8 — Special Configuration]
                │
                └── Output files
                      ├── postgres_compliance_<hostname>_<date>.csv
                      ├── postgres_admin_privileges_<hostname>_<date>.txt
                      ├── postgres_admin_privileges_<hostname>_<date>.json
                      ├── postgres_dml_privileges_<hostname>_<date>.txt
                      ├── postgres_dml_privileges_<hostname>_<date>.json
                      ├── postgres_roles_<hostname>_<date>.txt
                      ├── postgres_roles_<hostname>_<date>.json
                      ├── postgres_postmaster_params_<hostname>_<date>.txt
                      ├── postgres_postmaster_params_<hostname>_<date>.json
                      ├── postgres_sighup_params_<hostname>_<date>.txt
                      ├── postgres_sighup_params_<hostname>_<date>.json
                      ├── postgres_superuser_params_<hostname>_<date>.txt
                      ├── postgres_superuser_params_<hostname>_<date>.json
                      ├── postgres_user_params_<hostname>_<date>.txt
                      └── postgres_user_params_<hostname>_<date>.json
```

---

## 3. Invocation

```bash
bash engine/postgresql/cis_checks.sh [OPTIONS]

Options:
  --output-dir <path>   Directory to write all output files.
                        Defaults to the current directory if not specified.
  --help                Display the help menu and exit. No scan runs.
```

**Default behaviour:** If invoked with no arguments, the engine runs all checks and writes output to the current directory.

---

## 4. Pre-Flight

Before any checks run, the engine performs four pre-flight steps in order. A failure at any step exits the script with an informative message.

### 4.1 OS Detection

The engine detects the host package manager independently. This determines which package management commands are used in OS-level checks throughout the scan.

| Priority | Check | Command |
|---|---|---|
| 1 | apt available | `command -v apt-get` |
| 2 | dnf/rpm available | `command -v dnf` or `command -v rpm` |

- **apt found** — sets `PKG_MANAGER=apt`. All OS-level checks use `apt`-based commands.
- **dnf/rpm found** — sets `PKG_MANAGER=rpm`. All OS-level checks use `rpm`/`dnf`-based commands.
- **Neither found** — the engine exits immediately:

```
[ERROR] Could not detect a supported package manager on this host.
        Checked: apt-get, dnf, rpm

        This engine requires either apt (Debian/Ubuntu) or dnf/rpm (RHEL/Rocky).
        No checks were run. No report has been generated.
```

The OS detection result is printed to the console before any checks run:

```
[INFO] Package manager detected: apt
```

### 4.2 DB Credentials Prompt

The engine prompts the operator once for PostgreSQL connection credentials. These are used for all DB-level checks throughout the scan. If credentials are not fully provided, all DB-level checks are marked `SKIPPED` with reason `Database credentials not provided` — the scan continues with OS-level checks only.

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 PostgreSQL Connection Credentials
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  These are required for database-level checks.
  Leave blank to skip all database checks.

  Host     (default: localhost):
  Port     (default: 5432):
  Database :
  Username :
  Password :
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### 4.3 User List Input

The engine prompts the operator for the list of OS users expected to have PostgreSQL-related sudo access. Used by check 4.2.

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 User List for Sudo Validation (Check 4.2)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Enter space-separated usernames, or provide a path
  to a .txt file with one username per line.

  Leave blank to skip sudo validation.

  Input:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

- If input ends in `.txt`, the engine reads the file and loads usernames one per line.
- If input is a space-separated string, the engine splits it into individual usernames.
- If left blank, check 4.2 is marked `FAIL` with reason `No users provided — operator must verify sudoers configuration manually`. The script does not stop.

### 4.4 Maximum Log File Size

The engine prompts the operator for their desired maximum log rotation size in MB before the scan starts. Used by check 3.1.9.

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Maximum Log File Size (Check 3.1.9)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Enter the maximum log file size in MB (minimum: 10).
  Leave blank to fail this check.

  Size (MB):
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

- Values below 10 MB are rejected at the prompt and re-prompted.
- If left blank, check 3.1.9 is marked `FAIL` with reason `Operator did not provide minimum size`.

---

## 5. Log Destination Context

Several checks in Section 3 are conditional on the value of `log_destination`. The engine queries this value once at the start of Section 3 and uses it throughout the section.

`log_destination` can be a comma-separated combination of: `stderr`, `csvlog`, `syslog`, `jsonlog`.

| Condition | Applies to |
|---|---|
| `log_destination` includes `stderr` or `csvlog` | Checks 3.1.3, 3.1.4, 3.1.5, 3.1.6, 3.1.7, 3.1.8, 3.1.9 |
| `log_destination` includes `syslog` | Checks 3.1.10, 3.1.11, 3.1.12, 3.1.13 |
| Always run regardless of destination | All other Section 3 checks |

If a check's condition is not met it is marked `N/A` with a reason printed to the console and written to the Remediation column of the CSV.

---

## 6. Output Files

All output files are written to the directory specified by `--output-dir` (default: current directory).

| File | Description |
|---|---|
| `postgres_compliance_<hostname>_<date>.csv` | Main compliance report — one row per check |
| `postgres_admin_privileges_<hostname>_<date>.txt` | Roles with excessive admin privileges (Check 4.3) |
| `postgres_admin_privileges_<hostname>_<date>.json` | Same as above in JSON format |
| `postgres_dml_privileges_<hostname>_<date>.txt` | Roles with excessive DML privileges (Check 4.6) |
| `postgres_dml_privileges_<hostname>_<date>.json` | Same as above in JSON format |
| `postgres_roles_<hostname>_<date>.txt` | All users and predefined role assignments (Check 4.9) |
| `postgres_roles_<hostname>_<date>.json` | Same as above in JSON format |
| `postgres_postmaster_params_<hostname>_<date>.txt` | Postmaster runtime parameter snapshot (Check 6.3) |
| `postgres_postmaster_params_<hostname>_<date>.json` | Same as above in JSON format |
| `postgres_sighup_params_<hostname>_<date>.txt` | SIGHUP runtime parameter snapshot (Check 6.4) |
| `postgres_sighup_params_<hostname>_<date>.json` | Same as above in JSON format |
| `postgres_superuser_params_<hostname>_<date>.txt` | Superuser runtime parameter snapshot (Check 6.5) |
| `postgres_superuser_params_<hostname>_<date>.json` | Same as above in JSON format |
| `postgres_user_params_<hostname>_<date>.txt` | User runtime parameter snapshot (Check 6.6) |
| `postgres_user_params_<hostname>_<date>.json` | Same as above in JSON format |

### 6.1 CSV Schema

| Column | Description |
|---|---|
| `Standard` | The CIS control name |
| `Status` | `PASS`, `FAIL`, `SKIPPED`, `N/A`, or `MANUAL_REVIEW` |
| `Remediation` | Action to resolve a failing check. For `SKIPPED`/`N/A`, contains the reason. For `MANUAL_REVIEW`, contains the operator instruction. Empty for `PASS`. |

### 6.2 Status Definitions

| Status | Meaning |
|---|---|
| `PASS` | Check passed. |
| `FAIL` | Check failed. |
| `SKIPPED` | Could not run — typically DB credentials not provided. |
| `N/A` | Not applicable in this environment — e.g. syslog check when syslog not configured. |
| `MANUAL_REVIEW` | Cannot be fully automated. Output captured and operator instructed to review. |

---

## 7. Check Specifications

### Section 1 — Installation and Patches

---

#### 1.1 Ensure packages are obtained from authorized repositories (Manual)

**Method:**
- **apt:** Parse `/etc/apt/sources.list` and `/etc/apt/sources.list.d/`
- **rpm:** `dnf repolist all | grep -E 'enabled$'` then `dnf info $(rpm -qa | grep postgres) | grep -E '^Name|^Version|^From'`

**Authorised sources:** `apt.postgresql.org`, `yum.postgresql.org`, `download.postgresql.org`, and organisation-approved mirrors.

**Pass condition:** All configured repositories are authorised and PostgreSQL packages originate from approved sources.
**Fail condition:** Any unapproved repository is listed, or PostgreSQL packages originate from an unexpected repo.

**Status:** `MANUAL_REVIEW` — operator must confirm the repository list matches organisational policy.

---

#### 1.2 Install only required packages (Manual)

**Method:** List all installed PostgreSQL-related packages.
- **apt:** `dpkg -l $(apt-cache search postgresql --names-only | awk '{print $1}') 2>&1 | grep -v 'no packages found'`
- **rpm:** `rpm -q $(dnf search postgresql | cut -d: -f1 | cut -d. -f1) 2>&1 | grep -Ev 'package.*is not installed'`

**Status:** Always `MANUAL_REVIEW`.
**Console output:** Full package list printed to CLI.
**Remediation column:** `Review the installed packages above and remove any not required for this PostgreSQL deployment using apt purge <pkg> or dnf erase <pkg>.`

---

#### 1.3 Ensure systemd service files are enabled (Automated)

**Method:** `systemctl is-enabled postgresql-18.service`

**Pass condition:** Returns `enabled`.
**Fail condition:** Anything other than `enabled` is returned.

---

#### 1.4 Ensure data cluster initialized successfully (Automated)

**Method:** Check directory permissions and run:
```bash
sudo -u postgres /usr/pgsql-18/bin/postgresql-18-check-db-dir ~postgres/18/data
echo $?
```

**Pass condition:** Exit code is `0`.
**Fail condition:** Non-zero exit code, or the data directory does not exist or has incorrect permissions (`drwx------` owned by `postgres`).

---

#### 1.5 Ensure the latest security patches are applied (Manual)

**Method:** `SHOW server_version;` — print current version to console.

**Status:** Always `MANUAL_REVIEW`.
**Remediation column:** `Compare the version above against the latest PostgreSQL security announcements at https://www.postgresql.org/support/security/ and https://www.postgresql.org/support/versioning/ — update if behind and mark this check as PASS once verified.`

---

#### 1.6 Verify that PGPASSWORD is not set in users' profiles (Automated)

**Method:**
```bash
grep PGPASSWORD --no-messages /home/*/.{bashrc,profile,bash_profile}
grep PGPASSWORD --no-messages /root/.{bashrc,profile,bash_profile}
grep PGPASSWORD --no-messages /etc/environment
```

**Pass condition:** No matches found.
**Fail condition:** `PGPASSWORD` found in any profile file.

---

#### 1.7 Verify that the PGPASSWORD environment variable is not in use (Automated)

**Method:** `sudo grep PGPASSWORD /proc/*/environ`

**Pass condition:** No results (note: one false positive may appear for the grep process itself — this is expected and should be ignored).
**Fail condition:** `PGPASSWORD` found in any process environment.

---

### Section 2 — Directory and File Permissions

---

#### 2.1 Ensure the file permissions mask is correct (Manual)

**Method:** `sudo -u postgres bash -c 'umask' | tr -d '[:space:]'`

**Pass condition:** `0077` or `077`.
**Fail condition:** Any other value including the OS default `0022`.

---

#### 2.2 Ensure extension directory has appropriate ownership and permissions (Automated)

**Method:**
```bash
ext_dir=$(sudo /usr/pgsql-18/bin/pg_config --sharedir)/extension
sudo ls -ld $ext_dir
```

**Pass condition:** Directory is owned by `root:root` and permissions are `755` (`drwxr-xr-x`).
**Fail condition:** Any difference in ownership or permissions.

**Note:** If permissions required correction, all extensions in `$ext_dir` must be evaluated to ensure they have not been modified.

---

#### 2.3 Disable PostgreSQL command history (Automated)

**Method:**
```bash
sudo find /home -name ".psql_history" -exec ls -la {} \;
sudo find /root -name ".psql_history" -exec ls -la {} \;
```

For each file returned, check whether it is symbolically linked to `/dev/null`.

**Pass condition:** `.psql_history` does not exist or is symlinked to `/dev/null` for all users.
**Fail condition:** `.psql_history` exists as a regular file for any user.

---

#### 2.4 Ensure passwords are not stored in the service file (Manual)

**Method:**
```bash
sudo find / -name .pg_service.conf -type f -exec cat {} \; 2>/dev/null | grep password
sudo grep password /root/.pg_service.conf
grep password "${PGSERVICEFILE}"
grep password "${PGSYSCONFDIR}/pg_service.conf"
```

**Pass condition:** No `password=` entries found in any service file.
**Fail condition:** Any command above returns a `password=...` line.

---

### Section 3 — Logging and Auditing

---

#### 3.1.2 Ensure the log destinations are set correctly (Automated)

**Method:** `SHOW log_destination;`

**Pass condition:** Any valid combination of `stderr`, `csvlog`, `syslog`, `jsonlog` is configured and non-empty.
**Fail condition:** Value is empty or unrecognised.

**Note:** This check always runs first in Section 3 and its result gates all subsequent conditional checks.

**Default value:** `stderr`

---

#### 3.1.3 Ensure the logging collector is enabled (Automated)

**Condition:** Only runs if `log_destination` includes `stderr` or `csvlog`. Otherwise `N/A` — `logging_collector not applicable for configured log_destination`.

**Method:** `SHOW logging_collector;`

**Pass condition:** `on`
**Fail condition:** Any other value.

**Note:** This setting can only be changed at server restart.

**Default value:** `on`

---

#### 3.1.4 Ensure the log file destination directory is set correctly (Automated)

**Condition:** Only runs if `log_destination` includes `stderr` or `csvlog`. Otherwise `N/A`.

**Method:** `SHOW log_directory;`

**Pass condition:** Value is non-empty and set to an absolute path or a path relative to the cluster data directory.
**Fail condition:** Value is empty (which causes PostgreSQL to attempt writing to `/`).

**Default value:** `log` (relative to `$PGDATA`)

---

#### 3.1.5 Ensure the filename pattern for log files is set correctly (Automated)

**Condition:** Only runs if `log_destination` includes `stderr` or `csvlog`. Otherwise `N/A`.

**Method:** `SHOW log_filename;`

**Pass condition:** `postgresql-%Y%m%d.log`
**Fail condition:** Any other pattern.

**Remediation:** `ALTER SYSTEM SET log_filename='postgresql-%Y%m%d.log'; SELECT pg_reload_conf();`

**Default value:** `postgresql-%a.log`

---

#### 3.1.6 Ensure the log file permissions are set correctly (Automated)

**Condition:** Only runs if `log_destination` includes `stderr` or `csvlog`. Otherwise `N/A`.

**Method:** `SHOW log_file_mode;`

**Pass condition:** `0600`
**Fail condition:** Any other value.

**Default value:** `0600`

---

#### 3.1.7 Ensure log_truncate_on_rotation is enabled (Automated)

**Condition:** Only runs if `log_destination` includes `stderr` or `csvlog`. Otherwise `N/A`.

**Method:** `SHOW log_truncate_on_rotation;`

**Pass condition:** `on`
**Fail condition:** `off`

**Default value:** `on`

---

#### 3.1.8 Ensure the maximum log file lifetime is set correctly (Automated)

**Condition:** Only runs if `log_destination` includes `stderr` or `csvlog`. Otherwise `N/A`.

**Method:** `SHOW log_rotation_age;`

**Status:** `MANUAL_REVIEW` — current best practice recommends at least daily rotation but organisational logging policy governs the value.

**Remediation column:** `Review log_rotation_age above and confirm it aligns with your organisation's log retention policy. Recommended: at least 1d. To change: ALTER SYSTEM SET log_rotation_age='1d'; SELECT pg_reload_conf();`

**Default value:** `1d`

---

#### 3.1.9 Ensure the maximum log file size is set correctly (Automated)

**Condition:** Only runs if `log_destination` includes `stderr` or `csvlog`. Otherwise `N/A`.

**Method:** `SHOW log_rotation_size;` — compare against the operator-provided value from pre-flight (Section 4.4). The PostgreSQL unit is kB; the operator input in MB is converted for comparison.

**Pass condition:** Configured value matches operator-provided size.
**Fail condition:** Value is `0` (size-triggered rotation disabled) or does not match operator-provided size, or operator left input blank.

**Fail reason when blank:** `Operator did not provide minimum size.`
**Minimum accepted input:** 10 MB.

**Default value:** `0` (disabled)

---

#### 3.1.10 Ensure the correct syslog facility is selected (Manual)

**Condition:** Only runs if `log_destination` includes `syslog`. Otherwise `N/A` — `syslog not enabled`. Printed to console as the check runs.

**Method:** `SHOW syslog_facility;`

**Pass condition:** Value is one of `LOCAL0` through `LOCAL7`.
**Fail condition:** Any other value or empty.

**Default value:** `LOCAL0`

---

#### 3.1.11 Ensure syslog messages are not suppressed (Automated)

**Condition:** Only runs if `log_destination` includes `syslog`. Otherwise `N/A` — `syslog not enabled`.

**Method:** `SHOW syslog_sequence_numbers;`

**Pass condition:** `on`
**Fail condition:** `off`

**Default value:** `on`

---

#### 3.1.12 Ensure syslog messages are not lost due to size (Automated)

**Condition:** Only runs if `log_destination` includes `syslog`. Otherwise `N/A` — `syslog not enabled`.

**Method:** `SHOW syslog_split_messages;`

**Pass condition:** `on`
**Fail condition:** `off`

**Default value:** `on`

---

#### 3.1.13 Ensure the program name for PostgreSQL syslog messages is correct (Automated)

**Condition:** Only runs if `log_destination` includes `syslog`. Otherwise `N/A` — `syslog not enabled`.

**Method:** `SHOW syslog_ident;`

**Pass condition:** Value is non-empty and set to a recognisable identifier (e.g. `postgres` or a site-specific name).
**Fail condition:** Value is empty.

**Default value:** `postgres`

---

#### 3.1.14 Ensure the correct messages are written to the server log (Automated)

**Method:** `SHOW log_min_messages;`

**Pass condition:** `warning`
**Fail condition:** Any other value. Note: values more verbose than `warning` (e.g. `info`, `debug1`) are also a fail as they produce excessive output.

**Default value:** `WARNING`

---

#### 3.1.15 Ensure the correct SQL statements generating errors are recorded (Automated)

**Method:** `SHOW log_min_error_statement;`

**Pass condition:** `error`
**Fail condition:** Any other value.

**Default value:** `ERROR`

---

#### 3.1.16 Ensure debug_print_parse is disabled (Automated)

**Method:** `SHOW debug_print_parse;`

**Pass condition:** `off`
**Fail condition:** `on`

**Default value:** `off`

---

#### 3.1.17 Ensure debug_print_rewritten is disabled (Automated)

**Method:** `SHOW debug_print_rewritten;`

**Pass condition:** `off`
**Fail condition:** `on`

**Default value:** `off`

---

#### 3.1.18 Ensure debug_print_plan is disabled (Automated)

**Method:** `SHOW debug_print_plan;`

**Pass condition:** `off`
**Fail condition:** `on`

**Default value:** `off`

---

#### 3.1.19 Ensure debug_pretty_print is enabled (Automated)

**Method:** `SHOW debug_pretty_print;`

**Pass condition:** `on`
**Fail condition:** `off`

**Default value:** `on`

---

#### 3.1.20 Ensure log_connections is enabled (Automated)

**Method:** `SHOW log_connections;`

**Pass condition:** `all`

**Note:** PostgreSQL 18 introduced granular values (`receipt`, `authentication`, `authorization`, `setup_durations`, `all`). For backwards compatibility `on` is still supported and is equivalent to `all`. The expected value for this check is `all`.

**Fail condition:** Any value other than `all` (including empty string, `on`, or individual granular options).

**Default value:** empty string (disabled)

---

#### 3.1.21 Ensure log_disconnections is enabled (Automated)

**Method:** `SHOW log_disconnections;`

**Pass condition:** `on`
**Fail condition:** `off` or empty.

**Default value:** `off`

---

#### 3.1.22 Ensure log_error_verbosity is set correctly (Automated)

**Method:** `SHOW log_error_verbosity;`

**Pass condition:** `verbose`
**Fail condition:** `terse` or `default`.

**Default value:** `DEFAULT`

---

#### 3.1.23 Ensure log_hostname is set correctly (Automated)

**Method:** `SHOW log_hostname;`

**Pass condition:** `off`
**Fail condition:** `on`

**Rationale:** DNS resolution for each logged statement incurs non-negligible overhead, and IP addresses can be resolved to hostnames at review time. The benchmark recommends leaving this `off`.

**Default value:** `off`

---

#### 3.1.24 Ensure log_line_prefix is set correctly (Automated)

**Method:** `SHOW log_line_prefix;`

**Pass condition (non-syslog):** Value contains at minimum: `%m [%p]: [%l-1] db=%d,user=%u,app=%a,client=%h`
**Pass condition (syslog):** Value contains at minimum: `user=%u,db=%d,app=%a,client=%h`

**Fail condition:** Value is empty or missing required tokens for the configured destination.

**Remediation:** `ALTER SYSTEM SET log_line_prefix = '%m [%p]: [%l-1] db=%d,user=%u,app=%a,client=%h '; SELECT pg_reload_conf();`

**Default value:** `%m [%p]`

---

#### 3.1.25 Ensure log_statement is set correctly (Automated)

**Method:** `SHOW log_statement;`

**Pass condition:** `ddl`, `mod`, or `all`
**Fail condition:** `none`

**Default value:** `none`

---

#### 3.1.26 Ensure log_timezone is set correctly (Automated)

**Method:** `SHOW log_timezone;`

**Pass condition:** `GMT` or `UTC`
**Fail condition:** Any other value (e.g. `US/Eastern`, local timezone).

**Default value:** Matches the server OS timezone (set by PGDG packages).

---

#### 3.2 Ensure the PostgreSQL Audit Extension (pgAudit) is enabled (Automated)

**Method:**
```sql
SHOW shared_preload_libraries;
SHOW pgaudit.log;
```

**Pass condition:** `pgaudit` is present in `shared_preload_libraries` and `pgaudit.log` returns a valid set of auditing components.
**Fail condition:** `pgaudit` is absent from `shared_preload_libraries`, or `pgaudit.log` produces an error.

**Remediation:**
- **rpm:** `dnf -y install pgaudit_18`
- **apt:** `apt-get install -y postgresql-18-pgaudit`

Add to `postgresql.conf`: `shared_preload_libraries = 'pgaudit'` and `pgaudit.log='ddl,write'`, then restart the service.

---

### Section 4 — User Access and Authorization

---

#### 4.1 Ensure interactive login is disabled (Manual)

**Method:** `sudo grep postgres /etc/shadow | cut -d: -f1-2`

**Pass condition:** Output is `postgres:!<something>` (password field starts with `!`, indicating the account is locked).
**Fail condition:** Output does not contain `!` — the postgres OS account can log in interactively.

**Remediation:** `sudo passwd -l postgres`

---

#### 4.2 Ensure sudo is configured correctly (Manual)

**Method:** Check each user from the operator-provided user list against `/etc/sudoers` and `/etc/sudoers.d/*`.

**Console output:** For each user in the list, print whether they were found in sudoers:

```
[INFO] Checking sudoers for provided users...
       user1 — found in sudoers
       user2 — found in sudoers
       user3 — NOT found in sudoers
```

**Status:** Always `MANUAL_REVIEW`.

**Remediation column:** `Users found in sudoers: <list>. Users not found: <list>. Compare against your access matrix or organisational equivalent to validate authorisation. To add a user: echo '%dba ALL=(postgres) PASSWD: ALL' > /etc/sudoers.d/postgres && chmod 600 /etc/sudoers.d/postgres`

**If no users provided at pre-flight:** `FAIL` — `No users provided. Operator must verify sudoers configuration manually.` Script continues.

---

#### 4.3 Ensure excessive administrative privileges are revoked (Manual)

**Method:**
```bash
psql -c "\du+ *"
psql -c "select * from pg_user order by usename"
```

**Pass condition:** No non-superuser roles have `Superuser`, `Create role`, `Create DB`, `Replication`, or `Bypass RLS` attributes.
**Fail condition:** Any regular/application user has one or more of these attributes.

**Supplementary output:** Results written to:
- `postgres_admin_privileges_<hostname>_<date>.txt`
- `postgres_admin_privileges_<hostname>_<date>.json`

**Status:** `MANUAL_REVIEW`

**Remediation column:** `Review roles with elevated privileges in postgres_admin_privileges_<hostname>_<date>.txt. Compare against your access matrix or organisational equivalent. Revoke as needed: ALTER ROLE <name> NOSUPERUSER NOCREATEROLE NOCREATEDB NOREPLICATION NOBYPASSRLS NOINHERIT;`

---

#### 4.4 Lock out accounts if not currently in use (Manual)

**Method:**
```sql
SELECT rolname FROM pg_catalog.pg_roles
WHERE rolname !~ '^pg_' AND rolcanlogin;
```

**Status:** `MANUAL_REVIEW`.

**Remediation column:** `Review the login-capable accounts listed above. Disable inactive accounts with ALTER ROLE <account> NOLOGIN; Re-enable with ALTER ROLE <account> LOGIN;`

---

#### 4.5 Ensure excessive function privileges are revoked (Automated)

**Method:**
```sql
SELECT nspname, proname, proargtypes, prosecdef, rolname, proconfig
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
JOIN pg_authid a ON a.oid = p.proowner
WHERE proname NOT LIKE 'pgaudit%'
  AND (prosecdef OR NOT proconfig IS NULL);
```

**Pass condition:** No rows returned with `prosecdef = t`.
**Fail condition:** One or more `SECURITY DEFINER` functions detected.

**Remediation:** `ALTER FUNCTION <functionname> SECURITY INVOKER;` — or, if SECURITY DEFINER is required, restrict execute access: `REVOKE EXECUTE ON FUNCTION <name> FROM <role>;`

---

#### 4.6 Ensure excessive DML privileges are revoked (Manual)

**Method:**
```sql
SELECT t.schemaname, t.tablename, u.usename,
  has_table_privilege(u.usename, t.tablename, 'select') AS select,
  has_table_privilege(u.usename, t.tablename, 'insert') AS insert,
  has_table_privilege(u.usename, t.tablename, 'update') AS update,
  has_table_privilege(u.usename, t.tablename, 'delete') AS delete
FROM pg_tables t, pg_user u
WHERE t.schemaname NOT IN ('information_schema','pg_catalog');
```

**Status:** Always `MANUAL_REVIEW`.

**Supplementary output:** Results written to:
- `postgres_dml_privileges_<hostname>_<date>.txt`
- `postgres_dml_privileges_<hostname>_<date>.json`

**Remediation column:** `Review DML privilege assignments in postgres_dml_privileges_<hostname>_<date>.txt and compare against your access matrix or organisational equivalent. Revoke unauthorised grants: REVOKE INSERT, UPDATE, DELETE ON TABLE <table> FROM <role>;`

---

#### 4.7 Ensure Row Level Security (RLS) is configured correctly (Manual)

**Method:**
```sql
SELECT oid, relname, relrowsecurity FROM pg_class WHERE relrowsecurity IS TRUE;
```
Also check: `SELECT relname FROM pg_class WHERE relname = '<table>';` — `relrowsecurity = f` on a table that should be protected is a fail.

**Status:** `MANUAL_REVIEW`.

**Remediation column:** `Determine which tables require RLS per your organisation's data access policy. Enable with: ALTER TABLE <name> ENABLE ROW LEVEL SECURITY; Ensure no unauthorised users have BYPASSRLS: ALTER ROLE <user> NOBYPASSRLS;`

---

#### 4.8 Ensure the set_user extension is installed (Automated)

**Pre-condition:** Before the check runs, the engine verifies whether the `roletree` view exists:

```sql
SELECT 1 FROM pg_views WHERE viewname = 'roletree';
```

- **View exists** — proceed directly to the check.
- **View does not exist** — create it using the CIS-prescribed SQL before running the check.

**CIS-prescribed roletree view SQL:**

```sql
DROP VIEW IF EXISTS roletree;
CREATE OR REPLACE VIEW roletree AS
WITH RECURSIVE
roltree AS (
  SELECT u.rolname AS rolname,
         u.oid AS roloid,
         u.rolcanlogin,
         u.rolsuper,
         '{}'::name[] AS rolparents,
         NULL::oid AS parent_roloid,
         NULL::name AS parent_rolname
  FROM pg_catalog.pg_authid u
  LEFT JOIN pg_catalog.pg_auth_members m on u.oid = m.member
  LEFT JOIN pg_catalog.pg_authid g on m.roleid = g.oid
  WHERE g.oid IS NULL
  UNION ALL
  SELECT u.rolname AS rolname,
         u.oid AS roloid,
         u.rolcanlogin,
         u.rolsuper,
         t.rolparents || g.rolname AS rolparents,
         g.oid AS parent_roloid,
         g.rolname AS parent_rolname
  FROM pg_catalog.pg_authid u
  JOIN pg_catalog.pg_auth_members m on u.oid = m.member
  JOIN pg_catalog.pg_authid g on m.roleid = g.oid
  JOIN roltree t on t.roloid = g.oid
)
SELECT r.rolname, r.roloid, r.rolcanlogin, r.rolsuper, r.rolparents
FROM roltree r
ORDER BY 1;
```

**Method (after view confirmed):**
```sql
-- Check set_user extension is available
SELECT * FROM pg_available_extensions WHERE name = 'set_user';

-- Check for superuser roles that can still login directly
SELECT rolname FROM pg_authid WHERE rolsuper AND rolcanlogin;

-- Check for unprivileged roles with superuser access via role inheritance
SELECT ro.rolname, ro.roloid, ro.rolcanlogin, ro.rolsuper, ro.rolparents
FROM roletree ro
WHERE (ro.rolcanlogin AND ro.rolsuper)
   OR (ro.rolcanlogin AND EXISTS (
     SELECT TRUE FROM roletree ri
     WHERE ri.rolname = ANY (ro.rolparents) AND ri.rolsuper
   ));
```

**Pass condition:** `set_user` is listed in `pg_available_extensions` with an `installed_version`, and no unprivileged roles can login with superuser access (only `postgres` superuser with `NOLOGIN` is expected).
**Fail condition:** `set_user` not installed, or unprivileged roles with superuser inheritance found.

**Console output:** Prints whether the `roletree` view was already present or was created.

**Teardown:** After the check completes, the engine drops the `roletree` view regardless of whether it was pre-existing or created by the engine. This keeps the scan self-cleaning and leaves the database in the same state it was in before the scan ran.

```sql
DROP VIEW IF EXISTS roletree;
```

The teardown is also wired into the SIGINT/SIGTERM trap — if the scan is interrupted during or after check 4.8, the view is dropped before the engine exits.

---

#### 4.9 Make use of predefined roles (Manual)

**Method:**
```sql
SELECT rolname FROM pg_roles WHERE rolsuper IS TRUE;
```

Review against PostgreSQL 18 predefined roles: `pg_read_all_data`, `pg_write_all_data`, `pg_read_all_settings`, `pg_read_all_stats`, `pg_stat_scan_tables`, `pg_maintain`, `pg_monitor`, `pg_database_owner`, `pg_signal_backend`, `pg_read_server_files`, `pg_write_server_files`, `pg_execute_server_program`, `pg_checkpoint`, `pg_use_reserved_connections`, `pg_create_subscription`, `pg_signal_autovacuum_worker`.

**Status:** Always `MANUAL_REVIEW`.

**Supplementary output:** Results written to:
- `postgres_roles_<hostname>_<date>.txt`
- `postgres_roles_<hostname>_<date>.json`

**Remediation column:** `Review superuser roles above in postgres_roles_<hostname>_<date>.txt. Where a predefined role would suffice, grant it and remove superuser: GRANT pg_monitor TO <role>; ALTER ROLE <role> NOSUPERUSER; Compare against your access matrix or organisational equivalent.`

---

#### 4.10 Ensure all accounts that can log in have passwords (Manual)

**Method:**
```sql
SELECT rolname FROM pg_authid WHERE rolpassword IS NULL AND rolcanlogin;
```

**Pass condition:** No rows returned (all login-capable accounts have a password set).
**Fail condition:** One or more login-capable accounts have no password.

**Note:** Accounts using SSL certificate-based authentication may legitimately have no password, but it is still good practice to set one.

**Remediation:** `\password <username>` — or use `ALTER ROLE` (note: passwords set via ALTER ROLE are emitted to the PostgreSQL logs, so `\password` is preferred).

---

### Section 5 — Connection and Login

---

#### 5.1 Do not specify passwords in the command line (Manual)

**Method:**
```bash
sudo ps -few                  # Check process list
history                       # Check shell history
grep -r "postgresql://" /home/*/.bash_history /root/.bash_history 2>/dev/null
grep -rE "(--password|-W|PGPASSWORD=)" /home/*/.bash_history /home/*/.psql_history /root/.bash_history /root/.psql_history 2>/dev/null
```

**Pass condition:** No passwords visible in process list or shell/psql history. No connection URIs with embedded passwords. No `--password`/`-W`/`PGPASSWORD=` entries in history files.
**Fail condition:** Any of the above found.

---

#### 5.2 Ensure PostgreSQL is bound to an IP address (Manual)

**Method:** `SHOW listen_addresses;`

**Pass condition:** Value is a specific IP address or comma-separated list of specific addresses.
**Fail condition:** Value is `*` or `0.0.0.0`.

**Note:** The default `localhost` is acceptable. Docker images may set this to `*` — this must be corrected.

---

#### 5.3 Ensure login via local UNIX domain socket is configured correctly (Manual)

**Method:** Inspect `pg_hba.conf` for `local` entries.

**Pass condition:** `local` entries use `peer` authentication. Non-postgres UNIX users are denied login as the postgres superuser.
**Fail condition:** `local` entries use `trust` or any method that does not enforce peer identity.

**Status:** `MANUAL_REVIEW` — the operator must verify the pg_hba.conf `local` rules align with organisational policy.

---

#### 5.4 Ensure login via host TCP/IP socket is configured correctly (Manual)

**Method:** Inspect `pg_hba.conf` for `host` entries.

**Pass condition:** All remote `host` entries use `scram-sha-256` or `cert`. Use of `hostssl` with `scram-sha-256` is the recommended configuration.
**Fail condition:** Any `host` entry uses one of the following — each is a fail for a distinct reason:

| Method | Reason |
|---|---|
| `trust` | No authentication required — anyone can connect |
| `password` | Password sent in cleartext |
| `ident` | Relies on OS ident service — not appropriate for remote production connections |
| `md5` | Cryptographically weak — vulnerable to packet replay attacks; superseded by `scram-sha-256` |

**Note:** PostgreSQL 18 introduced `md5_password_warnings = on` by default, which warns when MD5 passwords are set. Treat any md5 entry as a fail regardless.

---

#### 5.5 Ensure per-account connection limits are used (Automated)

**Method:**
```sql
SELECT rolname, rolconnlimit FROM pg_roles WHERE rolname NOT LIKE 'pg_%';
```

**Pass condition:** No login roles have a connection limit of `-1` (unlimited).
**Fail condition:** Any user with `rolconnlimit = -1`.

**Default value:** `-1` (unlimited)

---

#### 5.6 Ensure password complexity is configured (Manual)

**Method:**
```sql
SHOW shared_preload_libraries;
SHOW dynamic_library_path;
```

**Pass condition:** `$libdir/passwordcheck` is present in `shared_preload_libraries` (given `$libdir` is in `dynamic_library_path`).
**Fail condition:** `passwordcheck` is not loaded.

**Remediation:** Add `$libdir/passwordcheck` to `shared_preload_libraries` in `postgresql.conf` and restart the service.

**Note:** The CIS benchmark notes that passwordcheck's built-in functionality is of limited value. Refer to the PostgreSQL documentation's caution notice. Consider additional password policy tooling.

---

### Section 6 — PostgreSQL Settings

---

#### 6.1 Understanding attack vectors and runtime parameters (Manual)

**Status:** Always `MANUAL_REVIEW`.

**Remediation column:** `Review all PostgreSQL configuration settings and configure logging to record all modifications. Understand the four attack vectors: via user session, via attribute, via server reload (SIGHUP), and via server restart. Refer to https://www.postgresql.org/docs/current/static/runtime-config.html`

---

#### 6.2 Ensure backend runtime parameters are configured correctly (Automated)

**Method:**
```sql
SELECT name, setting FROM pg_settings
WHERE context IN ('backend','superuser-backend')
ORDER BY 1;
```

**Expected values (PostgreSQL 18):**

| Parameter | Expected value |
|---|---|
| `ignore_system_indexes` | `off` |
| `jit_debugging_support` | `off` |
| `jit_profiling_support` | `off` |
| `log_connections` | `all` |
| `log_disconnections` | `on` |
| `post_auth_delay` | `0` |

**Pass condition:** All six parameters match expected values.
**Fail condition:** Any parameter deviates from the expected value.

**Note:** Changes to these parameters can only be made at server start. A successful exploit may not be detected until after a server restart.

---

#### 6.3 Ensure Postmaster runtime parameters are configured (Manual)

**Method:**
```sql
SELECT name, setting FROM pg_settings WHERE context = 'postmaster' ORDER BY 1;
```

**Status:** `MANUAL_REVIEW` — output is printed to console and written to supplementary files for baseline comparison.

**Supplementary output:**
- `postgres_postmaster_params_<hostname>_<date>.txt`
- `postgres_postmaster_params_<hostname>_<date>.json`

**Remediation column:** `Compare the postmaster parameter output in postgres_postmaster_params_<hostname>_<date>.txt against a previously archived baseline. Investigate and restore any unexpected changes. Changes require a server restart to take effect.`

---

#### 6.4 Ensure SIGHUP runtime parameters are configured (Manual)

**Method:**
```sql
SELECT name, setting FROM pg_settings WHERE context = 'sighup' ORDER BY 1;
```

**Status:** `MANUAL_REVIEW` — output is printed to console and written to supplementary files for baseline comparison.

**Supplementary output:**
- `postgres_sighup_params_<hostname>_<date>.txt`
- `postgres_sighup_params_<hostname>_<date>.json`

**Remediation column:** `Compare the SIGHUP parameter output in postgres_sighup_params_<hostname>_<date>.txt against a previously archived baseline. Restore any unexpected changes by editing postgresql.conf and running SELECT pg_reload_conf();`

---

#### 6.5 Ensure Superuser runtime parameters are configured (Manual)

**Method:**
```sql
SELECT name, setting FROM pg_settings WHERE context = 'superuser' ORDER BY 1;
```

**Status:** `MANUAL_REVIEW` — output is printed to console and written to supplementary files for baseline comparison.

**Supplementary output:**
- `postgres_superuser_params_<hostname>_<date>.txt`
- `postgres_superuser_params_<hostname>_<date>.json`

**Remediation column:** `Compare the superuser parameter output in postgres_superuser_params_<hostname>_<date>.txt against a previously archived baseline. Restore any unexpected changes. Changes require a server restart.`

---

#### 6.6 Ensure User runtime parameters are configured (Manual)

**Method:**
```sql
SELECT name, setting FROM pg_settings WHERE context = 'user' ORDER BY 1;
```

**Status:** `MANUAL_REVIEW` — output is printed to console and written to supplementary files for baseline comparison.

**Supplementary output:**
- `postgres_user_params_<hostname>_<date>.txt`
- `postgres_user_params_<hostname>_<date>.json`

**Remediation column:** `Compare the user parameter output in postgres_user_params_<hostname>_<date>.txt against a previously archived baseline. Revert any unauthorised changes. For attributes set on database entities, revert manually to default values.`

---

#### 6.7 Ensure FIPS 140-2 OpenSSL cryptography is used (Automated)

**Condition:** This check is only meaningful on RHEL, CentOS, or Rocky Linux. On other OS types (including Ubuntu/Debian), FIPS cannot be enabled natively and the check is marked `N/A` with reason `FIPS 140-2 native support is not available on this OS. Custom builds of OpenSSL may be used as an alternative.`

**Method (rpm-based only):**
```bash
fips-mode-setup --check
openssl version
```

**Pass condition:** `fips-mode-setup --check` returns `FIPS mode is enabled` and `openssl version` includes `fips`.
**Fail condition:** FIPS mode is not enabled or OpenSSL is not FIPS-capable.

---

#### 6.8 Ensure TLS is enabled and configured correctly (Automated)

**Method:**
```sql
SHOW ssl;
SELECT name, setting FROM pg_settings WHERE name = 'ssl';
```

**Pass condition:** `ssl` is `on`, `ssl_cert_file` is configured, `ssl_key_file` is configured, and `ssl_min_protocol_version` is `TLSv1.2` or `TLSv1.3`.
**Fail condition:** `ssl` is `off` or any of the above conditions are not met.

---

#### 6.9 Ensure the TLSv1.0 and TLSv1.1 protocols are disabled (Automated)

**Method:** `SHOW ssl_min_protocol_version;`

**Pass condition:** `TLSv1.2` or `TLSv1.3` (preferred).
**Fail condition:** `TLSv1.0`, `TLSv1.1`, or empty.

**Remediation:** `ALTER SYSTEM SET ssl_min_protocol_version = 'TLSv1.3'; SELECT pg_reload_conf();`

---

#### 6.10 Ensure weak SSL/TLS ciphers are disabled (Automated)

**Method:**
```sql
SHOW ssl_ciphers;
SHOW ssl_tls13_ciphers;
SELECT * FROM pg_stat_ssl WHERE cipher NOT IN
  ('TLS_AES_256_GCM_SHA384','TLS_AES_128_GCM_SHA256','TLS_AES_128_CCM_SHA256');
```

**Pass condition:** `ssl_ciphers` and `ssl_tls13_ciphers` contain only strong cipher suites. No existing connections use weak ciphers.
**Fail condition:** Any weak cipher present, or existing connections using ciphers outside the approved list.

**Note:** `ssl_tls13_ciphers` is new in PostgreSQL 18. If left empty, PostgreSQL falls back to the OpenSSL default list for TLS 1.3.

**Remediation:**
```sql
ALTER SYSTEM SET ssl_ciphers = 'TLS_AES_256_GCM_SHA384,TLS_AES_128_GCM_SHA256,TLS_AES_128_CCM_SHA256';
ALTER SYSTEM SET ssl_tls13_ciphers = 'TLS_AES_256_GCM_SHA384,TLS_AES_128_GCM_SHA256,TLS_AES_128_CCM_SHA256';
SELECT pg_reload_conf();
```

---

#### 6.11 Ensure the pgcrypto extension is installed and configured correctly (Manual)

**Method:**
```sql
SELECT * FROM pg_available_extensions WHERE name='pgcrypto';
```

**Pass condition:** `pgcrypto` appears in results with a non-null `installed_version`.
**Fail condition:** `pgcrypto` is not installed, or data requiring at-rest encryption is present but pgcrypto is unavailable.

**Status:** `MANUAL_REVIEW` — the operator must confirm whether data at rest requires encryption and whether disk/filesystem encryption is also in use.

**Remediation:** `CREATE EXTENSION pgcrypto;`

---

### Section 7 — Replication

#### Replication Detection Gate

Before any Section 7 check runs, the engine checks whether replication is actively configured on this host:

```sql
SELECT name, setting FROM pg_settings
WHERE name IN ('archive_mode', 'max_wal_senders', 'wal_level')
ORDER BY 1;
```

- **Replication detected** — `archive_mode` is `on`, OR `max_wal_senders` is greater than `0`, OR `wal_level` is `replica` or `logical`. The scan proceeds with all Section 7 checks.
- **Replication not detected** — all Section 7 checks are skipped. The engine prints the following to the console and records each check as `SKIPPED` in the CSV:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 SECTION 7 — Replication
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[INFO] Replication is not configured on this host.
       Section 7 checks will be skipped.

       The following checks were not evaluated:
         7.1  Ensure a replication-only user is created and used for streaming replication
         7.2  Ensure logging of replication commands is configured
         7.3  Ensure base backups are configured and functional
         7.4  Ensure WAL archiving is configured and functional
         7.5  Ensure streaming replication parameters are configured correctly

       If replication is required for this deployment, configure it
       and re-run the scan to evaluate these checks.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

**Remediation column for all skipped Section 7 checks:** `Replication not detected on this host. If replication is required, configure it and re-run the scan.`

---

#### 7.1 Ensure a replication-only user is created and used for streaming replication (Manual)

**Method:**
```sql
SELECT rolname FROM pg_roles WHERE rolreplication IS TRUE;
```

**Pass condition:** At least one non-superuser replication role exists (i.e. a dedicated `replication_user` role in addition to `postgres`).
**Fail condition:** Only `postgres` has replication privilege — no dedicated replication user exists.

**Remediation:**
```sql
CREATE USER replication_user REPLICATION ENCRYPTED PASSWORD 'XXX';
```
Then add to `pg_hba.conf`: `hostssl replication replication_user 0.0.0.0/0 scram-sha-256`

---

#### 7.2 Ensure logging of replication commands is configured (Manual)

**Method:** `SHOW log_replication_commands;`

**Pass condition:** `on`
**Fail condition:** `off`

**Remediation:** `ALTER SYSTEM SET log_replication_commands = 'on'; SELECT pg_reload_conf();`

---

#### 7.3 Ensure base backups are configured and functional (Manual)

**Method:** Manual operator verification — confirm backups exist and are updated on a regular basis.

**Status:** `MANUAL_REVIEW`.

**Remediation column:** `Manually confirm that base backups exist and are updated regularly. Use pg_basebackup or pgBackRest (see check 8.2). Backups should be stored on a separate file system. Test restoration periodically.`

---

#### 7.4 Ensure WAL archiving is configured and functional (Automated)

**Method:**
```sql
SELECT name, setting FROM pg_settings
WHERE name IN ('archive_mode','archive_command','archive_library')
  AND setting IS NOT NULL
  AND setting <> 'off'
  AND setting <> '(disabled)'
  AND setting <> '';
```

Also verify activity: `SELECT * FROM pg_stat_archiver;`

**Pass condition:** `archive_mode` is `on` AND either `archive_command` or `archive_library` is non-empty. `pg_stat_archiver` shows `archived_count` increasing and `failed_count` not increasing.
**Fail condition:** No rows returned from the settings query, or `archive_mode` is `off`, or archiving failures detected.

---

#### 7.5 Ensure streaming replication parameters are configured correctly (Manual)

**Method:**
- Confirm a dedicated non-superuser replication role exists (check 7.1).
- On the STANDBY host: `psql 'host=<primary> dbname=postgres user=replication_user password=<pwd> sslmode=require' -c 'select 1;'`
- Confirm `$PGDATA/standby.signal` is present on the STANDBY.
- Confirm `$PGDATA/postgresql.auto.conf` contains `primary_conninfo` with `sslmode=require`.

**Status:** `MANUAL_REVIEW`.

**Remediation column:** `Verify streaming replication uses SSL. Confirm primary_conninfo in postgresql.auto.conf on the standby includes sslmode=require and references the dedicated replication user.`

---

### Section 8 — Special Configuration Considerations

---

#### 8.1 Ensure PostgreSQL subdirectory locations are outside the data cluster (Manual)

**Method:**
```sql
SELECT name, setting FROM pg_settings
WHERE (name ~ '_directory$' OR name ~ '_tablespace');
```

**Pass condition:** `log_directory` is set to an absolute path outside `data_directory`. `temp_tablespaces` is defined, OR `temp_file_limit` is set to a non-default value.
**Fail condition:** Any of the listed directories fall inside `data_directory`, or `temp_tablespaces` is undefined and `temp_file_limit` has not been set.

**Status:** `MANUAL_REVIEW`.

**Remediation column:** `Relocate listed directories outside the data cluster per your organisational security policy. Ensure sufficient partition size. To relocate temp_tablespaces: CREATE TABLESPACE temp_tablespc LOCATION '/path/to/mount'; ALTER SYSTEM SET temp_tablespaces = 'temp_tablespc'; SELECT pg_reload_conf();`

---

#### 8.2 Ensure the backup and restore tool pgBackRest is installed and configured (Automated)

**Method:** `command -v pgbackrest && pgbackrest --version`

**Pass condition:** pgBackRest is installed and `pgbackrest info` returns a valid stanza configuration.
**Fail condition:** pgBackRest not installed or not configured.

**Remediation:**
- **rpm:** `dnf -y install pgbackrest`
- **apt:** `apt-get install -y pgbackrest`

Then configure stanza name, backup location, retention policy, and logging per the pgBackRest configuration guide.

---

#### 8.3 Ensure miscellaneous configuration settings are correct (Manual)

**Method:**
```sql
SELECT name, setting FROM pg_settings WHERE name IN (
  'external_pid_file', 'unix_socket_directories', 'shared_preload_libraries',
  'dynamic_library_path', 'local_preload_libraries', 'session_preload_libraries'
);
```

**Expected:** `shared_preload_libraries` should include `pgaudit`, `set_user`, and `$libdir/passwordcheck`. `unix_socket_directories` should be restricted (not world-writable). `local_preload_libraries` and `session_preload_libraries` should be empty unless explicitly required.

**Status:** `MANUAL_REVIEW` — print full output to console.

**Remediation column:** `Inspect file and directory permissions for all returned values. Only superusers should have access. Ensure shared_preload_libraries includes pgaudit, set_user, and $libdir/passwordcheck. Restart the cluster after any changes.`

---

## 8. Console Output

### 8.1 Scan Header

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Adhiambo — PostgreSQL CIS Benchmark Engine
 Benchmark : CIS PostgreSQL 18 Benchmark v1.0.0
 Host      : prod-db-01
 Date      : 2026-04-10
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### 8.2 Section Headers

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 SECTION 1 — Installation and Patches
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### 8.3 Per-Check Output

```
[PASS]           1.3   Ensure systemd service files are enabled
[MANUAL_REVIEW]  1.2   Install only required packages
[FAIL]           2.1   Ensure the file permissions mask is correct
[N/A]            3.1.3 Ensure the logging collector is enabled — syslog not enabled
[SKIPPED]        3.1.4 Ensure log file destination directory is set — database credentials not provided
```

### 8.4 Scan Summary Block

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 SCAN SUMMARY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  PASS             28
  FAIL             10
  MANUAL_REVIEW    12
  SKIPPED           3
  N/A               4
  ──────────────────
  TOTAL            57

  Output files:
    postgres_compliance_prod-db-01_2026-04-10.csv
    postgres_admin_privileges_prod-db-01_2026-04-10.txt
    postgres_admin_privileges_prod-db-01_2026-04-10.json
    postgres_dml_privileges_prod-db-01_2026-04-10.txt
    postgres_dml_privileges_prod-db-01_2026-04-10.json
    postgres_roles_prod-db-01_2026-04-10.txt
    postgres_roles_prod-db-01_2026-04-10.json
    postgres_postmaster_params_prod-db-01_2026-04-10.txt
    postgres_postmaster_params_prod-db-01_2026-04-10.json
    postgres_sighup_params_prod-db-01_2026-04-10.txt
    postgres_sighup_params_prod-db-01_2026-04-10.json
    postgres_superuser_params_prod-db-01_2026-04-10.txt
    postgres_superuser_params_prod-db-01_2026-04-10.json
    postgres_user_params_prod-db-01_2026-04-10.txt
    postgres_user_params_prod-db-01_2026-04-10.json

  Output directory: /opt/adhiambo/output
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## 9. Assumptions and Constraints

- The engine runs on the target Linux host with `bash` available.
- The engine exits at pre-flight if neither `apt` nor `rpm`/`dnf` is detected.
- `sudo` or root access is required for OS-level checks (shadow file, sudoers, process list, file permissions).
- If DB credentials are not provided, all DB-level checks are marked `SKIPPED` and the scan continues with OS-level checks only.
- If the user list is not provided at pre-flight, check 4.2 is marked `FAIL` but the script continues.
- If the log size is not provided at pre-flight, check 3.1.9 is marked `FAIL` but the script continues.
- The minimum accepted log size input is 10 MB.
- `log_destination` is queried once at the start of Section 3 and its value gates all conditional checks in that section.
- Check 6.7 (FIPS) is only executed on rpm-based systems (RHEL, CentOS, Rocky Linux). On apt-based systems it is marked `N/A`.
- Supplementary output files (TXT and JSON) are written to the same directory as the CSV.
- The engine does not modify any PostgreSQL configuration. All checks are read-only, with the exception of the `roletree` view created and immediately torn down in check 4.8.
- Section 7 checks are gated on replication being actively configured. If replication is not detected, all Section 7 checks are marked `SKIPPED` and the operator is informed via console output listing the skipped checks.
- The `roletree` view created in check 4.8 is always dropped after the check completes. The engine is self-cleaning — it leaves the database in the same state it was in before the scan. The teardown is also wired into the SIGINT/SIGTERM trap.
- Sections 6.3, 6.4, 6.5, and 6.6 produce supplementary TXT and JSON output files in addition to console output, enabling operators to diff parameter snapshots across scan runs.
- Checks 7.3 and 7.5 require standby host access to fully verify. These are marked `MANUAL_REVIEW` with instructions rather than `SKIPPED`, since the primary host checks (backup existence, pg_hba.conf entries) can still be assessed from the primary.

---

## 10. Corrections from Previous Design Document Version

The following corrections were made after reading the actual CIS PostgreSQL 18 Benchmark v1.0.0:

| Check | Previous specification | Corrected specification |
|---|---|---|
| 3.1.20 log_connections | Pass if `on` | Pass if `all` (PostgreSQL 18 changed the expected value) |
| 3.1.22 log_error_verbosity | Pass if `default` or `verbose` | Pass if `verbose` only |
| 3.1.23 log_hostname | Pass if `on` | Pass if `off` (benchmark recommends disabling for performance) |
| 3.1.26 log_timezone | Pass if `UTC` only; fail if `GMT` | Pass if `UTC` or `GMT` (both are acceptable per benchmark) |
| 4.1 Interactive login | Check shell in `/etc/passwd` | Check `/etc/shadow` for locked password (`!`) |
| 4.10 | Public schema protection | Ensure all accounts that can log in have passwords |
| 6.2 backend params | 5 parameters checked | 6 parameters checked (added `post_auth_delay`); `log_connections` expected as `all` not `on` |
| 6.10 Weak ciphers | Check `ssl_ciphers` only | Check both `ssl_ciphers` AND `ssl_tls13_ciphers` (new in PostgreSQL 18) |
| Section 2 | 8 checks (2.1–2.8) | 4 checks (2.1–2.4) — benchmark does not include the additional permission checks I had designed |
| 4.8 roletree SQL | Referenced but not specified | Full CIS-prescribed SQL now embedded in this document |

---

## 11. Open Items

| # | Item | Status |
|---|---|---|
| 1 | Define the handover interface contract between the current CSV reporting and the future `reporter.sh` component. | Open — pending Reporter design |

---

*This document is a living design spec. Updates should be made in the issues tab and reflected here before implementation begins.*