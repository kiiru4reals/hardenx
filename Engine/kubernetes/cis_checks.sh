#!/usr/bin/env bash
# =============================================================================
#  HardenX — Kubernetes CIS Benchmark Engine
#  Component  : engine/kubernetes.sh
#  Benchmark  : CIS Kubernetes Benchmark v1.9.0 (via kube-bench v0.8.0)
#  Scope      : Control Plane (v1) — kube-apiserver, etcd, controller-manager,
#               scheduler
#  Version    : 0.1
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
readonly HARDENX_VERSION="0.1"
readonly KUBE_BENCH_VERSION="v0.8.0"
readonly KUBE_BENCH_IMAGE="aquasec/kube-bench:${KUBE_BENCH_VERSION}"
readonly KUBE_BENCH_DEB="kube-bench_0.8.0_linux_amd64.deb"
readonly KUBE_BENCH_RPM="kube-bench_0.8.0_linux_amd64.rpm"
readonly KUBE_BENCH_BASE_URL="https://github.com/aquasecurity/kube-bench/releases/download/${KUBE_BENCH_VERSION}"
readonly KUBE_BENCH_TARGETS="master,etcd,controlplane,policies"
readonly JOB_NAME="hardenx-kube-bench"
readonly JOB_TIMEOUT="120s"
readonly SEPARATOR="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
readonly THIN_SEP="──────────────────"

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------
LEVEL=1
KUBECONFIG_PATH=""
NAMESPACE="kube-system"
KUBE_BENCH_IMAGE_OVERRIDE=""
OUTPUT_DIR="."
SCAN_ID=""

# Runtime state
MODE=""                    # binary | job | install
OS_TYPE=""                 # ubuntu | rocky
KUBE_BENCH_INSTALLED=false # tracks whether Install Mode placed the binary
KUBECONFIG_FOUND=false
API_REACHABLE=false
OS_REPORT_PATH=""
SECTION5_SKIP_REASON=""
OS_DEPENDENT_SKIP_REASON="OS engine under maintenance"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H%M")
RAW_JSON="/tmp/hardenx_kubebench_${TIMESTAMP}.json"

# Result counters
COUNT_PASS=0
COUNT_FAIL=0
COUNT_MANUAL=0
COUNT_SKIPPED=0
COUNT_NA=0

# Scoring accumulators — per section (pass|fail counts)
declare -A SECTION_PASS
declare -A SECTION_FAIL
declare -A SECTION_TITLE

# -----------------------------------------------------------------------------
# Trap — fires on SIGINT, SIGTERM, or EXIT when KUBE_BENCH_INSTALLED=true
# or MODE=job
# -----------------------------------------------------------------------------
_teardown() {
  local exit_code=$?
  echo ""
  if [[ "${MODE}" == "job" ]]; then
    echo "[TEARDOWN] Deleting kube-bench Job from cluster..."
    if kubectl delete job "${JOB_NAME}" \
        --namespace "${NAMESPACE}" \
        --kubeconfig "${KUBECONFIG_PATH}" \
        --ignore-not-found \
        > /dev/null 2>&1; then
      echo "           ✓ Deleted: ${JOB_NAME} (namespace: ${NAMESPACE})"
    else
      echo "[WARN] Failed to delete kube-bench Job automatically."
      echo "       To clean up manually, run:"
      echo "         kubectl delete job ${JOB_NAME} -n ${NAMESPACE}"
    fi
  fi

  if [[ "${KUBE_BENCH_INSTALLED}" == "true" ]]; then
    echo "[TEARDOWN] Uninstalling kube-bench..."
    if [[ "${OS_TYPE}" == "ubuntu" ]]; then
      apt-get remove -y kube-bench > /dev/null 2>&1 && \
        echo "           ✓ kube-bench removed." || \
        echo "[WARN] Failed to uninstall kube-bench automatically.
       To remove it manually, run:
         apt-get remove -y kube-bench"
    elif [[ "${OS_TYPE}" == "rocky" ]]; then
      dnf remove -y kube-bench > /dev/null 2>&1 && \
        echo "           ✓ kube-bench removed." || \
        echo "[WARN] Failed to uninstall kube-bench automatically.
       To remove it manually, run:
         dnf remove -y kube-bench"
    fi
  fi

  if [[ -f "${RAW_JSON}" ]]; then
    echo "[TEARDOWN] Raw kube-bench output: ${RAW_JSON}"
  fi
  echo "[TEARDOWN] Done."
  exit "${exit_code}"
}

trap '_teardown' SIGINT SIGTERM

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
_print_header() {
  local hostname
  hostname=$(hostname 2>/dev/null || echo "unknown")
  local mode_label
  case "${MODE}" in
    binary)  mode_label="Binary" ;;
    job)     mode_label="Job" ;;
    install) mode_label="Install" ;;
    *)       mode_label="Auto-detecting..." ;;
  esac

  echo "${SEPARATOR}"
  echo " HardenX — Kubernetes CIS Benchmark Engine"
  echo " Benchmark : CIS Kubernetes Benchmark v1.9.0"
  echo " Scope     : Control Plane (v1)"
  echo " Scan ID   : ${SCAN_ID}"
  echo " Host      : ${hostname}"
  echo " Level     : ${LEVEL}"
  echo " Mode      : ${mode_label}"
  echo "${SEPARATOR}"
}

