# HardenX — Product Paper
### CIS Compliance & Infrastructure Hardening Engine
**Version:** 0.1 - Internal Working Draft
**Status:** In Development

---

## 1. Executive Summary

HardenX is an automated compliance and infrastructure hardening engine designed to perform deep CIS (Center for Internet Security) benchmark checks across technologies hosted in enterprise cloud environments that fall outside the reach of conventional enterprise scanners.

The solution closes a critical visibility gap affecting internal product teams whose deployments do not conform to standard operating procedures and reside on cloud infrastructure that existing organisational scanners cannot interrogate. Beyond its internal mandate, HardenX is positioned as a value-added capability that can be offered to external clients during Vulnerability Assessment and Penetration Testing (VAPT) engagements.

---

## 2. Problem Statement

### 2.1 Background

In an agile organization, product teams operate with a degree of autonomy that promotes speed and innovation. A consequence of this autonomy, however, is that not all products adhere to the established Standard Operating Procedure (SOP) for infrastructure provisioning and management. Specifically:

- **Non-standard deployments** — Several products are hosted on enterprise cloud environments that deviate from the organisation's approved infrastructure baseline.
- **Scanner blind spots** — The organisation's current suite of security scanners lacks the capability to assess environments outside the standard footprint, leaving these deployments unaudited and potentially non-compliant.
- **Compliance debt accumulation** — Without regular, automated checks, infrastructure drift goes undetected, creating compounding compliance and security risk over time.
- **Inconsistent hardening posture** — The absence of a unified compliance check mechanism means that security hardening levels vary significantly across teams, with no reliable way to measure or report on the aggregate posture.

### 2.2 Consequence of Inaction

Leaving these environments unscanned exposes an organisation to:

- Regulatory and audit risk where infrastructure cannot be evidenced as compliant.
- Elevated attack surface due to misconfigured or unhardened systems.
- Reputational risk in the event of a breach originating from an unmonitored asset.
- Inability to provide evidence-based assurance to leadership or external auditors on the security posture of products.

---

## 3. Solution Overview

HardenX performs automated, targeted compliance assessments against the **CIS Benchmarks** — a globally recognised set of security configuration standards — across the technology stacks used by internal teams and external client environments.

The engine is designed to be:

- **Environment-agnostic** — capable of running checks against cloud-hosted infrastructure regardless of the cloud provider or configuration model.
- **Technology-aware** — built to recognise and assess the specific technologies in use across teams, rather than applying a one-size-fits-all scanner.
- **Actionable** — producing prioritised, human-readable reports that map findings directly to CIS controls and recommended remediation steps.
- **Extensible** — structured so that new technology checks can be added as the organisation's stack evolves or as new client engagements demand coverage of additional platforms.

---

## 4. Goals and Objectives

| Goal | Description |
|------|-------------|
| **Close the scanner gap** | Provide compliance visibility into cloud environments that existing enterprise scanners cannot reach. |
| **Enforce CIS standards** | Systematically check infrastructure configurations against CIS Benchmarks and surface deviations. |
| **Enable self-service hardening** | Equip engineering teams with actionable reports they can act on without waiting for a centralised security review. |
| **Support VAPT engagements** | Package compliance checks as an add-on service for external client engagements, enhancing the value of VAPT deliverables. |

---

## 5. Scope

### 5.1 In Scope

- The five confirmed v1 technology stacks: Ubuntu 24.04 LTS, Rocky Linux, PostgreSQL, Docker, and Kubernetes.
- CIS Benchmark controls applicable to the identified technology stacks.
- Container image vulnerability scanning and SBOM generation for Docker environments where an image is provided.
- External client environments during VAPT engagements, where client consent and rules of engagement permit.

### 5.2 Out of Scope (Current Phase)

- Real-time continuous monitoring (targeted for a future iteration).
- Auto-remediation of identified findings.
- Containerd-only environments — Docker engine checks require the Docker daemon and CLI. Containerd-only hosts are not in scope for the Docker engine.
- Environments covered by existing enterprise scanner tooling — HardenX is a complement, not a replacement.

