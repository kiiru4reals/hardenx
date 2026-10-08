#!/usr/bin/env bash
# =============================================================================
# HardenX — Researcher
# Detects active technologies on the target host and writes a structured
# JSON output file for hardenx.sh to consume.
#
# Usage: bash researcher.sh [OPTIONS]
# See --help for full usage information.
# =============================================================================

set -euo pipefail

# =============================================================================
# DEFAULTS
# =============================================================================

OUTPUT_DIR="."
HARDENX_VERSION="0.1"

# =============================================================================
# HELP MENU
# =============================================================================

show_help() {
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo " HardenX — Researcher"
  echo " Detects active technologies on the target host"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "USAGE"
  echo "  bash researcher.sh [OPTIONS]"
  echo ""
  echo "OPTIONS"
  echo "  --output-dir <path>"
  echo "      Directory to write the detection JSON output file."
  echo "      Defaults to the current directory if not specified."
  echo ""
  echo "  --help"
  echo "      Display this help menu and exit."
  echo ""
  echo "DEFAULTS"
  echo "  If invoked with no arguments:"
  echo "    --output-dir ."
  echo ""
  echo "EXAMPLES"
  echo "  Run detection with default output directory:"
  echo "    bash researcher.sh"
  echo ""
  echo "  Run detection and write output to a specific directory:"
  echo "    bash researcher.sh --output-dir /opt/hardenx/output"
  echo ""
  echo "NOTES"
  echo "  - sudo or root access is required for accurate detection of"
  echo "    system-level services."
  echo "  - Output file: hardenx_researcher_<timestamp>.json"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --scan-id)
      EXTERNAL_SCAN_ID="$2"
      shift 2
      ;;
    --help)
      show_help
      exit 0
      ;;
    *)
      echo "[ERROR] Unrecognised argument: $1"
      echo "        Run 'bash researcher.sh --help' for usage information."
      exit 1
      ;;
  esac
done

# =============================================================================
# PRE-FLIGHT: OUTPUT DIRECTORY CHECK
# =============================================================================

if [[ ! -d "$OUTPUT_DIR" ]]; then
  echo "[ERROR] Output directory does not exist: $OUTPUT_DIR"
  exit 1
fi

if [[ ! -w "$OUTPUT_DIR" ]]; then
  echo "[ERROR] Output directory is not writable: $OUTPUT_DIR"
  exit 1
fi

# =============================================================================
# UTILITIES
# =============================================================================

# Generate a UUID using uuidgen, with a fallback if uuidgen is unavailable.
generate_uuid() {
  if command -v uuidgen &>/dev/null; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    # Fallback: construct a UUID v4-shaped string from /dev/urandom
    local hex
    hex=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || \
          od -x /dev/urandom | head -1 | awk '{print $2$3"-"$4"-"$5"-"$6"-"$7$8$9}')
    echo "$hex"
  fi
}

# Escape a string for safe inclusion in JSON.
json_escape() {
  local val="$1"
  val="${val//\\/\\\\}"
  val="${val//\"/\\\"}"
  echo "$val"
}

# Print a JSON field. Handles null values and quoted strings.
# Usage: json_field <key> <value|null>
json_field() {
  local key="$1"
  local val="$2"
  if [[ "$val" == "null" ]]; then
    echo "\"$key\": null"
  else
    echo "\"$key\": \"$(json_escape "$val")\""
  fi
}

# =============================================================================
# SCAN SETUP
# =============================================================================

# Use the scan ID passed in by hardenx.sh if available, otherwise generate one.
# This ensures the Researcher and all engines share the same scan ID when
# invoked via hardenx.sh. When invoked directly, the Researcher generates its own.
if [[ -n "${EXTERNAL_SCAN_ID:-}" ]]; then
  SCAN_ID="$EXTERNAL_SCAN_ID"
else
  SCAN_ID=$(generate_uuid)
fi
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
HOSTNAME=$(hostname)
OUTPUT_FILE="$OUTPUT_DIR/hardenx_researcher_$(date -u +"%Y-%m-%dT%H%M").json"