_print_help() {
  echo "${SEPARATOR}"
  echo " HardenX — Kubernetes CIS Benchmark Engine"
  echo " Benchmark : CIS Kubernetes Benchmark v1.9.0"
  echo " Scope     : Control Plane (v1)"
  echo "${SEPARATOR}"
  cat <<'EOF'

USAGE
  bash engine/kubernetes.sh [OPTIONS]

OPTIONS
  --level <1|2>
      Scan level to run.
      Level 1 — Scored checks only (essential, foundational controls). (default)
      Level 2 — All checks, including unscored advisory controls.
                Includes all Level 1 checks.

  --kubeconfig <path>
      Path to the kubeconfig file used for API-dependent checks (Section 5)
      and for deploying the kube-bench Job when running in Job Mode.
      Defaults to /etc/kubernetes/admin.conf, then ~/.kube/config.
      If omitted and neither default is found, Section 5 checks are SKIPPED
      and Job Mode is unavailable.
      Example: --kubeconfig /home/ops/.kube/config

  --namespace <ns>
      Kubernetes namespace for the kube-bench Job in Job Mode.
      Applies to Job Mode only. Ignored in Binary Mode and Install Mode.
      Defaults to kube-system.
      Example: --namespace hardenx

  --kube-bench-image <image:tag>
      Container image for the kube-bench Job in Job Mode.
      Defaults to aquasec/kube-bench:v0.8.0.
      Use this to point Job Mode at an internal registry mirror in
      air-gapped or restricted-egress environments.
      Applies to Job Mode only. Ignored in Binary Mode and Install Mode.
      Example: --kube-bench-image registry.acme.internal/kube-bench:v0.8.0

  --output-dir <path>
      Directory to write all output files.
      Defaults to the current directory if not specified.

  --help
      Display this help menu and exit.

DEFAULTS
  If invoked with no arguments:
    --level 1  --namespace kube-system  --output-dir .
    (kubeconfig auto-detected, image: aquasec/kube-bench:v0.8.0)

EXAMPLES
  Run a Level 1 scan with auto-detected kubeconfig:
    bash engine/kubernetes.sh

  Run a Level 2 scan with an explicit kubeconfig:
    bash engine/kubernetes.sh --level 2 --kubeconfig /etc/kubernetes/admin.conf

  Run a Level 1 scan in Job Mode using a custom namespace:
    bash engine/kubernetes.sh --namespace hardenx

  Run Job Mode against an internal registry mirror (air-gapped):
    bash engine/kubernetes.sh --kube-bench-image registry.acme.internal/kube-bench:v0.8.0

  Run a Level 1 scan and write output to a specific directory:
    bash engine/kubernetes.sh --output-dir /opt/hardenx/output

NOTES
  - sudo or root access is required in Binary Mode and Install Mode.
  - Job Mode requires RBAC permissions to create/delete Jobs and read pod
    logs in the target namespace.
  - kube-bench mode is selected automatically:
      1. Binary in PATH  →  Binary Mode
      2. kubectl + API   →  Job Mode
      3. apt or dnf      →  Install Mode (prompts for consent)
  - Report output: hardenx_kubernetes_<timestamp>.csv

EOF
  echo "${SEPARATOR}"
}

_info()    { echo "[INFO]     $*"; }
_warn()    { echo "[WARN]     $*"; }
_error()   { echo "[ERROR]    $*"; }
_install() { echo "[INSTALL]  $*"; }

# Print a single check result line to console
_print_check() {
  local status="$1"
  local check_id="$2"
  local description="$3"
  local skip_reason="${4:-}"

  local label
  case "${status}" in
    PASS)          label="[PASS]          " ;;
    FAIL)          label="[FAIL]          " ;;
    MANUAL_REVIEW) label="[MANUAL_REVIEW] " ;;
    SKIPPED)       label="[SKIPPED: ${skip_reason}]" ;;
    N/A)           label="[N/A]           " ;;
    *)             label="[${status}]     " ;;
  esac

  echo "  ${label}  ${check_id}  ${description}"
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
_parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --level)
        LEVEL="${2:?'--level requires a value (1 or 2)'}"
        if [[ "${LEVEL}" != "1" && "${LEVEL}" != "2" ]]; then
          _error "Invalid value for --level: \"${LEVEL}\". Valid values: 1 | 2"
          exit 1
        fi
        shift 2
        ;;
      --kubeconfig)
        KUBECONFIG_PATH="${2:?'--kubeconfig requires a path'}"
        shift 2
        ;;
      --namespace)
        NAMESPACE="${2:?'--namespace requires a value'}"
        shift 2
        ;;
      --kube-bench-image)
        KUBE_BENCH_IMAGE_OVERRIDE="${2:?'--kube-bench-image requires an image:tag value'}"
        shift 2
        ;;
      --output-dir)
        OUTPUT_DIR="${2:?'--output-dir requires a path'}"
        shift 2
        ;;
      --scan-id)
        # Internal flag — passed by hardenx.sh to share scan_id across components
        SCAN_ID="${2:?'--scan-id requires a value'}"
        shift 2
        ;;
      --help)
        _print_help
        exit 0
        ;;
      *)
        _error "Unrecognised argument: \"$1\""
        echo "       Run with --help for usage information."
        exit 1
        ;;
    esac
  done

  # Generate scan_id if not provided by orchestrator
  if [[ -z "${SCAN_ID}" ]]; then
    SCAN_ID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "no-uuid-$(date +%s)")
  fi
}