---

## 6. Technical Approach

### 6.1 Assessment Methodology

HardenX follows a structured assessment flow:

```
Deploy script bundle to target host
        │
        ▼
Researcher: detect actively running technologies
        │
        ▼
Orchestrator: scope engines to invoke based on detection
        │
        ▼
CIS Benchmark Mapping
        │
        ▼
Automated Compliance Checks
        │
        ▼
Finding Classification & Scoring
        │
        ▼
Report Generation (CSV, JSON, TXT)
```

### 6.2 CIS Benchmark Coverage

Checks are aligned to the CIS Benchmark framework, which classifies controls into two implementation levels:

- **Level 1** — Essential, foundational security configurations with minimal operational impact. These are the baseline and are applied by default.
- **Level 2** — Defence-in-depth configurations intended for high-security environments. Includes all Level 1 checks plus additional controls. Applied where the environment warrants a more stringent posture.

Each check produces one of five result statuses:

| Status | Description |
|--------|-------------|
| `PASS` | The configuration meets the CIS control. |
| `FAIL` | The configuration does not meet the CIS control. |
| `N/A` | The check is not applicable to this environment. |
| `SKIPPED` | The check was not run. The reason is recorded in the Remediation field (e.g. a required tool is not installed, or a required parameter was not provided). |
| `MANUAL_REVIEW` | The check cannot be fully automated. The relevant command output is captured and provided to the operator for manual assessment. |

Every check also records the specific CIS control ID, a description of the finding, and a remediation recommendation.

### 6.3 Technology Coverage — v1

The following five technologies constitute the confirmed scope for HardenX v1. Coverage was determined based on the technology audit conducted across internal environments.

| Technology | Category | CIS Benchmark |
|------------|----------|---------------|
| **Ubuntu 24.04 LTS** | Operating System | CIS Ubuntu Linux 24.04 LTS Benchmark |
| **Rocky Linux** | Operating System | CIS Rocky Linux Benchmark |
| **PostgreSQL** | Database | CIS PostgreSQL Benchmark |
| **Docker** | Container Runtime | CIS Docker Benchmark v1.8.0 (Docker v28+) |
| **Kubernetes** | Container Orchestration | CIS Kubernetes Benchmark |

**Rationale for v1 scope:**

- **Ubuntu 24.04 LTS & Rocky Linux** — The two primary operating systems in use across multiple deployments. Both are well-supported by CIS Benchmarks and represent the largest surface area for OS-level misconfiguration. Only Ubuntu 24.04 LTS is supported in v1; other Ubuntu versions are detected and flagged but are not assessed. All Rocky Linux versions are supported in v1.
- **PostgreSQL** — The predominant database engine across internal products. Database hardening is a high-priority control domain given the sensitivity of data typically stored at this layer.
- **Docker & Kubernetes** — Container workloads form the backbone of deployment architectures. CIS Benchmarks for both Docker (runtime) and Kubernetes (orchestration) address a broad set of controls including image security, runtime privileges, network policies, RBAC, and secrets management.

### 6.4 The Researcher

Before any compliance checks run, HardenX's Researcher component interrogates the target host to determine which of the five supported technologies are actively running. This detection step drives which Engine scripts are invoked — engines for technologies that are not running are not invoked.

**Active-running detection.** The Researcher only flags a technology as detected if it is actively running at the time of the scan. The presence of installed binaries or packages is not sufficient. This prevents engines from running checks against technologies that are installed but dormant, avoiding false positives and irrelevant findings.

**Auto-scoping.** The output of the Researcher is a structured JSON file that lists which engines to invoke. The operator does not need to know in advance what is running on the host — the Researcher determines the scan scope automatically.

**Version enforcement.** The Researcher enforces version requirements. For Ubuntu, only 24.04 LTS is supported in v1. If a different Ubuntu version is detected, the Researcher records it and notifies the operator, but the Ubuntu engine is not invoked. This ensures the correct CIS Benchmark is applied and prevents incorrect checks from running against an unsupported release.

