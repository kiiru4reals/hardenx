# Adhiambo — Docker Engine Design Document
### Component: `engine/docker.sh` + Reporting Layer
**Benchmark Reference:** CIS Docker Benchmark v1.6.0
**Check Engine:** Docker Bench for Security
**Image Scanner:** Trivy
**Docker Server Support:** v1.13.0 and above
**Status:** Implemented — v2.0.0-alpha
**Version:** 0.4

---

## 1. Purpose

This document defines the design for the Adhiambo Docker Engine and its reporting layer. The Docker Engine implements CIS Benchmark v1.6.0 compliance checks by delegating check execution to **Docker Bench for Security**, and uses **Trivy** for image vulnerability scanning. The reporting layer is implemented across a set of Bash and Python components that produce structured output in multiple formats.

This document reflects the current implemented state of the engine. Open items at the end of this document capture features that are designed but not yet implemented and should be used to generate tracked issues.

---

## 2. Role in the Architecture

```
adhiambo.sh (entrypoint & orchestrator)
        │
        ├── [Docker CIS Compliance]
        │     └── engine_docker_cis.sh
        │               ├── docker-bench-security.sh
        │               │         └── <image>-compliance-report.log
        │               └── generate_docker_cis_csv.py
        │                         ├── <image>-compliance-report.csv
        │                         ├── <image>-compliance-summary.csv
        │                         ├── <image>-compliance-report.json
        │                         ├── <image>-compliance-report.html
        │                         └── <image>-compliance-report.zip
        │
        ├── [Vulnerability Scanning]
        │     └── engine_trivy_wrapper.sh
        │               └── engine_trivy.sh
        │                         ├── trivy image (JSON output)
        │                         ├── generate_vulnerability_html.py
        │                         ├── <image>-vulnerability-report.csv
        │                         ├── <image>-vulnerability-summary.csv
        │                         ├── <image>-vulnerability-report.html
        │                         └── <image>-vulnerability-report.zip
        │
        └── [Reporting Layer]
              └── reporter.sh
                        ├── excel_reporter.py
                        │         └── <assessment>-assessment.xlsx
                        └── full_assessment_html.py
                                  └── <assessment>.html
```

---

## 3. Component Inventory

| Component | Type | Responsibility |
|---|---|---|
| `engine_docker_cis.sh` | Bash | Orchestrates Docker Bench execution and compliance report generation |
| `engine_trivy_wrapper.sh` | Bash | Launches the Trivy engine and preserves assessment directory context |
| `engine_trivy.sh` | Bash | Image discovery, Trivy execution, vulnerability report generation |
| `generate_docker_cis_csv.py` | Python | Parses Docker Bench log, merges with controls library, produces CSV/JSON |
| `generate_docker_cis_html.py` | Python | Generates HTML compliance report from CSV output |
| `generate_vulnerability_html.py` | Python | Generates HTML vulnerability report from Trivy CSV output |
| `excel_reporter.py` | Python | Consolidates all CSV reports into a single Excel workbook |
| `full_assessment_html.py` | Python | Generates a consolidated HTML assessment dashboard |
| `reporter.sh` | Bash | Assessment directory management and report format selection |
| `utils.sh` | Bash | Shared logging, debug output, and helper functions |
| `config.sh` | Bash | Centralised configuration — paths, severity filters, scanner selection |

---

## 4. Configuration (`config.sh`)

All engine behaviour is driven by `config.sh`. It is sourced at startup by every engine and reporting component before any other action. Changing a value here updates the behaviour of all components simultaneously.

### Path Configuration

