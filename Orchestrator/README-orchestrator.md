# Adhiambo — Orchestrator Design Document

### Component: `adhiambo.sh`

**Status:** Implemented — engine integration in progress (see Section 5.2)
**Version:** 1.0

---

## 1. Purpose

This document defines the design for the Adhiambo orchestrator (`adhiambo.sh`). The orchestrator is the single entry point for every Adhiambo scan. It is responsible for accepting operator input, invoking the Researcher, reading the Researcher's detection output, and invoking the relevant Engine scripts in the correct order.

`adhiambo.sh` owns the end-to-end scan lifecycle. It does not perform detection or compliance checks itself — those responsibilities belong to the Researcher and Engine layers respectively. Its role is coordination: ensuring the right components run, in the right order, with the right arguments.

---

## 2. Role in the Architecture

```
Operator
    │
    ▼
adhiambo.sh  ◄── entry point & orchestrator
    │
    ▼
researcher.sh
    │
    └── adhiambo_researcher_<timestamp>.json
            │
            ▼
adhiambo.sh reads JSON → invokes Engine scripts in priority order
    │
    ├── Engine/ubuntu/cis_checks.sh             (if detected)
    ├── Engine/rocky-linux/cis_checks.sh        (if detected)
    ├── Engine/postgres/postgres_cis_checks.sh  (if detected)
    ├── Engine/docker/cis_checks.sh             (if detected)
    └── Engine/kubernetes/cis_checks.sh         (if detected)
            │
            ▼
        reporter.sh  (once available; reporter_docker.sh in interim)
```

All paths are resolved relative to the project root, which is the parent of the `Orchestrator/` directory `adhiambo.sh` lives in. The script can be invoked from any working directory.

Throughout this document the engines are referred to by their technology key — `ubuntu`, `rocky`, `postgresql`, `docker`, `kubernetes` — which is also the value accepted by `--tech`. Each key maps to the script shown above.

---

## 3. Invocation

```bash
bash adhiambo.sh [OPTIONS]

Options:
  --level <1|2>           Scan level. Defaults to 1 if not specified.
  --tech <technology>     Run a single-technology scan, bypassing the Researcher.
                          Valid values: ubuntu | rocky | postgresql | docker | kubernetes
                          If omitted, the Researcher runs and detects all active technologies.
  --image <image:tag>     Target container image for Docker and Kubernetes image-level checks.
                          Passed through to the relevant Engine(s) when Docker or Kubernetes
                          is in scope. Ignored if neither is detected or specified via --tech.
  --sbom-format <format>  SBOM output format: cyclonedx | spdx.
                          Passed through to the Docker Engine. Defaults to cyclonedx.
  --output-dir <path>     Directory to write all output files (Researcher JSON, Engine CSVs).
                          Defaults to the current directory if not specified.
  --help                  Display the help menu and exit. No scan runs.
```

**Default behaviour:** If invoked with no arguments, the Researcher runs against the local host, detects all active supported technologies, and invokes the relevant engines at Level 1.

```bash
# Equivalent — both run a full auto-detected Level 1 scan
bash adhiambo.sh
bash adhiambo.sh --level 1
```

**Single-technology scan:** The `--tech` flag bypasses the Researcher entirely and invokes only the specified engine directly. This is useful when the operator already knows which technology they want to assess, or when running Adhiambo against a single component in isolation.

```bash
# Run only the Docker engine at Level 2
bash adhiambo.sh --tech docker --level 2 --image myrepo/myapp:latest
```

**Help menu:** Invoking `--help` prints usage information and exits without running any scan.

```bash
bash adhiambo.sh --help
```

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Adhiambo — CIS Compliance & Infrastructure Hardening Engine
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

USAGE
  bash adhiambo.sh [OPTIONS]

