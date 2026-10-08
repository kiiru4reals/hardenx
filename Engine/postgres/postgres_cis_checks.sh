#!/usr/bin/env bash
# =============================================================================
# HardenX — PostgreSQL CIS Benchmark Engine
# Component  : engine/postgresql/cis_checks.sh
# Benchmark  : CIS PostgreSQL 18 Benchmark v1.0.0 (03-27-2026)
# Version    : 1.0.0
# =============================================================================

set -uo pipefail

# =============================================================================
# GLOBALS
# =============================================================================
HOSTNAME=$(hostname)
DATE=$(date +%F)
OUTPUT_DIR="."
PKG_MANAGER=""

# DB credentials
PG_HOST="localhost"
PG_PORT="5432"
PG_DB=""
PG_USER=""
PG_PASSWORD=""
SKIP_DB_CHECKS=1

# User list for sudo check (4.2)
USER_LIST=()
USER_LIST_PROVIDED=0

# Log size in MB for check 3.1.9
LOG_SIZE_MB=""

# Log destination — queried once at start of Section 3, gates conditional checks
LOG_DESTINATION=""

# Replication flag — set during Section 7 pre-gate
REPLICATION_ENABLED=0

# roletree teardown flag — set when view is created in check 4.8
ROLETREE_CREATED=0

# Server access flag — 1 if running on the target PostgreSQL server (OS commands
# available), 0 if running remotely (DB checks only via psql).
# Set during pre-flight by prompt_server_access().
SERVER_ACCESS=1

# Output file paths — initialised after OUTPUT_DIR is known
CSV_FILE=""
ADMIN_PRIV_TXT="" ADMIN_PRIV_JSON=""
DML_PRIV_TXT=""   DML_PRIV_JSON=""
ROLES_TXT=""      ROLES_JSON=""
POSTMASTER_TXT="" POSTMASTER_JSON=""
SIGHUP_TXT=""     SIGHUP_JSON=""
SUPERUSER_TXT=""  SUPERUSER_JSON=""
USER_PARAMS_TXT="" USER_PARAMS_JSON=""

# =============================================================================
# TEARDOWN — fires on EXIT, SIGINT, SIGTERM
# Drops the roletree view if HardenX created it, leaving the DB self-clean.
# =============================================================================
teardown() {
    if [[ "${ROLETREE_CREATED:-0}" -eq 1 && "${SKIP_DB_CHECKS:-1}" -eq 0 ]]; then
        echo ""
        echo "[TEARDOWN] Dropping roletree view..."
        export PGPASSWORD="$PG_PASSWORD"
        psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
            -c "DROP VIEW IF EXISTS roletree;" > /dev/null 2>&1 || true
        unset PGPASSWORD
        ROLETREE_CREATED=0
        echo "[TEARDOWN] roletree view dropped. Engine is self-clean."
    fi
}
trap teardown EXIT SIGINT SIGTERM

# =============================================================================
# ARGUMENT PARSING
# =============================================================================
usage() {
cat << 'USAGE_EOF'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 HardenX — PostgreSQL CIS Benchmark Engine
 Benchmark : CIS PostgreSQL 18 Benchmark v1.0.0
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

USAGE
  bash engine/postgresql/cis_checks.sh [OPTIONS]

OPTIONS
  --output-dir <path>
      Directory to write all output files.
      Defaults to the current directory if not specified.

  --help
      Display this help menu and exit.

DEFAULTS
  If invoked with no arguments:
    --output-dir .

EXAMPLES
  Run with default output directory:
    bash engine/postgresql/cis_checks.sh

  Run with specific output directory:
    bash engine/postgresql/cis_checks.sh --output-dir /opt/hardenx/output

NOTES
  - sudo or root access is required for OS-level checks.
  - Output: postgres_compliance_<hostname>_<date>.csv plus supplementary files.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
USAGE_EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "[ERROR] Unknown argument: $1"
            echo "        Use --help for usage information."
            exit 1
            ;;
    esac
done

# =============================================================================
# OUTPUT FILE INITIALISATION
# =============================================================================
init_output_files() {
    CSV_FILE="${OUTPUT_DIR}/postgres_compliance_${HOSTNAME}_${DATE}.csv"
    ADMIN_PRIV_TXT="${OUTPUT_DIR}/postgres_admin_privileges_${HOSTNAME}_${DATE}.txt"
    ADMIN_PRIV_JSON="${OUTPUT_DIR}/postgres_admin_privileges_${HOSTNAME}_${DATE}.json"
    DML_PRIV_TXT="${OUTPUT_DIR}/postgres_dml_privileges_${HOSTNAME}_${DATE}.txt"
    DML_PRIV_JSON="${OUTPUT_DIR}/postgres_dml_privileges_${HOSTNAME}_${DATE}.json"
    ROLES_TXT="${OUTPUT_DIR}/postgres_roles_${HOSTNAME}_${DATE}.txt"
    ROLES_JSON="${OUTPUT_DIR}/postgres_roles_${HOSTNAME}_${DATE}.json"
    POSTMASTER_TXT="${OUTPUT_DIR}/postgres_postmaster_params_${HOSTNAME}_${DATE}.txt"
    POSTMASTER_JSON="${OUTPUT_DIR}/postgres_postmaster_params_${HOSTNAME}_${DATE}.json"
    SIGHUP_TXT="${OUTPUT_DIR}/postgres_sighup_params_${HOSTNAME}_${DATE}.txt"
    SIGHUP_JSON="${OUTPUT_DIR}/postgres_sighup_params_${HOSTNAME}_${DATE}.json"
    SUPERUSER_TXT="${OUTPUT_DIR}/postgres_superuser_params_${HOSTNAME}_${DATE}.txt"
    SUPERUSER_JSON="${OUTPUT_DIR}/postgres_superuser_params_${HOSTNAME}_${DATE}.json"
    USER_PARAMS_TXT="${OUTPUT_DIR}/postgres_user_params_${HOSTNAME}_${DATE}.txt"
    USER_PARAMS_JSON="${OUTPUT_DIR}/postgres_user_params_${HOSTNAME}_${DATE}.json"

    # Initialise the CSV with headers
    echo "Standard,Status,Remediation" > "$CSV_FILE"
}

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Write one row to the CSV report
write_csv() {
    local standard="$1"
    local status="$2"
    local remediation="$3"
    # Escape internal double-quotes
    standard="${standard//\"/\"\"}"
    remediation="${remediation//\"/\"\"}"
    printf '"%s","%s","%s"\n' "$standard" "$status" "$remediation" >> "$CSV_FILE"
}

# Print a formatted check result line to the console
print_check() {
    local status="$1"
    local check_id="$2"
    local description="$3"
    local reason="${4:-}"
    local label
    case "$status" in
        PASS)          label="[PASS]          " ;;
        FAIL)          label="[FAIL]          " ;;
        MANUAL_REVIEW) label="[MANUAL_REVIEW] " ;;
        SKIPPED)       label="[SKIPPED]       " ;;
        N/A)           label="[N/A]           " ;;
        *)             label="[${status}]     " ;;
    esac
    if [[ -n "$reason" ]]; then
        echo "  ${label} ${check_id}  ${description} — ${reason}"
    else
        echo "  ${label} ${check_id}  ${description}"
    fi
}

# Print a section header banner
section_header() {
    local section="$1"
    local title="$2"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " SECTION ${section} — ${title}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Run a psql query and return single-value trimmed output.
# Returns the string "SKIP" if DB checks are disabled.
run_pg_query() {
    local query="$1"
    if [[ "${SKIP_DB_CHECKS:-1}" -eq 1 ]]; then
        echo "SKIP"
        return
    fi
    export PGPASSWORD="$PG_PASSWORD"
    local result
    result=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        -t -c "$query" 2>/dev/null | tr -d '[:space:]')
    unset PGPASSWORD
    echo "$result"
}

# Run a psql query and return multi-line output (strips leading whitespace, removes blank lines)
run_pg_query_multiline() {
    local query="$1"
    if [[ "${SKIP_DB_CHECKS:-1}" -eq 1 ]]; then
        echo "SKIP"
        return
    fi
    export PGPASSWORD="$PG_PASSWORD"
    local result
    result=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        -t -c "$query" 2>/dev/null \
        | sed 's/^[[:space:]]*//' \
        | sed '/^[[:space:]]*$/d')
    unset PGPASSWORD
    echo "$result"
}

# Write name|setting pairs to TXT and JSON supplementary files (for sections 6.3-6.6)
write_params_supplementary() {
    local txt_file="$1"
    local json_file="$2"
    local query="$3"
    local title="$4"

    if [[ "${SKIP_DB_CHECKS:-1}" -eq 1 ]]; then
        echo "Database credentials not provided — output not available." > "$txt_file"
        echo "[]" > "$json_file"
        return
    fi

    export PGPASSWORD="$PG_PASSWORD"
    local raw
    raw=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        -t -A -F'|' -c "$query" 2>/dev/null || echo "")
    unset PGPASSWORD

    # TXT
    {
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo " ${title}"
        echo " Host : ${HOSTNAME}"
        echo " Date : ${DATE}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        printf "\n%-50s %s\n" "Parameter" "Setting"
        printf "%-50s %s\n" \
            "──────────────────────────────────────────────────" \
            "──────────────────────────────"
        while IFS='|' read -r name setting; do
            [[ -z "$name" ]] && continue
            printf "%-50s %s\n" "$name" "$setting"
        done <<< "$raw"
    } > "$txt_file"

    # JSON
    {
        local first=1
        echo "["
        while IFS='|' read -r name setting; do
            [[ -z "$name" ]] && continue
            [[ "$first" -eq 0 ]] && echo ","
            printf '  {"name": "%s", "setting": "%s"}' "$name" "$setting"
            first=0
        done <<< "$raw"
        echo ""
        echo "]"
    } > "$json_file"
}

# Check if a destination string is present in LOG_DESTINATION (comma-separated list)
log_dest_includes() {
    local dest="$1"
    echo "$LOG_DESTINATION" | grep -qi "$dest"
}

# Emit a SKIPPED result for a check that requires local server access.
# Called at the top of every OS-level check when SERVER_ACCESS=0.
_server_only_skipped() {
    local check_id="$1"
    local description="$2"
    local std="$3"
    print_check "SKIPPED" "$check_id" "$description" \
        "server access not available — run this script on the target server to evaluate"
    write_csv "$std" "SKIPPED" \
        "This check requires local OS access to the target server. \
Re-run cis_checks.sh directly on the PostgreSQL host to evaluate this control."
}


# =============================================================================
# PRE-FLIGHT
# =============================================================================

validate_output_dir() {
    if [[ ! -d "$OUTPUT_DIR" ]]; then
        echo "[ERROR] Output directory does not exist: $OUTPUT_DIR"
        echo "        No scan was run."
        exit 1
    fi
    if [[ ! -w "$OUTPUT_DIR" ]]; then
        echo "[ERROR] Output directory is not writable: $OUTPUT_DIR"
        echo "        No scan was run."
        exit 1
    fi
}

prompt_server_access() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " Execution Mode"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Is this script running directly on the target"
    echo "  PostgreSQL server?"
    echo ""
    echo "  [y] Yes — OS-level and DB checks will both run."
    echo "  [n] No  — Running remotely. Only DB checks will run."
    echo "            OS-level checks will be marked SKIPPED."
    echo ""
    while true; do
        read -rp "  Running on the target server? (y/n): " server_input
        case "${server_input,,}" in
            y|yes)
                SERVER_ACCESS=1
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "[INFO] Mode: ON-SERVER — OS-level and DB checks enabled."
                break
                ;;
            n|no)
                SERVER_ACCESS=0
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "[INFO] Mode: REMOTE — DB checks only. OS-level checks will be SKIPPED."
                break
                ;;
            *)
                echo "  Please enter y or n."
                ;;
        esac
    done
}

detect_os() {
    # Only meaningful when running on the server — skip silently in remote mode
    if [[ "$SERVER_ACCESS" -eq 0 ]]; then
        PKG_MANAGER="unknown"
        return
    fi
    echo ""
    echo "[INFO] Detecting package manager..."
    if command -v apt-get > /dev/null 2>&1; then
        PKG_MANAGER="apt"
    elif command -v dnf > /dev/null 2>&1; then
        PKG_MANAGER="rpm"
    elif command -v rpm > /dev/null 2>&1; then
        PKG_MANAGER="rpm"
    else
        echo "[ERROR] Could not detect a supported package manager on this host."
        echo "        Checked: apt-get, dnf, rpm"
        echo ""
        echo "        This engine requires either apt (Debian/Ubuntu) or dnf/rpm (RHEL/Rocky)."
        echo "        No checks were run. No report has been generated."
        exit 1
    fi
    echo "[INFO] Package manager detected: ${PKG_MANAGER}"
}

prompt_credentials() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " PostgreSQL Connection Credentials"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  These are required for database-level checks."
    echo "  Leave blank to skip all database checks."
    echo ""
    read -rp "  Host     (default: localhost): " input_host
    PG_HOST="${input_host:-localhost}"
    read -rp "  Port     (default: 5432): "    input_port
    PG_PORT="${input_port:-5432}"
    read -rp "  Database : " PG_DB
    read -rp "  Username : " PG_USER
    read -s -rp "  Password : " PG_PASSWORD
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [[ -z "$PG_DB" || -z "$PG_USER" || -z "$PG_PASSWORD" ]]; then
        SKIP_DB_CHECKS=1
        echo "[INFO] Database credentials not fully provided. DB-level checks will be SKIPPED."
    else
        SKIP_DB_CHECKS=0
        export PGPASSWORD="$PG_PASSWORD"
        if ! psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
            -c "SELECT 1;" > /dev/null 2>&1; then
            echo "[WARN] Could not connect to PostgreSQL with the provided credentials."
            echo "       DB-level checks will be SKIPPED."
            SKIP_DB_CHECKS=1
        else
            echo "[INFO] Database connection verified."
        fi
        unset PGPASSWORD
    fi
}

prompt_user_list() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " User List for Sudo Validation (Check 4.2)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Enter space-separated usernames, or a path to a"
    echo "  .txt file with one username per line."
    echo "  Leave blank to skip sudo user validation."
    echo ""
    read -rp "  Input: " user_input
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [[ -z "$user_input" ]]; then
        USER_LIST_PROVIDED=0
        return
    fi
    USER_LIST_PROVIDED=1
    if [[ "$user_input" == *.txt ]]; then
        if [[ -f "$user_input" ]]; then
            mapfile -t USER_LIST < "$user_input"
        else
            echo "[WARN] File not found: $user_input — user list will be empty."
            USER_LIST_PROVIDED=0
        fi
    else
        read -r -a USER_LIST <<< "$user_input"
    fi
}

prompt_log_size() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " Maximum Log File Size (Check 3.1.9)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Enter the maximum log rotation size in MB (min: 10)."
    echo "  Leave blank to fail this check."
    echo ""
    while true; do
        read -rp "  Size (MB): " input_size
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        if [[ -z "$input_size" ]]; then
            LOG_SIZE_MB=""
            echo "[INFO] No log size provided. Check 3.1.9 will be marked FAIL."
            break
        elif [[ "$input_size" =~ ^[0-9]+$ ]] && [[ "$input_size" -ge 10 ]]; then
            LOG_SIZE_MB="$input_size"
            echo "[INFO] Log rotation size set to ${LOG_SIZE_MB} MB."
            break
        else
            echo "  [ERROR] Value must be a whole number of 10 or greater. Please re-enter."
        fi
    done
}