| Variable | Default | Description |
|---|---|---|
| `BASE_DIR` | `$HOME/Documents/docker-projects/hardenx` | Root project directory |
| `IMAGES_DIR` | `$BASE_DIR/images` | Directory containing TAR image archives |
| `IMPORT_DIR` | `/media/sf_Documents` | Optional external import directory (e.g. VirtualBox shared folder). TAR files placed here are copied to `IMAGES_DIR` automatically. |
| `REPORTS_DIR` | `$BASE_DIR/reports` | Root directory for all per-image assessment output |
| `COMPLIANCE_REPORTS_DIR` | `$BASE_DIR/reports/compliance` | Directory for standalone compliance report output |
| `DOCKER_BENCH_DIR` | `$HOME/tools/docker-bench-security` | Path to Docker Bench for Security installation. Note: this points to the user's home directory tools folder, not inside the project bundle. |

### Scanner Configuration

| Variable | Default | Description |
|---|---|---|
| `SCANNERS` | `vuln,secret,misconfig` | Trivy scanner types to enable. Supported values: `vuln`, `secret`, `misconfig`, `license`. |
| `SEVERITIES` | `CRITICAL,HIGH,MEDIUM,LOW` | Severity levels to include in Trivy reports. Supported values: `UNKNOWN`, `LOW`, `MEDIUM`, `HIGH`, `CRITICAL`. |
| `IGNORE_UNFIXED` | `true` | Suppress vulnerabilities that do not yet have an available fix. |
| `HTML_TEMPLATE` | *(empty)* | Optional path to a Trivy HTML template for fallback HTML generation. Leave empty to disable. |

### Runtime State

| Variable | Default | Description |
|---|---|---|
| `CURRENT_ASSESSMENT_NAME` | *(empty)* | Set at runtime by `reporter.sh` when an assessment directory is initialised. |
| `CURRENT_ASSESSMENT_DIR` | *(empty)* | Set at runtime by `reporter.sh`. Full path to the active assessment directory. |
| `QUIET` | `false` | Set to `true` by the `-q` flag at invocation. Suppresses console output. |
| `VERBOSE` | `false` | Set to `true` by the `-v` flag at invocation. Enables debug output, overrides quiet mode. |

> **Open Item 12:** There is no `CONTROLS_LIBRARY` variable in `config.sh`. The controls library path is currently hardcoded in `engine_docker_cis.sh`. A `CONTROLS_LIBRARY` variable should be added to `config.sh` to make the path configurable and consistent with how all other paths are managed.

If any required variable is missing or empty at startup, the engine exits with an explicit error identifying the missing variable.

---

## 5. Controls Library

The controls library is a CSV file that maps CIS Docker Benchmark check identifiers to their metadata. It is the reference source for enriching Docker Bench findings with descriptions, audit steps, and remediation guidance. The path to this file is configured via `config.sh` and passed to `generate_docker_cis_csv.py` at runtime.

> **Note:** The controls library file location is not yet confirmed in the project structure. This is tracked in Open Item 12.

### 5.1 Fields

| Field | Description |
|---|---|
| `REF` | Adhiambo control reference (e.g. `A1`, `B3`). Used as the primary key for merging with Docker Bench output. |
| `Standard` | The CIS Benchmark control name or title. |
| `Description/Rationale` | Plain-language explanation of what the control checks and why it matters. |
| `Audit` | The audit command or procedure used to verify the control. |
| `Remediation` | The specific action required to resolve a failing control. |

### 5.2 Section Reference Mapping

Docker Bench for Security outputs check IDs in the format `<section>.<check>` (e.g. `2.14`). The controls library uses a letter-prefixed reference scheme. The mapping is:

| Docker Bench Section | Controls Library Prefix | CIS Topic |
|---|---|---|
| `1.x` | `A` | Host Configuration |
| `2.x` | `B` | Docker Daemon Configuration |
| `3.x` | `C` | Docker Daemon Configuration Files |
| `4.x` | `D` | Container Images and Build Files |
| `5.x` | `E` | Container Runtime |

**Example:** Docker Bench check `2.14` maps to controls library reference `B14`.

If a Docker Bench check ID has no corresponding entry in the controls library, the check is still included in the output with `Standard` set to `Control metadata not found` and empty `Description/Rationale`, `Audit`, and `Remediation` fields.

---