# -----------------------------------------------------------------------------
# Pre-flight: 1 — Control plane detection
# -----------------------------------------------------------------------------
_preflight_control_plane() {
  if ! pgrep -x kube-apiserver > /dev/null 2>&1; then
    _error "No control plane detected on this host."
    echo "        kube-apiserver is not running. This engine targets control"
    echo "        plane nodes only."
    echo ""
    echo "        If this is a worker node, worker node checks are outside the"
    echo "        scope of the v1 Kubernetes Engine. If you expected a control"
    echo "        plane to be running, verify the cluster status before re-running."
    echo ""
    echo "        No checks were run. No report has been generated."
    exit 1
  fi
  _info "Control plane detected (kube-apiserver is running)."
}

# -----------------------------------------------------------------------------
# Pre-flight: 2 — kubeconfig lookup
# -----------------------------------------------------------------------------
_preflight_kubeconfig() {
  local candidates=()

  # Operator-specified path takes priority
  if [[ -n "${KUBECONFIG_PATH}" ]]; then
    candidates=("${KUBECONFIG_PATH}")
  else
    candidates=(
      "/etc/kubernetes/admin.conf"
      "${HOME}/.kube/config"
    )
  fi

  for candidate in "${candidates[@]}"; do
    if [[ -f "${candidate}" ]]; then
      KUBECONFIG_PATH="${candidate}"
      KUBECONFIG_FOUND=true
      _info "kubeconfig found: ${KUBECONFIG_PATH}"
      return
    fi
  done

  KUBECONFIG_FOUND=false
  SECTION5_SKIP_REASON="No kubeconfig found"
  _warn "No kubeconfig found at default locations and --kubeconfig was not provided."
  echo "       Section 5 (Policies) checks will be marked SKIPPED."
  echo "       Checks in Sections 1, 2, and 3 will proceed as normal."
  echo ""
  echo "       To enable Section 5 checks, provide a kubeconfig with:"
  echo "         --kubeconfig <path>"
}

# -----------------------------------------------------------------------------
# Pre-flight: 3 — API connectivity
# -----------------------------------------------------------------------------
_preflight_api() {
  if [[ "${KUBECONFIG_FOUND}" == "false" ]]; then
    API_REACHABLE=false
    return
  fi

  if kubectl cluster-info --kubeconfig "${KUBECONFIG_PATH}" > /dev/null 2>&1; then
    API_REACHABLE=true
    _info "Cluster API is reachable."
  else
    API_REACHABLE=false
    SECTION5_SKIP_REASON="kubectl cannot reach the cluster API"
    _warn "kubectl cannot reach the cluster API using: ${KUBECONFIG_PATH}"
    echo "       Section 5 (Policies) checks will be marked SKIPPED."
    echo "       Checks in Sections 1, 2, and 3 will proceed as normal."
  fi
}

# -----------------------------------------------------------------------------
# Pre-flight: 4 — OS engine report lookup
# -----------------------------------------------------------------------------
_preflight_os_report() {
  local ubuntu_report rocky_report
  ubuntu_report=$(find "${OUTPUT_DIR}" -maxdepth 1 -name "hardenx_ubuntu_*.csv" 2>/dev/null | sort | tail -1)
  rocky_report=$(find "${OUTPUT_DIR}" -maxdepth 1 -name "hardenx_rocky_*.csv" 2>/dev/null | sort | tail -1)

  if [[ -n "${ubuntu_report}" ]]; then
    OS_REPORT_PATH="${ubuntu_report}"
    _info "Ubuntu OS engine report found: ${OS_REPORT_PATH}"
  elif [[ -n "${rocky_report}" ]]; then
    OS_REPORT_PATH="${rocky_report}"
    _info "Rocky Linux OS engine report found: ${OS_REPORT_PATH}"
  else
    OS_REPORT_PATH=""
    OS_DEPENDENT_SKIP_REASON="OS engine under maintenance"
    _warn "No OS engine report found in output directory."
    echo "       OS_DEPENDENT checks will be marked SKIPPED: ${OS_DEPENDENT_SKIP_REASON}"
  fi
}