# =============================================================================
# SECTION 1 — INSTALLATION AND PATCHES
# =============================================================================

check_1_1() {
    local STD="1.1 Ensure packages are obtained from authorized repositories"
    if [[ "$SERVER_ACCESS" -eq 0 ]]; then
        _server_only_skipped "1.1" \
            "Ensure packages are obtained from authorized repositories" "$STD"; return
    fi
    echo ""
    echo "  Configured repositories:"
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        grep -Rh "^[^#]*deb " /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null \
            | awk '{print "    " $2}' | sort -u
        grep -Rh "^[^#]*URIs:" /etc/apt/sources.list.d/*.sources 2>/dev/null \
            | awk '{print "    " $2}' | sort -u
    else
        dnf repolist all 2>/dev/null | grep -E 'enabled$' | awk '{print "    " $0}' || \
            echo "    (could not retrieve dnf repo list)"
        # Show where PostgreSQL packages came from
        if rpm -qa 2>/dev/null | grep -qi postgres; then
            echo ""
            echo "  PostgreSQL package sources:"
            dnf info $(rpm -qa 2>/dev/null | grep -i postgres) 2>/dev/null \
                | grep -E '^Name|^Version|^From' | awk '{print "    " $0}' || true
        fi
    fi
    print_check "MANUAL_REVIEW" "1.1" "Ensure packages are obtained from authorized repositories"
    write_csv "$STD" "MANUAL_REVIEW" \
        "Review the repository list printed to console. Ensure all sources are authorised \
(apt.postgresql.org, yum.postgresql.org, download.postgresql.org, or organisation-approved mirrors). \
Remove any unauthorised repositories."
}

check_1_2() {
    local STD="1.2 Install only required packages"
    if [[ "$SERVER_ACCESS" -eq 0 ]]; then
        _server_only_skipped "1.2" "Install only required packages" "$STD"; return
    fi
    echo ""
    echo "  Installed PostgreSQL packages:"
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        dpkg -l 2>/dev/null | grep -i postgres | awk '{print "    " $2 " " $3}' || \
            echo "    (none found)"
    else
        rpm -qa 2>/dev/null | grep -i postgres | sort | awk '{print "    " $0}' || \
            echo "    (none found)"
    fi
    print_check "MANUAL_REVIEW" "1.2" "Install only required packages"
    write_csv "$STD" "MANUAL_REVIEW" \
        "Review the installed packages printed to console. Remove any not required: \
apt purge <pkg> (Debian) or dnf erase <pkg> (RHEL)."
}

check_1_3() {
    local STD="1.3 Ensure systemd service files are enabled"
    if [[ "$SERVER_ACCESS" -eq 0 ]]; then
        _server_only_skipped "1.3" "Ensure systemd service files are enabled" "$STD"; return
    fi
    local services
    services=$(systemctl list-unit-files 2>/dev/null | grep -i "postgresql" | awk '{print $1}')
    if [[ -z "$services" ]]; then
        print_check "FAIL" "1.3" "Ensure systemd service files are enabled" \
            "no PostgreSQL systemd services found"
        write_csv "$STD" "FAIL" \
            "No PostgreSQL systemd services found. Install PostgreSQL or verify service names."
        return
    fi
    local disabled=""
    while read -r svc; do
        [[ -z "$svc" ]] && continue
        local s
        s=$(systemctl is-enabled "$svc" 2>/dev/null || echo "disabled")
        [[ "$s" != "enabled" ]] && disabled+="$svc "
    done <<< "$services"
    if [[ -z "$disabled" ]]; then
        print_check "PASS" "1.3" "Ensure systemd service files are enabled"
        write_csv "$STD" "PASS" ""
    else
        print_check "FAIL" "1.3" "Ensure systemd service files are enabled" \
            "disabled: $disabled"
        write_csv "$STD" "FAIL" \
            "The following services are not enabled: ${disabled}. \
Fix: systemctl enable <service-name>"
    fi
}

check_1_4() {
    local STD="1.4 Ensure data cluster initialized successfully"
    if [[ "$SERVER_ACCESS" -eq 0 ]]; then
        _server_only_skipped "1.4" \
            "Ensure data cluster initialized successfully" "$STD"; return
    fi
    # Look for a PG_VERSION file which indicates a valid cluster
    local data_dir
    data_dir=$(find /var/lib/pgsql /var/lib/postgresql -name "PG_VERSION" 2>/dev/null \
        | head -1 | xargs -I{} dirname {} 2>/dev/null)

    if [[ -z "$data_dir" ]]; then
        print_check "FAIL" "1.4" "Ensure data cluster initialized successfully" \
            "PG_VERSION file not found under /var/lib/pgsql or /var/lib/postgresql"
        write_csv "$STD" "FAIL" \
            "PostgreSQL data cluster not found. Initialize with: \
PGSETUP_INITDB_OPTIONS=-k /usr/pgsql-18/bin/postgresql-18-setup initdb"
        return
    fi

    local perms owner
    perms=$(stat -c '%a' "$data_dir" 2>/dev/null || echo "unknown")
    owner=$(stat -c '%U' "$data_dir" 2>/dev/null || echo "unknown")

    if [[ "$perms" == "700" && "$owner" == "postgres" ]]; then
        print_check "PASS" "1.4" "Ensure data cluster initialized successfully"
        write_csv "$STD" "PASS" ""
    else
        print_check "FAIL" "1.4" "Ensure data cluster initialized successfully" \
            "perms: $perms owner: $owner (expected 700/postgres)"
        write_csv "$STD" "FAIL" \
            "Data directory $data_dir has incorrect permissions or ownership \
(${perms}/${owner}). Expected 700/postgres."
    fi
}

check_1_5() {
    local STD="1.5 Ensure the latest security patches are applied"
    local version
    version=$(run_pg_query "SHOW server_version;")
    if [[ "$version" == "SKIP" ]]; then
        print_check "SKIPPED" "1.5" "Ensure the latest security patches are applied" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."
        return
    fi
    echo ""
    echo "  Current PostgreSQL server_version: $version"
    print_check "MANUAL_REVIEW" "1.5" "Ensure the latest security patches are applied"
    write_csv "$STD" "MANUAL_REVIEW" \
        "Current version: ${version}. Compare against the latest security announcements at \
https://www.postgresql.org/support/security/ and https://www.postgresql.org/support/versioning/ \
— update if behind and mark this check PASS once verified."
}

check_1_6() {
    local STD="1.6 Verify that PGPASSWORD is not set in users' profiles"
    if [[ "$SERVER_ACCESS" -eq 0 ]]; then
        _server_only_skipped "1.6" \
            "Verify that PGPASSWORD is not set in users' profiles" "$STD"; return
    fi
    local matches
    matches=$(grep -l "PGPASSWORD" \
        /home/*/.bashrc /home/*/.profile /home/*/.bash_profile \
        /root/.bashrc /root/.profile /root/.bash_profile \
        /etc/environment 2>/dev/null || true)
    if [[ -z "$matches" ]]; then
        print_check "PASS" "1.6" \
            "Verify that PGPASSWORD is not set in users' profiles"
        write_csv "$STD" "PASS" ""
    else
        print_check "FAIL" "1.6" \
            "Verify that PGPASSWORD is not set in users' profiles"
        write_csv "$STD" "FAIL" \
            "PGPASSWORD found in: $(echo "$matches" | tr '\n' ' '). \
Remove it and use a .pgpass file or other secure authentication method instead."
    fi
}