## 6. Docker CIS Engine (`engine_docker_cis.sh`)

### 6.1 Invocation

`cis_checks.sh` is the Docker engine entry point. It is invoked by `adhiambo.sh` when Docker checks are part of the scan scope, and can also be run standalone by an operator for Docker-only assessments.

**Invoked by Adhiambo:**
```bash
# adhiambo.sh calls cis_checks.sh internally when Docker is in scope
bash adhiambo.sh --tech docker
```

**Standalone invocation:**
```bash
./cis_checks.sh [OPTIONS]

Options:
  -V, --vulnerability-scan    Vulnerability Scan — runs Trivy only
  -C, --docker-cis            Docker CIS Compliance Scan — runs Docker Bench for Security only
  -A, --full-assessment       Full Security Assessment — runs Trivy and Docker CIS, produces consolidated reports
  -q, --quiet                 Quiet mode — suppresses console output
  -v, --verbose               Verbose mode — enables debug output, overrides quiet mode
  -H, -h, --help              Display usage information and exit
```

**Default behaviour:** If invoked with no arguments, `cis_checks.sh` runs in interactive mode and presents a scan mode selection menu defaulting to option 3 (Full Security Assessment).

```bash
# Interactive mode — presents scan mode menu
./cis_checks.sh

# Full Security Assessment, quiet output
./cis_checks.sh -A -q
./cis_checks.sh --full-assessment --quiet

# Vulnerability scan only
./cis_checks.sh -V
./cis_checks.sh --vulnerability-scan

# Docker CIS compliance scan only
./cis_checks.sh -C
./cis_checks.sh --docker-cis

# Verbose output for debugging
./cis_checks.sh -v
./cis_checks.sh --verbose
```

**Internal `SCAN_MODE` values:** The selected mode is stored in the `SCAN_MODE` variable and used by the engine dispatcher:

| Flag | `SCAN_MODE` value |
|---|---|
| `-V` / `--vulnerability-scan` | `vulnerability-scan` |
| `-C` / `--docker-cis` | `docker-cis` |
| `-A` / `--full-assessment` | `full-assessment` |

> **Note:** The `-A` / `--full-assessment` mode still prompts the operator interactively for image selection. Fully non-interactive CI mode is tracked as Open Item 6.

### 6.2 Assessment Directory

The engine writes all output to a dedicated assessment directory under `REPORTS_DIR`. The directory name follows the convention:

```
<image_name>-security-assessment/
```

In a full assessment run (where both Trivy and Docker CIS engines run together), the existing assessment directory created by the Trivy engine is reused. In a standalone Docker CIS run, a new directory is created:

```
docker-cis-<YYYYMMDD-HHMMSS>/
```

### 6.3 Docker Bench for Security Execution

Docker Bench for Security is invoked from its installation directory as defined in `DOCKER_BENCH_DIR`:

```bash
cd "$DOCKER_BENCH_DIR"
sudo bash docker-bench-security.sh
```

The full output is written to the log report file. In verbose mode the output is also streamed to the console via `tee`.

If `DOCKER_BENCH_DIR` is not defined in `config.sh` or the directory does not exist, the engine exits immediately with an error:

```
[!] DOCKER_BENCH_DIR is not defined in config.sh
[!] Docker Bench for Security not found: <path>
```

### 6.4 Report Generation

After Docker Bench completes, the engine calls `generate_docker_cis_csv.py` to produce the structured reports:

```bash
python3 generate_docker_cis_csv.py \
    <controls.csv> \
    <docker-bench.log> \
    <output.csv> \
    <summary.csv>
```

If the controls library is not found, the engine exits with an error:

```
[!] Control library not found: <path>
```

### 6.5 Compliance Artifact Replication

In a full assessment run involving multiple images, Docker Bench for Security produces a single set of compliance findings that applies to the host — not to individual images. The engine replicates the compliance artifacts to every image assessment directory under `REPORTS_DIR` so that each per-image report is complete.