**Permanent scan artifact.** The Researcher JSON output is retained as a permanent scan artifact alongside the engine reports at the end of every scan. It records what was detected, what was not, the detection method used for each technology, and which engines were invoked — forming a complete record of the scan's scope.

### 6.5 Scan Modes

HardenX operates in one of two modes depending on how it is invoked.

**Auto-detection mode (default)** runs the Researcher first. The Researcher detects all actively running supported technologies and the orchestrator invokes only the relevant engines in a fixed priority order. This is the standard mode for a complete infrastructure scan and produces the most thorough results.

```bash
# Full auto-detected scan at Level 1 (default)
bash hardenx.sh

# Full auto-detected scan at Level 2
bash hardenx.sh --level 2
```

**Single-technology mode (`--tech`)** bypasses the Researcher entirely and invokes one specified engine directly. This is useful when the operator already knows which technology they want to assess, wants to re-run a single engine after a full scan, or is scanning a single component in isolation.

```bash
# Run only the Docker engine at Level 2 with a target image
bash hardenx.sh --tech docker --level 2 --image myrepo/myapp:latest
```

The trade-off with single-technology mode is completeness. The Docker and Kubernetes engines include a class of checks that depend on OS engine output (see Section 6.8). When these engines are run in isolation with `--tech`, no OS engine has run and those checks are marked `SKIPPED`. A full auto-detection scan, which runs the OS engine first, produces a complete report including those findings.

### 6.6 Invocation Model

HardenX v1 is a **Bash-based CLI tool**. Bash was chosen deliberately — the overwhelming majority of technologies in scope run on Linux servers, making Bash a native, dependency-free execution environment that requires no runtime installation on the target system.

The v1 workflow is intentionally manual and follows two steps:

**Step 1 — Deploy:** The operator transfers the HardenX script bundle to the target server via SSH (or the relevant authentication method available for that environment).

```bash
scp -r hardenx/ user@target-host:/opt/hardenx/
```

**Step 2 — Invoke:** The operator SSH's into the server and manually calls the scan script, specifying the desired scan level and any optional parameters.

```bash
ssh user@target-host
cd /opt/hardenx
bash hardenx.sh --level 2
```

Each Engine script also supports a `--help` flag that prints usage information, available options, defaults, and examples, then exits without running any checks. This is intended as a quick field reference for operators.

```bash
bash engine/docker.sh --help
```

If an Engine script is invoked with no arguments, it runs with defaults — Level 1 scan, no image, and technology-appropriate defaults for any optional parameters. This keeps the tool low-friction for first-time runs and buy-in demonstrations.

This manual invocation model is appropriate for v1 given the nature of the environments being assessed. Automated scheduling and remote execution are candidates for a future version.

### 6.7 Scan ID and Finding Correlation

At the start of every scan, HardenX generates a UUID that is shared across the Researcher JSON output and every engine report produced in the same run. This Scan ID is printed in the console header at the start of the run and appears in all output files.

The Scan ID allows all findings from a single scan session to be correlated back to one point-in-time assessment. This is particularly relevant for audit evidence use cases — when a stakeholder or auditor reviews multiple engine reports, the shared Scan ID confirms they originated from the same run and the same host state.

### 6.8 Image Scanning and SBOM Generation

When a container image is provided via the `--image` flag, HardenX performs two additional assessments beyond host and daemon configuration checks.

**Vulnerability scanning.** HardenX uses Docker Scout to run a CVE scan against the target image and includes the findings in the engine report. This provides a view of known vulnerabilities present in the image's dependencies and base layers, alongside the host-level hardening findings.

**SBOM generation.** HardenX generates a Software Bill of Materials for the target image in either CycloneDX (default) or SPDX format, selectable via the `--sbom-format` flag. The SBOM file path is recorded in the engine report.

```bash
# Level 2 scan with image, CycloneDX SBOM (default)
bash hardenx.sh --tech docker --level 2 --image myrepo/myapp:latest

# Level 1 scan with image, SPDX SBOM
bash hardenx.sh --tech docker --image myrepo/myapp:latest --sbom-format spdx
```