# Arrays to collect results
declare -A TECH_DETECTED
declare -A TECH_VERSION
declare -A TECH_METHOD
declare -A TECH_NOTES
ENGINES_TO_INVOKE=()

# =============================================================================
# HEADER
# =============================================================================

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " HardenX — Researcher"
echo " Detecting active technologies on this host..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# =============================================================================
# DETECTION: UBUNTU
# =============================================================================

detect_ubuntu() {
  TECH_METHOD[ubuntu]="/etc/os-release"
  TECH_VERSION[ubuntu]="null"
  TECH_NOTES[ubuntu]="null"
  TECH_DETECTED[ubuntu]="false"

  if [[ ! -f /etc/os-release ]]; then
    TECH_NOTES[ubuntu]="\/etc\/os-release not found"
    printf "%-16s %s\n" "[NOT DETECTED]" "ubuntu"
    return
  fi

  local id version_id
  id=$(grep -E "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
  version_id=$(grep -E "^VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d '"')

  if [[ "$id" != "ubuntu" ]]; then
    printf "%-16s %s\n" "[NOT DETECTED]" "ubuntu"
    return
  fi

  if [[ "$version_id" == "24.04" ]]; then
    TECH_DETECTED[ubuntu]="true"
    TECH_VERSION[ubuntu]="24.04"
    ENGINES_TO_INVOKE+=("ubuntu")
    printf "%-16s %-14s %s\n" "[DETECTED]" "ubuntu" "24.04 LTS"
  else
    TECH_VERSION[ubuntu]="$version_id"
    TECH_NOTES[ubuntu]="Ubuntu detected but version $version_id is not supported in v1. Supported version: 24.04 LTS."
    printf "%-16s %-14s %s\n" "[UNSUPPORTED]" "ubuntu" "$version_id — supported version is 24.04 LTS"
  fi
}

# =============================================================================
# DETECTION: ROCKY LINUX
# =============================================================================

detect_rocky() {
  TECH_METHOD[rocky_linux]="/etc/os-release"
  TECH_VERSION[rocky_linux]="null"
  TECH_NOTES[rocky_linux]="null"
  TECH_DETECTED[rocky_linux]="false"

  if [[ ! -f /etc/os-release ]]; then
    TECH_NOTES[rocky_linux]="\/etc\/os-release not found"
    printf "%-16s %s\n" "[NOT DETECTED]" "rocky_linux"
    return
  fi

  local id version_id
  id=$(grep -E "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
  version_id=$(grep -E "^VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d '"')

  if [[ "$id" != "rocky" ]]; then
    printf "%-16s %s\n" "[NOT DETECTED]" "rocky_linux"
    return
  fi

  TECH_DETECTED[rocky_linux]="true"
  TECH_VERSION[rocky_linux]="$version_id"
  ENGINES_TO_INVOKE+=("rocky_linux")
  printf "%-16s %-14s %s\n" "[DETECTED]" "rocky_linux" "$version_id"
}

# =============================================================================
# DETECTION: POSTGRESQL
# =============================================================================

detect_postgresql() {
  TECH_METHOD[postgresql]="null"
  TECH_VERSION[postgresql]="null"
  TECH_NOTES[postgresql]="null"
  TECH_DETECTED[postgresql]="false"

  local running=false

  # Method 1: pg_isready
  if command -v pg_isready &>/dev/null; then
    if pg_isready &>/dev/null; then
      running=true
      TECH_METHOD[postgresql]="pg_isready"
    fi
  fi

  # Method 2: systemctl
  if [[ "$running" == "false" ]] && command -v systemctl &>/dev/null; then
    if systemctl is-active --quiet postgresql 2>/dev/null; then
      running=true
      TECH_METHOD[postgresql]="systemctl is-active postgresql"
    fi
  fi

  # Method 3: pgrep fallback
  if [[ "$running" == "false" ]]; then
    if pgrep -x postgres &>/dev/null; then
      running=true
      TECH_METHOD[postgresql]="pgrep -x postgres"
    fi
  fi

  if [[ "$running" == "false" ]]; then
    TECH_NOTES[postgresql]="No running PostgreSQL process found via pg_isready, systemctl, or pgrep"
    printf "%-16s %s\n" "[NOT DETECTED]" "postgresql"
    return
  fi

  # Version detection via psql
  local version="null"
  if command -v psql &>/dev/null; then
    version=$(psql --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "null")
  fi

  TECH_DETECTED[postgresql]="true"
  TECH_VERSION[postgresql]="$version"
  ENGINES_TO_INVOKE+=("postgresql")
  printf "%-16s %-14s %s\n" "[DETECTED]" "postgresql" "$version"
}

# =============================================================================
# DETECTION: DOCKER
# =============================================================================

detect_docker() {
  TECH_METHOD[docker]="null"
  TECH_VERSION[docker]="null"
  TECH_NOTES[docker]="null"
  TECH_DETECTED[docker]="false"

  # Method 1: docker info
  if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    local version
    version=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "null")
    TECH_DETECTED[docker]="true"
    TECH_VERSION[docker]="$version"
    TECH_METHOD[docker]="docker info"
    ENGINES_TO_INVOKE+=("docker")
    printf "%-16s %-14s %s\n" "[DETECTED]" "docker" "$version"
    return
  fi

  # Method 2: Docker socket check
  if test -S /var/run/docker.sock 2>/dev/null; then
    TECH_NOTES[docker]="Docker socket found but docker info failed — daemon may be starting"
    printf "%-16s %-14s %s\n" "[NOT DETECTED]" "docker" "socket found but daemon unreachable"
    return
  fi

  printf "%-16s %s\n" "[NOT DETECTED]" "docker"
}

# =============================================================================
# DETECTION: KUBERNETES
# =============================================================================

detect_kubernetes() {
  TECH_METHOD[kubernetes]="null"
  TECH_VERSION[kubernetes]="null"
  TECH_NOTES[kubernetes]="null"
  TECH_DETECTED[kubernetes]="false"

  local found_components=()
  local not_found_components=()

  # Method 1: kubelet via systemctl
  if command -v systemctl &>/dev/null && systemctl is-active --quiet kubelet 2>/dev/null; then
    found_components+=("kubelet")
  else
    not_found_components+=("kubelet not active")
  fi

  # Method 2: kube-apiserver via pgrep
  if pgrep -x kube-apiserver &>/dev/null; then
    found_components+=("kube-apiserver")
  else
    not_found_components+=("kube-apiserver not found")
  fi

  # Method 3: kubectl cluster connectivity
  if command -v kubectl &>/dev/null && kubectl cluster-info &>/dev/null 2>&1; then
    found_components+=("kubectl")
  else
    not_found_components+=("kubectl unreachable")
  fi

  if [[ ${#found_components[@]} -eq 0 ]]; then
    TECH_NOTES[kubernetes]="$(IFS=', '; echo "${not_found_components[*]}")"
    TECH_METHOD[kubernetes]="systemctl, pgrep, kubectl"
    printf "%-16s %-14s %s\n" "[NOT DETECTED]" "kubernetes" "$(IFS=', '; echo "${not_found_components[*]}")"
    return
  fi

  # Version detection
  local version="null"
  if command -v kubectl &>/dev/null; then
    version=$(kubectl version --client --short 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "null")
  elif command -v kubelet &>/dev/null; then
    version=$(kubelet --version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "null")
  fi

  TECH_DETECTED[kubernetes]="true"
  TECH_VERSION[kubernetes]="$version"
  TECH_METHOD[kubernetes]="systemctl, pgrep, kubectl"
  TECH_NOTES[kubernetes]="Components found: $(IFS=', '; echo "${found_components[*]}")"
  ENGINES_TO_INVOKE+=("kubernetes")
  printf "%-16s %-14s %s\n" "[DETECTED]" "kubernetes" "$version"
}

# =============================================================================
# RUN DETECTION
# =============================================================================

# OS detection: Ubuntu and Rocky Linux are mutually exclusive
detect_ubuntu
detect_rocky

# Non-OS technologies are evaluated independently
detect_postgresql
detect_docker
detect_kubernetes

echo ""

# =============================================================================
# ENGINE INVOCATION ORDER
# Priority: OS → PostgreSQL → Docker → Kubernetes
# =============================================================================

ORDERED_ENGINES=()

for tech in ubuntu rocky_linux postgresql docker kubernetes; do
  for engine in "${ENGINES_TO_INVOKE[@]}"; do
    if [[ "$engine" == "$tech" ]]; then
      ORDERED_ENGINES+=("$tech")
    fi
  done
done

# =============================================================================
# JSON OUTPUT
# =============================================================================

# Build engines_to_invoke JSON array
engines_json="["
for i in "${!ORDERED_ENGINES[@]}"; do
  engines_json+="\"${ORDERED_ENGINES[$i]}\""
  if [[ $i -lt $(( ${#ORDERED_ENGINES[@]} - 1 )) ]]; then
    engines_json+=", "
  fi
done
engines_json+="]"

cat > "$OUTPUT_FILE" <<EOF
{
  "hardenx_version": "$HARDENX_VERSION",
  "scan_id": "$SCAN_ID",
  "timestamp": "$TIMESTAMP",
  "hostname": "$(json_escape "$HOSTNAME")",
  "technologies": {
    "ubuntu": {
      $(json_field "detected" "${TECH_DETECTED[ubuntu]}"),
      $(json_field "version" "${TECH_VERSION[ubuntu]}"),
      $(json_field "detection_method" "${TECH_METHOD[ubuntu]}"),
      $(json_field "notes" "${TECH_NOTES[ubuntu]}")
    },
    "rocky_linux": {
      $(json_field "detected" "${TECH_DETECTED[rocky_linux]}"),
      $(json_field "version" "${TECH_VERSION[rocky_linux]}"),
      $(json_field "detection_method" "${TECH_METHOD[rocky_linux]}"),
      $(json_field "notes" "${TECH_NOTES[rocky_linux]}")
    },
    "postgresql": {
      $(json_field "detected" "${TECH_DETECTED[postgresql]}"),
      $(json_field "version" "${TECH_VERSION[postgresql]}"),
      $(json_field "detection_method" "${TECH_METHOD[postgresql]}"),
      $(json_field "notes" "${TECH_NOTES[postgresql]}")
    },
    "docker": {
      $(json_field "detected" "${TECH_DETECTED[docker]}"),
      $(json_field "version" "${TECH_VERSION[docker]}"),
      $(json_field "detection_method" "${TECH_METHOD[docker]}"),
      $(json_field "notes" "${TECH_NOTES[docker]}")
    },
    "kubernetes": {
      $(json_field "detected" "${TECH_DETECTED[kubernetes]}"),
      $(json_field "version" "${TECH_VERSION[kubernetes]}"),
      $(json_field "detection_method" "${TECH_METHOD[kubernetes]}"),
      $(json_field "notes" "${TECH_NOTES[kubernetes]}")
    }
  },
  "engines_to_invoke": $engines_json
}
EOF

# Fix detected boolean values — JSON booleans must not be quoted
sed -i 's/"detected": "true"/"detected": true/g' "$OUTPUT_FILE"
sed -i 's/"detected": "false"/"detected": false/g' "$OUTPUT_FILE"

# =============================================================================
# SUMMARY BLOCK
# =============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " DETECTION SUMMARY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ ${#ORDERED_ENGINES[@]} -eq 0 ]]; then
  echo "  Technologies detected   : none"
  echo ""
  echo "  No supported technologies were found running on this host."
  echo "  No engines will be invoked. HardenX will exit."
else
  echo "  Technologies detected   : $(IFS=', '; echo "${ORDERED_ENGINES[*]}")"
  echo "  Engines to be invoked   : $(IFS=', '; echo "${ORDERED_ENGINES[*]}")"
fi

echo ""
echo "  Detection report saved to: $(basename "$OUTPUT_FILE")"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# =============================================================================
# EXIT
# =============================================================================

# If no engines to invoke, exit with code 3 so hardenx.sh can handle cleanly
if [[ ${#ORDERED_ENGINES[@]} -eq 0 ]]; then
  exit 3
fi

exit 0