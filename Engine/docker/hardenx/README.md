# HardenX v2.0.0-alpha

> **Scan. Harden. Comply.**

HardenX is an enterprise-grade container security assessment platform that automates vulnerability scanning, Docker CIS Benchmark compliance, and executive reporting for container images.

It integrates:

- **Trivy** for vulnerability, secret, and misconfiguration scanning
- **Docker Bench for Security** for Docker CIS Benchmark compliance
- **Python-based reporting** for HTML dashboards and Excel workbooks

HardenX supports:

- Local Docker images
- Docker image TAR archives
- Registry-based image scanning
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
- [Contributing](#contributing)
---

# Features

## Vulnerability Scanning

HardenX uses Trivy to perform:

- OS package vulnerability scanning
- Application dependency scanning
- Secret detection
- Misconfiguration analysis
- Severity filtering
- Ignore-unfixed filtering

## Docker CIS Benchmark Compliance

HardenX integrates Docker Bench for Security to perform:

- Docker CIS Benchmark checks
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
- Images pulled from container registries
- Optional import from user-specified directories

## Enterprise Reporting

For every scanned image, HardenX can generate:

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
git clone https://github.com/your-org/hardenx.git
cd hardenx
chmod +x hardenx modules/*.sh modules/*.py
./hardenx
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
pip3 install openpyxl pandas
```

## Docker Bench for Security

```bash
git clone https://github.com/docker/docker-bench-security.git tools/docker-bench-security
```

---

# Usage

## Interactive Mode

```bash
./hardenx
```

## Quiet Mode

```bash
./hardenx -q
```

## Verbose Mode

```bash
./hardenx -v
```

## Automated Full Security Assessment

```bash
./hardenx -A
```

---

# Scan Modes

## 1. Vulnerability Scan

Runs Trivy only.

## 2. Docker CIS Compliance Scan

Runs Docker Bench for Security only.

## 3. Full Security Assessment (Recommended)

Runs both Trivy and Docker CIS and produces consolidated reports.

---

# Image Sources

## Local Docker Images

Automatically discovers images already loaded into Docker.

## TAR Archives

Discovers all `.tar` files in the `images/` directory.

## Registry-Based Scanning

Pulls images directly from registries and scans them immediately.

Examples:

```text
nginx:latest
ubuntu:24.04
python:3.12-slim
ghcr.io/org/app:v1
myregistry.company.com/backend:prod
```

## Optional External Import

At runtime, HardenX can import TAR archives from any directory:

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

---

# Report Formats

## 1. Separate Reports

Generates CSV, JSON, HTML, and ZIP reports.

## 2. Combined Excel Workbook

Generates a consolidated `.xlsx` workbook.

## 3. Both

Generates all supported outputs.

---

# Project Structure

```text
hardenx/
├── hardenx
├── config.sh
├── README.md
├── ARCHITECTURE.md
├── CONTRIBUTING.md
├── CHANGELOG.md
├── LICENSE
├── .gitignore
├── images/
├── reports/
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
│   └── generate_docker_cis_csv.py
└── tools/
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

HardenX follows a layered architecture consisting of:

1. Presentation Layer (`hardenx`)
2. Orchestration Layer
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
./hardenx
```

Selections:

```text
1
nginx:latest
```

## Scan All Images

```bash
./hardenx -q
```

Press Enter at the image selection prompt (default `[2]`).

## Run a Full Security Assessment

```bash
./hardenx -A
```

---

# Command-Line Options

| Option | Description |
|------|------|
| `-A` | Full Security Assessment |
| `-V` | Vulnerability Scan |
| `-C` | Docker CIS Compliance Scan |
| `-q` | Quiet mode |
| `-v` | Verbose mode |
| `-h` | Help |

---

# Dependencies

## Required Tools

- Docker
- Trivy
- jq
- zip
- rsync
- Python 3

## Python Libraries

- openpyxl
- pandas

---

# Exit Codes

| Code | Meaning |
|------|------|
| `0` | Success |
| `1` | Scan failure |
| `10` | CRITICAL vulnerabilities detected |

---

# Supported Registries

- Docker Hub
- GitHub Container Registry (GHCR)
- Amazon ECR
- Azure Container Registry (ACR)
- Google Artifact Registry
- Private OCI registries

---

# CI/CD Integration

Example GitHub Actions step:

```yaml
- name: Run HardenX
  run: ./hardenx -A -q
```

Use HardenX exit codes to fail builds when critical vulnerabilities are detected.

---

# Troubleshooting

## Validate Shell Syntax

```bash
bash -n hardenx
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

---

# Roadmap

- PDF executive reports
- CVSS-based risk scoring
- Policy-based build gating
- Registry authentication helpers
- Scheduled assessments
- SBOM generation
- Kubernetes CIS Benchmark integration

---

# Contributing

Contributions are welcome.

Please read [CONTRIBUTING.md](CONTRIBUTING.md) for:

- Development environment setup
- Coding standards
- Testing requirements
- Pull request guidelines

---


---

# Motto

> **Scan. Harden. Comply.**