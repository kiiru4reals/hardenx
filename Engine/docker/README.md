# Adhiambo — Docker CIS Assessment Engine
### `cis_checks.sh` — Scan. Harden. Comply.
**Version:** 2.0.0-alpha
**Status:** Implemented — Docker Engine

Adhiambo is an enterprise-grade container security assessment platform that automates vulnerability scanning, Docker CIS Benchmark compliance, and executive reporting for container images.

It integrates:

- **Trivy** for vulnerability, secret, and misconfiguration scanning
- **Docker Bench for Security** for CIS Docker Benchmark v1.6.0 compliance
- **Python-based reporting** for HTML dashboards and Excel workbooks

Adhiambo supports:

- Local Docker images
- Docker image TAR archives
- Registry-based image scanning (manual pull required — see [Supported Registries](#supported-registries))
- Optional import of TAR archives from external directories
- Multi-image assessments
- Full security assessments with consolidated reporting

---

# Table of Contents

- [Features](#features)
- [Quick Start](#quick-start)
- [Installation](#installation)
- [Usage](#usage)
- [Scan Modes](#scan-modes)
- [Image Sources](#image-sources)
- [Report Formats](#report-formats)
- [Project Structure](#project-structure)
- [Documentation](#documentation)
- [Architecture Overview](#architecture-overview)
- [Examples](#examples)
- [Command-Line Options](#command-line-options)
- [Dependencies](#dependencies)
- [Exit Codes](#exit-codes)
- [Supported Registries](#supported-registries)
- [CI/CD Integration](#cicd-integration)
- [Troubleshooting](#troubleshooting)
- [Roadmap](#roadmap)

---

# Features

## Vulnerability Scanning

Adhiambo uses Trivy to perform:

- OS package vulnerability scanning
- Application dependency scanning
- Secret detection
- Misconfiguration analysis
- Severity filtering
- Ignore-unfixed filtering

## Docker CIS Benchmark Compliance

Adhiambo integrates Docker Bench for Security to perform:

- CIS Docker Benchmark v1.6.0 checks
- Compliance scoring
- Executive summaries
- HTML and Excel reporting

## Multi-Image Support

- Scan a single image
- Scan multiple selected images
- Scan all available images
- Pull images directly from registries

## Image Acquisition Methods

- Local Docker images
- TAR archives stored in `images/`
- Images pulled from container registries via `docker pull`
- Optional import from user-specified directories

## Enterprise Reporting

For every scanned image, Adhiambo can generate:

- JSON reports
- CSV reports
- Summary CSV files
- HTML dashboards
- ZIP archives
- Consolidated Excel workbooks
- Consolidated HTML assessment reports

## Operational Modes

- Interactive mode
- Quiet mode (`-q`)
- Verbose mode (`-v`)
- Automated Full Security Assessment (`-A`)

---

# Quick Start

```bash
git clone https://github.com/your-org/adhiambo.git
cd adhiambo
chmod +x cis_checks.sh modules/*.sh modules/*.py
./cis_checks.sh
```

---

# Installation

## System Dependencies

```bash
sudo apt update
sudo apt install -y \
    docker.io \
    trivy \
    jq \
    zip \
    rsync \
    python3 \
    python3-pip
```

## Python Dependencies

```bash
pip3 install openpyxl
```

## Docker Bench for Security

```bash
git clone https://github.com/docker/docker-bench-security.git \
    $HOME/tools/docker-bench-security
```

---

# Usage

## Interactive Mode

```bash
./cis_checks.sh
```

## Quiet Mode

```bash
./cis_checks.sh -q
```

## Verbose Mode

```bash
./cis_checks.sh -v
```

## Automated Full Security Assessment

```bash
./cis_checks.sh -A
```

---

# Scan Modes

## 1. Vulnerability Scan (`-V`)

Runs Trivy only. Produces vulnerability reports for selected images.

## 2. Docker CIS Compliance Scan (`-C`)

Runs Docker Bench for Security only. Produces CIS compliance reports for the Docker host.

## 3. Full Security Assessment (`-A`) — Recommended

Runs both Trivy and Docker Bench for Security and produces consolidated reports. If Trivy fails or is declined, the compliance scan still runs.

---

# Image Sources

## Local Docker Images

Automatically discovers images already loaded into Docker.

## TAR Archives

Discovers all `.tar` files in the `images/` directory.

## Registry-Based Scanning

Pull images manually before scanning:

```bash
docker pull nginx:latest
./cis_checks.sh -V
```

## Optional External Import

At runtime, Adhiambo can import TAR archives from any directory:

```text
Would you like to import image archives from another directory? [y/N]:
```

---

# Image Selection Menu

```text
1) Pull image from registry
2) Scan ALL images
3) docker:flask-lab:v1
4) docker:nginx:latest
5) tar:application.tar
...
```

Examples:

```text
1          # Pull image from registry
2          # Scan ALL images
3          # Scan first listed image
3,4,5      # Scan multiple images
```

> **Note:** Full Security Assessment (`-A`) supports one image per run. Use Vulnerability Scan (`-V`) for multiple images.

---

# Report Formats

## 1. Separate Reports

Generates CSV, JSON, HTML, and ZIP reports.

## 2. Combined Excel Workbook

Generates a consolidated `.xlsx` workbook.

## 3. Both (Default)

Generates all supported outputs.

---

# Project Structure

```text
adhiambo/
├── cis_checks.sh               # Docker engine entry point
├── config.sh                   # Centralised configuration
├── README.md
├── ARCHITECTURE.md
├── CONTRIBUTING.md
├── CHANGELOG.md
├── LICENSE
├── .gitignore
├── images/                     # Docker image TAR archives
├── reports/                    # Per-image assessment directories
├── modules/
│   ├── engine_trivy.sh
│   ├── engine_trivy_wrapper.sh
│   ├── engine_docker_cis.sh
│   ├── exporter.sh
│   ├── reporter.sh
│   ├── utils.sh
│   ├── excel_reporter.py
│   ├── generate_vulnerability_html.py
│   ├── full_assessment_html.py
│   ├── generate_docker_cis_html.py
│   └── generate_docker_cis_csv.py
└── tools/                      # External dependencies (outside project bundle)

# External
$HOME/tools/
└── docker-bench-security/
```

---

# Documentation

- **README.md** — User guide and installation instructions
- **ARCHITECTURE.md** — Technical architecture and design documentation
- **CONTRIBUTING.md** — Contribution guidelines
- **CHANGELOG.md** — Release history
- **LICENSE** — Project license

---

# Architecture Overview

Adhiambo follows a layered architecture:

1. Platform Orchestrator (`adhiambo.sh`) — calls `cis_checks.sh` for Docker assessments
2. Docker Engine Entry Point (`cis_checks.sh`) — orchestrates Trivy and Docker Bench
3. Engine Layer (`engine_trivy.sh`, `engine_docker_cis.sh`)
4. Reporting Layer (`exporter.sh`, Python reporters)
5. Utility Layer (`utils.sh`)
6. Configuration Layer (`config.sh`)
7. Artifact Layer (`images/`, `reports/`)

For detailed design documentation, see [ARCHITECTURE.md](ARCHITECTURE.md).

---

# Examples

## Scan an Image from Docker Hub

```bash
./cis_checks.sh
```

Selections:

```text
1
nginx:latest
```

## Scan All Images

```bash
./cis_checks.sh -q
```

Press Enter at the image selection prompt (default `[2]`).

## Run a Full Security Assessment

```bash
./cis_checks.sh -A
```

---

# Command-Line Options

| Option | Long Form | Description |
|------|------|------|
| `-A` | `--full-assessment` | Full Security Assessment |
| `-V` | `--vulnerability-scan` | Vulnerability Scan |
| `-C` | `--docker-cis` | Docker CIS Compliance Scan |
| `-q` | `--quiet` | Quiet mode |
| `-v` | `--verbose` | Verbose mode |
| `-h`, `-H` | `--help` | Help |

---

# Dependencies

## Required Tools

- Docker
- Trivy
- jq
- zip
- rsync
- Python 3
- Docker Bench for Security (installed at `$HOME/tools/docker-bench-security`)

## Python Libraries

- openpyxl

---

# Exit Codes

| Code | Meaning |
|------|------|
| `0` | Success — scan completed, no CRITICAL findings |
| `1` | Scan failure or dependency installation declined |
| `10` | CRITICAL vulnerabilities detected |

---

# Supported Registries

Adhiambo supports images from any registry accessible via `docker pull`. Pull the image manually before running a scan:

```bash
docker pull nginx:latest
docker pull ghcr.io/org/app:v1
docker pull myregistry.company.com/backend:prod
```

Supported registries include Docker Hub, GitHub Container Registry (GHCR), Amazon ECR, Azure Container Registry, Google Artifact Registry, and private OCI registries.

> **Note:** Automated registry authentication (login/logout flow) is not yet implemented. Images must be pulled manually before scanning. Registry authentication is tracked as a planned feature — see [Roadmap](#roadmap).

---

# CI/CD Integration

Use Adhiambo exit codes to fail builds when critical vulnerabilities are detected:

```yaml
- name: Run Adhiambo Docker Assessment
  run: ./cis_checks.sh -A -q

- name: Archive Reports
  uses: actions/upload-artifact@v3
  with:
    name: security-reports
    path: reports/
```

> **Note:** Full non-interactive CI mode with flag-based image selection is planned. Currently, `-A` still prompts for image selection.

---

# Troubleshooting

## Validate Shell Syntax

```bash
bash -n cis_checks.sh
bash -n modules/*.sh
```

## Validate Python Scripts

```bash
python3 -m py_compile modules/*.py
```

## Corrupted TAR Archive

```bash
tar -tf image.tar
docker load -i image.tar
```

## Docker Permission Denied

```bash
sudo usermod -aG docker $USER
newgrp docker
```

## Docker Bench for Security Not Found

Ensure Docker Bench is cloned to the correct location:

```bash
git clone https://github.com/docker/docker-bench-security.git \
    $HOME/tools/docker-bench-security
```

Then verify `DOCKER_BENCH_DIR` in `config.sh` points to the correct path.

---

# Roadmap

| Item | Description |
|------|------|
| Registry authentication | Automated login/logout flow for ECR, GCR, GHCR, and self-hosted registries |
| SBOM generation | CycloneDX and SPDX SBOM output via Trivy |
| CIS level filtering | Level 1 vs Level 2 check distinction |
| Non-interactive / CI mode | Flag-based image selection for pipeline automation |
| CIS Docker Benchmark v1.8.0 | Upgrade once Docker Bench for Security adds support |
| Reporter decoupling | Standalone reporter reusable across all Adhiambo engines |
| Ubuntu 24.04 LTS engine | CIS Ubuntu benchmark checks |
| Rocky Linux engine | CIS Rocky Linux benchmark checks |
| PostgreSQL engine | CIS PostgreSQL benchmark checks |
| Kubernetes engine | CIS Kubernetes benchmark checks via kube-bench |
| PDF executive reports | PDF output format |
| Risk scoring | Aggregate risk score across vulnerability and compliance findings |

---

*This README covers the Docker engine (`cis_checks.sh`). For the full Adhiambo platform documentation, see [ARCHITECTURE.md](ARCHITECTURE.md).*