Replication is skipped for the directory where the compliance scan was originally generated. Directories named `compliance/` are excluded from the target list.

---

## 7. Trivy Engine (`engine_trivy.sh` + `engine_trivy_wrapper.sh`)

### 7.1 Wrapper (`engine_trivy_wrapper.sh`)

The wrapper launches `engine_trivy.sh` as a subprocess and preserves the assessment directory context after the engine exits. Because `engine_trivy.sh` runs in a subprocess, exported variables do not survive into the parent shell. The wrapper recovers `CURRENT_ASSESSMENT_DIR` by finding the most recently modified assessment directory under `REPORTS_DIR` that is not a `docker-cis-*` directory.

### 7.2 Image Sources

The Trivy engine discovers images from three sources:

| Source | Method |
|---|---|
| Docker daemon | `docker image ls` — lists all locally pulled images |
| TAR archives | `find $IMAGES_DIR -name "*.tar"` — loads archived images |
| Registry | Interactive pull via `docker pull <image>` |

The operator selects images interactively from a numbered menu. Multiple images can be selected for vulnerability scans. Full Security Assessment mode restricts selection to a single image.

### 7.3 Dependency Check

At startup, the engine checks for required dependencies: `trivy`, `jq`, and `zip`. If any are missing, the operator is prompted to install them:

```
[!] Missing dependencies: trivy jq
Install them now? [y/N]:
```

- **y** — installs missing packages via `apt`.
- **N** — the engine exits without running any checks.

### 7.4 Trivy Invocation

```bash
trivy image \
    --quiet \
    --scanners "$SCANNERS" \
    --severity "$SEVERITIES" \
    --format json \
    --output <json_report> \
    [--ignore-unfixed] \
    <image>
```

For TAR-based images, `--input <file>` is used instead of the image name directly.

### 7.5 Severity Override

The operator can override the configured severity filter at invocation time:

```bash
bash engine_trivy.sh --severity CRITICAL,HIGH
```

If `--severity` is not provided, the value from `SEVERITIES` in `config.sh` is used.

### 7.6 Scan Types

The `SCANNERS` configuration variable controls which Trivy scan types are enabled. Supported values:

| Scanner | What it detects |
|---|---|
| `vuln` | Known CVEs in OS packages and application dependencies |
| `secret` | Hardcoded secrets, API keys, credentials |
| `misconfig` | Dockerfile and container configuration issues |

Multiple scanners can be enabled simultaneously (e.g. `vuln,secret,misconfig`).

### 7.7 Exit Codes

| Code | Meaning |
|---|---|
| `0` | Scan completed. No CRITICAL findings. |
| `1` | Scan failed or dependency installation declined. |
| `10` | Scan completed. One or more CRITICAL findings detected. |

---

## 8. Status Values

Docker Bench for Security produces four status values. These are carried through the pipeline without remapping and appear in all output formats:

| Status | Meaning | Report Colour |
|---|---|---|
| `PASS` | Configuration meets the CIS control | Green |
| `WARN` | Configuration does not meet the CIS control | Red |
| `INFO` | Informational — requires operator assessment | Blue |
| `NOTE` | Advisory note — requires operator assessment | Grey |

> **Note:** The Adhiambo-wide status model (PASS, FAIL, N/A, SKIPPED, MANUAL_REVIEW) has not been applied to the Docker engine in v1. The native Docker Bench status values are used throughout. Alignment with the Adhiambo status model is tracked as Open Item 7.

---

## 9. Output Formats

### 9.1 Per-Image Compliance Outputs

| File | Description |
|---|---|
| `<image>-compliance-report.log` | Raw Docker Bench for Security output |
| `<image>-compliance-report.csv` | Enriched findings merged with controls library |
| `<image>-compliance-summary.csv` | Aggregated counts per status value |
| `<image>-compliance-report.json` | Structured JSON report for programmatic consumption |
| `<image>-compliance-report.html` | Human-readable HTML compliance report |
| `<image>-compliance-report.zip` | Packaged archive of all compliance artifacts |