OPTIONS
  --level <1|2>
      Scan level to run.
      Level 1 — Essential, foundational CIS controls. (default)
      Level 2 — Defence-in-depth controls. Includes all Level 1 checks.

  --tech <technology>
      Run a single-technology scan, bypassing the Researcher.
      Valid values: ubuntu | rocky | postgresql | docker | kubernetes
      If omitted, the Researcher auto-detects all active technologies.

  --image <image:tag>
      Target container image for Docker and Kubernetes image-level checks.
      Passed through to the relevant Engine(s).
      Example: myrepo/myapp:latest
      Example: 123456789.dkr.ecr.eu-west-1.amazonaws.com/myapp:v1.2

  --sbom-format <cyclonedx|spdx>
      SBOM output format for Docker Scout.
      Defaults to cyclonedx if not specified.

  --output-dir <path>
      Directory to write all output files.
      Defaults to the current directory if not specified.

  --help
      Display this help menu and exit.

DEFAULTS
  If invoked with no arguments:
    --level 1  --output-dir .  --sbom-format cyclonedx  (Researcher auto-detection)

EXAMPLES
  Full auto-detected scan at Level 1 (default):
    bash adhiambo.sh

  Full auto-detected scan at Level 2:
    bash adhiambo.sh --level 2

  Single-technology scan — Docker at Level 2 with an image:
    bash adhiambo.sh --tech docker --level 2 --image myrepo/myapp:latest

  Full scan with a specific output directory:
    bash adhiambo.sh --output-dir /opt/adhiambo/output

NOTES
  - sudo or root access is required for OS-level and daemon-level checks.
  - All output files are written to the directory specified by --output-dir.
  - Using --tech bypasses the Researcher and runs the engine script only.
    Engines with OS-dependent checks (e.g. docker, kubernetes) will mark
    those checks SKIPPED when no OS engine report is present. Use
    auto-detection mode for a complete scan.
  - See the individual engine documentation for technology-specific requirements.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## 4. Scan Modes

`adhiambo.sh` operates in one of two modes depending on whether `--tech` is provided.

### 4.1 Auto-Detection Mode (default)

When `--tech` is not provided, the orchestrator runs the Researcher first and uses its JSON output to determine which engines to invoke. This is the standard mode for a full infrastructure scan.

```
Researcher runs → JSON output → orchestrator reads engines_to_invoke → engines invoked
```

### 4.2 Single-Technology Mode (`--tech`)

When `--tech` is provided, the Researcher is skipped entirely. The orchestrator validates the provided technology name and invokes the corresponding engine script directly with the supplied arguments. No detection, no JSON output, no Researcher console output.

This mode is appropriate when:

- The operator is scanning a known single-technology environment.
- The operator wants to re-run one engine after a full scan without repeating detection.
- The Researcher is being bypassed for diagnostic or development purposes.

**Consequence — OS-dependent checks will be skipped:** Engines such as Docker and Kubernetes include `OS_DEPENDENT` checks that require a prior OS engine report to be present in the output directory. When `--tech` is used to invoke these engines in isolation, no OS engine has run and no OS report exists. Those checks will be marked `SKIPPED: OS engine report not found`, consistent with the skip logic defined in the Docker Engine design document. The operator should be aware that the resulting report will not include OS-level findings for the targeted technology. To obtain a complete report including OS-dependent checks, use auto-detection mode without `--tech` so that the OS engine runs first.

**Validation:** If an unrecognised value is passed to `--tech`, the orchestrator exits immediately with an error before any scan runs.

```
[ERROR] Unrecognised value for --tech: "nginx"
        Valid values: ubuntu | rocky | postgresql | docker | kubernetes

        No scan was run.
```

---

## 5. Argument Pass-Through

The orchestrator forwards operator arguments to the components it invokes. Engines exit with an error on any flag they do not recognise, so the orchestrator forwards **only the flags each engine currently accepts**. The supported set per engine is held in the `ENGINE_FLAGS` table in `adhiambo.sh`.

### 5.1 Target Contract

Once every engine implements the full interface, the pass-through is:

| Argument | Passed to |
|---|---|
| `--level` | All engines |
| `--image` | `docker`, `kubernetes` |
| `--sbom-format` | `docker` |
| `--output-dir` | All engines, `researcher.sh` |
| `--scan-id` | All engines, `researcher.sh` (internal — not an operator flag) |

### 5.2 Current State

| Engine | `--level` | `--output-dir` | `--scan-id` | `--image` | `--sbom-format` |
|---|---|---|---|---|---|
| `ubuntu` | ✓ | ✓ | ✓ | — | — |
| `rocky` | ✗ | ✗ | ✗ | — | — |
| `postgresql` | ✗ | ✓ | ✗ | — | — |
| `docker` | ✓ | ✓ | ✓ | ✓ | ✓ |
| `kubernetes` | ✓ | ✓ | ✓ | ✗ | — |

✓ forwarded · ✗ not yet supported by the engine, so not forwarded · — not applicable to this engine

Consequences the operator should be aware of:

- **`rocky`** takes no arguments. It runs the same checks regardless of `--level`, prints results to the console only, and writes no report file.
- **`postgresql`** runs the same checks regardless of `--level`. It is interactive: it prompts for execution mode, database credentials, a user list and a log size before scanning, so it cannot run unattended.
- **`kubernetes`** does not accept `--image`. If `--image` is supplied it is forwarded to `docker` only.
- **`docker`** — `Engine/docker/cis_checks.sh` is currently a placeholder that accepts the flags and performs no checks. The HardenX tool under `Engine/docker/hardenx/` is not yet wired to it.

When an engine gains support for a flag, add it to that engine's entry in `ENGINE_FLAGS` and update the table above.

The orchestrator does not transform or interpret these arguments before passing them — it forwards the raw values provided by the operator, with the exception of `--output-dir`, which is resolved to an absolute path. Each engine is responsible for validating its own inputs.

---

## 6. Engine Invocation Order

When operating in auto-detection mode, the orchestrator invokes engines in the following fixed priority order, regardless of the order technologies appear in the Researcher's `engines_to_invoke` array:

| Priority | Engine | Rationale |
|---|---|---|
| 1 | `ubuntu` or `rocky` | OS-level checks must complete first. The Docker and Kubernetes engines depend on OS engine output for `OS_DEPENDENT` checks. Only one OS engine can run per host. |
| 2 | `postgresql` | Database checks are independent of container runtime findings. |
| 3 | `docker` | Requires OS engine output for `OS_DEPENDENT` checks. |
| 4 | `kubernetes` | Requires OS engine output for `OS_DEPENDENT` checks. |

In single-technology mode (`--tech`), only the specified engine runs. Invocation order is not relevant.

**Technology name mapping:** The Researcher reports Rocky Linux as `rocky_linux` in `engines_to_invoke` (see the Researcher design document). The orchestrator maps this to its own engine key `rocky` when reading the JSON. All other names are identical in both components.

---

## 7. Output Directory Management

All output files produced by the Researcher and Engines are written to the directory specified by `--output-dir` (default: current directory). The orchestrator is responsible for:

- Passing `--output-dir` consistently to the Researcher and to every Engine script that accepts it (see Section 5.2).
- Verifying that the output directory exists and is writable before any component runs.
- Resolving the directory to an absolute path, so every component writes to the same location regardless of its own working directory.

After the Researcher exits, the orchestrator locates its JSON output by matching the current `scan_id` inside `adhiambo_researcher_*.json` files in the output directory. A Researcher file left behind by an earlier scan is never used.

If the specified directory does not exist or is not writable, the orchestrator exits before invoking any component:

```
[ERROR] Output directory is not writable or does not exist: /opt/adhiambo/output

        No scan was run.
```

---

## 8. Console Output

### 8.1 Scan Header

The orchestrator prints a header at the start of every scan run:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Adhiambo — CIS Compliance & Infrastructure Hardening Engine
 Scan ID  : a3f1c2d4-7e89-4b12-bc34-0f1e2d3a4c5b
 Host     : prod-server-01
 Level    : 2
 Mode     : Auto-detection
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