Docker Scout must be installed on the target host for image scanning and SBOM generation to run. If it is not present, image-level checks are marked `SKIPPED` and a warning is printed to the console. Host and daemon checks are not affected.

### 6.9 Cross-Engine Dependency Model

The Docker and Kubernetes engines include a class of checks — referred to as `OS_DEPENDENT` checks — that operate at the host OS level: auditd rules for container-related files, file and directory permission checks, kernel parameters, and systemd service configuration. These checks differ between Ubuntu and Rocky Linux and are owned entirely by the OS engines.

Rather than duplicating this logic across engines, HardenX's Docker and Kubernetes engines read the OS engine's output report for these checks and reference the relevant findings directly. Each OS-dependent finding in the Docker or Kubernetes report cites the source OS engine check ID so results are fully traceable.

In practice, this means:

- The OS engine must run before the Docker or Kubernetes engine for OS-dependent findings to be populated. In auto-detection mode this is guaranteed by the fixed engine invocation order.
- When running in single-technology mode (`--tech docker` or `--tech kubernetes`), no OS engine report is present and OS-dependent checks are marked `SKIPPED`. A full auto-detection scan produces complete results.

### 6.10 Failure Resilience

HardenX is designed to return as much output as possible even when things go wrong during a scan.

**Engine failures do not abort the scan.** If one engine exits with an error, the remaining engines continue running. The failed engine is flagged in the scan footer and the orchestrator exits with a non-zero code, but findings from all other engines are complete and usable.

**Technology stopping mid-scan is handled distinctly.** If a technology that was running at detection time becomes unavailable during the scan (e.g. the Docker daemon stops), the engine detects this, exits cleanly, and the orchestrator logs the specific cause. The distinction between an engine crash and a lost technology is visible in the scan footer, so the operator knows immediately what happened.

**Signal handling.** If the operator interrupts a scan with Ctrl+C, teardown routines still run. For the Docker engine specifically, this means all registry sessions are logged out even on interruption. Partial output files produced up to the point of interruption are retained and noted as incomplete.

### 6.11 Credential Safety Model

HardenX handles credentials with the following guarantees:

- **No credential storage.** Credentials are never written to disk or persisted within HardenX. They are entered interactively at invocation time and used in-memory only.
- **Existing session detection.** Before prompting for new credentials, the Docker engine checks for any existing authenticated registry sessions on the host and surfaces them to the operator, showing the registry hostname and a masked username. The operator can retain, replace, or supplement existing sessions before the scan begins.
- **Guaranteed logout.** All registry sessions opened during a scan are fully logged out at the end of every run — whether the scan completed successfully, encountered an error, or was interrupted mid-run. The host is returned to an unauthenticated state after every HardenX invocation.

For VAPT engagements, the full credential lifecycle — provisioning, handling during the scan, and teardown — is governed by the Rules of Engagement template (see Section 7.2).

### 6.12 Access & Connectivity Model

Since HardenX is deployed directly onto the target server, it does not require inbound network access or a dedicated scanning user on a separate host. The operator needs only:

| Requirement | Detail |
|-------------|--------|
| **SSH access** | Ability to SCP the script bundle onto the target server and SSH in to invoke it. |
| **Execution permissions** | The invoking user must have sufficient privileges to run the Researcher and Engine components — typically a user with `sudo` access for OS-level checks, or the relevant service account for database and container checks. |

### 6.13 Reporting

Each Engine script produces structured findings that are passed to the Reporter. Every finding contains four fields, which map directly to the columns in all three output formats:

| Column | Description |
|--------|-------------|
| **Check Name** | The short identifier for the CIS control being evaluated. |
| **Description** | A plain-language explanation of what the check is testing and why it matters. |
| **Status** | The result of the check: `PASS`, `FAIL`, `N/A`, `SKIPPED`, or `MANUAL_REVIEW`. |
| **Remediation** | The specific action required to resolve a failing check. For `SKIPPED` checks, contains the reason the check was not run. For `MANUAL_REVIEW` checks, contains the captured command output. Empty for `PASS` and `N/A` results. |