### 9.2 Per-Image Vulnerability Outputs

| File | Description |
|---|---|
| `<image>-vulnerability-report.json` | Raw Trivy JSON output |
| `<image>-vulnerability-report.csv` | Detailed findings (CVEs, secrets, misconfigurations) |
| `<image>-vulnerability-summary.csv` | Aggregated counts by severity and finding type |
| `<image>-vulnerability-report.html` | Human-readable HTML vulnerability report |
| `<image>-vulnerability-report.zip` | Packaged archive of all vulnerability artifacts |

### 9.3 Consolidated Outputs (Full Assessment)

| File | Description |
|---|---|
| `<assessment>-assessment.xlsx` | Excel workbook consolidating all CSV reports into one file, one sheet per CSV |
| `<assessment>.html` | HTML dashboard summarising vulnerability and compliance findings with links to all artifacts |

### 9.4 CSV Schema — Compliance Report

| Column | Description |
|---|---|
| `REF` | Adhiambo control reference (e.g. `A1`, `B3`) |
| `Standard` | CIS Benchmark control name |
| `Description/Rationale` | Plain-language explanation of the control |
| `Audit` | Audit procedure for the control |
| `Remediation` | Remediation guidance for failing controls |
| `Status` | `PASS`, `WARN`, `INFO`, or `NOTE` |

### 9.5 CSV Schema — Vulnerability Report

| Column | Description |
|---|---|
| `Finding Type` | `Vulnerability`, `Secret`, or `Misconfiguration` |
| `Target` | The scanned file, package, or layer |
| `Component Type` | OS package type or language ecosystem |
| `Severity` | `CRITICAL`, `HIGH`, `MEDIUM`, or `LOW` |
| `Finding ID` | CVE ID, secret rule ID, or misconfiguration ID |
| `Package` | Affected package name |
| `Installed Version` | Version currently present |
| `Fixed Version` | Version in which the issue is resolved (if available) |
| `Title` | Short description of the finding |
| `Reference URL` | Link to the advisory or reference |
| `Description` | Full description (truncated to 1000 characters) |

---

## 10. Reporting Layer

> **Architectural Note — Tight Coupling**
>
> The reporting layer documented in this section is currently tightly coupled to the Docker engine. The Python scripts, file naming conventions, assessment directory structure, and CSV schemas are all Docker-specific and live inside the engine itself.
>
> The intended direction is to decouple this reporting layer into a standalone `reporter.sh` component that can be reused across all five Adhiambo engines. When the reporter component is prioritised, a decision will be made on whether to adopt the current implementation as the foundation or rebuild it to a new specification. Until that decision is made, the current implementation should be treated as the reference — no changes should be made to the output schemas or file naming conventions without cross-engine agreement.
>
> This item is tracked in Open Item 11.

### 10.1 `reporter.sh`

Handles assessment directory lifecycle and report format selection.

**Assessment directory initialisation:** Creates a dedicated directory per image scan under `REPORTS_DIR` and clears any existing content. Exposes `CURRENT_ASSESSMENT_DIR` and `CURRENT_ASSESSMENT_NAME` to all downstream components.

**Report format selection:** Prompts the operator to select one of three output modes:

| Option | Format | Description |
|---|---|---|
| 1 | `csv` | Separate CSV files only |
| 2 | `excel` | Combined Excel workbook only |
| 3 | `both` | CSV files and Excel workbook (default) |

The selected format is stored in `REPORT_FORMAT` and respected by all downstream reporting components. The format is only selected once per run — subsequent engine invocations in a full assessment reuse the previously selected value.

### 10.2 `excel_reporter.py`

Reads all CSV files in an assessment directory and produces a single Excel workbook with one worksheet per CSV file. Column widths are auto-sized based on content (capped at 80 characters). The output file is named:

```
<assessment_dir>/<assessment_name>-assessment.xlsx
```