# -----------------------------------------------------------------------------
# Pre-flight: 5 — kube-bench availability and mode selection
# -----------------------------------------------------------------------------
_preflight_mode_select() {
  # Priority 1: binary in PATH
  if command -v kube-bench > /dev/null 2>&1; then
    MODE="binary"
    _info "kube-bench binary found. Running in Binary Mode."
    return
  fi

  _info "kube-bench binary not found in PATH."

  # Priority 2: Job Mode — needs kubectl and reachable API
  if command -v kubectl > /dev/null 2>&1 && [[ "${API_REACHABLE}" == "true" ]]; then
    MODE="job"
    _info "kubectl is available and cluster API is reachable."
    _info "Switching to Job Mode — kube-bench will be deployed as a Kubernetes Job."
    return
  fi

  _info "Job Mode unavailable — kubectl cannot reach the cluster API."

  # Priority 3: Install Mode — needs a TTY, package manager, and download tool
  local pkg_manager="" download_tool=""

  if command -v apt-get > /dev/null 2>&1; then
    pkg_manager="apt"
    OS_TYPE="ubuntu"
  elif command -v dnf > /dev/null 2>&1; then
    pkg_manager="dnf"
    OS_TYPE="rocky"
  fi

  if command -v curl > /dev/null 2>&1; then
    download_tool="curl"
  elif command -v wget > /dev/null 2>&1; then
    download_tool="wget"
  fi

  if [[ -n "${pkg_manager}" && -n "${download_tool}" ]]; then
    # Check for interactive TTY — required for consent prompt
    if [[ ! -t 0 ]]; then
      _error "kube-bench cannot be run on this host."
      echo ""
      echo "        Install Mode was selected but the engine is running"
      echo "        non-interactively (no TTY). Operator consent cannot be"
      echo "        obtained without an interactive terminal."
      echo ""
      echo "        To resolve, either:"
      echo "          - Install kube-bench manually: https://github.com/aquasecurity/kube-bench"
      echo "          - Run this engine in an interactive terminal session."
      echo ""
      echo "        No checks were run. No report has been generated."
      exit 1
    fi
    MODE="install"
    _info "Supported package manager (${pkg_manager}) and download tool (${download_tool}) detected."
    _info "Switching to Install Mode — kube-bench will be installed, used, then removed."
    return
  fi

  # No viable mode
  _error "kube-bench cannot be run on this host."
  echo ""
  echo "        - Binary not found in PATH."
  echo "        - Job Mode unavailable: no kubeconfig or cluster API unreachable."
  echo "        - Install Mode unavailable: no supported package manager (checked: apt, dnf)"
  echo "          or no download tool available (checked: curl, wget)."
  echo ""
  echo "        To resolve, either:"
  echo "          - Install kube-bench manually: https://github.com/aquasecurity/kube-bench"
  echo "          - Provide a valid kubeconfig: --kubeconfig <path>"
  echo "          - If running Job Mode in an air-gapped environment, mirror the kube-bench"
  echo "            image to an internal registry and pass it with:"
  echo "            --kube-bench-image registry.acme.internal/kube-bench:v0.8.0"
  echo ""
  echo "        No checks were run. No report has been generated."
  exit 1
}

# -----------------------------------------------------------------------------
# Run all pre-flight checks
# -----------------------------------------------------------------------------
_run_preflight() {
  echo ""
  echo "  Running pre-flight checks..."
  echo ""
  _preflight_control_plane
  _preflight_kubeconfig
  _preflight_api
  _preflight_os_report
  _preflight_mode_select
  echo ""
}

# -----------------------------------------------------------------------------
# kube-bench execution: Binary Mode
# -----------------------------------------------------------------------------
_exec_binary() {
  _info "Running kube-bench (Binary Mode)..."
  if ! kube-bench run \
      --targets "${KUBE_BENCH_TARGETS}" \
      --json \
      > "${RAW_JSON}" 2>&1; then
    local exit_code=$?
    _error "kube-bench exited with a non-zero status (exit code: ${exit_code})."
    echo "        The Kubernetes scan cannot continue."
    echo "        Review the kube-bench output above for details."
    echo "        Scan ID: ${SCAN_ID}"
    echo ""
    echo "        No report has been generated."
    rm -f "${RAW_JSON}"
    exit 1
  fi
  _info "kube-bench complete. Raw output: ${RAW_JSON}"
}

# -----------------------------------------------------------------------------
# kube-bench execution: Job Mode
# -----------------------------------------------------------------------------
_exec_job() {
  local image="${KUBE_BENCH_IMAGE_OVERRIDE:-${KUBE_BENCH_IMAGE}}"

  _info "Generating kube-bench Job manifest (image: ${image})..."

  local manifest
  manifest=$(cat <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: hardenx
    scan-id: "${SCAN_ID}"
spec:
  template:
    spec:
      hostPID: true
      hostIPC: true
      hostNetwork: true
      restartPolicy: Never
      nodeSelector:
        node-role.kubernetes.io/control-plane: ""
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
        - key: node-role.kubernetes.io/master
          operator: Exists
          effect: NoSchedule
      volumes:
        - name: var-lib-etcd
          hostPath:
            path: /var/lib/etcd
        - name: etc-kubernetes
          hostPath:
            path: /etc/kubernetes
        - name: etc-systemd
          hostPath:
            path: /etc/systemd
        - name: usr-lib-systemd
          hostPath:
            path: /usr/lib/systemd
        - name: etc-cni-netd
          hostPath:
            path: /etc/cni/net.d/
      containers:
        - name: kube-bench
          image: ${image}
          command:
            - kube-bench
            - run
            - --targets
            - ${KUBE_BENCH_TARGETS}
            - --json
          volumeMounts:
            - name: var-lib-etcd
              mountPath: /var/lib/etcd
              readOnly: true
            - name: etc-kubernetes
              mountPath: /etc/kubernetes
              readOnly: true
            - name: etc-systemd
              mountPath: /etc/systemd
              readOnly: true
            - name: usr-lib-systemd
              mountPath: /usr/lib/systemd
              readOnly: true
            - name: etc-cni-netd
              mountPath: /etc/cni/net.d/
              readOnly: true
EOF
  )

  _info "Deploying Job to cluster (namespace: ${NAMESPACE})..."
  if ! echo "${manifest}" | kubectl apply -f - \
      --kubeconfig "${KUBECONFIG_PATH}" > /dev/null 2>&1; then
    _error "Failed to deploy kube-bench Job."
    echo "        Namespace : ${NAMESPACE}"
    echo "        Scan ID   : ${SCAN_ID}"
    echo ""
    echo "        Ensure the kubeconfig has permissions to create Jobs in"
    echo "        namespace ${NAMESPACE}:"
    echo "          Required: create/get/delete jobs, get/list pods, get pods/log"
    echo ""
    echo "        No checks were run. No report has been generated."
    exit 1
  fi

  _info "kube-bench Job deployed: ${JOB_NAME} (namespace: ${NAMESPACE})"
  _info "Waiting for Job to complete (timeout: ${JOB_TIMEOUT})..."

  if ! kubectl wait "job/${JOB_NAME}" \
      --namespace "${NAMESPACE}" \
      --for=condition=complete \
      --timeout="${JOB_TIMEOUT}" \
      --kubeconfig "${KUBECONFIG_PATH}" > /dev/null 2>&1; then
    _error "kube-bench Job did not complete successfully."
    echo "        Status    : Failed or timed out after ${JOB_TIMEOUT}"
    echo "        Job       : ${JOB_NAME}"
    echo "        Namespace : ${NAMESPACE}"
    echo "        Scan ID   : ${SCAN_ID}"
    echo ""
    echo "        If the pod failed due to an image pull error (ErrImagePull /"
    echo "        ImagePullBackOff), the cluster cannot reach the default registry."
    echo "        Mirror the image to an internal registry and retry with:"
    echo "          --kube-bench-image registry.acme.internal/kube-bench:v0.8.0"
    echo ""
    echo "        To investigate, re-run with verbose kubectl output or inspect"
    echo "        pod events in the ${NAMESPACE} namespace."
    echo ""
    echo "        The Job has been deleted. No report has been generated."
    kubectl delete job "${JOB_NAME}" \
      --namespace "${NAMESPACE}" \
      --kubeconfig "${KUBECONFIG_PATH}" \
      --ignore-not-found > /dev/null 2>&1 || true
    exit 1
  fi

  _info "Job complete. Retrieving results..."
  if ! kubectl logs "job/${JOB_NAME}" \
      --namespace "${NAMESPACE}" \
      --kubeconfig "${KUBECONFIG_PATH}" \
      > "${RAW_JSON}" 2>&1; then
    _error "Failed to retrieve kube-bench Job logs."
    echo "        Job    : ${JOB_NAME}"
    echo "        Scan ID: ${SCAN_ID}"
    echo ""
    echo "        No report has been generated."
    exit 1
  fi

  _info "Results written to: ${RAW_JSON}"

  # Cleanup — also handled by trap but we clean up eagerly here
  _info "Deleting kube-bench Job..."
  kubectl delete job "${JOB_NAME}" \
    --namespace "${NAMESPACE}" \
    --kubeconfig "${KUBECONFIG_PATH}" \
    --ignore-not-found > /dev/null 2>&1 || true
  # Prevent double-deletion in trap
  MODE="binary"
}