check_1_7() {
    local STD="1.7 Verify that the PGPASSWORD environment variable is not in use"
    if [[ "$SERVER_ACCESS" -eq 0 ]]; then
        _server_only_skipped "1.7" \
            "Verify that the PGPASSWORD environment variable is not in use" "$STD"; return
    fi
    # Grep /proc/*/environ — exclude our own PID to avoid false positive
    local matches
    matches=$(sudo grep -rl "PGPASSWORD" /proc/*/environ 2>/dev/null \
        | grep -v "/proc/$$/environ" || true)
    if [[ -z "$matches" ]]; then
        print_check "PASS" "1.7" \
            "Verify that the PGPASSWORD environment variable is not in use"
        write_csv "$STD" "PASS" ""
    else
        print_check "FAIL" "1.7" \
            "Verify that the PGPASSWORD environment variable is not in use"
        write_csv "$STD" "FAIL" \
            "PGPASSWORD is set in one or more active processes \
($(echo "$matches" | tr '\n' ' ')). Check which scripts or users are setting it \
and change to a more secure authentication method."
    fi
}

run_section_1() {
    section_header "1" "Installation and Patches"
    check_1_1
    check_1_2
    check_1_3
    check_1_4
    check_1_5
    check_1_6
    check_1_7
}

# =============================================================================
# SECTION 2 — DIRECTORY AND FILE PERMISSIONS
# =============================================================================

check_2_1() {
    local STD="2.1 Ensure the file permissions mask is correct"
    if [[ "$SERVER_ACCESS" -eq 0 ]]; then
        _server_only_skipped "2.1" \
            "Ensure the file permissions mask is correct" "$STD"; return
    fi
    local umask_val
    umask_val=$(sudo -u postgres bash -c 'umask' 2>/dev/null | tr -d '[:space:]')
    if [[ -z "$umask_val" ]]; then
        print_check "FAIL" "2.1" "Ensure the file permissions mask is correct" \
            "could not read postgres umask"
        write_csv "$STD" "FAIL" \
            "Could not read the postgres user umask. Ensure the postgres OS account exists \
and sudo access is available."
        return
    fi
    if [[ "$umask_val" == "0077" || "$umask_val" == "077" ]]; then
        print_check "PASS" "2.1" "Ensure the file permissions mask is correct"
        write_csv "$STD" "PASS" ""
    else
        print_check "FAIL" "2.1" "Ensure the file permissions mask is correct" \
            "umask is $umask_val"
        write_csv "$STD" "FAIL" \
            "postgres user umask is ${umask_val}. Expected 0077. Add 'umask 077' to \
~postgres/.bash_profile and run: source ~/.bash_profile"
    fi
}

check_2_2() {
    local STD="2.2 Ensure extension directory has appropriate ownership and permissions"
    if [[ "$SERVER_ACCESS" -eq 0 ]]; then
        _server_only_skipped "2.2" \
            "Ensure extension directory has appropriate ownership and permissions" "$STD"; return
    fi
    # Locate pg_config — try PATH first, then common locations
    local pg_config_bin
    pg_config_bin=$(command -v pg_config 2>/dev/null \
        || find /usr -name "pg_config" 2>/dev/null | head -1)

    if [[ -z "$pg_config_bin" ]]; then
        print_check "FAIL" "2.2" \
            "Ensure extension directory has appropriate ownership and permissions" \
            "pg_config not found"
        write_csv "$STD" "FAIL" \
            "Could not locate pg_config to determine the extension directory. \
Ensure PostgreSQL binaries are installed."
        return
    fi

    local share_dir ext_dir
    share_dir=$("$pg_config_bin" --sharedir 2>/dev/null)
    ext_dir="${share_dir}/extension"

    if [[ ! -d "$ext_dir" ]]; then
        print_check "FAIL" "2.2" \
            "Ensure extension directory has appropriate ownership and permissions" \
            "directory not found: $ext_dir"
        write_csv "$STD" "FAIL" \
            "Extension directory not found: ${ext_dir}."
        return
    fi

    local perms owner grp
    perms=$(stat -c '%a' "$ext_dir" 2>/dev/null)
    owner=$(stat -c '%U' "$ext_dir" 2>/dev/null)
    grp=$(stat -c '%G'   "$ext_dir" 2>/dev/null)

    if [[ "$perms" == "755" && "$owner" == "root" && "$grp" == "root" ]]; then
        print_check "PASS" "2.2" \
            "Ensure extension directory has appropriate ownership and permissions"
        write_csv "$STD" "PASS" ""
    else
        print_check "FAIL" "2.2" \
            "Ensure extension directory has appropriate ownership and permissions" \
            "perms: $perms owner: ${owner}:${grp}"
        write_csv "$STD" "FAIL" \
            "Extension directory ${ext_dir} has incorrect ownership or permissions \
(${perms} ${owner}:${grp}). Expected 755 root:root. Fix: \
sudo chown root:root ${ext_dir} && sudo chmod 0755 ${ext_dir}"
    fi
}

check_2_3() {
    local STD="2.3 Disable PostgreSQL command history"
    if [[ "$SERVER_ACCESS" -eq 0 ]]; then
        _server_only_skipped "2.3" \
            "Disable PostgreSQL command history" "$STD"; return
    fi
    local findings=()
    while IFS= read -r hist_file; do
        if [[ -L "$hist_file" ]]; then
            local target
            target=$(readlink "$hist_file")
            [[ "$target" != "/dev/null" ]] && \
                findings+=("$hist_file -> $target (not /dev/null)")
        else
            findings+=("$hist_file (regular file — not symlinked to /dev/null)")
        fi
    done < <(sudo find /home /root -name ".psql_history" 2>/dev/null)

    if [[ ${#findings[@]} -eq 0 ]]; then
        print_check "PASS" "2.3" "Disable PostgreSQL command history"
        write_csv "$STD" "PASS" ""
    else
        local finding_str
        finding_str=$(printf '%s; ' "${findings[@]}")
        print_check "FAIL" "2.3" "Disable PostgreSQL command history"
        write_csv "$STD" "FAIL" \
            "psql_history files found: ${finding_str}. Fix: \
rm -f ~/.psql_history && ln -s /dev/null ~/.psql_history \
(repeat for each affected user). Also set PSQL_HISTORY=/dev/null in /etc/environment."
    fi
}

check_2_4() {
    local STD="2.4 Ensure passwords are not stored in the service file"
    if [[ "$SERVER_ACCESS" -eq 0 ]]; then
        _server_only_skipped "2.4" \
            "Ensure passwords are not stored in the service file" "$STD"; return
    fi
    local matches=""
    matches+=$(sudo find / -name .pg_service.conf -type f \
        -exec grep "password" {} \; 2>/dev/null || true)
    matches+=$(sudo grep "password" /root/.pg_service.conf 2>/dev/null || true)
    [[ -n "${PGSERVICEFILE:-}" ]] && \
        matches+=$(grep "password" "$PGSERVICEFILE" 2>/dev/null || true)
    [[ -n "${PGSYSCONFDIR:-}" ]] && \
        matches+=$(grep "password" "${PGSYSCONFDIR}/pg_service.conf" 2>/dev/null || true)

    if [[ -z "$matches" ]]; then
        print_check "PASS" "2.4" "Ensure passwords are not stored in the service file"
        write_csv "$STD" "PASS" ""
    else
        print_check "FAIL" "2.4" "Ensure passwords are not stored in the service file"
        write_csv "$STD" "FAIL" \
            "password= entries found in pg_service.conf file(s). \
Remove all password entries from the service file(s) identified above."
    fi
}

run_section_2() {
    section_header "2" "Directory and File Permissions"
    check_2_1
    check_2_2
    check_2_3
    check_2_4
}


# =============================================================================
# SECTION 3 — LOGGING AND AUDITING
# =============================================================================

detect_log_destination() {
    if [[ "${SKIP_DB_CHECKS:-1}" -eq 1 ]]; then
        LOG_DESTINATION=""
        return
    fi
    LOG_DESTINATION=$(run_pg_query "SHOW log_destination;")
}

check_3_1_2() {
    local STD="3.1.2 Ensure the log destinations are set correctly"
    if [[ "${SKIP_DB_CHECKS:-1}" -eq 1 ]]; then
        print_check "SKIPPED" "3.1.2" "Ensure the log destinations are set correctly" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."
        return
    fi
    if [[ -z "$LOG_DESTINATION" ]]; then
        print_check "FAIL" "3.1.2" "Ensure the log destinations are set correctly" \
            "could not query log_destination"
        write_csv "$STD" "FAIL" \
            "Could not query log_destination. Verify database connectivity."
        return
    fi
    if echo "$LOG_DESTINATION" | grep -qiE "stderr|csvlog|syslog|jsonlog"; then
        print_check "PASS" "3.1.2" "Ensure the log destinations are set correctly"
        write_csv "$STD" "PASS" ""
    else
        print_check "FAIL" "3.1.2" "Ensure the log destinations are set correctly" \
            "value: $LOG_DESTINATION"
        write_csv "$STD" "FAIL" \
            "log_destination is '${LOG_DESTINATION}'. Set to one or more of: \
stderr, csvlog, syslog, jsonlog. \
Example: ALTER SYSTEM SET log_destination='csvlog'; SELECT pg_reload_conf();"
    fi
}

# Helper: emit N/A when a logging-collector check isn't applicable
_logging_collector_na() {
    local check_id="$1" description="$2" std="$3"
    print_check "N/A" "$check_id" "$description" \
        "not applicable for log_destination: $LOG_DESTINATION"
    write_csv "$std" "N/A" \
        "Not applicable — log_destination is '${LOG_DESTINATION}', \
which does not include stderr or csvlog."
}

# Helper: emit N/A when a syslog check isn't applicable
_syslog_na() {
    local check_id="$1" description="$2" std="$3"
    print_check "N/A" "$check_id" "$description" "syslog not enabled"
    write_csv "$std" "N/A" \
        "syslog not enabled — log_destination is '${LOG_DESTINATION}'."
}

check_3_1_3() {
    local STD="3.1.3 Ensure the logging collector is enabled"
    if [[ "${SKIP_DB_CHECKS:-1}" -eq 1 ]]; then
        print_check "SKIPPED" "3.1.3" "Ensure the logging collector is enabled" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi
    if ! log_dest_includes "stderr" && ! log_dest_includes "csvlog"; then
        _logging_collector_na "3.1.3" "Ensure the logging collector is enabled" "$STD"; return
    fi
    local val; val=$(run_pg_query "SHOW logging_collector;")
    if [[ "$val" == "on" ]]; then
        print_check "PASS" "3.1.3" "Ensure the logging collector is enabled"
        write_csv "$STD" "PASS" ""
    else
        print_check "FAIL" "3.1.3" "Ensure the logging collector is enabled"
        write_csv "$STD" "FAIL" \
            "logging_collector is '${val}'. Enable: \
ALTER SYSTEM SET logging_collector='on'; then restart PostgreSQL (restart required)."
    fi
}

check_3_1_4() {
    local STD="3.1.4 Ensure the log file destination directory is set correctly"
    if [[ "${SKIP_DB_CHECKS:-1}" -eq 1 ]]; then
        print_check "SKIPPED" "3.1.4" \
            "Ensure the log file destination directory is set correctly" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi
    if ! log_dest_includes "stderr" && ! log_dest_includes "csvlog"; then
        _logging_collector_na "3.1.4" \
            "Ensure the log file destination directory is set correctly" "$STD"; return
    fi
    local val; val=$(run_pg_query "SHOW log_directory;")
    if [[ -n "$val" ]]; then
        print_check "PASS" "3.1.4" \
            "Ensure the log file destination directory is set correctly"
        write_csv "$STD" "PASS" ""
    else
        print_check "FAIL" "3.1.4" \
            "Ensure the log file destination directory is set correctly"
        write_csv "$STD" "FAIL" \
            "log_directory is not set. Set it per your organisation's logging policy: \
ALTER SYSTEM SET log_directory='/var/log/postgres'; SELECT pg_reload_conf();"
    fi
}

check_3_1_5() {
    local STD="3.1.5 Ensure the filename pattern for log files is set correctly"
    if [[ "${SKIP_DB_CHECKS:-1}" -eq 1 ]]; then
        print_check "SKIPPED" "3.1.5" \
            "Ensure the filename pattern for log files is set correctly" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi
    if ! log_dest_includes "stderr" && ! log_dest_includes "csvlog"; then
        _logging_collector_na "3.1.5" \
            "Ensure the filename pattern for log files is set correctly" "$STD"; return
    fi
    local val; val=$(run_pg_query "SHOW log_filename;")
    if [[ "$val" == "postgresql-%Y%m%d.log" ]]; then
        print_check "PASS" "3.1.5" \
            "Ensure the filename pattern for log files is set correctly"
        write_csv "$STD" "PASS" ""
    else
        print_check "FAIL" "3.1.5" \
            "Ensure the filename pattern for log files is set correctly" "value: $val"
        write_csv "$STD" "FAIL" \
            "log_filename is '${val}'. Expected 'postgresql-%Y%m%d.log'. \
Fix: ALTER SYSTEM SET log_filename='postgresql-%Y%m%d.log'; SELECT pg_reload_conf();"
    fi
}

check_3_1_6() {
    local STD="3.1.6 Ensure the log file permissions are set correctly"
    if [[ "${SKIP_DB_CHECKS:-1}" -eq 1 ]]; then
        print_check "SKIPPED" "3.1.6" \
            "Ensure the log file permissions are set correctly" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi
    if ! log_dest_includes "stderr" && ! log_dest_includes "csvlog"; then
        _logging_collector_na "3.1.6" \
            "Ensure the log file permissions are set correctly" "$STD"; return
    fi
    local val; val=$(run_pg_query "SHOW log_file_mode;")
    if [[ "$val" == "0600" ]]; then
        print_check "PASS" "3.1.6" "Ensure the log file permissions are set correctly"
        write_csv "$STD" "PASS" ""
    else
        print_check "FAIL" "3.1.6" "Ensure the log file permissions are set correctly" \
            "value: $val"
        write_csv "$STD" "FAIL" \
            "log_file_mode is '${val}'. Expected '0600'. \
Fix: ALTER SYSTEM SET log_file_mode='0600'; SELECT pg_reload_conf();"
    fi
}

check_3_1_7() {
    local STD="3.1.7 Ensure log_truncate_on_rotation is enabled"
    if [[ "${SKIP_DB_CHECKS:-1}" -eq 1 ]]; then
        print_check "SKIPPED" "3.1.7" "Ensure log_truncate_on_rotation is enabled" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi
    if ! log_dest_includes "stderr" && ! log_dest_includes "csvlog"; then
        _logging_collector_na "3.1.7" \
            "Ensure log_truncate_on_rotation is enabled" "$STD"; return
    fi
    local val; val=$(run_pg_query "SHOW log_truncate_on_rotation;")
    if [[ "$val" == "on" ]]; then
        print_check "PASS" "3.1.7" "Ensure log_truncate_on_rotation is enabled"
        write_csv "$STD" "PASS" ""
    else
        print_check "FAIL" "3.1.7" "Ensure log_truncate_on_rotation is enabled"
        write_csv "$STD" "FAIL" \
            "log_truncate_on_rotation is '${val}'. \
Fix: ALTER SYSTEM SET log_truncate_on_rotation='on'; SELECT pg_reload_conf();"
    fi
}

check_3_1_8() {
    local STD="3.1.8 Ensure the maximum log file lifetime is set correctly"
    if [[ "${SKIP_DB_CHECKS:-1}" -eq 1 ]]; then
        print_check "SKIPPED" "3.1.8" \
            "Ensure the maximum log file lifetime is set correctly" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi
    if ! log_dest_includes "stderr" && ! log_dest_includes "csvlog"; then
        _logging_collector_na "3.1.8" \
            "Ensure the maximum log file lifetime is set correctly" "$STD"; return
    fi
    local val; val=$(run_pg_query "SHOW log_rotation_age;")
    echo ""
    echo "  log_rotation_age: $val"
    print_check "MANUAL_REVIEW" "3.1.8" \
        "Ensure the maximum log file lifetime is set correctly"
    write_csv "$STD" "MANUAL_REVIEW" \
        "log_rotation_age is '${val}'. Confirm this aligns with your organisation's log \
retention policy. Recommended: at least 1d. \
Fix: ALTER SYSTEM SET log_rotation_age='1d'; SELECT pg_reload_conf();"
}

check_3_1_9() {
    local STD="3.1.9 Ensure the maximum log file size is set correctly"
    if [[ "${SKIP_DB_CHECKS:-1}" -eq 1 ]]; then
        print_check "SKIPPED" "3.1.9" \
            "Ensure the maximum log file size is set correctly" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi
    if ! log_dest_includes "stderr" && ! log_dest_includes "csvlog"; then
        _logging_collector_na "3.1.9" \
            "Ensure the maximum log file size is set correctly" "$STD"; return
    fi
    if [[ -z "$LOG_SIZE_MB" ]]; then
        print_check "FAIL" "3.1.9" \
            "Ensure the maximum log file size is set correctly" \
            "no size provided by operator"
        write_csv "$STD" "FAIL" \
            "Operator did not provide minimum size. Re-run the scan and enter the \
desired log rotation size in MB (minimum: 10)."
        return
    fi
    # PostgreSQL stores log_rotation_size in kB internally
    local val_kb expected_kb
    val_kb=$(run_pg_query \
        "SELECT setting FROM pg_settings WHERE name='log_rotation_size';")
    expected_kb=$(( LOG_SIZE_MB * 1024 ))

    if [[ "$val_kb" == "0" ]]; then
        print_check "FAIL" "3.1.9" \
            "Ensure the maximum log file size is set correctly" \
            "size-triggered rotation disabled (0)"
        write_csv "$STD" "FAIL" \
            "log_rotation_size is 0 (disabled). Set to at least ${LOG_SIZE_MB}MB: \
ALTER SYSTEM SET log_rotation_size='${LOG_SIZE_MB}MB'; SELECT pg_reload_conf();"
    elif [[ "$val_kb" -eq "$expected_kb" ]]; then
        print_check "PASS" "3.1.9" \
            "Ensure the maximum log file size is set correctly"
        write_csv "$STD" "PASS" ""
    else
        local actual_mb=$(( val_kb / 1024 ))
        print_check "FAIL" "3.1.9" \
            "Ensure the maximum log file size is set correctly" \
            "expected ${LOG_SIZE_MB}MB got ${actual_mb}MB"
        write_csv "$STD" "FAIL" \
            "log_rotation_size is ${actual_mb}MB but expected ${LOG_SIZE_MB}MB. \
Fix: ALTER SYSTEM SET log_rotation_size='${LOG_SIZE_MB}MB'; SELECT pg_reload_conf();"
    fi
}

check_3_1_10() {
    local STD="3.1.10 Ensure the correct syslog facility is selected"
    if [[ "${SKIP_DB_CHECKS:-1}" -eq 1 ]]; then
        print_check "SKIPPED" "3.1.10" \
            "Ensure the correct syslog facility is selected" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi
    if ! log_dest_includes "syslog"; then
        _syslog_na "3.1.10" "Ensure the correct syslog facility is selected" "$STD"; return
    fi
    local val; val=$(run_pg_query "SHOW syslog_facility;")
    if echo "$val" | grep -qiE "^local[0-7]$"; then
        print_check "PASS" "3.1.10" "Ensure the correct syslog facility is selected"
        write_csv "$STD" "PASS" ""
    else
        print_check "FAIL" "3.1.10" "Ensure the correct syslog facility is selected" \
            "value: $val"
        write_csv "$STD" "FAIL" \
            "syslog_facility is '${val}'. Must be LOCAL0 through LOCAL7. \
Fix per your syslog policy: \
ALTER SYSTEM SET syslog_facility='LOCAL1'; SELECT pg_reload_conf();"
    fi
}

check_3_1_11() {
    local STD="3.1.11 Ensure syslog messages are not suppressed"
    if [[ "${SKIP_DB_CHECKS:-1}" -eq 1 ]]; then
        print_check "SKIPPED" "3.1.11" "Ensure syslog messages are not suppressed" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi
    if ! log_dest_includes "syslog"; then
        _syslog_na "3.1.11" "Ensure syslog messages are not suppressed" "$STD"; return
    fi
    local val; val=$(run_pg_query "SHOW syslog_sequence_numbers;")
    if [[ "$val" == "on" ]]; then
        print_check "PASS" "3.1.11" "Ensure syslog messages are not suppressed"
        write_csv "$STD" "PASS" ""
    else
        print_check "FAIL" "3.1.11" "Ensure syslog messages are not suppressed"
        write_csv "$STD" "FAIL" \
            "syslog_sequence_numbers is '${val}'. \
Fix: ALTER SYSTEM SET syslog_sequence_numbers='on'; SELECT pg_reload_conf();"
    fi
}

check_3_1_12() {
    local STD="3.1.12 Ensure syslog messages are not lost due to size"
    if [[ "${SKIP_DB_CHECKS:-1}" -eq 1 ]]; then
        print_check "SKIPPED" "3.1.12" \
            "Ensure syslog messages are not lost due to size" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi
    if ! log_dest_includes "syslog"; then
        _syslog_na "3.1.12" "Ensure syslog messages are not lost due to size" "$STD"; return
    fi
    local val; val=$(run_pg_query "SHOW syslog_split_messages;")
    if [[ "$val" == "on" ]]; then
        print_check "PASS" "3.1.12" "Ensure syslog messages are not lost due to size"
        write_csv "$STD" "PASS" ""
    else
        print_check "FAIL" "3.1.12" "Ensure syslog messages are not lost due to size"
        write_csv "$STD" "FAIL" \
            "syslog_split_messages is '${val}'. \
Fix: ALTER SYSTEM SET syslog_split_messages='on'; SELECT pg_reload_conf();"
    fi
}

check_3_1_13() {
    local STD="3.1.13 Ensure the program name for PostgreSQL syslog messages is correct"
    if [[ "${SKIP_DB_CHECKS:-1}" -eq 1 ]]; then
        print_check "SKIPPED" "3.1.13" \
            "Ensure the program name for PostgreSQL syslog messages is correct" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi
    if ! log_dest_includes "syslog"; then
        _syslog_na "3.1.13" \
            "Ensure the program name for PostgreSQL syslog messages is correct" \
            "$STD"; return
    fi
    local val; val=$(run_pg_query "SHOW syslog_ident;")
    if [[ -n "$val" ]]; then
        print_check "PASS" "3.1.13" \
            "Ensure the program name for PostgreSQL syslog messages is correct"
        write_csv "$STD" "PASS" ""
    else
        print_check "FAIL" "3.1.13" \
            "Ensure the program name for PostgreSQL syslog messages is correct"
        write_csv "$STD" "FAIL" \
            "syslog_ident is empty. Set a recognisable program name: \
ALTER SYSTEM SET syslog_ident='postgres'; SELECT pg_reload_conf();"
    fi
}

check_3_1_14() {
    local STD="3.1.14 Ensure the correct messages are written to the server log"
    local val; val=$(run_pg_query "SHOW log_min_messages;")
    if [[ "$val" == "SKIP" ]]; then
        print_check "SKIPPED" "3.1.14" \
            "Ensure the correct messages are written to the server log" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi
    if [[ "$val" == "warning" ]]; then
        print_check "PASS" "3.1.14" \
            "Ensure the correct messages are written to the server log"
        write_csv "$STD" "PASS" ""
    else
        print_check "FAIL" "3.1.14" \
            "Ensure the correct messages are written to the server log" "value: $val"
        write_csv "$STD" "FAIL" \
            "log_min_messages is '${val}'. Expected 'warning'. \
Fix: ALTER SYSTEM SET log_min_messages='warning'; SELECT pg_reload_conf();"
    fi
}

check_3_1_15() {
    local STD="3.1.15 Ensure the correct SQL statements generating errors are recorded"
    local val; val=$(run_pg_query "SHOW log_min_error_statement;")
    if [[ "$val" == "SKIP" ]]; then
        print_check "SKIPPED" "3.1.15" \
            "Ensure the correct SQL statements generating errors are recorded" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi
    if [[ "$val" == "error" ]]; then
        print_check "PASS" "3.1.15" \
            "Ensure the correct SQL statements generating errors are recorded"
        write_csv "$STD" "PASS" ""
    else
        print_check "FAIL" "3.1.15" \
            "Ensure the correct SQL statements generating errors are recorded" "value: $val"
        write_csv "$STD" "FAIL" \
            "log_min_error_statement is '${val}'. Expected 'error'. \
Fix: ALTER SYSTEM SET log_min_error_statement='error'; SELECT pg_reload_conf();"
    fi
}

# Checks 3.1.16 – 3.1.21: simple on/off queries — use a compact helper pattern
_check_onoff() {
    local std="$1" check_id="$2" description="$3" param="$4" expected="$5" remediation="$6"
    local val; val=$(run_pg_query "SHOW ${param};")
    if [[ "$val" == "SKIP" ]]; then
        print_check "SKIPPED" "$check_id" "$description" "database credentials not provided"
        write_csv "$std" "SKIPPED" "Database credentials not provided."; return
    fi
    if [[ "$val" == "$expected" ]]; then
        print_check "PASS" "$check_id" "$description"
        write_csv "$std" "PASS" ""
    else
        print_check "FAIL" "$check_id" "$description" "value: $val"
        write_csv "$std" "FAIL" "${param} is '${val}'. ${remediation}"
    fi
}

check_3_1_16() {
    _check_onoff \
        "3.1.16 Ensure debug_print_parse is disabled" \
        "3.1.16" "Ensure debug_print_parse is disabled" \
        "debug_print_parse" "off" \
        "Disable it: ALTER SYSTEM SET debug_print_parse='off'; SELECT pg_reload_conf();"
}
check_3_1_17() {
    _check_onoff \
        "3.1.17 Ensure debug_print_rewritten is disabled" \
        "3.1.17" "Ensure debug_print_rewritten is disabled" \
        "debug_print_rewritten" "off" \
        "Disable it: ALTER SYSTEM SET debug_print_rewritten='off'; SELECT pg_reload_conf();"
}
check_3_1_18() {
    _check_onoff \
        "3.1.18 Ensure debug_print_plan is disabled" \
        "3.1.18" "Ensure debug_print_plan is disabled" \
        "debug_print_plan" "off" \
        "Disable it: ALTER SYSTEM SET debug_print_plan='off'; SELECT pg_reload_conf();"
}
check_3_1_19() {
    _check_onoff \
        "3.1.19 Ensure debug_pretty_print is enabled" \
        "3.1.19" "Ensure debug_pretty_print is enabled" \
        "debug_pretty_print" "on" \
        "Enable it: ALTER SYSTEM SET debug_pretty_print='on'; SELECT pg_reload_conf();"
}
check_3_1_21() {
    _check_onoff \
        "3.1.21 Ensure log_disconnections is enabled" \
        "3.1.21" "Ensure log_disconnections is enabled" \
        "log_disconnections" "on" \
        "Enable it: ALTER SYSTEM SET log_disconnections='on'; SELECT pg_reload_conf(); \
(verify in a new session)"
}

check_3_1_20() {
    # PostgreSQL 18 expects 'all' — backwards-compat values (on/true/yes/1) are not sufficient
    local STD="3.1.20 Ensure log_connections is enabled"
    local val; val=$(run_pg_query "SHOW log_connections;")
    if [[ "$val" == "SKIP" ]]; then
        print_check "SKIPPED" "3.1.20" "Ensure log_connections is enabled" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi
    if [[ "$val" == "all" ]]; then
        print_check "PASS" "3.1.20" "Ensure log_connections is enabled"
        write_csv "$STD" "PASS" ""
    else
        print_check "FAIL" "3.1.20" "Ensure log_connections is enabled" "value: $val"
        write_csv "$STD" "FAIL" \
            "log_connections is '${val}'. Expected 'all' (PostgreSQL 18). \
Fix: ALTER SYSTEM SET log_connections='all'; SELECT pg_reload_conf(); \
(verify in a new session — cannot verify in the same connection)."
    fi
}

check_3_1_22() {
    local STD="3.1.22 Ensure log_error_verbosity is set correctly"
    local val; val=$(run_pg_query "SHOW log_error_verbosity;")
    if [[ "$val" == "SKIP" ]]; then
        print_check "SKIPPED" "3.1.22" "Ensure log_error_verbosity is set correctly" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi
    if [[ "$val" == "verbose" ]]; then
        print_check "PASS" "3.1.22" "Ensure log_error_verbosity is set correctly"
        write_csv "$STD" "PASS" ""
    else
        print_check "FAIL" "3.1.22" "Ensure log_error_verbosity is set correctly" \
            "value: $val"
        write_csv "$STD" "FAIL" \
            "log_error_verbosity is '${val}'. Expected 'verbose'. \
Fix: ALTER SYSTEM SET log_error_verbosity='verbose'; SELECT pg_reload_conf();"
    fi
}

check_3_1_23() {
    local STD="3.1.23 Ensure log_hostname is set correctly"
    local val; val=$(run_pg_query "SHOW log_hostname;")
    if [[ "$val" == "SKIP" ]]; then
        print_check "SKIPPED" "3.1.23" "Ensure log_hostname is set correctly" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi
    if [[ "$val" == "off" ]]; then
        print_check "PASS" "3.1.23" "Ensure log_hostname is set correctly"
        write_csv "$STD" "PASS" ""
    else
        print_check "FAIL" "3.1.23" "Ensure log_hostname is set correctly" "value: $val"
        write_csv "$STD" "FAIL" \
            "log_hostname is '${val}'. Expected 'off' — DNS resolution per logged \
statement adds overhead; IPs can be resolved at review time. \
Fix: ALTER SYSTEM SET log_hostname='off'; SELECT pg_reload_conf();"
    fi
}

check_3_1_24() {
    local STD="3.1.24 Ensure log_line_prefix is set correctly"
    local val; val=$(run_pg_query "SHOW log_line_prefix;")
    if [[ "$val" == "SKIP" ]]; then
        print_check "SKIPPED" "3.1.24" "Ensure log_line_prefix is set correctly" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi
    # Required tokens differ by destination
    # syslog minimum : %u %d %a %h
    # non-syslog min : %m %p %l %d %u %a %h
    local pass=0
    if log_dest_includes "syslog"; then
        if echo "$val" | grep -q "%u" && echo "$val" | grep -q "%d" \
            && echo "$val" | grep -q "%a" && echo "$val" | grep -q "%h"; then
            pass=1
        fi
    else
        if echo "$val" | grep -q "%m" && echo "$val" | grep -q "%p" \
            && echo "$val" | grep -q "%d" && echo "$val" | grep -q "%u" \
            && echo "$val" | grep -q "%a" && echo "$val" | grep -q "%h"; then
            pass=1
        fi
    fi
    if [[ "$pass" -eq 1 ]]; then
        print_check "PASS" "3.1.24" "Ensure log_line_prefix is set correctly"
        write_csv "$STD" "PASS" ""
    else
        print_check "FAIL" "3.1.24" "Ensure log_line_prefix is set correctly" \
            "value: $val"
        write_csv "$STD" "FAIL" \
            "log_line_prefix is '${val}'. Missing required tokens. \
Fix: ALTER SYSTEM SET log_line_prefix='%m [%p]: [%l-1] db=%d,user=%u,app=%a,client=%h '; \
SELECT pg_reload_conf();"
    fi
}

check_3_1_25() {
    local STD="3.1.25 Ensure log_statement is set correctly"
    local val; val=$(run_pg_query "SHOW log_statement;")
    if [[ "$val" == "SKIP" ]]; then
        print_check "SKIPPED" "3.1.25" "Ensure log_statement is set correctly" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi
    if [[ "$val" == "ddl" || "$val" == "mod" || "$val" == "all" ]]; then
        print_check "PASS" "3.1.25" "Ensure log_statement is set correctly"
        write_csv "$STD" "PASS" ""
    else
        print_check "FAIL" "3.1.25" "Ensure log_statement is set correctly" "value: $val"
        write_csv "$STD" "FAIL" \
            "log_statement is '${val}'. Expected ddl, mod, or all (none is a fail). \
Fix: ALTER SYSTEM SET log_statement='ddl'; SELECT pg_reload_conf();"
    fi
}

check_3_1_26() {
    local STD="3.1.26 Ensure log_timezone is set correctly"
    local val; val=$(run_pg_query "SHOW log_timezone;")
    if [[ "$val" == "SKIP" ]]; then
        print_check "SKIPPED" "3.1.26" "Ensure log_timezone is set correctly" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi
    if [[ "$val" == "UTC" || "$val" == "GMT" ]]; then
        print_check "PASS" "3.1.26" "Ensure log_timezone is set correctly"
        write_csv "$STD" "PASS" ""
    else
        print_check "FAIL" "3.1.26" "Ensure log_timezone is set correctly" "value: $val"
        write_csv "$STD" "FAIL" \
            "log_timezone is '${val}'. Expected UTC or GMT. \
Fix: ALTER SYSTEM SET log_timezone='UTC'; SELECT pg_reload_conf();"
    fi
}

check_3_2() {
    local STD="3.2 Ensure the PostgreSQL Audit Extension (pgAudit) is enabled"
    if [[ "${SKIP_DB_CHECKS:-1}" -eq 1 ]]; then
        print_check "SKIPPED" "3.2" \
            "Ensure the PostgreSQL Audit Extension (pgAudit) is enabled" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi
    local preload; preload=$(run_pg_query "SHOW shared_preload_libraries;")
    if ! echo "$preload" | grep -qi "pgaudit"; then
        print_check "FAIL" "3.2" \
            "Ensure the PostgreSQL Audit Extension (pgAudit) is enabled" \
            "pgaudit not in shared_preload_libraries"
        write_csv "$STD" "FAIL" \
            "pgaudit not found in shared_preload_libraries. Install: \
dnf -y install pgaudit_18 (rpm) or apt-get install -y postgresql-18-pgaudit (apt). \
Add 'pgaudit' to shared_preload_libraries and set pgaudit.log='ddl,write' in postgresql.conf, \
then restart."
        return
    fi
    # Check pgaudit.log is configured
    export PGPASSWORD="$PG_PASSWORD"
    local pgaudit_log
    pgaudit_log=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        -t -c "SHOW pgaudit.log;" 2>/dev/null | tr -d '[:space:]' || echo "ERROR")
    unset PGPASSWORD
    if [[ -n "$pgaudit_log" && "$pgaudit_log" != "ERROR"* ]]; then
        print_check "PASS" "3.2" \
            "Ensure the PostgreSQL Audit Extension (pgAudit) is enabled"
        write_csv "$STD" "PASS" ""
    else
        print_check "FAIL" "3.2" \
            "Ensure the PostgreSQL Audit Extension (pgAudit) is enabled" \
            "pgaudit.log not configured"
        write_csv "$STD" "FAIL" \
            "pgaudit is loaded but pgaudit.log is not configured. \
Add to postgresql.conf: pgaudit.log='ddl,write' and restart."
    fi
}

run_section_3() {
    section_header "3" "Logging and Auditing"
    detect_log_destination
    check_3_1_2;  check_3_1_3;  check_3_1_4;  check_3_1_5
    check_3_1_6;  check_3_1_7;  check_3_1_8;  check_3_1_9
    check_3_1_10; check_3_1_11; check_3_1_12; check_3_1_13
    check_3_1_14; check_3_1_15; check_3_1_16; check_3_1_17
    check_3_1_18; check_3_1_19; check_3_1_20; check_3_1_21
    check_3_1_22; check_3_1_23; check_3_1_24; check_3_1_25
    check_3_1_26; check_3_2
}


# =============================================================================
# SECTION 4 — USER ACCESS AND AUTHORIZATION
# =============================================================================

check_4_1() {
    local STD="4.1 Ensure interactive login is disabled"
    if [[ "$SERVER_ACCESS" -eq 0 ]]; then
        _server_only_skipped "4.1" \
            "Ensure interactive login is disabled" "$STD"; return
    fi
    local shadow_entry
    shadow_entry=$(sudo grep "^postgres:" /etc/shadow 2>/dev/null | cut -d: -f1-2)
    if [[ -z "$shadow_entry" ]]; then
        print_check "FAIL" "4.1" "Ensure interactive login is disabled" \
            "could not read /etc/shadow"
        write_csv "$STD" "FAIL" \
            "Could not read /etc/shadow. Ensure sudo access is available. \
Manual check: sudo grep postgres /etc/shadow | cut -d: -f1-2 \
— should return postgres:!<something>"
        return
    fi
    local pw_field
    pw_field=$(echo "$shadow_entry" | cut -d: -f2)
    if [[ "$pw_field" == "!"* ]]; then
        print_check "PASS" "4.1" "Ensure interactive login is disabled"
        write_csv "$STD" "PASS" ""
    else
        print_check "FAIL" "4.1" "Ensure interactive login is disabled"
        write_csv "$STD" "FAIL" \
            "The postgres OS account is not locked (password field does not start with !). \
Lock it: sudo passwd -l postgres"
    fi
}

check_4_2() {
    local STD="4.2 Ensure sudo is configured correctly"
    if [[ "$SERVER_ACCESS" -eq 0 ]]; then
        _server_only_skipped "4.2" \
            "Ensure sudo is configured correctly" "$STD"; return
    fi
    if [[ "$USER_LIST_PROVIDED" -eq 0 ]]; then
        print_check "FAIL" "4.2" "Ensure sudo is configured correctly" \
            "no users provided at scan start"
        write_csv "$STD" "FAIL" \
            "No users provided. Operator must verify sudoers configuration manually. \
Compare /etc/sudoers and /etc/sudoers.d/ against your access matrix or \
organisational equivalent."
        return
    fi
    local found=() not_found=()
    echo ""
    echo "  Checking sudoers for provided users..."
    for user in "${USER_LIST[@]}"; do
        [[ -z "$user" ]] && continue
        if sudo grep -rqE \
            "^[[:space:]]*(%?${user}|${user})[[:space:]]" \
            /etc/sudoers /etc/sudoers.d/ 2>/dev/null; then
            echo "    ${user} — found in sudoers"
            found+=("$user")
        else
            echo "    ${user} — NOT found in sudoers"
            not_found+=("$user")
        fi
    done
    local found_str not_found_str
    found_str=$(printf '%s ' "${found[@]:-none}")
    not_found_str=$(printf '%s ' "${not_found[@]:-none}")
    print_check "MANUAL_REVIEW" "4.2" "Ensure sudo is configured correctly"
    write_csv "$STD" "MANUAL_REVIEW" \
        "Users found in sudoers: ${found_str}. Users NOT found: ${not_found_str}. \
Compare against your access matrix or organisational equivalent. \
To add a user: echo '%dba ALL=(postgres) PASSWD: ALL' > /etc/sudoers.d/postgres \
&& chmod 600 /etc/sudoers.d/postgres"
}

check_4_3() {
    local STD="4.3 Ensure excessive administrative privileges are revoked"
    if [[ "${SKIP_DB_CHECKS:-1}" -eq 1 ]]; then
        print_check "SKIPPED" "4.3" \
            "Ensure excessive administrative privileges are revoked" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi
    export PGPASSWORD="$PG_PASSWORD"
    local raw
    raw=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        -t -A -F'|' -c \
        "SELECT rolname, rolsuper::text, rolcreaterole::text, rolcreatedb::text, \
rolreplication::text, rolbypassrls::text \
FROM pg_roles ORDER BY rolname;" 2>/dev/null || echo "")
    unset PGPASSWORD

    # TXT supplementary
    {
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo " PostgreSQL Administrative Privileges"
        echo " Host : ${HOSTNAME}  Date : ${DATE}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        printf "\n%-30s %-10s %-12s %-10s %-12s %-10s\n" \
            "Role" "Superuser" "CreateRole" "CreateDB" "Replication" "BypassRLS"
        printf "%-30s %-10s %-12s %-10s %-12s %-10s\n" \
            "$(printf '─%.0s' {1..30})" "──────────" "────────────" \
            "──────────" "────────────" "──────────"
        while IFS='|' read -r name super cr cdb rep brl; do
            [[ -z "$name" ]] && continue
            printf "%-30s %-10s %-12s %-10s %-12s %-10s\n" \
                "$name" "$super" "$cr" "$cdb" "$rep" "$brl"
        done <<< "$raw"
    } > "$ADMIN_PRIV_TXT"

    # JSON supplementary
    {
        local first=1
        echo "["
        while IFS='|' read -r name super cr cdb rep brl; do
            [[ -z "$name" ]] && continue
            [[ "$first" -eq 0 ]] && echo ","
            printf '  {"rolname":"%s","rolsuper":"%s","rolcreaterole":"%s",'\
'"rolcreatedb":"%s","rolreplication":"%s","rolbypassrls":"%s"}' \
                "$name" "$super" "$cr" "$cdb" "$rep" "$brl"
            first=0
        done <<< "$raw"
        echo ""
        echo "]"
    } > "$ADMIN_PRIV_JSON"

    print_check "MANUAL_REVIEW" "4.3" \
        "Ensure excessive administrative privileges are revoked"
    write_csv "$STD" "MANUAL_REVIEW" \
        "Review role attributes in ${ADMIN_PRIV_TXT##*/} and ${ADMIN_PRIV_JSON##*/}. \
Compare against your access matrix or organisational equivalent. \
Revoke as needed: ALTER ROLE <name> NOSUPERUSER NOCREATEROLE NOCREATEDB \
NOREPLICATION NOBYPASSRLS NOINHERIT;"
}

check_4_4() {
    local STD="4.4 Lock out accounts if not currently in use"
    if [[ "${SKIP_DB_CHECKS:-1}" -eq 1 ]]; then
        print_check "SKIPPED" "4.4" "Lock out accounts if not currently in use" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi
    local result
    result=$(run_pg_query_multiline \
        "SELECT rolname FROM pg_catalog.pg_roles \
WHERE rolname !~ '^pg_' AND rolcanlogin;")
    echo ""
    echo "  Login-capable accounts:"
    echo "$result" | while read -r line; do
        [[ -n "$line" ]] && echo "    $line"
    done
    print_check "MANUAL_REVIEW" "4.4" "Lock out accounts if not currently in use"
    write_csv "$STD" "MANUAL_REVIEW" \
        "Review login-capable accounts printed to console. \
Disable inactive accounts: ALTER ROLE <account> NOLOGIN; \
Re-enable when needed: ALTER ROLE <account> LOGIN;"
}

check_4_5() {
    local STD="4.5 Ensure excessive function privileges are revoked"
    if [[ "${SKIP_DB_CHECKS:-1}" -eq 1 ]]; then
        print_check "SKIPPED" "4.5" "Ensure excessive function privileges are revoked" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi
    export PGPASSWORD="$PG_PASSWORD"
    local result
    result=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        -t -c "SELECT nspname||'.'||proname
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
JOIN pg_authid a ON a.oid = p.proowner
WHERE proname NOT LIKE 'pgaudit%'
  AND prosecdef IS TRUE;" 2>/dev/null \
        | sed 's/^[[:space:]]*//' | sed '/^[[:space:]]*$/d' || echo "")
    unset PGPASSWORD
    if [[ -z "$result" ]]; then
        print_check "PASS" "4.5" "Ensure excessive function privileges are revoked"
        write_csv "$STD" "PASS" ""
    else
        local count; count=$(echo "$result" | wc -l | tr -d '[:space:]')
        print_check "FAIL" "4.5" "Ensure excessive function privileges are revoked" \
            "${count} SECURITY DEFINER function(s) detected"
        write_csv "$STD" "FAIL" \
            "${count} SECURITY DEFINER function(s) found: \
$(echo "$result" | tr '\n' ' '). \
Change to SECURITY INVOKER where possible: ALTER FUNCTION <name> SECURITY INVOKER; \
Or restrict execute: REVOKE EXECUTE ON FUNCTION <name> FROM <role>;"
    fi
}

check_4_6() {
    local STD="4.6 Ensure excessive DML privileges are revoked"
    if [[ "${SKIP_DB_CHECKS:-1}" -eq 1 ]]; then
        print_check "SKIPPED" "4.6" "Ensure excessive DML privileges are revoked" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi
    export PGPASSWORD="$PG_PASSWORD"
    local raw
    raw=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        -t -A -F'|' -c \
        "SELECT t.schemaname, t.tablename, u.usename,
  has_table_privilege(u.usename, t.schemaname||'.'||t.tablename,'select')::text,
  has_table_privilege(u.usename, t.schemaname||'.'||t.tablename,'insert')::text,
  has_table_privilege(u.usename, t.schemaname||'.'||t.tablename,'update')::text,
  has_table_privilege(u.usename, t.schemaname||'.'||t.tablename,'delete')::text
FROM pg_tables t, pg_user u
WHERE t.schemaname NOT IN ('information_schema','pg_catalog')
ORDER BY t.schemaname, t.tablename, u.usename;" 2>/dev/null || echo "")
    unset PGPASSWORD

    # TXT supplementary
    {
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo " PostgreSQL DML Privileges"
        echo " Host : ${HOSTNAME}  Date : ${DATE}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        printf "\n%-18s %-28s %-18s %-6s %-6s %-6s %-6s\n" \
            "Schema" "Table" "User" "SEL" "INS" "UPD" "DEL"
        printf "%-18s %-28s %-18s %-6s %-6s %-6s %-6s\n" \
            "──────────────────" "────────────────────────────" \
            "──────────────────" "──────" "──────" "──────" "──────"
        while IFS='|' read -r sch tbl usr s i u d; do
            [[ -z "$sch" ]] && continue
            printf "%-18s %-28s %-18s %-6s %-6s %-6s %-6s\n" \
                "$sch" "$tbl" "$usr" "$s" "$i" "$u" "$d"
        done <<< "$raw"
    } > "$DML_PRIV_TXT"

    # JSON supplementary
    {
        local first=1
        echo "["
        while IFS='|' read -r sch tbl usr s i u d; do
            [[ -z "$sch" ]] && continue
            [[ "$first" -eq 0 ]] && echo ","
            printf '  {"schema":"%s","table":"%s","user":"%s",'\
'"select":"%s","insert":"%s","update":"%s","delete":"%s"}' \
                "$sch" "$tbl" "$usr" "$s" "$i" "$u" "$d"
            first=0
        done <<< "$raw"
        echo ""
        echo "]"
    } > "$DML_PRIV_JSON"

    print_check "MANUAL_REVIEW" "4.6" "Ensure excessive DML privileges are revoked"
    write_csv "$STD" "MANUAL_REVIEW" \
        "Review DML privilege matrix in ${DML_PRIV_TXT##*/} and ${DML_PRIV_JSON##*/}. \
Compare against your access matrix or organisational equivalent. \
Revoke: REVOKE INSERT, UPDATE, DELETE ON TABLE <table> FROM <role>;"
}

check_4_7() {
    local STD="4.7 Ensure Row Level Security (RLS) is configured correctly"
    if [[ "${SKIP_DB_CHECKS:-1}" -eq 1 ]]; then
        print_check "SKIPPED" "4.7" \
            "Ensure Row Level Security (RLS) is configured correctly" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi
    local result
    result=$(run_pg_query_multiline \
        "SELECT oid::text || ' ' || relname || ' (RLS: ' || relrowsecurity::text || ')' \
FROM pg_class WHERE relrowsecurity IS TRUE;")
    echo ""
    echo "  Tables with RLS enabled:"
    if [[ -z "$result" ]]; then
        echo "    (none)"
    else
        echo "$result" | while read -r line; do
            [[ -n "$line" ]] && echo "    $line"
        done
    fi
    print_check "MANUAL_REVIEW" "4.7" \
        "Ensure Row Level Security (RLS) is configured correctly"
    write_csv "$STD" "MANUAL_REVIEW" \
        "Review RLS-enabled tables above. Determine which tables require RLS per your \
data access policy. Enable: ALTER TABLE <name> ENABLE ROW LEVEL SECURITY; \
Ensure no unauthorised users have BYPASSRLS: ALTER ROLE <user> NOBYPASSRLS;"
}

check_4_8() {
    local STD="4.8 Ensure the set_user extension is installed"
    if [[ "${SKIP_DB_CHECKS:-1}" -eq 1 ]]; then
        print_check "SKIPPED" "4.8" "Ensure the set_user extension is installed" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi

    # Create roletree view (CIS-prescribed SQL)
    local ROLETREE_SQL
    ROLETREE_SQL="DROP VIEW IF EXISTS roletree;
CREATE OR REPLACE VIEW roletree AS
WITH RECURSIVE roltree AS (
  SELECT u.rolname,u.oid AS roloid,u.rolcanlogin,u.rolsuper,
         '{}'::name[] AS rolparents,NULL::oid AS parent_roloid,NULL::name AS parent_rolname
  FROM pg_catalog.pg_authid u
  LEFT JOIN pg_catalog.pg_auth_members m ON u.oid=m.member
  LEFT JOIN pg_catalog.pg_authid g ON m.roleid=g.oid
  WHERE g.oid IS NULL
  UNION ALL
  SELECT u.rolname,u.oid,u.rolcanlogin,u.rolsuper,
         t.rolparents||g.rolname,g.oid,g.rolname
  FROM pg_catalog.pg_authid u
  JOIN pg_catalog.pg_auth_members m ON u.oid=m.member
  JOIN pg_catalog.pg_authid g ON m.roleid=g.oid
  JOIN roltree t ON t.roloid=g.oid
)
SELECT r.rolname,r.roloid,r.rolcanlogin,r.rolsuper,r.rolparents
FROM roltree r ORDER BY 1;"

    export PGPASSWORD="$PG_PASSWORD"
    if psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        -c "$ROLETREE_SQL" > /dev/null 2>&1; then
        ROLETREE_CREATED=1
        echo ""
        echo "  [INFO] roletree view created for check 4.8 (will be dropped on teardown)."
    else
        echo ""
        echo "  [WARN] Could not create roletree view — some sub-checks may be incomplete."
    fi

    # Check set_user is installed
    local set_user_ver
    set_user_ver=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        -t -c "SELECT installed_version FROM pg_available_extensions \
WHERE name='set_user';" 2>/dev/null | tr -d '[:space:]')

    # Check for non-postgres superusers that can login directly
    local direct_super
    direct_super=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        -t -c "SELECT COUNT(*) FROM pg_authid \
WHERE rolsuper AND rolcanlogin AND rolname!='postgres';" \
        2>/dev/null | tr -d '[:space:]')

    # Check roletree for unprivileged roles with inherited superuser
    local inherited_super=0
    if [[ "$ROLETREE_CREATED" -eq 1 ]]; then
        inherited_super=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
            -t -c "SELECT COUNT(*) FROM roletree ro