In single-technology mode, `Mode` reflects the targeted technology:

```
 Mode     : Single-technology — docker
```

### 8.2 Component Handoff Messages

As the orchestrator transitions between components, it prints brief handoff messages so the operator can follow the scan lifecycle.

**Auto-detection mode:**

```
[INFO] Starting Researcher...
```

*(Researcher output follows)*

```
[INFO] Researcher complete. Technologies detected: ubuntu, postgresql, docker
[INFO] Invoking engines in order: ubuntu → postgresql → docker
```

*(Engine output follows for each)*

```
[INFO] All engines complete.
```

**Single-technology mode:** The Researcher does not run, so no Researcher handoff messages are printed. The orchestrator moves directly from the scan header to engine invocation:

```
[INFO] Invoking engine: docker
```

*(Engine output follows)*

```
[INFO] Engine complete.
```

### 8.3 No Technologies Detected

If the Researcher detects no supported technologies, the orchestrator exits cleanly after the Researcher summary without invoking any engines:

```
[INFO] No supported technologies detected. Nothing to scan. Adhiambo will exit.
```

### 8.4 Scan Footer

After all components have completed, the orchestrator prints a closing footer. The footer shows a per-engine breakdown of all check statuses — PASS, FAIL, SKIPPED, MANUAL_REVIEW, and N/A — alongside the list of output files produced during the run.

> **Note:** The per-engine status counts in the footer are sourced from the Reporter output. Full implementation of this footer is pending the Reporter design. Until the Reporter is in place, the footer lists output files only.

> **Note — report file names:** The examples below show the target naming convention, `adhiambo_<technology>_<timestamp>.csv`. Not every engine follows it yet. The footer lists the file each engine actually writes, as defined in the `ENGINE_REPORT_GLOBS` table in `adhiambo.sh`, and only counts files written during the current scan:
>
> | Engine | Report listed in the footer |
> |---|---|
> | `ubuntu` | `adhiambo_ubuntu_<timestamp>.csv` |
> | `rocky` | None — console output only |
> | `postgresql` | `postgres_compliance_<hostname>_<date>.csv` |
> | `docker` | None — the placeholder writes no report |
> | `kubernetes` | `adhiambo_kubernetes_<timestamp>.csv` |
>
> For engines with no report file the footer prints `<technology>: no report file in output directory (see engine output above)`. If an engine that should write a report did not, the footer prints `adhiambo_<technology>_<not produced>`.

**Auto-detection mode:**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 SCAN COMPLETE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Results summary:

  ubuntu
    PASS           42
    FAIL            6
    SKIPPED         3
    MANUAL_REVIEW   2
    N/A             1
    ─────────────────
    TOTAL          54

  postgresql
    PASS           18
    FAIL            4
    SKIPPED         0
    MANUAL_REVIEW   1
    N/A             2
    ─────────────────
    TOTAL          25

  docker
    PASS           31
    FAIL            8
    SKIPPED         5
    MANUAL_REVIEW   3
    N/A             2
    ─────────────────
    TOTAL          49

  Output files:
    adhiambo_researcher_2026-04-10T1143.json
    adhiambo_ubuntu_2026-04-10T1143.csv
    adhiambo_postgresql_2026-04-10T1143.csv
    adhiambo_docker_2026-04-10T1143.csv

  Output directory: /opt/adhiambo/output
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

**Single-technology mode:** No Researcher JSON is produced. Only the engine output file is listed:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 SCAN COMPLETE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Results summary:

  docker
    PASS           31
    FAIL            8
    SKIPPED         5
    MANUAL_REVIEW   3
    N/A             2
    ─────────────────
    TOTAL          49

  Output files:
    adhiambo_docker_2026-04-10T1143.csv

  Output directory: /opt/adhiambo/output

  Note: Scan was run in single-technology mode (--tech docker).
        OS-dependent checks were marked SKIPPED — no OS engine report present.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