# -----------------------------------------------------------------------------
# kube-bench execution: Install Mode
# -----------------------------------------------------------------------------
_exec_install() {
  local hostname
  hostname=$(hostname 2>/dev/null || echo "unknown")

  # Detect OS if not already set (fallback in case Researcher JSON not present)
  if [[ -z "${OS_TYPE}" ]]; then
    if [[ -f /etc/os-release ]]; then
      source /etc/os-release 2>/dev/null || true
      case "${ID:-}" in
        ubuntu) OS_TYPE="ubuntu" ;;
        rocky)  OS_TYPE="rocky"  ;;
        *)
          _error "Install Mode: unrecognised OS (ID=${ID:-unknown})."
          echo "        Supported: ubuntu, rocky."
          echo "        Install kube-bench manually: https://github.com/aquasecurity/kube-bench"
          echo ""
          echo "        No checks were run. No report has been generated."
          exit 1
          ;;
      esac
    fi
  fi

  # Determine download tool
  local download_tool=""
  if command -v curl > /dev/null 2>&1; then
    download_tool="curl"
  elif command -v wget > /dev/null 2>&1; then
    download_tool="wget"
  fi

  # Consent prompt
  echo ""
  echo "${SEPARATOR}"
  echo " [INSTALL] kube-bench was not found on this host."
  echo "           HardenX can install it automatically to complete this scan,"
  echo "           then remove it once the scan is finished."
  echo ""
  echo "           Package : kube-bench ${KUBE_BENCH_VERSION}"
  echo "           Source  : ${KUBE_BENCH_BASE_URL}"
  echo "           Host    : ${hostname}"
  echo "${SEPARATOR}"
  echo ""
  read -r -p "  Proceed with installation? [y/N]: " consent
  echo ""

  if [[ "${consent}" != "y" && "${consent}" != "Y" ]]; then
    _info "Installation cancelled by operator. No changes were made to this host."
    echo "       No checks were run. No report has been generated."
    exit 0
  fi

  # Download
  local package_file url
  if [[ "${OS_TYPE}" == "ubuntu" ]]; then
    package_file="${KUBE_BENCH_DEB}"
    url="${KUBE_BENCH_BASE_URL}/${KUBE_BENCH_DEB}"
  else
    package_file="${KUBE_BENCH_RPM}"
    url="${KUBE_BENCH_BASE_URL}/${KUBE_BENCH_RPM}"
  fi

  _install "Downloading kube-bench ${KUBE_BENCH_VERSION} for linux/amd64..."
  if [[ "${download_tool}" == "curl" ]]; then
    if ! curl -fsSL -o "/tmp/${package_file}" "${url}"; then
      _error "Failed to download kube-bench from GitHub."
      echo "        URL    : ${url}"
      echo "        Tool   : curl"
      echo "        Reason : curl exited with non-zero status"
      echo ""
      echo "        Check outbound internet access to github.com and try again."
      echo "        Alternatively, install kube-bench manually before running this engine."
      echo ""
      echo "        No checks were run. No report has been generated."
      exit 1
    fi
  else
    if ! wget -q -O "/tmp/${package_file}" "${url}"; then
      _error "Failed to download kube-bench from GitHub."
      echo "        URL    : ${url}"
      echo "        Tool   : wget"
      echo "        Reason : wget exited with non-zero status"
      echo ""
      echo "        Check outbound internet access to github.com and try again."
      echo "        Alternatively, install kube-bench manually before running this engine."
      echo ""
      echo "        No checks were run. No report has been generated."
      exit 1
    fi
  fi

  # Install
  _install "Installing package..."
  if [[ "${OS_TYPE}" == "ubuntu" ]]; then
    if ! apt-get install -y "/tmp/${package_file}" > /dev/null 2>&1; then
      _error "Package installation failed."
      echo "        Package: /tmp/${package_file}"
      echo ""
      echo "        No checks were run. No report has been generated."
      rm -f "/tmp/${package_file}"
      exit 1
    fi
  else
    if ! dnf install -y "/tmp/${package_file}" > /dev/null 2>&1; then
      _error "Package installation failed."
      echo "        Package: /tmp/${package_file}"
      echo ""
      echo "        No checks were run. No report has been generated."
      rm -f "/tmp/${package_file}"
      exit 1
    fi
  fi

  rm -f "/tmp/${package_file}"
  KUBE_BENCH_INSTALLED=true
  _install "kube-bench installed successfully."
  _install "Note: kube-bench will be uninstalled at the end of this scan."
  echo ""

  # Run as binary now that it is installed
  _exec_binary
}