WHERE (ro.rolcanlogin AND ro.rolsuper)
   OR (ro.rolcanlogin AND EXISTS (
         SELECT TRUE FROM roletree ri
         WHERE ri.rolname=ANY(ro.rolparents) AND ri.rolsuper));" \
            2>/dev/null | tr -d '[:space:]')
    fi
    unset PGPASSWORD

    local fail=0 reasons=""
    [[ -z "$set_user_ver" ]] && { fail=1; reasons+="set_user not installed; "; }
    [[ -n "$direct_super" && "$direct_super" -gt 0 ]] && {
        fail=1
        reasons+="${direct_super} non-postgres superuser(s) with direct login; "
    }
    # >1 because postgres itself may appear
    [[ "$inherited_super" -gt 1 ]] && {
        fail=1
        reasons+="roles with inherited superuser access detected; "
    }

    if [[ "$fail" -eq 0 ]]; then
        print_check "PASS" "4.8" "Ensure the set_user extension is installed"
        write_csv "$STD" "PASS" ""
    else
        print_check "FAIL" "4.8" "Ensure the set_user extension is installed" \
            "$reasons"
        write_csv "$STD" "FAIL" \
            "Issues: ${reasons}. Install set_user: \
dnf -y install set_user_18 (rpm) or apt-get install -y postgresql-18-set-user (apt). \
Add 'set_user' to shared_preload_libraries and restart. \
Grant to DBAs: GRANT EXECUTE ON FUNCTION set_user(text) TO <dba_role>;"
    fi
}