### 10.3 `full_assessment_html.py`

Generates a consolidated HTML dashboard for a full assessment. The dashboard includes:

- Vulnerability summary table (sourced from `<image>-vulnerability-summary.csv`)
- Compliance summary table (sourced from `<image>-compliance-summary.csv`)
- Artifact index with links to all generated files

### 10.4 `generate_docker_cis_html.py`

Generates an HTML compliance report from the enriched compliance CSV and summary CSV. Each finding row is colour-coded by status value. The report includes a summary table and a detailed findings table.

### 10.5 `utils.sh`

Provides shared helper functions used across all engine and reporting components:

| Function | Description |
|---|---|
| `log()` | Timestamped output. Suppressed in quiet mode unless verbose is enabled. |
| `debug()` | Debug output. Only printed when `VERBOSE=true`. |
| `section()` | Prints a formatted section header. |
| `require_command()` | Checks whether a command exists. |
| `ensure_dir()` | Creates a directory if it does not exist. |

---

## 11. Output Modes

The engine supports two runtime output modes controlled by CLI flags:

| Short Flag | Long Flag | Mode | Behaviour |
|---|---|---|---|
| *(none)* | *(none)* | Normal | All log output and banners printed to console |
| `-q` | `--quiet` | Quiet | Suppresses all console output; logs still written to file. Banner is suppressed unless verbose mode is also active. Final report location line is always shown regardless of quiet mode. |
| `-v` | `--verbose` | Verbose | Enables debug output; overrides quiet mode |

Quiet and verbose modes are set at `cis_checks.sh` invocation and propagated to all engines and reporting components via the `QUIET` and `VERBOSE` variables initialised in `config.sh`.

---

## 12. Component Flow

```
adhiambo.sh (Adhiambo platform orchestrator)
        │
        └── cis_checks.sh (Docker engine entry point)
                │
                ├── [Startup]
                │     ├── parse_args() — set SCAN_MODE, QUIET, VERBOSE
                │     ├── show_banner() — suppressed if QUIET=true
                │     ├── Source config.sh
                │     └── Source utils.sh, reporter.sh, exporter.sh, engine_trivy_wrapper.sh
                │
                ├── [Interactive Menu — if no SCAN_MODE provided]
                │     └── interactive_menu() — prompts operator, defaults to full-assessment
                │
                ├── [Report Format Selection]
                │     └── select_report_format() — prompts once, reused across engines
                │
                ├── [Engine Dispatcher — run_selected_engines()]
                │     │
                │     ├── [-V: vulnerability-scan]
                │     │     └── run_trivy_engine()
                │     │           └── engine_trivy.sh (subprocess)
                │     │                 ├── install_missing_dependencies() — trivy, jq, zip
                │     │                 ├── load_images() — Docker daemon + TAR files
                │     │                 ├── select_images() — interactive selection
                │     │                 └── run_scan() per selected image
                │     │                       ├── init_assessment_dir()
                │     │                       ├── trivy image --format json
                │     │                       ├── generate_csv()
                │     │                       ├── generate_summary()
                │     │                       └── generate_vulnerability_html.py
                │     │
                │     ├── [-C: docker-cis]
                │     │     ├── Source engine_docker_cis.sh (lazy loaded)
                │     │     └── run_docker_cis_engine()
                │     │           ├── Validate DOCKER_BENCH_DIR
                │     │           ├── Reuse or create assessment directory
                │     │           ├── Rebuild ALL_ASSESSMENT_DIRS from REPORTS_DIR
                │     │           ├── sudo bash docker-bench-security.sh → .log
                │     │           ├── generate_docker_cis_csv.py → .csv, .json, summary.csv
                │     │           ├── generate_docker_cis_html.py → .html
                │     │           ├── package_reports() → .zip
                │     │           └── Replicate artifacts to all assessment directories
                │     │
                │     └── [-A: full-assessment]
                │           ├── run_trivy_engine() || true
                │           │     Note: Trivy failure does not abort the full assessment.
                │           │     The CIS engine runs regardless.
                │           ├── Save CURRENT_ASSESSMENT_DIR and CURRENT_ASSESSMENT_NAME
                │           ├── Source engine_docker_cis.sh (lazy loaded)
                │           ├── Restore CURRENT_ASSESSMENT_DIR and CURRENT_ASSESSMENT_NAME
                │           └── run_docker_cis_engine()
                │
                ├── [Post-Engine]
                │     ├── Rebuild ALL_ASSESSMENT_DIRS from REPORTS_DIR (excluding compliance/)
                │     └── Recover CURRENT_ASSESSMENT_DIR if unset (newest directory fallback)
                │
                ├── [Excel Report Generation]
                │     ├── Multiple images → generate_excel_report() per assessment directory
                │     └── Single image  → generate_excel_report() for CURRENT_ASSESSMENT_DIR
                │
                └── [Final Output — always shown regardless of quiet mode]
                      └── "Reports are stored under: $REPORTS_DIR"
```