# -----------------------------------------------------------------------------
# Result parsing — reads RAW_JSON and builds findings arrays
# -----------------------------------------------------------------------------
# Each finding is stored as:
#   FINDINGS_ID[n]          check id
#   FINDINGS_DESC[n]        description
#   FINDINGS_STATUS[n]      PASS|FAIL|MANUAL_REVIEW|SKIPPED|N/A
#   FINDINGS_REMEDIATION[n] remediation text
#   FINDINGS_SECTION[n]     section number (e.g. "1.2")
#   FINDINGS_SCORED[n]      true|false
declare -a FINDINGS_ID=()
declare -a FINDINGS_DESC=()
declare -a FINDINGS_STATUS=()
declare -a FINDINGS_REMEDIATION=()
declare -a FINDINGS_SECTION=()
declare -a FINDINGS_SCORED=()

_parse_results() {
  _info "Parsing kube-bench results..."

  if [[ ! -f "${RAW_JSON}" ]]; then
    _error "Raw JSON not found at ${RAW_JSON}. Cannot parse results."
    exit 1
  fi

  # Use python3 to parse the kube-bench JSON — more reliable than jq for
  # multi-line fields and nested structures
  if ! command -v python3 > /dev/null 2>&1; then
    _error "python3 is required to parse kube-bench JSON output but was not found."
    echo "        Install python3 and re-run."
    exit 1
  fi

  local parsed_tsv
  parsed_tsv=$(python3 - "${RAW_JSON}" <<'PYEOF'
import json, sys, re

def clean(s):
    """Collapse whitespace and strip for TSV safety."""
    return re.sub(r'[\t\r\n]+', ' ', str(s or '')).strip()

def iter_json_objects(path):
    """
    kube-bench writes one JSON object per target, concatenated in the same
    file — e.g. {"Controls":[...]}{"Controls":[...]}
    json.load() cannot handle this; raw_decode walks the file correctly.
    """
    with open(path) as f:
        content = f.read()
    decoder = json.JSONDecoder()
    pos = 0
    while pos < len(content):
        # Skip whitespace between objects
        while pos < len(content) and content[pos] in ' \t\n\r':
            pos += 1
        if pos >= len(content):
            break
        obj, end = decoder.raw_decode(content, pos)
        yield obj
        pos = end

for root in iter_json_objects(sys.argv[1]):
    # kube-bench v0.8.0 wraps results in a "Controls" key:
    #   {"Controls": [{...}, {...}]}
    # Older versions may return a bare list or bare object — handle all forms.
    if isinstance(root, list):
        controls_list = root
    elif isinstance(root, dict) and 'Controls' in root:
        controls_list = root['Controls'] or []
    else:
        controls_list = [root]

    for controls in controls_list:
        section_id    = clean(controls.get('id', ''))
        section_title = clean(controls.get('text', '') or controls.get('desc', ''))

        # Skip any entry with no section id (e.g. summary nodes)
        if not section_id:
            continue

        tests = controls.get('tests', []) or []
        for test_group in tests:
            group_id = clean(test_group.get('section', ''))
            results  = test_group.get('results', []) or []
            for result in results:
                check_id    = clean(result.get('test_number', ''))
                description = clean(result.get('test_desc', ''))
                kb_status   = clean(result.get('status', '')).upper()
                remediation = clean(result.get('remediation', ''))
                scored      = str(result.get('scored', True)).lower()

                # Skip results with no check id
                if not check_id:
                    continue

                # Map kube-bench status to HardenX status
                if kb_status == 'PASS':
                    status = 'PASS'
                    remediation = ''
                elif kb_status == 'FAIL':
                    status = 'FAIL'
                elif kb_status in ('WARN', 'INFO'):
                    status = 'MANUAL_REVIEW'
                    remediation = '[MANUAL REVIEW REQUIRED] ' + remediation
                else:
                    status = 'MANUAL_REVIEW'
                    remediation = '[MANUAL REVIEW REQUIRED] ' + remediation

                print('\t'.join([
                    check_id, description, status, remediation,
                    section_id, group_id, scored, section_title
                ]))
PYEOF
  )

  if [[ $? -ne 0 ]]; then
    _error "Failed to parse kube-bench JSON output."
    echo "        Raw output: ${RAW_JSON}"
    echo "        Error: ${parsed_tsv}"
    exit 1
  fi

  local idx=0
  while IFS=$'\t' read -r check_id desc status remediation section_id group_id scored section_title; do
    # Apply level filter — Level 1 = scored only, Level 2 = all
    if [[ "${LEVEL}" == "1" && "${scored}" == "false" ]]; then
      continue
    fi

    # Section 5 skip logic
    if [[ "${section_id}" == "5" && -n "${SECTION5_SKIP_REASON}" ]]; then
      status="SKIPPED"
      remediation="${SECTION5_SKIP_REASON}"
    fi

    # OS_DEPENDENT override — audit rule checks (section 1.1 file permission checks
    # that depend on auditd config from the OS engine)
    # These checks are identified by the OS_DEPENDENT tag in the description
    # For now all are marked SKIPPED pending OS engine rewrite
    # TODO: replace with live OS report lookup once OS engines are complete

    FINDINGS_ID[idx]="${check_id}"
    FINDINGS_DESC[idx]="${desc}"
    FINDINGS_STATUS[idx]="${status}"
    FINDINGS_REMEDIATION[idx]="${remediation}"
    FINDINGS_SECTION[idx]="${section_id}"
    FINDINGS_SCORED[idx]="${scored}"

    # Track section titles — guard against empty section_id
    if [[ -n "${section_id}" ]]; then
      SECTION_TITLE["${section_id}"]="${section_title}"
    fi

    (( idx++ )) || true
  done <<< "${parsed_tsv}"

  _info "Parsed ${idx} check results (after level filtering)."
}