check_4_9() {
    local STD="4.9 Make use of predefined roles"
    if [[ "${SKIP_DB_CHECKS:-1}" -eq 1 ]]; then
        print_check "SKIPPED" "4.9" "Make use of predefined roles" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi
    export PGPASSWORD="$PG_PASSWORD"
    local superusers all_roles
    superusers=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        -t -A -F'|' -c \
        "SELECT rolname FROM pg_roles WHERE rolsuper ORDER BY rolname;" \
        2>/dev/null || echo "")
    all_roles=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        -t -A -F'|' -c \
        "SELECT rolname, rolsuper::text, rolcanlogin::text, \
rolcreaterole::text, rolcreatedb::text FROM pg_roles ORDER BY rolname;" \
        2>/dev/null || echo "")
    unset PGPASSWORD

    # TXT supplementary
    {
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo " PostgreSQL Roles and Predefined Role Usage"
        echo " Host : ${HOSTNAME}  Date : ${DATE}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "Superuser roles:"
        echo "$superusers" | while IFS='|' read -r name; do
            [[ -n "$name" ]] && echo "  $name"
        done
        echo ""
        printf "%-30s %-10s %-10s %-12s %-10s\n" \
            "All Roles" "Superuser" "CanLogin" "CreateRole" "CreateDB"
        printf "%-30s %-10s %-10s %-12s %-10s\n" \
            "$(printf '─%.0s' {1..30})" "──────────" "──────────" \
            "────────────" "──────────"
        while IFS='|' read -r name sup log cr cdb; do
            [[ -z "$name" ]] && continue
            printf "%-30s %-10s %-10s %-12s %-10s\n" "$name" "$sup" "$log" "$cr" "$cdb"
        done <<< "$all_roles"
        echo ""
        echo "PostgreSQL 18 predefined roles: pg_read_all_data, pg_write_all_data,"
        echo "  pg_read_all_settings, pg_read_all_stats, pg_stat_scan_tables, pg_maintain,"
        echo "  pg_monitor, pg_database_owner, pg_signal_backend, pg_read_server_files,"
        echo "  pg_write_server_files, pg_execute_server_program, pg_checkpoint,"
        echo "  pg_use_reserved_connections, pg_create_subscription, pg_signal_autovacuum_worker"
    } > "$ROLES_TXT"

    # JSON supplementary
    {
        echo "{"
        echo '  "superuser_roles": ['
        local first=1
        while IFS='|' read -r name; do
            [[ -z "$name" ]] && continue
            [[ "$first" -eq 0 ]] && echo ","
            printf '    "%s"' "$name"; first=0
        done <<< "$superusers"
        echo ""
        echo "  ],"
        echo '  "all_roles": ['
        first=1
        while IFS='|' read -r name sup log cr cdb; do
            [[ -z "$name" ]] && continue
            [[ "$first" -eq 0 ]] && echo ","
            printf '    {"rolname":"%s","rolsuper":"%s","rolcanlogin":"%s",'\
'"rolcreaterole":"%s","rolcreatedb":"%s"}' \
                "$name" "$sup" "$log" "$cr" "$cdb"
            first=0
        done <<< "$all_roles"
        echo ""
        echo "  ]"
        echo "}"
    } > "$ROLES_JSON"

    print_check "MANUAL_REVIEW" "4.9" "Make use of predefined roles"
    write_csv "$STD" "MANUAL_REVIEW" \
        "Review superuser roles in ${ROLES_TXT##*/}. Where a predefined role suffices, \
grant it and remove superuser: GRANT pg_monitor TO <role>; ALTER ROLE <role> NOSUPERUSER; \
Compare against your access matrix or organisational equivalent."
}

