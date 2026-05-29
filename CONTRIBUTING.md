# Contributing to HardenX

First, thank you for your interest in contributing to HardenX.

HardenX is an enterprise-grade container security assessment platform that combines:

- Vulnerability scanning with Trivy
- Docker CIS Benchmark compliance with Docker Bench for Security
- Executive reporting in CSV, JSON, HTML, ZIP, and Excel formats
- Multi-image and registry-based assessments

Contributions are welcome from security engineers, developers, DevSecOps practitioners, compliance specialists, and technical writers.

---

# Table of Contents

- [Ways to Contribute](#ways-to-contribute)
- [Development Environment Setup](#development-environment-setup)
- [Project Structure](#project-structure)
- [Coding Standards](#coding-standards)
- [Testing Requirements](#testing-requirements)
- [Documentation Standards](#documentation-standards)
- [Commit Message Guidelines](#commit-message-guidelines)
- [Pull Request Process](#pull-request-process)
- [Reporting Bugs](#reporting-bugs)
- [Requesting Features](#requesting-features)
- [Security Vulnerability Disclosure](#security-vulnerability-disclosure)
- [Code of Conduct](#code-of-conduct)

---

# Ways to Contribute

You can contribute in many ways:

- Reporting bugs
- Suggesting features
- Improving documentation
- Writing tests
- Enhancing Bash modules
- Developing Python reporting scripts
- Adding new scanning engines
- Improving CI/CD integrations

---

# Development Environment Setup

## Clone the Repository

```bash
git clone .....
cd hardenx
```

## Install Dependencies

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

## Install Python Dependencies

```bash
pip3 install openpyxl pandas
```

## Install Docker Bench for Security

```bash
git clone https://github.com/docker/docker-bench-security.git tools/docker-bench-security
```

## Make Scripts Executable

```bash
chmod +x hardenx
chmod +x modules/*.sh
chmod +x modules/*.py
```

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

# Coding Standards

## Bash Standards

- Use `#!/usr/bin/env bash`
- Use `set -euo pipefail`
- Quote all variable expansions
- Prefer local variables inside functions
- Use descriptive function names
- Keep functions focused on a single responsibility
- Validate syntax with:

```bash
bash -n hardenx
bash -n modules/*.sh
```

## Python Standards

- Follow PEP 8
- Use Python 3.10+
- Prefer standard library modules where possible
- Format code with `black`
- Lint with `flake8`

## General Principles

- Separation of concerns
- Minimal side effects
- Clear naming
- Reusable components
- Backward compatibility when practical

---

# Testing Requirements

Before submitting a pull request, verify:

```bash
bash -n hardenx
bash -n modules/*.sh
python3 -m py_compile modules/*.py
./hardenx -A
```

Recommended manual tests:

- Vulnerability Scan
- Docker CIS Compliance Scan
- Full Security Assessment
- Registry-based image pulls
- Multi-image selections
- Quiet mode (`-q`)
- Verbose mode (`-v`)

---

# Documentation Standards

When adding or modifying features:

1. Update `README.md` if user-facing behavior changes.
2. Update `ARCHITECTURE.md` if system design changes.
3. Update `CHANGELOG.md` with release notes.
4. Add usage examples where appropriate.

Documentation should be:

- Clear
- Accurate
- Reproducible
- Consistent with current behavior

---

# Commit Message Guidelines

Use descriptive commit messages.

Examples:

```text
feat: add registry-based image scanning
fix: replicate compliance reports to all assessment directories
docs: add architecture documentation
refactor: simplify image selection workflow
test: add syntax validation checks
```

Suggested prefixes:

- `feat`
- `fix`
- `docs`
- `refactor`
- `test`
- `chore`

---

# Pull Request Process

1. Fork the repository.
2. Create a feature branch.
3. Implement and test changes.
4. Update documentation.
5. Commit with clear messages.
6. Submit a pull request.
7. Respond to review feedback.

Each pull request should include:

- Summary of changes
- Motivation
- Testing performed
- Screenshots or sample outputs if relevant

---

# Reporting Bugs

When reporting bugs, include:

- HardenX version
- Operating system and distribution
- Docker version
- Trivy version
- Steps to reproduce
- Expected behavior
- Actual behavior
- Relevant logs or screenshots

---

# Requesting Features

Feature requests should describe:

- The problem being solved
- Proposed functionality
- Example workflows
- Expected outputs
- Potential implementation ideas (optional)

---

# Security Vulnerability Disclosure

If you discover a security vulnerability in HardenX, please report it privately rather than opening a public issue.

Include:

- Description of the issue
- Steps to reproduce
- Potential impact
- Suggested mitigation (if known)

---

# Code of Conduct

Contributors are expected to:

- Be respectful and professional
- Provide constructive feedback
- Focus on technical merit
- Support collaborative problem solving

Harassment, abusive language, and discriminatory behavior are not tolerated.

---

# Recognition

All meaningful contributions are appreciated, including:

- Code
- Documentation
- Testing
- Design feedback
- Issue reporting

---

# Architectural Philosophy

HardenX is built around the principles of:

- Security by default
- Automation-first workflows
- Modular design
- Enterprise reporting
- Extensibility

Every contribution should reinforce these goals.

---

# Getting Started

If you are new to the project, good first contributions include:

- Improving documentation
- Adding tests
- Fixing shellcheck warnings
- Enhancing HTML reports
- Improving error handling

---

# Thank You

Thank you for helping improve HardenX.

Together we are building a powerful, extensible, and enterprise-ready container security assessment platform.

> **Scan. Harden. Comply.**