# ============================================================================
# Trivy Enterprise Image Scanner Configuration
# ============================================================================

# Base project directory
BASE_DIR="$HOME/Documents/docker-projects/hardenx"

# Directory where Docker image TAR files are stored
IMAGES_DIR="$BASE_DIR/images"

# Optional import directory (e.g., VirtualBox shared folder)
# Docker image TAR files placed here will be copied automatically to IMAGES_DIR
IMPORT_DIR="/media/sf_Documents"

# Root directory for generated reports
# Reports are stored under:
#   $REPORTS_DIR/<image-name>/
REPORTS_DIR="$BASE_DIR/reports"

# Trivy scanners to enable
# Available: vuln, secret, misconfig, license
SCANNERS="vuln,secret,misconfig"

# Severity levels to include in reports
# Supported values: UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL
SEVERITIES="CRITICAL,HIGH,MEDIUM,LOW"

# Ignore vulnerabilities that do not yet have an available fix
# true  = exclude unfixed findings
# false = include all findings
IGNORE_UNFIXED="true"

# Optional HTML template for Trivy
# Leave empty to disable HTML report generation
# Example:
# HTML_TEMPLATE="$BASE_DIR/templates/html.tpl"
HTML_TEMPLATE=""
# ============================================================================
# Docker CIS Compliance Configuration
# ============================================================================
DOCKER_BENCH_DIR="$HOME/tools/docker-bench-security"
COMPLIANCE_REPORTS_DIR="$BASE_DIR/reports/compliance"

# ============================================================================
# Shared Assessment Reporting
# ============================================================================
CURRENT_ASSESSMENT_NAME=""
CURRENT_ASSESSMENT_DIR=""

# Runtime flags
QUIET=false
VERBOSE=false