check_4_10() {
    local STD="4.10 Ensure all accounts that can log in have passwords"
    if [[ "${SKIP_DB_CHECKS:-1}" -eq 1 ]]; then
        print_check "SKIPPED" "4.10" \
            "Ensure all accounts that can log in have passwords" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi
    local result
    result=$(run_pg_query_multiline \
        "SELECT rolname FROM pg_authid \
WHERE rolpassword IS NULL AND rolcanlogin;")
    if [[ -z "$result" ]]; then
        print_check "PASS" "4.10" \
            "Ensure all accounts that can log in have passwords"
        write_csv "$STD" "PASS" ""
    else
        local count; count=$(echo "$result" | wc -l | tr -d '[:space:]')
        print_check "FAIL" "4.10" \
            "Ensure all accounts that can log in have passwords" \
            "${count} account(s) with no password"
        write_csv "$STD" "FAIL" \
            "${count} login-capable account(s) have no password: \
$(echo "$result" | tr '\n' ' '). Set passwords: \password <username> \
(preferred over ALTER ROLE to avoid log exposure)."
    fi
}

run_section_4() {
    section_header "4" "User Access and Authorization"
    check_4_1;  check_4_2;  check_4_3;  check_4_4;  check_4_5
    check_4_6;  check_4_7;  check_4_8;  check_4_9;  check_4_10
}


# =============================================================================
# SECTION 5 — CONNECTION AND LOGIN
# =============================================================================