The `Note` line appears only for engines that contain `OS_DEPENDENT` checks (Docker, Kubernetes). It is omitted for OS and PostgreSQL engines, which have no such dependency.

---

## 9. Scan ID

The orchestrator generates a UUID at startup and passes it to the Researcher and all Engine scripts as the `scan_id`. This ID appears in the Researcher JSON output and is included in every Engine report, allowing all findings from a single invocation to be correlated back to one scan session.

```bash
SCAN_ID=$(uuidgen)
```

The `scan_id` is also printed in the scan header (see Section 8.1).

---

## 10. Component Flow

```
adhiambo.sh
    │
    ├── [Startup]
    │     ├── Register SIGINT/SIGTERM trap → cleanup function
    │     ├── Parse and validate arguments
    │     ├── Verify output directory is writable
    │     ├── Generate scan_id
    │     └── Print scan header
    │
    ├── [Mode: Auto-detection]
    │     ├── Invoke researcher.sh --output-dir <path> --scan-id <uuid>
    │     ├── Read the adhiambo_researcher_<timestamp>.json carrying this scan_id
    │     └── Build ordered engine invocation list from engines_to_invoke
    │           (rocky_linux is mapped to the rocky engine)
    │
    │   [Mode: Single-technology]
    │     ├── Validate --tech value
    │     └── Build single-item engine invocation list (no Researcher invoked)
    │
    ├── [Engine Invocation — in priority order]
    │     ├── Invoke each engine with the flags it accepts (see Section 5.2)
    │     ├── Print handoff message before each engine
    │     └── Wait for each engine to complete before invoking the next
    │
    ├── [Scan Footer]
    │     └── Print list of all output files and output directory
    │
    └── [Exit]
          └── Exit 0 on success; non-zero on any component failure
```

---

## 11. Failure Modes

The orchestrator defines five failure conditions. Each has a distinct exit code, console message, and teardown behaviour.

### Exit Code Reference

| Exit Code | Condition |
|---|---|
| `0` | Scan completed successfully. |
| `1` | User interruption — operator sent SIGINT (Ctrl+C) or SIGTERM. |
| `2` | Engine failure — an engine script exited with a non-zero status during a scan. |
| `3` | No technologies found — the Researcher completed but detected no supported technologies. |
| `4` | Technology stopped mid-scan — a technology became unavailable after the scan started. |
| `5` | Engine not found — a required engine script is missing from the bundle at startup. |

---

### 11.1 User Interruption

**Trigger:** The operator sends SIGINT (Ctrl+C) or SIGTERM while a scan is in progress.

The orchestrator registers a trap for both signals as the **first action at startup**, before argument parsing, pre-flight checks, or any component is invoked. This ensures the trap is active for the entire lifecycle of the script.

```bash
cleanup() {
    echo ""
    echo "[INTERRUPTED] Scan interrupted by operator."
    echo "[TEARDOWN]    Running cleanup..."
    # Any orchestrator-level cleanup (e.g. temp files) runs here.
    # Registry logout is handled by the engine-level trap — see note below.
    echo "[TEARDOWN]    Done."
    exit 1
}

trap cleanup SIGINT SIGTERM
```

When the trap fires, the orchestrator prints a message, runs its own cleanup, and exits with code `1`.

```
[INTERRUPTED] Scan interrupted by operator.
[TEARDOWN]    Running cleanup...
[TEARDOWN]    Done.

Partial output files may exist in: /opt/adhiambo/output
Adhiambo exited.
```

Any output files written up to the point of interruption are retained. They are noted as partial in the message so the operator is aware the report is incomplete.