The Reporter generates output in three formats from a single findings input: **CSV** (for data processing and import into other tools), **JSON** (for programmatic consumption and integration), and **TXT** (for human-readable review and documentation).

### 6.14 Console Output

In addition to the three file-based report formats, each Engine script streams live output to the console as checks execute. This provides real-time visibility into scan progress, supports debugging, and allows the operator to identify where a scan is stalling without waiting for the final report.

The console output has four layers:

**Section headers** — printed before each group of checks to visually separate the CIS benchmark sections as the scan progresses.

**Per-check status lines** — printed as each check completes. The format is consistent across all Engine scripts:

```
[PASS]           2.1   Ensure network traffic is restricted between containers
[FAIL]           2.2   Ensure logging level is set to info
[MANUAL_REVIEW]  2.6   Ensure TLS authentication for Docker daemon is configured
[SKIPPED: No image provided]  4.1  Ensure a user for the container has been created
```

**Manual review blocks** — for checks that cannot be fully automated (`MANUAL_REVIEW`), the relevant command output is collected during the section and printed as a block at the end of that section, before the next section begins. This keeps the per-check output readable while ensuring the operator can review raw output in context. The same output is also written to the Remediation column of the CSV report.

**Scan summary block** — after all checks have run, a summary block is printed to the console showing the total count of each status across the entire scan, along with the path to the generated report file. The summary block appears in the console only and is not written to any report file.

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 SCAN SUMMARY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  PASS             18
  FAIL              5
  MANUAL_REVIEW     3
  SKIPPED           4
  N/A               2
  ──────────────────
  TOTAL            32

  Report saved to: hardenx_docker_2026-04-10T1143.csv
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### 6.15 Tool Architecture

HardenX is structured as three discrete components that execute in sequence. This separation of concerns keeps each component focused, testable, and independently maintainable.

```
┌─────────────────────────────────────────────────────┐
│                  hardenx.sh (entrypoint)            │
└──────────────┬──────────────────────────────────────┘
               │
               ▼
┌──────────────────────────┐
│       RESEARCHER         │  Detects which supported technologies
│  researcher.sh           │  are actively running on the host and
│                          │  scopes which engines to invoke.
└──────────────┬───────────┘
               │
               ▼
┌──────────────────────────┐
│         ENGINE           │  Technology-specific scan scripts.
│  engine/ubuntu.sh        │  Each script runs the CIS checks for
│  engine/rocky.sh         │  its technology at the requested level
│  engine/postgresql.sh    │  and outputs structured findings.
│  engine/docker.sh        │
│  engine/kubernetes.sh    │
└──────────────┬───────────┘
               │
               ▼
┌──────────────────────────┐
│        REPORTER          │  Consumes findings from the Engine and
│  reporter.sh             │  generates output in CSV, JSON, and TXT.
└──────────────────────────┘
```

**Researcher** — Interrogates the host to determine which supported technologies are actively running. Produces a structured JSON output that the orchestrator reads to determine which engines to invoke. The Researcher JSON is retained as a permanent scan artifact alongside engine reports.

**Engine** — A collection of technology-specific Bash scripts, one per supported technology. Each Engine script is self-contained and implements the CIS checks for its technology at the level specified by the operator. Adding support for a new technology in future versions means adding a new Engine script without modifying the rest of the tool.

**Reporter** — Consumes the structured findings output by the Engine and produces the final reports in all three formats (CSV, JSON, TXT) from a single findings input, ensuring consistency across all outputs.

---

## 7. v1 Deliverables

The following defines what HardenX v1 will produce. These deliverables collectively constitute the definition of done for v1.

### 7.1 Tool Deliverables

**1. HardenX Bash Script Bundle**

A deployable set of Bash scripts structured around the three-component architecture (Researcher, Engine, Reporter). The bundle is self-contained and designed to be dropped onto a target Linux server via SSH and invoked manually.

**2. CIS Check Library — v1**

A validated set of CIS Benchmark checks covering all five v1 technologies, organised by scan level. Each check is peer-reviewed before inclusion in the library.