check_5_1() {
    local STD="5.1 Do not specify passwords in the command line"
    if [[ "$SERVER_ACCESS" -eq 0 ]]; then
        _server_only_skipped "5.1" \
            "Do not specify passwords in the command line" "$STD"; return
    fi
    local findings=()

    # Check process list
    local ps_hits
    ps_hits=$(sudo ps -few 2>/dev/null \
        | grep -E "(postgresql://[^@]*:[^@]+@|--password[= ]|PGPASSWORD=)" \
        | grep -v grep || true)
    [[ -n "$ps_hits" ]] && findings+=("Password visible in process list")

    # Check history files
    local history_files=()
    mapfile -t history_files < <(
        find /home /root -maxdepth 2 \
            \( -name ".bash_history" -o -name ".psql_history" \) 2>/dev/null)

    for f in "${history_files[@]}"; do
        if sudo grep -qE \
            "(--password|-W[[:space:]]|PGPASSWORD=|postgresql://[^@]*:[^@]+@)" \
            "$f" 2>/dev/null; then
            findings+=("Password pattern found in: $f")
        fi
    done

    if [[ ${#findings[@]} -eq 0 ]]; then
        print_check "PASS" "5.1" "Do not specify passwords in the command line"
        write_csv "$STD" "PASS" ""
    else
        local finding_str
        finding_str=$(printf '%s; ' "${findings[@]}")
        print_check "FAIL" "5.1" "Do not specify passwords in the command line"
        write_csv "$STD" "FAIL" \
            "Password exposure detected: ${finding_str}. \
Use a .pgpass file (~/.pgpass, chmod 600) or PGPASSFILE env var instead of \
embedding passwords in commands or environment variables."
    fi
}

check_5_2() {
    local STD="5.2 Ensure PostgreSQL is bound to an IP address"
    local val; val=$(run_pg_query "SHOW listen_addresses;")
    if [[ "$val" == "SKIP" ]]; then
        print_check "SKIPPED" "5.2" \
            "Ensure PostgreSQL is bound to an IP address" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi
    if [[ "$val" == "*" || "$val" == "0.0.0.0" ]]; then
        print_check "FAIL" "5.2" "Ensure PostgreSQL is bound to an IP address" \
            "value: $val"
        write_csv "$STD" "FAIL" \
            "listen_addresses is '${val}' — PostgreSQL listens on all interfaces. \
Set a specific IP in postgresql.conf: listen_addresses = '<your_ip>' (requires restart)."
    else
        print_check "PASS" "5.2" "Ensure PostgreSQL is bound to an IP address"
        write_csv "$STD" "PASS" ""
    fi
}

check_5_3() {
    local STD="5.3 Ensure login via local UNIX domain socket is configured correctly"

    if [[ "$SERVER_ACCESS" -eq 1 ]]; then
        # On-server path: read pg_hba.conf directly
        local hba_file
        hba_file=$(sudo -u postgres psql -t -c "SHOW hba_file;" 2>/dev/null \
            | tr -d '[:space:]')
        if [[ -z "$hba_file" || ! -f "$hba_file" ]]; then
            print_check "FAIL" "5.3" \
                "Ensure login via local UNIX domain socket is configured correctly" \
                "pg_hba.conf not found"
            write_csv "$STD" "FAIL" \
                "Could not locate pg_hba.conf. Ensure PostgreSQL is running and the \
postgres OS user can query SHOW hba_file."
            return
        fi
        local insecure
        insecure=$(grep -E "^[[:space:]]*local" "$hba_file" 2>/dev/null \
            | grep -vE "^[[:space:]]*#" \
            | grep -vE "[[:space:]]peer[[:space:]]*$" || true)
    else
        # Remote path: use pg_hba_file_rules() view (available PostgreSQL 10+)
        if [[ "${SKIP_DB_CHECKS:-1}" -eq 1 ]]; then
            print_check "SKIPPED" "5.3" \
                "Ensure login via local UNIX domain socket is configured correctly" \
                "database credentials not provided"
            write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
        fi
        local insecure
        insecure=$(run_pg_query \
            "SELECT COUNT(*) FROM pg_hba_file_rules \
WHERE type='local' \
  AND auth_method NOT IN ('peer','scram-sha-256','cert');")
        # Treat as string comparison — non-zero count means insecure entries exist
        [[ "$insecure" == "0" ]] && insecure="" || insecure="non-peer local entries: $insecure"
    fi

    if [[ -z "$insecure" ]]; then
        print_check "PASS" "5.3" \
            "Ensure login via local UNIX domain socket is configured correctly"
        write_csv "$STD" "PASS" ""
    else
        print_check "MANUAL_REVIEW" "5.3" \
            "Ensure login via local UNIX domain socket is configured correctly"
        write_csv "$STD" "MANUAL_REVIEW" \
            "Local socket entries not using peer authentication found in pg_hba.conf. \
Review and update to peer where appropriate: local all all peer"
    fi
}

check_5_4() {
    local STD="5.4 Ensure login via host TCP/IP socket is configured correctly"
    local insecure=""

    if [[ "$SERVER_ACCESS" -eq 1 ]]; then
        # On-server path: read pg_hba.conf directly
        local hba_file
        hba_file=$(sudo -u postgres psql -t -c "SHOW hba_file;" 2>/dev/null \
            | tr -d '[:space:]')
        if [[ -z "$hba_file" || ! -f "$hba_file" ]]; then
            print_check "FAIL" "5.4" \
                "Ensure login via host TCP/IP socket is configured correctly" \
                "pg_hba.conf not found"
            write_csv "$STD" "FAIL" "Could not locate pg_hba.conf."; return
        fi
        insecure=$(grep -E "^[[:space:]]*(host|hostssl|hostnossl)[[:space:]]" \
            "$hba_file" 2>/dev/null \
            | grep -vE "^[[:space:]]*#" \
            | grep -vE "127\.0\.0\.1|::1" \
            | grep -E "[[:space:]](trust|password|ident|md5)[[:space:]]*$" || true)
    else
        # Remote path: use pg_hba_file_rules() view (available PostgreSQL 10+)
        if [[ "${SKIP_DB_CHECKS:-1}" -eq 1 ]]; then
            print_check "SKIPPED" "5.4" \
                "Ensure login via host TCP/IP socket is configured correctly" \
                "database credentials not provided"
            write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
        fi
        local count
        count=$(run_pg_query \
            "SELECT COUNT(*) FROM pg_hba_file_rules \
WHERE type IN ('host','hostssl','hostnossl') \
  AND address NOT IN ('127.0.0.1','::1') \
  AND auth_method IN ('trust','password','ident','md5');")
        [[ "$count" != "0" ]] && insecure="$count insecure remote host entries detected"
    fi

    if [[ -z "$insecure" ]]; then
        print_check "PASS" "5.4" \
            "Ensure login via host TCP/IP socket is configured correctly"
        write_csv "$STD" "PASS" ""
    else
        print_check "FAIL" "5.4" \
            "Ensure login via host TCP/IP socket is configured correctly"
        write_csv "$STD" "FAIL" \
            "Insecure remote TCP/IP auth methods found in pg_hba.conf. \
trust (no auth), password (cleartext), ident (OS-level), and md5 (weak/replay-vulnerable) \
are all failures. Replace with scram-sha-256 or cert. \
Use hostssl to enforce SSL on the connection entry."
    fi
}

check_5_5() {
    local STD="5.5 Ensure per-account connection limits are used"
    if [[ "${SKIP_DB_CHECKS:-1}" -eq 1 ]]; then
        print_check "SKIPPED" "5.5" "Ensure per-account connection limits are used" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi
    local result
    result=$(run_pg_query_multiline \
        "SELECT rolname||' (limit: '||rolconnlimit::text||')' \
FROM pg_roles \
WHERE rolname NOT LIKE 'pg_%' \
  AND rolconnlimit = -1 \
  AND rolcanlogin;")
    if [[ -z "$result" ]]; then
        print_check "PASS" "5.5" "Ensure per-account connection limits are used"
        write_csv "$STD" "PASS" ""
    else
        local count; count=$(echo "$result" | wc -l | tr -d '[:space:]')
        print_check "FAIL" "5.5" "Ensure per-account connection limits are used" \
            "${count} account(s) with unlimited connections"
        write_csv "$STD" "FAIL" \
            "${count} account(s) have no connection limit (-1): \
$(echo "$result" | tr '\n' ' '). \
Set limits: ALTER USER <user> CONNECTION LIMIT <n>;"
    fi
}

check_5_6() {
    local STD="5.6 Ensure password complexity is configured"
    if [[ "${SKIP_DB_CHECKS:-1}" -eq 1 ]]; then
        print_check "SKIPPED" "5.6" "Ensure password complexity is configured" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi
    local preload; preload=$(run_pg_query "SHOW shared_preload_libraries;")
    if echo "$preload" | grep -qi "passwordcheck"; then
        print_check "PASS" "5.6" "Ensure password complexity is configured"
        write_csv "$STD" "PASS" ""
    else
        print_check "FAIL" "5.6" "Ensure password complexity is configured" \
            "passwordcheck not in shared_preload_libraries"
        write_csv "$STD" "FAIL" \
            "passwordcheck not found in shared_preload_libraries. \
Add '\$libdir/passwordcheck' to shared_preload_libraries in postgresql.conf and restart. \
Note: passwordcheck has limited built-in capability — consider additional \
password policy tooling for production environments."
    fi
}

run_section_5() {
    section_header "5" "Connection and Login"
    check_5_1; check_5_2; check_5_3; check_5_4; check_5_5; check_5_6
}

# =============================================================================
# SECTION 6 — POSTGRESQL SETTINGS
# =============================================================================

check_6_1() {
    local STD="6.1 Understanding attack vectors and runtime parameters"
    print_check "MANUAL_REVIEW" "6.1" \
        "Understanding attack vectors and runtime parameters"
    write_csv "$STD" "MANUAL_REVIEW" \
        "Review all PostgreSQL configuration settings. Understand the four attack vectors: \
(1) via user session, (2) via role attribute, (3) via server reload (SIGHUP), \
(4) via server restart. Configure logging to record all modifications. \
Reference: https://www.postgresql.org/docs/current/static/runtime-config.html"
}

check_6_2() {
    local STD="6.2 Ensure backend runtime parameters are configured correctly"
    if [[ "${SKIP_DB_CHECKS:-1}" -eq 1 ]]; then
        print_check "SKIPPED" "6.2" \
            "Ensure backend runtime parameters are configured correctly" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi

    export PGPASSWORD="$PG_PASSWORD"
    local output
    output=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        -t -A -F'|' -c \
        "SELECT name, setting FROM pg_settings \
WHERE context IN ('backend','superuser-backend') ORDER BY 1;" \
        2>/dev/null || echo "")
    unset PGPASSWORD

    if [[ -z "$output" ]]; then
        print_check "FAIL" "6.2" \
            "Ensure backend runtime parameters are configured correctly" \
            "could not query pg_settings"
        write_csv "$STD" "FAIL" \
            "Could not query backend runtime parameters. Verify database connectivity."
        return
    fi

    # Expected values per CIS PostgreSQL 18 Benchmark
    local -A expected=(
        [ignore_system_indexes]="off"
        [jit_debugging_support]="off"
        [jit_profiling_support]="off"
        [log_connections]="all"
        [log_disconnections]="on"
        [post_auth_delay]="0"
    )

    local fail=0 fail_params=""
    for param in "${!expected[@]}"; do
        local actual
        actual=$(echo "$output" | grep "^${param}|" | cut -d'|' -f2)
        if [[ "$actual" != "${expected[$param]}" ]]; then
            fail=1
            fail_params+="${param}='${actual}' (expected '${expected[$param]}'); "
        fi
    done

    if [[ "$fail" -eq 0 ]]; then
        print_check "PASS" "6.2" \
            "Ensure backend runtime parameters are configured correctly"
        write_csv "$STD" "PASS" ""
    else
        print_check "FAIL" "6.2" \
            "Ensure backend runtime parameters are configured correctly" \
            "deviations found"
        write_csv "$STD" "FAIL" \
            "Backend parameters deviate from expected values: ${fail_params}. \
Correct in postgresql.conf (restart required for context=backend parameters)."
    fi
}

check_6_3() {
    local STD="6.3 Ensure Postmaster runtime parameters are configured"
    write_params_supplementary \
        "$POSTMASTER_TXT" "$POSTMASTER_JSON" \
        "SELECT name, setting FROM pg_settings WHERE context='postmaster' ORDER BY 1;" \
        "Postmaster Runtime Parameters"
    print_check "MANUAL_REVIEW" "6.3" \
        "Ensure Postmaster runtime parameters are configured"
    write_csv "$STD" "MANUAL_REVIEW" \
        "Compare postmaster parameter snapshot in ${POSTMASTER_TXT##*/} against a \
previously archived baseline. Investigate and restore any unexpected changes. \
Changes require a server restart to take effect."
}

check_6_4() {
    local STD="6.4 Ensure SIGHUP runtime parameters are configured"
    write_params_supplementary \
        "$SIGHUP_TXT" "$SIGHUP_JSON" \
        "SELECT name, setting FROM pg_settings WHERE context='sighup' ORDER BY 1;" \
        "SIGHUP Runtime Parameters"
    print_check "MANUAL_REVIEW" "6.4" \
        "Ensure SIGHUP runtime parameters are configured"
    write_csv "$STD" "MANUAL_REVIEW" \
        "Compare SIGHUP parameter snapshot in ${SIGHUP_TXT##*/} against a previously \
archived baseline. Restore unexpected changes via postgresql.conf and \
SELECT pg_reload_conf();"
}

check_6_5() {
    local STD="6.5 Ensure Superuser runtime parameters are configured"
    write_params_supplementary \
        "$SUPERUSER_TXT" "$SUPERUSER_JSON" \
        "SELECT name, setting FROM pg_settings WHERE context='superuser' ORDER BY 1;" \
        "Superuser Runtime Parameters"
    print_check "MANUAL_REVIEW" "6.5" \
        "Ensure Superuser runtime parameters are configured"
    write_csv "$STD" "MANUAL_REVIEW" \
        "Compare superuser parameter snapshot in ${SUPERUSER_TXT##*/} against a \
previously archived baseline. Restore unexpected changes. \
Changes require a server restart."
}

check_6_6() {
    local STD="6.6 Ensure User runtime parameters are configured"
    write_params_supplementary \
        "$USER_PARAMS_TXT" "$USER_PARAMS_JSON" \
        "SELECT name, setting FROM pg_settings WHERE context='user' ORDER BY 1;" \
        "User Runtime Parameters"
    print_check "MANUAL_REVIEW" "6.6" \
        "Ensure User runtime parameters are configured"
    write_csv "$STD" "MANUAL_REVIEW" \
        "Compare user parameter snapshot in ${USER_PARAMS_TXT##*/} against a previously \
archived baseline. Revert unauthorised changes. For attributes set on database \
entities, revert manually to default values."
}

check_6_7() {
    local STD="6.7 Ensure FIPS 140-2 OpenSSL cryptography is used"
    if [[ "$SERVER_ACCESS" -eq 0 ]]; then
        _server_only_skipped "6.7" \
            "Ensure FIPS 140-2 OpenSSL cryptography is used" "$STD"; return
    fi
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        print_check "N/A" "6.7" \
            "Ensure FIPS 140-2 OpenSSL cryptography is used" \
            "native FIPS support not available on Debian/Ubuntu"
        write_csv "$STD" "N/A" \
            "FIPS 140-2 native support is only available on RHEL/CentOS/Rocky Linux. \
On Debian/Ubuntu a custom OpenSSL build is required. \
This check is not applicable for apt-based systems."
        return
    fi
    local fips_check
    fips_check=$(fips-mode-setup --check 2>/dev/null || echo "FIPS mode is disabled.")
    local openssl_ver
    openssl_ver=$(openssl version 2>/dev/null || echo "")
    if echo "$fips_check" | grep -qi "FIPS mode is enabled" \
        && echo "$openssl_ver" | grep -qi "fips"; then
        print_check "PASS" "6.7" \
            "Ensure FIPS 140-2 OpenSSL cryptography is used"
        write_csv "$STD" "PASS" ""
    else
        print_check "FAIL" "6.7" \
            "Ensure FIPS 140-2 OpenSSL cryptography is used"
        write_csv "$STD" "FAIL" \
            "FIPS mode is not enabled or OpenSSL is not FIPS-capable. \
Enable with: fips-mode-setup --enable && reboot. \
Verify with: fips-mode-setup --check"
    fi
}

check_6_8() {
    local STD="6.8 Ensure TLS is enabled and configured correctly"
    if [[ "${SKIP_DB_CHECKS:-1}" -eq 1 ]]; then
        print_check "SKIPPED" "6.8" \
            "Ensure TLS is enabled and configured correctly" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi
    local ssl_on ssl_cert ssl_key ssl_min_proto
    ssl_on=$(run_pg_query "SHOW ssl;")
    ssl_cert=$(run_pg_query "SHOW ssl_cert_file;")
    ssl_key=$(run_pg_query "SHOW ssl_key_file;")
    ssl_min_proto=$(run_pg_query "SHOW ssl_min_protocol_version;")

    local fail=0 reasons=""
    [[ "$ssl_on" != "on" ]] && {
        fail=1; reasons+="ssl is '${ssl_on}' (expected on); "; }
    [[ -z "$ssl_cert" ]] && {
        fail=1; reasons+="ssl_cert_file not set; "; }
    [[ -z "$ssl_key" ]] && {
        fail=1; reasons+="ssl_key_file not set; "; }
    [[ "$ssl_min_proto" != "TLSv1.2" && "$ssl_min_proto" != "TLSv1.3" ]] && {
        fail=1
        reasons+="ssl_min_protocol_version is '${ssl_min_proto}' \
(expected TLSv1.2 or TLSv1.3); "
    }
    if [[ "$fail" -eq 0 ]]; then
        print_check "PASS" "6.8" "Ensure TLS is enabled and configured correctly"
        write_csv "$STD" "PASS" ""
    else
        print_check "FAIL" "6.8" "Ensure TLS is enabled and configured correctly" \
            "$reasons"
        write_csv "$STD" "FAIL" \
            "TLS configuration issues: ${reasons}. \
Set ssl=on, configure ssl_cert_file and ssl_key_file, and set \
ssl_min_protocol_version='TLSv1.3' in postgresql.conf. Requires restart."
    fi
}

check_6_9() {
    local STD="6.9 Ensure the TLSv1.0 and TLSv1.1 protocols are disabled"
    local val; val=$(run_pg_query "SHOW ssl_min_protocol_version;")
    if [[ "$val" == "SKIP" ]]; then
        print_check "SKIPPED" "6.9" \
            "Ensure the TLSv1.0 and TLSv1.1 protocols are disabled" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi
    if [[ "$val" == "TLSv1.2" || "$val" == "TLSv1.3" ]]; then
        print_check "PASS" "6.9" \
            "Ensure the TLSv1.0 and TLSv1.1 protocols are disabled"
        write_csv "$STD" "PASS" ""
    else
        print_check "FAIL" "6.9" \
            "Ensure the TLSv1.0 and TLSv1.1 protocols are disabled" "value: $val"
        write_csv "$STD" "FAIL" \
            "ssl_min_protocol_version is '${val}'. TLSv1.0 and TLSv1.1 are deprecated \
(RFC 8996). Fix: ALTER SYSTEM SET ssl_min_protocol_version='TLSv1.3'; \
SELECT pg_reload_conf();"
    fi
}

check_6_10() {
    local STD="6.10 Ensure weak SSL/TLS ciphers are disabled"
    if [[ "${SKIP_DB_CHECKS:-1}" -eq 1 ]]; then
        print_check "SKIPPED" "6.10" "Ensure weak SSL/TLS ciphers are disabled" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi
    local ssl_ciphers ssl_tls13_ciphers weak_conns
    ssl_ciphers=$(run_pg_query "SHOW ssl_ciphers;")
    ssl_tls13_ciphers=$(run_pg_query "SHOW ssl_tls13_ciphers;")
    weak_conns=$(run_pg_query \
        "SELECT COUNT(*) FROM pg_stat_ssl \
WHERE cipher NOT IN \
('TLS_AES_256_GCM_SHA384','TLS_AES_128_GCM_SHA256','TLS_AES_128_CCM_SHA256');")

    local fail=0 reasons=""
    if echo "$ssl_ciphers" | \
        grep -qiE "RC4|DES|3DES|NULL|aNULL|eNULL|EXPORT|LOW|MD5"; then
        fail=1
        reasons+="ssl_ciphers contains weak ciphers: '${ssl_ciphers}'; "
    fi
    if [[ -n "$weak_conns" && "$weak_conns" -gt 0 ]]; then
        fail=1
        reasons+="${weak_conns} active connection(s) using non-approved ciphers; "
    fi
    if [[ "$fail" -eq 0 ]]; then
        print_check "PASS" "6.10" "Ensure weak SSL/TLS ciphers are disabled"
        write_csv "$STD" "PASS" ""
    else
        local approved="TLS_AES_256_GCM_SHA384,TLS_AES_128_GCM_SHA256,TLS_AES_128_CCM_SHA256"
        print_check "FAIL" "6.10" "Ensure weak SSL/TLS ciphers are disabled" \
            "$reasons"
        write_csv "$STD" "FAIL" \
            "Weak cipher issues: ${reasons}. Fix: \
ALTER SYSTEM SET ssl_ciphers='${approved}'; \
ALTER SYSTEM SET ssl_tls13_ciphers='${approved}'; \
SELECT pg_reload_conf();"
    fi
}

check_6_11() {
    local STD="6.11 Ensure the pgcrypto extension is installed and configured correctly"
    if [[ "${SKIP_DB_CHECKS:-1}" -eq 1 ]]; then
        print_check "SKIPPED" "6.11" \
            "Ensure the pgcrypto extension is installed and configured correctly" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi
    local installed_version
    installed_version=$(run_pg_query \
        "SELECT installed_version FROM pg_available_extensions \
WHERE name='pgcrypto';")
    if [[ -n "$installed_version" ]]; then
        print_check "PASS" "6.11" \
            "Ensure the pgcrypto extension is installed and configured correctly"
        write_csv "$STD" "PASS" ""
    else
        print_check "MANUAL_REVIEW" "6.11" \
            "Ensure the pgcrypto extension is installed and configured correctly"
        write_csv "$STD" "MANUAL_REVIEW" \
            "pgcrypto is not installed. Determine whether data at rest requires \
encryption. If so: CREATE EXTENSION pgcrypto; Also confirm whether disk or \
filesystem-level encryption is in use. If neither is present and sensitive data \
exists, this should be treated as a FAIL."
    fi
}

run_section_6() {
    section_header "6" "PostgreSQL Settings"
    check_6_1;  check_6_2;  check_6_3;  check_6_4;  check_6_5;  check_6_6
    check_6_7;  check_6_8;  check_6_9;  check_6_10; check_6_11
}


# =============================================================================
# SECTION 7 — REPLICATION
# =============================================================================

detect_replication() {
    if [[ "${SKIP_DB_CHECKS:-1}" -eq 1 ]]; then
        REPLICATION_ENABLED=0
        return
    fi
    local archive_mode max_wal_senders wal_level
    archive_mode=$(run_pg_query \
        "SELECT setting FROM pg_settings WHERE name='archive_mode';")
    max_wal_senders=$(run_pg_query \
        "SELECT setting FROM pg_settings WHERE name='max_wal_senders';")
    wal_level=$(run_pg_query \
        "SELECT setting FROM pg_settings WHERE name='wal_level';")

    if [[ "$archive_mode" == "on" ]] \
        || { [[ -n "$max_wal_senders" ]] && [[ "$max_wal_senders" -gt 0 ]]; } \
        || [[ "$wal_level" == "replica" || "$wal_level" == "logical" ]]; then
        REPLICATION_ENABLED=1
    else
        REPLICATION_ENABLED=0
    fi
}

_skip_replication_check() {
    local check_id="$1" description="$2" std="$3"
    print_check "SKIPPED" "$check_id" "$description" "replication not configured"
    write_csv "$std" "SKIPPED" \
        "Replication not detected on this host. \
If replication is required, configure it and re-run the scan."
}

check_7_1() {
    local STD="7.1 Ensure a replication-only user is created and used for streaming replication"
    local non_postgres_repl
    non_postgres_repl=$(run_pg_query \
        "SELECT COUNT(*) FROM pg_roles \
WHERE rolreplication IS TRUE AND rolname != 'postgres';")
    if [[ -n "$non_postgres_repl" && "$non_postgres_repl" -gt 0 ]]; then
        print_check "PASS" "7.1" \
            "Ensure a replication-only user is created and used for streaming replication"
        write_csv "$STD" "PASS" ""
    else
        print_check "FAIL" "7.1" \
            "Ensure a replication-only user is created and used for streaming replication" \
            "only postgres has replication privilege"
        write_csv "$STD" "FAIL" \
            "No dedicated replication user exists — only 'postgres' has replication privilege. \
Create one: CREATE USER replication_user REPLICATION ENCRYPTED PASSWORD 'XXX'; \
Then add to pg_hba.conf: \
hostssl replication replication_user 0.0.0.0/0 scram-sha-256"
    fi
}

check_7_2() {
    local STD="7.2 Ensure logging of replication commands is configured"
    _check_onoff \
        "$STD" "7.2" \
        "Ensure logging of replication commands is configured" \
        "log_replication_commands" "on" \
        "Enable it: ALTER SYSTEM SET log_replication_commands='on'; \
SELECT pg_reload_conf();"
}

check_7_3() {
    local STD="7.3 Ensure base backups are configured and functional"
    print_check "MANUAL_REVIEW" "7.3" \
        "Ensure base backups are configured and functional"
    write_csv "$STD" "MANUAL_REVIEW" \
        "Manually confirm base backups exist and are updated regularly. \
Use pg_basebackup or pgBackRest (see check 8.2). \
Store backups on a separate file system. Test restoration periodically. \
pg_basebackup example: pg_basebackup --host=<primary> --port=5432 \
--username=replication_user --pgdata=~postgres/18/data --progress --verbose \
--write-recovery-conf --wal-method=stream"
}

check_7_4() {
    local STD="7.4 Ensure WAL archiving is configured and functional"
    if [[ "${SKIP_DB_CHECKS:-1}" -eq 1 ]]; then
        print_check "SKIPPED" "7.4" \
            "Ensure WAL archiving is configured and functional" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi
    export PGPASSWORD="$PG_PASSWORD"
    local archive_rows
    archive_rows=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        -t -c "SELECT name FROM pg_settings
WHERE name IN ('archive_mode','archive_command','archive_library')
  AND setting IS NOT NULL
  AND setting NOT IN ('off','(disabled)','');" 2>/dev/null \
        | tr -d '[:space:]' | tr '\n' ',' || echo "")

    local failed_count
    failed_count=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        -t -c "SELECT failed_count FROM pg_stat_archiver;" 2>/dev/null \
        | tr -d '[:space:]' || echo "0")
    unset PGPASSWORD

    if [[ -z "$archive_rows" ]]; then
        print_check "FAIL" "7.4" \
            "Ensure WAL archiving is configured and functional" \
            "archiving not configured"
        write_csv "$STD" "FAIL" \
            "WAL archiving is not configured. archive_mode, archive_command, or \
archive_library are not set. Configure archiving in postgresql.conf and restart."
        return
    fi
    if [[ -n "$failed_count" && "$failed_count" -gt 0 ]]; then
        print_check "FAIL" "7.4" \
            "Ensure WAL archiving is configured and functional" \
            "archiver reports $failed_count failure(s)"
        write_csv "$STD" "FAIL" \
            "WAL archiving has ${failed_count} failure(s) in pg_stat_archiver. \
Investigate the archive_command or archive_library and fix the underlying issue."
        return
    fi
    print_check "PASS" "7.4" "Ensure WAL archiving is configured and functional"
    write_csv "$STD" "PASS" ""
}

check_7_5() {
    local STD="7.5 Ensure streaming replication parameters are configured correctly"
    print_check "MANUAL_REVIEW" "7.5" \
        "Ensure streaming replication parameters are configured correctly"
    write_csv "$STD" "MANUAL_REVIEW" \
        "Verify streaming replication uses SSL. On the STANDBY host: \
(1) Confirm \$PGDATA/standby.signal exists. \
(2) Confirm \$PGDATA/postgresql.auto.conf contains primary_conninfo with \
sslmode=require referencing the dedicated replication user. \
(3) Test: psql 'host=<primary> dbname=postgres user=replication_user \
password=<pwd> sslmode=require' -c 'SELECT 1;'"
}

run_section_7() {
    section_header "7" "Replication"
    detect_replication

    if [[ "$REPLICATION_ENABLED" -eq 0 ]]; then
        echo ""
        echo "  [INFO] Replication is not configured on this host."
        echo "         Section 7 checks will be skipped."
        echo ""
        echo "         Checks not evaluated:"
        echo "           7.1  Ensure a replication-only user is created"
        echo "           7.2  Ensure logging of replication commands is configured"
        echo "           7.3  Ensure base backups are configured and functional"
        echo "           7.4  Ensure WAL archiving is configured and functional"
        echo "           7.5  Ensure streaming replication parameters are configured correctly"
        echo ""
        echo "         If replication is required, configure it and re-run the scan."

        _skip_replication_check "7.1" \
            "Ensure a replication-only user is created and used for streaming replication" \
            "7.1 Ensure a replication-only user is created and used for streaming replication"
        _skip_replication_check "7.2" \
            "Ensure logging of replication commands is configured" \
            "7.2 Ensure logging of replication commands is configured"
        _skip_replication_check "7.3" \
            "Ensure base backups are configured and functional" \
            "7.3 Ensure base backups are configured and functional"
        _skip_replication_check "7.4" \
            "Ensure WAL archiving is configured and functional" \
            "7.4 Ensure WAL archiving is configured and functional"
        _skip_replication_check "7.5" \
            "Ensure streaming replication parameters are configured correctly" \
            "7.5 Ensure streaming replication parameters are configured correctly"
        return
    fi

    check_7_1; check_7_2; check_7_3; check_7_4; check_7_5
}

# =============================================================================
# SECTION 8 — SPECIAL CONFIGURATION CONSIDERATIONS
# =============================================================================

check_8_1() {
    local STD="8.1 Ensure PostgreSQL subdirectory locations are outside the data cluster"
    if [[ "${SKIP_DB_CHECKS:-1}" -eq 1 ]]; then
        print_check "SKIPPED" "8.1" \
            "Ensure PostgreSQL subdirectory locations are outside the data cluster" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi

    local data_dir log_dir temp_tablespaces temp_file_limit
    data_dir=$(run_pg_query "SHOW data_directory;")
    log_dir=$(run_pg_query "SHOW log_directory;")
    temp_tablespaces=$(run_pg_query "SHOW temp_tablespaces;")
    temp_file_limit=$(run_pg_query \
        "SELECT setting FROM pg_settings WHERE name='temp_file_limit';")

    echo ""
    echo "  data_directory   : $data_dir"
    echo "  log_directory    : $log_dir"
    echo "  temp_tablespaces : $temp_tablespaces"
    echo "  temp_file_limit  : $temp_file_limit"

    local fail=0 reasons=""

    # log_directory is a relative path → it lives inside PGDATA
    if [[ -n "$log_dir" && "$log_dir" != /* ]]; then
        fail=1
        reasons+="log_directory '${log_dir}' is relative (inside data cluster); "
    fi

    # Neither temp_tablespaces nor a size cap is set
    if [[ -z "$temp_tablespaces" ]] \
        && { [[ -z "$temp_file_limit" ]] || [[ "$temp_file_limit" == "-1" ]]; }; then
        fail=1
        reasons+="temp_tablespaces not defined and temp_file_limit is unlimited; "
    fi

    if [[ "$fail" -eq 0 ]]; then
        print_check "MANUAL_REVIEW" "8.1" \
            "Ensure PostgreSQL subdirectory locations are outside the data cluster"
        write_csv "$STD" "MANUAL_REVIEW" \
            "Review directory settings above. Verify log_directory is an absolute path \
outside data_directory. Ensure temp_tablespaces is configured or temp_file_limit is set."
    else
        print_check "FAIL" "8.1" \
            "Ensure PostgreSQL subdirectory locations are outside the data cluster" \
            "$reasons"
        write_csv "$STD" "FAIL" \
            "Directory configuration issues: ${reasons}. \
Move log_directory outside PGDATA (set an absolute path). \
To configure temp_tablespaces: \
CREATE TABLESPACE temp_tablespc LOCATION '/path/to/mount'; \
ALTER SYSTEM SET temp_tablespaces='temp_tablespc'; SELECT pg_reload_conf();"
    fi
}

check_8_2() {
    local STD="8.2 Ensure the backup and restore tool pgBackRest is installed and configured"
    if [[ "$SERVER_ACCESS" -eq 0 ]]; then
        _server_only_skipped "8.2" \
            "Ensure the backup and restore tool pgBackRest is installed and configured" \
            "$STD"; return
    fi
    if ! command -v pgbackrest > /dev/null 2>&1; then
        print_check "FAIL" "8.2" \
            "Ensure the backup and restore tool pgBackRest is installed and configured" \
            "not installed"
        if [[ "$PKG_MANAGER" == "apt" ]]; then
            write_csv "$STD" "FAIL" \
                "pgBackRest is not installed. \
Install: apt-get install -y pgbackrest. \
Then configure stanza, backup location, retention policy, and logging \
per pgBackRest documentation."
        else
            write_csv "$STD" "FAIL" \
                "pgBackRest is not installed. \
Install: dnf -y install pgbackrest. \
Then configure stanza, backup location, retention policy, and logging \
per pgBackRest documentation."
        fi
        return
    fi

    local info
    info=$(pgbackrest info 2>&1 || echo "")
    if echo "$info" | grep -qi "error\|no stanza"; then
        print_check "FAIL" "8.2" \
            "Ensure the backup and restore tool pgBackRest is installed and configured" \
            "installed but no stanza configured"
        write_csv "$STD" "FAIL" \
            "pgBackRest is installed but not configured. \
Configure /etc/pgbackrest/pgbackrest.conf and run: \
pgbackrest --stanza=<name> stanza-create"
        return
    fi
    print_check "PASS" "8.2" \
        "Ensure the backup and restore tool pgBackRest is installed and configured"
    write_csv "$STD" "PASS" ""
}

check_8_3() {
    local STD="8.3 Ensure miscellaneous configuration settings are correct"
    if [[ "${SKIP_DB_CHECKS:-1}" -eq 1 ]]; then
        print_check "SKIPPED" "8.3" \
            "Ensure miscellaneous configuration settings are correct" \
            "database credentials not provided"
        write_csv "$STD" "SKIPPED" "Database credentials not provided."; return
    fi

    export PGPASSWORD="$PG_PASSWORD"
    local output
    output=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        -t -c "SELECT name, setting FROM pg_settings WHERE name IN (
  'external_pid_file','unix_socket_directories','shared_preload_libraries',
  'dynamic_library_path','local_preload_libraries','session_preload_libraries'
);" 2>/dev/null || echo "")
    unset PGPASSWORD

    echo ""
    echo "  Miscellaneous configuration settings:"
    echo "$output" | while read -r line; do
        [[ -n "$line" ]] && echo "    $line"
    done

    local preload; preload=$(run_pg_query "SHOW shared_preload_libraries;")
    local fail=0 missing=""
    for lib in "pgaudit" "set_user"; do
        if ! echo "$preload" | grep -qi "$lib"; then
            fail=1; missing+="${lib} "
        fi
    done

    if [[ "$fail" -eq 0 ]]; then
        print_check "MANUAL_REVIEW" "8.3" \
            "Ensure miscellaneous configuration settings are correct"
        write_csv "$STD" "MANUAL_REVIEW" \
            "Review settings printed to console. Inspect file and directory permissions \
for all returned values. Only superusers should have access. \
Confirm shared_preload_libraries includes: pgaudit, set_user, \$libdir/passwordcheck."
    else
        print_check "FAIL" "8.3" \
            "Ensure miscellaneous configuration settings are correct" \
            "missing from shared_preload_libraries: $missing"
        write_csv "$STD" "FAIL" \
            "shared_preload_libraries is missing required libraries: ${missing}. \
Add to postgresql.conf and restart. \
Expected: pgaudit, set_user, \$libdir/passwordcheck."
    fi
}

run_section_8() {
    section_header "8" "Special Configuration Considerations"
    check_8_1; check_8_2; check_8_3
}


# =============================================================================
# SCAN SUMMARY
# =============================================================================
print_summary() {
    # Count each status from the CSV (skip the header row)
    # grep -c always outputs a number (0 when no matches) but exits 1 on no match.
    # Use || true to suppress the non-zero exit — do NOT use || echo 0 as that
    # appends a second value and breaks the arithmetic on the next line.
    local pass fail manual skipped na
    pass=$(tail -n +2 "$CSV_FILE" 2>/dev/null | grep -c ',"PASS",' || true)
    fail=$(tail -n +2 "$CSV_FILE" 2>/dev/null | grep -c ',"FAIL",' || true)
    manual=$(tail -n +2 "$CSV_FILE" 2>/dev/null | grep -c ',"MANUAL_REVIEW",' || true)
    skipped=$(tail -n +2 "$CSV_FILE" 2>/dev/null | grep -c ',"SKIPPED",' || true)
    na=$(tail -n +2 "$CSV_FILE" 2>/dev/null | grep -c ',"N/A",' || true)
    # Default each to 0 if empty (e.g. CSV file missing or unreadable)
    pass=${pass:-0}; fail=${fail:-0}; manual=${manual:-0}
    skipped=${skipped:-0}; na=${na:-0}
    local total=$(( pass + fail + manual + skipped + na ))

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " SCAN SUMMARY"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "  %-18s %d\n" "PASS"          "$pass"
    printf "  %-18s %d\n" "FAIL"          "$fail"
    printf "  %-18s %d\n" "MANUAL_REVIEW" "$manual"
    printf "  %-18s %d\n" "SKIPPED"       "$skipped"
    printf "  %-18s %d\n" "N/A"           "$na"
    echo "  ──────────────────────"
    printf "  %-18s %d\n" "TOTAL"         "$total"
    echo ""
    echo "  Output files:"
    # Only list files that were actually created
    local output_files=(
        "$CSV_FILE"
        "$ADMIN_PRIV_TXT"  "$ADMIN_PRIV_JSON"
        "$DML_PRIV_TXT"    "$DML_PRIV_JSON"
        "$ROLES_TXT"       "$ROLES_JSON"
        "$POSTMASTER_TXT"  "$POSTMASTER_JSON"
        "$SIGHUP_TXT"      "$SIGHUP_JSON"
        "$SUPERUSER_TXT"   "$SUPERUSER_JSON"
        "$USER_PARAMS_TXT" "$USER_PARAMS_JSON"
    )
    for f in "${output_files[@]}"; do
        [[ -f "$f" ]] && echo "    ${f##*/}"
    done
    echo ""
    echo "  Output directory: ${OUTPUT_DIR}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    # Step 1 — validate output directory before creating any files
    validate_output_dir

    # Step 2 — initialise output file paths and write CSV header
    init_output_files

    # Step 3 — ask the operator whether we are on-server or remote
    prompt_server_access

    # Step 4 — OS detection (no-op in remote mode; exits if unsupported OS on-server)
    detect_os

    # Step 5 — pre-scan operator prompts
    prompt_credentials
    prompt_user_list
    prompt_log_size

    # Step 6 — print scan header (after prompts so mode is known)
    local mode_label
    if [[ "$SERVER_ACCESS" -eq 1 ]]; then
        mode_label="ON-SERVER (OS + DB checks)"
    else
        mode_label="REMOTE (DB checks only)"
    fi
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " HardenX — PostgreSQL CIS Benchmark Engine"
    echo " Benchmark : CIS PostgreSQL 18 Benchmark v1.0.0"
    echo " Host      : ${HOSTNAME}"
    echo " Date      : ${DATE}"
    echo " Mode      : ${mode_label}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    echo ""
    echo "[INFO] Starting compliance scan..."

    # Step 7 — run all sections in order
    run_section_1
    run_section_2
    run_section_3
    run_section_4
    run_section_5
    run_section_6
    run_section_7
    run_section_8

    # Step 8 — print summary (teardown fires automatically via EXIT trap)
    print_summary
}

main "$@"