---

## 13. Design Pattern Mapping

| Component | Pattern | Rationale |
|---|---|---|
| `adhiambo.sh` | Facade / Controller | Single entry point coordinating all engines |
| `engine_docker_cis.sh` | Strategy | Interchangeable compliance check execution |
| `engine_trivy.sh` | Strategy | Interchangeable vulnerability scan execution |
| `reporter.sh` | Factory | Produces structured output in selected format |
| `excel_reporter.py` | Builder | Assembles multi-sheet workbook from CSV inputs |
| `generate_docker_cis_csv.py` | Adapter | Translates Docker Bench log output into structured CSV/JSON |
| `config.sh` | Configuration Object | Centralised runtime settings |
| `utils.sh` | Utility / Helper | Shared cross-cutting concerns |

---

## 14. Extensibility Model

The engine is designed so that its two core tools — Docker Bench for Security and Trivy — can be replaced or supplemented without redesigning the broader architecture. The Python reporting layer is the only component that would need to change if the underlying tool output format changes.

Specifically:
- If Docker Bench for Security is updated to support a newer CIS benchmark version, only the controls library and the section reference mapping in `generate_docker_cis_csv.py` need updating.
- If Trivy is replaced by a different scanner, only the invocation commands in `engine_trivy.sh` and the CSV generation logic need updating.
- Additional scan types (SBOM generation, licence compliance) can be added as new output steps in `engine_trivy.sh` without modifying existing scan logic.
- New report formats can be added as new Python modules without modifying the Bash engines.

---

## 15. CI/CD Integration

While Adhiambo v1 is a manually invoked tool, the engine is designed to be automation-ready. Exit code `10` from `engine_trivy.sh` signals CRITICAL findings to a pipeline without requiring log parsing:

```yaml
# Example GitHub Actions step
- name: Run Adhiambo Security Assessment
  run: ./cis_checks.sh -A -q

- name: Archive Reports
  uses: actions/upload-artifact@v3
  with:
    name: security-reports
    path: reports/
```

Full non-interactive CI mode with flag-based image selection is a candidate for a future iteration (see Open Item 6).

---

## 16. Assumptions & Constraints

- All engines run on the target Linux host with `bash` available.
- `sudo` access is required for Docker Bench for Security execution.
- Python 3 must be available on the host for all reporting components.
- `openpyxl` Python package must be installed for Excel report generation.
- `jq` and `zip` must be available for Trivy report packaging.
- `rsync` must be available for optional TAR archive imports.
- Docker Bench for Security must be cloned into `$HOME/tools/docker-bench-security/` before running compliance scans. The path is configurable via `DOCKER_BENCH_DIR` in `config.sh`.
- The controls library CSV file must be present at the path configured in `config.sh`. If absent, compliance report generation will fail. The path is currently hardcoded — see Open Item 12.
- Trivy is installed interactively if not found. If installation is declined, vulnerability scanning does not run.
- Full Security Assessment mode (`-A`) still prompts the operator for image selection. It is not fully non-interactive.
- Vulnerability-only scans (`-V`) support multiple images. Full Security Assessment (`-A`) supports one image per run.
- Registry authentication is not handled by the tool. Images must be pulled manually via `docker pull` before scanning.