| Level | Description |
|-------|-------------|
| **Level 1** | Essential, foundational CIS controls with minimal operational impact. The default baseline — applicable to all environments. |
| **Level 2** | Defence-in-depth CIS controls for environments requiring a more stringent posture. Includes all Level 1 checks plus additional controls. |

**3. Report Output — Three Formats**

The Reporter produces findings in three formats from every scan:

| Format | Primary Use |
|--------|-------------|
| **CSV** | Data processing, import into spreadsheets or other tooling, further analysis. |
| **JSON** | Programmatic consumption, integration with other systems, future tooling. |
| **TXT** | Human-readable review, documentation, inclusion in assessment reports. |

Every finding across all three formats contains the same four fields:

| Column | Description |
|--------|-------------|
| **Check Name** | Short identifier for the CIS control being evaluated. |
| **Description** | Plain-language explanation of what the check tests and why it matters. |
| **Status** | `PASS`, `FAIL`, `N/A`, `SKIPPED`, or `MANUAL_REVIEW`. |
| **Remediation** | The specific action to resolve a failing check. For `SKIPPED` checks, contains the reason the check was not run. For `MANUAL_REVIEW` checks, contains the captured command output. Blank for `PASS` and `N/A` results. |

**4. SBOM Output**

Where Docker Scout is available and an image is provided, HardenX produces a Software Bill of Materials for the target image in CycloneDX (default) or SPDX format. The SBOM file path is recorded in the engine report.

**5. Researcher Detection Report**

Every scan in auto-detection mode produces a Researcher JSON artifact recording which technologies were detected, which were not, the detection method used for each, and the list of engines invoked. This file is retained as a permanent part of the scan record.

**6. Console Output**

Each Engine script streams live output to the console as checks execute. The console output includes section headers, a per-check status line for every check as it completes, manual review blocks at the end of each section for checks requiring operator review, and a scan summary block at the end of the run. The summary block is console-only and is not written to any report file. See Section 6.14 for the full console output specification.

### 7.2 Process & Engagement Deliverables

| Deliverable | Description |
|-------------|-------------|
| **Access & Permissions Framework** | A documented process for safely provisioning the access needed to deploy and run HardenX on a target server, including a teardown checklist for post-assessment cleanup. |
| **VAPT Rules of Engagement (RoE) Template** | A template formalising how HardenX is scoped and deployed during external VAPT engagements, covering client consent, credential handling, and deliverable expectations. |

### 7.3 v1 Success Criteria

v1 is considered complete when:

- All five technology Engine scripts are built, peer-reviewed, and functional for Level 1 and Level 2.
- Each Engine script runs with sensible defaults when invoked with no arguments.
- Each Engine script produces correct help output when invoked with `--help`.
- The Researcher correctly identifies running technologies on a target host and scopes engine invocation accordingly.
- The Researcher correctly handles unsupported OS versions and does not invoke an engine for them.
- The Reporter successfully generates CSV, JSON, and TXT output from Engine findings.
- All four report columns (Check Name, Description, Status, Remediation) are consistently populated across all formats.
- Console output streams correctly during scan execution, including section headers, per-check status lines, manual review blocks, and the scan summary block.
- Image scanning and SBOM generation produce correct output when Docker Scout is available and an image is provided.
- All registry sessions are logged out at the end of every scan, including scans that are interrupted mid-run.
- The Access & Permissions Framework and VAPT RoE Template are documented and approved.

---

## 8. Use Cases

### 8.1 Internal — Product Team Compliance Audits

Engineering and security teams can invoke HardenX against a team's environment to get a point-in-time compliance posture assessment. The output supports:

- Pre-production hardening before a product goes live.
- Periodic compliance reviews as part of a security programme.
- Evidence generation for internal audits and risk reviews.

### 8.2 Internal — Leadership Visibility

Leadership can use aggregated HardenX outputs to understand the compliance posture across all teams, track improvement over time, and make informed decisions about where to direct remediation effort and investment.

### 8.3 External — VAPT Value Addition

During client VAPT engagements, HardenX can be offered as an additional deliverable. Rather than returning only penetration test findings, the team can also provide:

- A CIS Benchmark compliance report covering the client's infrastructure.
- Hardening recommendations that go beyond identified vulnerabilities.
- A differentiated, higher-value engagement compared to standard VAPT offerings.

This positions the organisation as a comprehensive security partner rather than a point-in-time tester.

### 8.4 Container Image Security Review

Where a target Docker environment is in scope, HardenX can assess a specific container image for known vulnerabilities and produce a Software Bill of Materials. This use case is distinct from infrastructure hardening — it addresses the security posture of what is running inside the containers, not just how the host and daemon are configured.

This is relevant both internally (pre-production image review before a product goes live) and for VAPT clients who want image-level assurance alongside host-level findings.

---

## 9. Value Proposition

### For Engineering & Security Teams
- Immediate, actionable visibility into compliance gaps that were previously invisible.
- Self-service capability reduces dependency on centralised security reviews.
- Clear remediation guidance mapped to industry-standard benchmarks.
- Auto-scoping via the Researcher means no manual configuration is needed to get a complete scan — HardenX determines what to assess automatically.

### For Leadership
- Quantified, evidence-based view of the organisation's security posture across internal products.
- Demonstrates a proactive, standards-aligned approach to infrastructure security.
- Supports audit readiness and reduces the risk of compliance-related findings during external reviews.
- Scan IDs enable all findings from a point-in-time assessment to be correlated and evidenced as a single scan session.

### For External Clients (VAPT)
- Adds a compliance dimension to security assessments that clients increasingly expect.
- Provides a structured, internationally recognised framework (CIS) for understanding their hardening posture.
- Delivers SBOM output and image vulnerability findings alongside host-level compliance results  addressing the full container security picture in a single engagement.
- Increases the overall value and stickiness of the organisation's VAPT service offering.

---

## 10. Glossary

| Term | Definition |
|------|------------|
| **CLI** | Command-Line Interface — a text-based interface used to interact with a software tool by typing commands. |
| **RoE** | Rules of Engagement — a documented agreement defining the scope, methods, and boundaries of a security assessment. |
| **CIS** | Center for Internet Security — a non-profit that publishes internationally recognised security benchmarks and best practices. |
| **CIS Benchmark** | A set of configuration guidelines developed by CIS to help organisations secure their systems against known attack patterns. |
| **VAPT** | Vulnerability Assessment and Penetration Testing — a security assessment methodology that identifies and validates vulnerabilities in a target environment. |
| **SOP** | Standard Operating Procedure — the organisation's established baseline for how infrastructure should be provisioned and managed. |
| **Infrastructure Hardening** | The process of reducing a system's attack surface by applying security configurations and removing unnecessary functionality. |
| **SKIPPED** | A check result status indicating the check was not run. The reason is recorded in the Remediation field (e.g. a required tool is not installed, or a required parameter was not provided). |
| **MANUAL_REVIEW** | A check result status indicating the check cannot be fully automated. The relevant command output is captured and provided to the operator for manual assessment. |
| **Researcher** | The HardenX component that interrogates the target host before any compliance checks run, determines which supported technologies are actively running, and produces the JSON output that scopes engine invocation. |
| **Engine** | A technology-specific Bash script that implements the CIS Benchmark checks for one supported technology. Each engine is self-contained and runs at the level specified by the operator. |
| **Scan ID** | A UUID generated at the start of every HardenX run, shared across the Researcher JSON and all engine reports from the same invocation. Used to correlate all findings from a single scan session. |
| **SBOM** | Software Bill of Materials — a structured inventory of the components, libraries, and dependencies present in a software artefact such as a container image. |
| **Docker Scout** | A Docker tool used by HardenX for container image vulnerability scanning and SBOM generation. Must be installed separately on the target host. |
| **OS-Dependent Check** | A check in the Docker or Kubernetes engine that operates at the host OS level and depends on output from the OS engine (Ubuntu or Rocky Linux). These checks are skipped when no OS engine report is present. |

---

*This document is a living product paper and will be updated as HardenX progresses through development. All feedback should be directed to the issues tab.*