# -----------------------------------------------------------------------------
# Console output — print results section by section
# -----------------------------------------------------------------------------
_print_results() {
  echo ""

  local current_section=""
  local -a manual_review_buffer=()

  for idx in "${!FINDINGS_ID[@]}"; do
    local check_id="${FINDINGS_ID[idx]}"
    local desc="${FINDINGS_DESC[idx]}"
    local status="${FINDINGS_STATUS[idx]}"
    local remediation="${FINDINGS_REMEDIATION[idx]}"
    local section="${FINDINGS_SECTION[idx]}"

    # New section header
    if [[ "${section}" != "${current_section}" ]]; then
      # Flush manual review block for previous section
      if [[ ${#manual_review_buffer[@]} -gt 0 ]]; then
        _flush_manual_review "${current_section}" manual_review_buffer
        manual_review_buffer=()
      fi
      current_section="${section}"
      echo ""
      echo "${SEPARATOR}"
      echo " SECTION ${section} — ${SECTION_TITLE[${section}]:-}"
      echo "${SEPARATOR}"
    fi

    # Print check line
    if [[ "${status}" == "SKIPPED" ]]; then
      _print_check "SKIPPED" "${check_id}" "${desc}" "${remediation}"
    else
      _print_check "${status}" "${check_id}" "${desc}"
    fi

    # Collect manual review entries
    if [[ "${status}" == "MANUAL_REVIEW" ]]; then
      manual_review_buffer+=("${check_id}|${desc}|${remediation}")
    fi

    # Update counters
    case "${status}" in
      PASS)          (( COUNT_PASS++ ))    || true ;;
      FAIL)          (( COUNT_FAIL++ ))    || true ;;
      MANUAL_REVIEW) (( COUNT_MANUAL++ ))  || true ;;
      SKIPPED)       (( COUNT_SKIPPED++ )) || true ;;
      N/A)           (( COUNT_NA++ ))      || true ;;
    esac

    # Update section scoring
    if [[ -n "${section}" ]]; then
      if [[ "${status}" == "PASS" ]]; then
        SECTION_PASS["${section}"]=$(( ${SECTION_PASS["${section}"]:-0} + 1 ))
      elif [[ "${status}" == "FAIL" ]]; then
        SECTION_FAIL["${section}"]=$(( ${SECTION_FAIL["${section}"]:-0} + 1 ))
      fi
    fi
  done

  # Flush final section manual review block
  if [[ ${#manual_review_buffer[@]} -gt 0 ]]; then
    _flush_manual_review "${current_section}" manual_review_buffer
  fi
}

_flush_manual_review() {
  local section="$1"
  local -n buffer_ref=$2

  if [[ ${#buffer_ref[@]} -eq 0 ]]; then return; fi

  echo ""
  echo "${SEPARATOR}"
  echo " MANUAL REVIEW REQUIRED — SECTION ${section}"
  echo " The following checks require operator review."
  echo " Output has also been captured in the CSV report."
  echo "${SEPARATOR}"

  for entry in "${buffer_ref[@]}"; do
    IFS='|' read -r mr_id mr_desc mr_remediation <<< "${entry}"
    echo ""
    echo "--- ${mr_id}  ${mr_desc} ---"
    echo "Guidance: ${mr_remediation}"
    echo "---"
  done
}

# -----------------------------------------------------------------------------
# Scoring
# -----------------------------------------------------------------------------
_calculate_scores() {
  declare -gA SECTION_SCORES
  local total_pass=0 total_fail=0

  for section in "${!SECTION_PASS[@]}"; do
    local sp="${SECTION_PASS[${section}]:-0}"
    local sf="${SECTION_FAIL[${section}]:-0}"
    local denom=$(( sp + sf ))
    if [[ "${denom}" -gt 0 ]]; then
      SECTION_SCORES["${section}"]=$(python3 -c "print(f'{${sp}/${denom}*100:.1f}%')")
    else
      SECTION_SCORES["${section}"]="N/A"
    fi
    (( total_pass += sp )) || true
    (( total_fail += sf )) || true
  done

  local total_denom=$(( total_pass + total_fail ))
  if [[ "${total_denom}" -gt 0 ]]; then
    OVERALL_SCORE=$(python3 -c "print(f'{${total_pass}/${total_denom}*100:.1f}%')")
  else
    OVERALL_SCORE="N/A"
  fi
}

# -----------------------------------------------------------------------------
# Scan summary block (console only)
# -----------------------------------------------------------------------------
_print_summary() {
  local total=$(( COUNT_PASS + COUNT_FAIL + COUNT_MANUAL + COUNT_SKIPPED + COUNT_NA ))

  echo ""
  echo "${SEPARATOR}"
  echo " SCAN SUMMARY"
  echo "${SEPARATOR}"
  printf "  %-18s %d\n" "PASS"          "${COUNT_PASS}"
  printf "  %-18s %d\n" "FAIL"          "${COUNT_FAIL}"
  printf "  %-18s %d\n" "MANUAL_REVIEW" "${COUNT_MANUAL}"
  printf "  %-18s %d\n" "SKIPPED"       "${COUNT_SKIPPED}"
  printf "  %-18s %d\n" "N/A"           "${COUNT_NA}"
  echo "  ${THIN_SEP}"
  printf "  %-18s %d\n" "TOTAL"         "${total}"

  echo ""
  echo "${SEPARATOR}"
  echo " COMPLIANCE SCORES"
  echo "${SEPARATOR}"
  echo "  (Sections with only MANUAL_REVIEW or SKIPPED results are not scored)"
  echo ""

  for section in $(echo "${!SECTION_SCORES[@]}" | tr ' ' '\n' | sort); do
    printf "  Section %-4s %-36s : %s\n" \
      "${section}" \
      "(${SECTION_TITLE[${section}]:-})" \
      "${SECTION_SCORES[${section}]}"
  done

  echo "  ${THIN_SEP}───────────────────────────────────────────"
  printf "  %-42s : %s\n" "Overall Score" "${OVERALL_SCORE}"

  echo ""
  echo "  Report saved to: ${OUTPUT_FILE}"
  echo "${SEPARATOR}"
  echo ""
}

# -----------------------------------------------------------------------------
# Reporter — write CSV
# -----------------------------------------------------------------------------
_write_report() {
  OUTPUT_FILE="${OUTPUT_DIR}/hardenx_kubernetes_${TIMESTAMP}.csv"

  _info "Writing report to ${OUTPUT_FILE}..."

  bash "$(dirname "$0")/../reporter_kubernetes.sh" \
    --output-file "${OUTPUT_FILE}" \
    --findings-json "${RAW_JSON}" \
    --overall-score "${OVERALL_SCORE}" \
    --section-scores "$(declare -p SECTION_SCORES)" \
    --section-titles "$(declare -p SECTION_TITLE)" \
    --level "${LEVEL}" \
    2>/dev/null || _write_report_inline
}

# Inline fallback — write CSV directly if reporter_kubernetes.sh is not present
_write_report_inline() {
  _warn "reporter_kubernetes.sh not found. Writing CSV directly from engine."
  OUTPUT_FILE="${OUTPUT_DIR}/hardenx_kubernetes_${TIMESTAMP}.csv"

  {
    echo "Check Name,Description,Status,Remediation"
    for idx in "${!FINDINGS_ID[@]}"; do
      local check_id="${FINDINGS_ID[idx]}"
      local desc="${FINDINGS_DESC[idx]}"
      local status="${FINDINGS_STATUS[idx]}"
      local remediation="${FINDINGS_REMEDIATION[idx]}"
      # Escape double quotes in fields
      desc="${desc//\"/\"\"}"
      remediation="${remediation//\"/\"\"}"
      echo "\"${check_id}\",\"${desc}\",\"${status}\",\"${remediation}\""
    done

    # Score metadata rows
    for section in $(echo "${!SECTION_SCORES[@]}" | tr ' ' '\n' | sort); do
      local title="${SECTION_TITLE[${section}]:-}"
      title="${title//\"/\"\"}"
      echo "\"SCORE:section_${section}\",\"${title}\",\"${SECTION_SCORES[${section}]}\",\"\""
    done
    echo "\"SCORE:overall\",\"Overall Compliance Score\",\"${OVERALL_SCORE}\",\"\""

  } > "${OUTPUT_FILE}"

  _info "Report written: ${OUTPUT_FILE}"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  _parse_args "$@"
  _run_preflight
  _print_header

  echo ""
  echo "  Starting scan..."
  echo ""

  # Execute kube-bench using the selected mode
  case "${MODE}" in
    binary)  _exec_binary  ;;
    job)     _exec_job     ;;
    install) _exec_install ;;
  esac

  # Parse, display, score, report
  _parse_results
  _print_results
  _calculate_scores
  _write_report
  _print_summary

  # Suppress trap teardown side-effects for clean exit
  # (Job already deleted in _exec_job; install teardown still fires via trap)
  exit 0
}

main "$@"