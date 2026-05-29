# HardenX Architecture

> **Technical Architecture and Design Documentation**

This document describes the internal architecture of HardenX, including its modular components, execution flow, design principles, and extensibility model.

---

# Table of Contents

- [Overview](#overview)
- [High-Level Architecture](#high-level-architecture)
- [Execution Flow](#execution-flow)
- [Architectural Layers](#architectural-layers)
- [Module Responsibilities](#module-responsibilities)
- [Directory Structure](#directory-structure)
- [Reporting Architecture](#reporting-architecture)
- [Data Flow](#data-flow)
- [Design Principles](#design-principles)
- [Design Pattern Mapping](#design-pattern-mapping)
- [Extensibility Model](#extensibility-model)
- [CI/CD Integration](#cicd-integration)
- [Future Architecture Roadmap](#future-architecture-roadmap)
- [Architectural Summary](#architectural-summary)

---

# Overview

HardenX is a modular container security assessment framework designed to perform:

- Vulnerability scanning using Trivy
- Docker CIS Benchmark compliance using Docker Bench for Security
- Multi-image assessments
- Registry-based image acquisition
- Executive reporting in CSV, JSON, HTML, ZIP, and Excel formats

The platform is built using Bash for orchestration and Python for advanced reporting and visualization.

---

# High-Level Architecture

```text
                           ┌───────────────────────┐
                           │       User CLI        │
                           │      ./hardenx        │
                           └───────────┬───────────┘
                                       │
                                       ▼
                           ┌───────────────────────┐
                           │   Main Orchestrator   │
                           │       hardenx         │
                           └───────────┬───────────┘
                                       │
                                       ▼
                           ┌───────────────────────┐
                           │ Scan Mode Selection   │
                           │ - Vulnerability Scan  │
                           │ - Docker CIS Scan     │
                           │ - Full Assessment     │
                           └───────────┬───────────┘
                                       │
                ┌──────────────────────┴──────────────────────┐
                │                                             │
                ▼                                             ▼
   ┌──────────────────────────┐                  ┌──────────────────────────┐
   │  Trivy Engine Wrapper    │                  │  Docker CIS Engine       │
   │ engine_trivy_wrapper.sh  │                  │ engine_docker_cis.sh     │
   └──────────────┬───────────┘                  └──────────────┬───────────┘
                  │                                             │
                  ▼                                             ▼
   ┌──────────────────────────┐                  ┌──────────────────────────┐
   │     Trivy Engine         │                  │ Docker Bench for Security│
   │   engine_trivy.sh        │                  │ (docker-bench-security)  │
   └──────────────┬───────────┘                  └──────────────┬───────────┘
                  │                                             │
                  └──────────────────────┬──────────────────────┘
                                         ▼
                           ┌───────────────────────┐
                           │   Reporting Layer     │
                           │    exporter.sh        │
                           └───────────┬───────────┘
                                       │
                    ┌──────────────────┼──────────────────┐
                    │                  │                  │
                    ▼                  ▼                  ▼
          ┌────────────────┐  ┌────────────────┐  ┌────────────────────┐
          │ CSV / JSON /   │  │ Excel Workbook │  │ Consolidated HTML  │
          │ HTML / ZIP     │  │ .xlsx          │  │ Assessment Report  │
          └────────────────┘  └────────────────┘  └────────────────────┘
                                       │
                                       ▼
                           ┌───────────────────────┐
                           │ Per-Image Assessment  │
                           │ Directories           │
                           └───────────────────────┘
```

---

# Execution Flow

1. User launches `./hardenx`.
2. Command-line arguments are parsed.
3. Scan mode is selected.
4. Report format is selected.
5. Selected engines are executed.
6. Images are discovered from:
   - Local Docker daemon
   - `images/` TAR archives
   - Container registries
   - Optional external import paths
7. Vulnerability and/or compliance scans run.
8. Reports are generated.
9. Consolidated Excel and HTML reports are created.
10. All artifacts are stored in per-image assessment directories.

---

# Architectural Layers

## 1. Presentation Layer

### `hardenx`

Primary command-line entry point and application controller.

Responsibilities:

- Displays banner
- Parses CLI options
- Shows menus
- Selects scan mode
- Coordinates engine execution
- Triggers consolidated reporting
- Displays final report location

---

## 2. Orchestration Layer

Coordinates execution of scanning engines based on the selected mode:

- Vulnerability Scan
- Docker CIS Compliance Scan
- Full Security Assessment

This layer ensures the correct sequence and preserves context across engines.

---

## 3. Engine Layer

### Trivy Engine Wrapper (`engine_trivy_wrapper.sh`)

- Launches Trivy engine
- Preserves assessment directory context
- Supports quiet and verbose modes

### Trivy Engine (`engine_trivy.sh`)

- Discovers Docker images
- Imports TAR archives
- Pulls images from registries
- Executes Trivy
- Generates vulnerability reports

### Docker CIS Engine (`engine_docker_cis.sh`)

- Runs Docker Bench for Security
- Parses compliance results
- Generates compliance reports
- Replicates compliance artifacts to all assessment directories

---

## 4. Reporting Layer

### Exporter (`exporter.sh`)

Coordinates advanced reporting:

- Consolidated Excel workbooks
- Full assessment HTML dashboards

### Reporter (`reporter.sh`)

Provides:

- Assessment directory initialization
- Report context management

### Python Reporting Modules

- `excel_reporter.py`
- `generate_vulnerability_html.py`
- `full_assessment_html.py`
- `generate_docker_cis_csv.py`

---

## 5. Utility Layer

### `utils.sh`

Shared helper functions:

- Timestamped logging
- Debug output
- Quiet and verbose controls

---

## 6. Configuration Layer

### `config.sh`

Centralized settings:

- Directory paths
- Severity filters
- Scanner selections
- HTML templates
- Ignore-unfixed settings

---

## 7. Artifact Layer

### `images/`

Stores Docker image TAR archives.

### `reports/`

Stores per-image assessment directories and all generated reports.

### `tools/`

Contains third-party dependencies such as Docker Bench for Security.

---

# Module Responsibilities

| Module | Responsibility |
|------|------|
| `hardenx` | Application controller and orchestrator |
| `config.sh` | Central configuration |
| `engine_trivy.sh` | Vulnerability scanning engine |
| `engine_trivy_wrapper.sh` | Trivy engine launcher and context preservation |
| `engine_docker_cis.sh` | Docker CIS compliance engine |
| `reporter.sh` | Assessment directory management |
| `exporter.sh` | Consolidated reporting |
| `utils.sh` | Logging and debugging |
| `excel_reporter.py` | Excel workbook generation |
| `generate_vulnerability_html.py` | Vulnerability HTML generation |
| `full_assessment_html.py` | Consolidated HTML dashboard |
| `generate_docker_cis_csv.py` | Compliance CSV and summaries |

---

# Directory Structure

```text
hardenx/
├── hardenx
├── config.sh
├── README.md
├── ARCHITECTURE.md
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

# Reporting Architecture

For each image, HardenX creates:

```text
<image>-security-assessment/
```

Containing:

- Vulnerability JSON, CSV, Summary CSV, HTML, ZIP
- Compliance LOG, CSV, JSON, Summary CSV, HTML, ZIP
- Consolidated Excel workbook
- Consolidated HTML assessment report

---

# Data Flow

```text
Container Image
      │
      ▼
Trivy / Docker Bench
      │
      ▼
JSON / LOG Output
      │
      ▼
CSV and Summary Generation
      │
      ▼
Python Reporting Modules
      │
      ▼
HTML and Excel Deliverables
      │
      ▼
Per-Image Assessment Directory
```

---

# Design Principles

- Separation of Concerns
- Single Responsibility Principle
- Modularity
- Extensibility
- Automation Readiness
- Per-Image Isolation
- Enterprise Reporting

---

# Design Pattern Mapping

| Component | Pattern |
|------|------|
| `hardenx` | Facade / Controller |
| Engine scripts | Strategy |
| `config.sh` | Configuration Object |
| `reporter.sh` | Factory |
| `exporter.sh` | Builder |
| Python reporters | Adapter / Renderer |

---

# Extensibility Model

New engines can be added without redesigning the platform, such as:

- SBOM generation
- Kubernetes CIS Benchmark
- OpenSCAP integration
- Policy-as-Code enforcement
- PDF reporting

Each new engine can reuse:

- Configuration layer
- Logging utilities
- Reporting framework
- Assessment directory management

---

# CI/CD Integration

HardenX is designed for automation and can be integrated into:

- GitHub Actions
- GitLab CI
- Jenkins
- Azure DevOps
- AWS CodeBuild

Typical workflow:

1. Pull image from registry.
2. Run HardenX.
3. Fail pipeline on critical findings.
4. Archive generated reports.

---

# Future Architecture Roadmap

Planned enhancements include:

- Plugin-based engine discovery
- Registry authentication helpers
- Policy engine
- Scheduled assessments
- PDF executive reports
- Risk scoring
- Kubernetes and OpenShift assessments

---

# Architectural Summary

HardenX is a layered, modular security assessment framework that:

- Acquires images from multiple sources
- Performs vulnerability and compliance analysis
- Generates executive-quality reports
- Supports multi-image and registry-based assessments
- Integrates into CI/CD pipelines
- Scales through modular engine design

> **HardenX is a production-ready container security assessment platform built for extensibility, automation, and enterprise reporting.**