**Engine-level traps:** The orchestrator trap handles cleanup at the orchestrator level. Engines that open sessions or acquire resources — such as the Docker engine's registry logins — are responsible for their own SIGINT/SIGTERM traps to guarantee resource release regardless of how they are invoked. When an interruption occurs during an engine invocation, the engine's trap fires first and handles engine-specific teardown (e.g. Docker registry logout). The orchestrator's trap then handles any remaining orchestrator-level cleanup. The two traps are independent and do not conflict.

---

### 11.2 Engine Failure

**Trigger:** An engine script exits with a non-zero status code during execution (e.g. an unhandled error or unexpected crash within the engine).

The orchestrator logs the failure, marks that engine as failed in the scan footer, and **continues invoking the remaining engines**. A failed engine does not abort the scan — other technologies should still be assessed.

```
[ERROR] Engine failed: docker (exit code 2)
        The Docker engine encountered an unexpected error and did not complete.
        Remaining engines will still run.
        Please report this issue with the scan_id: a3f1c2d4-7e89-4b12-bc34-0f1e2d3a4c5b
```

The scan footer reflects the failure:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 SCAN COMPLETE (with errors)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Output files:
    adhiambo_researcher_2026-04-10T1143.json
    adhiambo_ubuntu_2026-04-10T1143.csv
    adhiambo_docker_2026-04-10T1143.csv        [FAILED — incomplete]
    adhiambo_kubernetes_2026-04-10T1143.csv

  Output directory: /opt/adhiambo/output
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

The orchestrator exits with code `2` if one or more engines failed, even if other engines completed successfully.

---

### 11.3 No Technologies Found

**Trigger:** The Researcher completes successfully but `engines_to_invoke` in the output JSON is empty — no supported technologies were detected as actively running on the host.

This is not an error condition. The Researcher ran correctly; there is simply nothing to scan.

```
[INFO] No supported technologies detected. Nothing to scan. Adhiambo will exit.
```

The Researcher JSON is retained as a scan artifact. No engine is invoked. The orchestrator exits with code `3`.

---

### 11.4 Technology Stopped Mid-Scan

**Trigger:** A technology that was running at detection time becomes unavailable during the scan — for example, the Docker daemon stops or crashes while the Docker engine is executing checks.

Each engine is responsible for detecting this condition internally and signalling it to the orchestrator by exiting with code `4`. This distinguishes a lost technology from a general engine crash (exit code `2`) and allows the orchestrator to produce an accurate, specific message.

The orchestrator handles a `4` exit from an engine the same way it handles a `2` — the failed engine is logged, the remaining engines continue — but the console message and scan footer make the cause explicit.

**Console output:**

```
[ERROR] Technology unavailable: docker
        The Docker daemon stopped or became unreachable during the scan.
        The Docker engine has exited. Remaining engines will still run.
        Partial findings up to the point of failure have been retained.
        Scan ID: a3f1c2d4-7e89-4b12-bc34-0f1e2d3a4c5b
```

**Scan footer:**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 SCAN COMPLETE (with errors)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Output files:
    adhiambo_researcher_2026-04-10T1143.json
    adhiambo_ubuntu_2026-04-10T1143.csv
    adhiambo_docker_2026-04-10T1143.csv        [INCOMPLETE — technology stopped mid-scan]
    adhiambo_kubernetes_2026-04-10T1143.csv

  Output directory: /opt/adhiambo/output
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Note the distinction from an engine failure in the footer: `[INCOMPLETE — technology stopped mid-scan]` versus `[FAILED — incomplete]`. This makes it immediately clear to the operator whether the issue was with the engine itself or the technology it was scanning.

The orchestrator exits with code `4` if one or more technologies stopped mid-scan, even if all other engines completed successfully. If a mix of engine failures and mid-scan stops occurred in the same run, the orchestrator exits with code `2` — engine failure takes precedence.

---

### 11.5 Engine Not Found

**Trigger:** An engine script that is required for the current scan is missing from the Adhiambo bundle (e.g. `Engine/docker/cis_checks.sh` is absent from the deployment).