---

## 17. Open Items

| # | Item | Owner | Status |
|---|---|---|---|
| 1 | **SBOM generation** — Trivy supports CycloneDX and SPDX SBOM output. This is not yet implemented. Add `trivy image --format cyclonedx` as an output step in `engine_trivy.sh` and reference the SBOM path in the compliance report. | Engineering | Open |
| 2 | **Registry login/logout flow** — no authentication flow exists for private registries (ECR, GCR, GHCR, Harbor). Currently only images already pulled locally or via manual `docker pull` are supported. Implement registry detection and per-registry login/logout as defined in earlier design iterations. | Engineering | Open |
| 3 | **CIS level filtering** — Docker Bench for Security runs all checks by default. Level 1 vs Level 2 check distinction is not implemented. Implement level filtering during result parsing in `generate_docker_cis_csv.py` and expose via a `-l <1|2>` flag on `cis_checks.sh`. | Engineering | Open |
| 4 | **`-h` help flag** — the `-h` flag is listed in the CLI options but the full help menu content is not yet defined. Define the help output for `cis_checks.sh -h` covering all flags, defaults, and examples. | Engineering | Open |
| 5 | **Docker daemon pre-flight check** — no check for containerd-only environments. Add daemon detection before Docker Bench execution with an informative exit message. | Engineering | Open |
| 6 | **Non-interactive / CI mode** — `-A` Full Security Assessment still prompts for image selection. A fully non-interactive mode with flag-based image specification is needed for CI/CD pipeline use. `--all` / `-a` flag for scanning all images is partially implemented. | Engineering | Open |
| 7 | **Status model alignment** — the Docker engine uses native Docker Bench status values (PASS, WARN, INFO, NOTE). The Adhiambo-wide model uses PASS, FAIL, N/A, SKIPPED, MANUAL_REVIEW. Alignment should be implemented in `generate_docker_cis_csv.py` once the broader Adhiambo status model is ratified across all engines. | Security team | Open |
| 8 | **OS engine dependency** — OS-dependent CIS checks (auditd rules, file permissions, kernel parameters) are not separated from Docker-specific checks. Once the Ubuntu and Rocky Linux engines are complete, `OS_DEPENDENT` checks should be marked `SKIPPED: OS engine report not found` until the OS engine report is present. | Engineering | Pending OS engine rewrite |
| 9 | **Monitor Docker Bench for Security for CIS Docker Benchmark v1.8.0 support.** Upgrade benchmark version and revalidate controls library and section mapping once available. | Engineering | Open |
| 10 | **`--output-dir` flag** — output directory is currently hardcoded via `REPORTS_DIR` in `config.sh`. Add an output directory flag to allow the operator to specify it at invocation time. | Engineering | Open |
| 11 | **Reporter decoupling** — the reporting layer is currently tightly coupled to the Docker engine. The intended direction is a standalone reporter component reusable across all five engines. When this is prioritised, a decision must be made on whether to adopt the current Docker reporting implementation as the foundation or rebuild to a new specification. No changes should be made to the current output schemas or file naming conventions until that decision is made. | Engineering | Open |
| 12 | **Controls library location and configuration** — the controls library CSV path is hardcoded in `engine_docker_cis.sh` as `$SCRIPT_DIR/../data/docker-cis-controls.csv` but there is no `data/` directory in the current project structure and no corresponding variable in `config.sh`. Two actions required: (1) confirm the file location and add it to the project, (2) add a `CONTROLS_LIBRARY` variable to `config.sh` so the path is configurable like all other paths. | Engineering | Open |

---

*This document is a living design spec. Open items should be raised as tracked issues before implementation begins.*