This is a pre-flight check. The orchestrator verifies that all required engine scripts exist and are executable **before** invoking the Researcher or running any checks. If any required script is missing, the scan does not start. In auto-detection mode the same check is applied to `Researcher/researcher.sh`.

```
[ERROR] Engine script not found for: docker
        The Adhiambo bundle may be incomplete or corrupted.

        Expected location : /opt/adhiambo/Engine/docker/cis_checks.sh
        Scan ID           : a3f1c2d4-7e89-4b12-bc34-0f1e2d3a4c5b

        No scan was run.
```

In auto-detection mode, the orchestrator cannot know in advance which engines will be needed (since the Researcher has not run yet), so it verifies that **all five engine scripts** are present. In single-technology mode (`--tech`), only the specified engine script is checked.

The orchestrator exits with code `5`.

---

## 12. Assumptions & Constraints

- `adhiambo.sh` runs on the target Linux host with `bash` available.
- `sudo` or root access is recommended. The orchestrator itself does not require elevated privileges, but many Engine checks do.
- Engines are invoked sequentially, not in parallel. This keeps output readable and avoids race conditions on shared output files.
- The orchestrator does not retry failed engines. If an engine exits with a non-zero status, it is logged as a failure and the remaining engines continue.
- The `scan_id` is generated once per `adhiambo.sh` invocation and is shared across all components. Direct engine invocations (outside of `adhiambo.sh`) generate their own independent scan IDs.
- SIGINT and SIGTERM traps are registered as the first action at startup, before argument parsing or any component is invoked, to ensure the trap is active for the full script lifecycle. Engine-level traps for engine-specific teardown (e.g. Docker registry logout) are the responsibility of each engine and operate independently.

---

## 13. Open Items

| # | Item | Status |
|---|---|---|
| 1 | Confirm whether `--tech` should still invoke the Researcher for metadata collection (hostname, version info) even when bypassing detection. | **Closed** — `--tech` runs the engine script only. The Researcher is not invoked. OS-dependent checks in the targeted engine are marked `SKIPPED: OS engine report not found` by design. |
| 2 | Define the non-zero exit code scheme. | **Closed** — Exit codes defined in Section 11: `0` success, `1` user interruption, `2` engine failure, `3` no technologies found, `4` technology stopped mid-scan (surfaced as engine failure), `5` engine not found. |
| 3 | Confirm behaviour when `reporter.sh` replaces interim reporting helpers — orchestrator may need to invoke `reporter.sh` as a final step once all engines complete, rather than each engine invoking its own reporter. | Open — pending Reporter design |
| 4 | Confirm whether the scan footer should include a roll-up of total PASS / FAIL counts across all engines, or whether per-engine summaries are sufficient. | **Closed** — Footer shows a per-engine breakdown of all statuses: PASS, FAIL, SKIPPED, MANUAL_REVIEW, and N/A. Full implementation pending Reporter design. |
| 5 | Bring every engine up to the target pass-through contract in Section 5.1 (`--level`, `--output-dir`, `--scan-id` on all engines; `--image` on `kubernetes`) and the `adhiambo_<technology>_<timestamp>.csv` report name. Until then the orchestrator forwards a per-engine subset (Section 5.2). | Open — `rocky`, `postgresql`, `kubernetes` outstanding |
| 6 | Replace the `Engine/docker/cis_checks.sh` placeholder with a real Docker engine entry point (wire in HardenX or implement the Docker Engine design). A Docker scan currently reports success without running any checks. | Open |
| 7 | Engines signal "technology stopped mid-scan" with exit code `4` (Section 11.4). No engine implements this yet; all failures currently surface as engine failures (exit code `2`). | Open |
| 8 | The Researcher detects Kubernetes on any node with an active kubelet, but the Kubernetes engine exits unless `kube-apiserver` is running. On worker nodes this surfaces as an engine failure. Align detection with the engine's control-plane-only scope. | Open |

---

*This document is a living design spec. Updates should be made in the issues tab and reflected here before implementation begins.*
