# HardenX — Researcher Design Document
### Component: `researcher.sh`
**Status:** Implemented
**Version:** 1.0

---

## 1. Purpose

This document defines the design for the HardenX Researcher (`researcher.sh`). The Researcher is responsible for interrogating the target host, determining which of the five v1 supported technologies are actively running, and producing a structured JSON file that `hardenx.sh` reads to determine which Engine scripts to invoke.

The Researcher does not run compliance checks. Its sole responsibility is detection and reporting. All compliance logic belongs in the Engine layer.

---

## 2. Role in the Architecture

The Researcher sits between the `hardenx.sh` entrypoint and the Engine layer:

```
hardenx.sh (entrypoint & orchestrator)
        │
        ▼
researcher.sh
        │
        └── hardenx_researcher_<timestamp>.json
                │
                ▼
hardenx.sh reads JSON → invokes relevant Engine scripts
```

`hardenx.sh` invokes the Researcher first, waits for it to complete, reads the JSON output, and then invokes only the Engine scripts that correspond to detected technologies. Engines for technologies that were not detected are not invoked.

---

## 3. Invocation

The Researcher is invoked by `hardenx.sh` as part of the standard scan flow. It can also be invoked directly by an operator for diagnostic purposes.

```bash
bash researcher.sh [OPTIONS]

Options:
  --output-dir <path>   Directory to write the JSON output file.
                        Defaults to the current directory if not specified.
  --scan-id <uuid>      Internal — passed by hardenx.sh so the Researcher and all
                        engines share one scan ID. Not shown in the help menu.
                        If omitted, the Researcher generates its own.
  --help                Display the help menu and exit. Detection does not run.
```

**Exit codes:** `0` — at least one supported technology was detected. `3` — detection completed but nothing was detected; the JSON file is still written. `1` — invalid argument, or the output directory does not exist or is not writable.

**Default behaviour:** If invoked with no arguments, the Researcher runs detection against the local host and writes the JSON output to the current directory.

```bash
# Equivalent
bash researcher.sh
bash researcher.sh --output-dir .
```

**Help menu:** Invoking `--help` prints usage information and exits without running detection.

```bash
bash researcher.sh --help
```

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 HardenX — Researcher
 Detects active technologies on the target host
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

USAGE
  bash researcher.sh [OPTIONS]

OPTIONS
  --output-dir <path>
      Directory to write the detection JSON output file.
      Defaults to the current directory if not specified.

  --help
      Display this help menu and exit.

DEFAULTS
  If invoked with no arguments:
    --output-dir .

EXAMPLES
  Run detection with default output directory:
    bash researcher.sh

  Run detection and write output to a specific directory:
    bash researcher.sh --output-dir /opt/hardenx/output

NOTES
  - sudo or root access is required for accurate detection of
    system-level services.
  - Output file: hardenx_researcher_<timestamp>.json

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## 4. Detection Scope

The Researcher checks for the following five technologies, which constitute the confirmed v1 scope:

| Technology | Category |
|---|---|
| Ubuntu 24.04 LTS | Operating System |
| Rocky Linux | Operating System |
| PostgreSQL | Database |
| Docker | Container Runtime |
| Kubernetes | Container Orchestration |

---

## 5. Detection Methodology

### 5.1 Detection Threshold

A technology is considered **detected** only if it is **actively running** at the time the Researcher executes. Presence of binaries or installed packages alone is not sufficient. This ensures that only relevant engines are invoked — an engine will not run checks against a technology that is not active on the host.

### 5.2 Per-Technology Detection Logic

Detection for each technology is evaluated independently. The methods are evaluated in the order listed, stopping at the first conclusive result.

---

#### Ubuntu 24.04 LTS

Ubuntu is an operating system, so detection is based on the host's identity rather than a running service.

| Step | Method | Command |
|---|---|---|
| 1 | Read OS release file | `cat /etc/os-release` |
| 2 | Confirm `ID=ubuntu` and `VERSION_ID="24.04"` | String match against output |

The version check is strict — Ubuntu versions other than 24.04 LTS are marked as `DETECTED_UNSUPPORTED_VERSION` rather than `DETECTED`. This ensures the correct CIS Benchmark is applied and prevents incorrect checks from running against an unsupported release.

---

#### Rocky Linux

Detection follows the same approach as Ubuntu.

| Step | Method | Command |
|---|---|---|
| 1 | Read OS release file | `cat /etc/os-release` |
| 2 | Confirm `ID="rocky"` | String match against output |

The Researcher captures the Rocky Linux version from `VERSION_ID` and includes it in the JSON output. No version restriction is applied in v1 — all Rocky Linux versions are marked `DETECTED` — however the version is recorded so the correct CIS Benchmark version can be applied by the Engine.

---

#### PostgreSQL

| Step | Method | Command |
|---|---|---|
| 1 | Check for running PostgreSQL process | `pg_isready` or `systemctl is-active postgresql` |
| 2 | If systemctl is unavailable, fall back to process check | `pgrep -x postgres` |

A successful `pg_isready` response or an `active` systemctl status constitutes detection. A PostgreSQL binary present on the host but with no running process is **not** detected.

---

#### Docker

| Step | Method | Command |
|---|---|---|
| 1 | Check Docker daemon is running | `docker info > /dev/null 2>&1` |
| 2 | If Docker info fails, check for Docker socket | `test -S /var/run/docker.sock` |

A successful `docker info` constitutes detection. If the Docker binary is present but the daemon is not running, Docker is **not** detected. If only containerd is present with no Docker daemon, Docker is **not** detected — this aligns with the containerd handling defined in the Docker Engine design document.

---

#### Kubernetes

Kubernetes detection focuses on the presence of active cluster components rather than a single service, since the relevant process differs depending on whether the host is a control plane node or a worker node.

| Step | Method | Command |
|---|---|---|
| 1 | Check for running kubelet (present on all node types) | `systemctl is-active kubelet` |
| 2 | Check for running kube-apiserver (control plane only) | `pgrep -x kube-apiserver` |
| 3 | Check for kubectl connectivity | `kubectl cluster-info > /dev/null 2>&1` |

Detection is confirmed if **any one** of the above methods returns a positive result. The Researcher records which components were found and includes this in the JSON output so the Kubernetes Engine can adjust its checks accordingly (e.g. control-plane-specific checks are only relevant if the apiserver is detected).

---

### 5.3 OS Detection Note

Because Ubuntu and Rocky Linux are operating systems, only one of the two can be detected on a given host. If neither is detected — for example, the host is running Debian or Amazon Linux — the Researcher records this in the JSON output and no OS engine is invoked. Non-OS technologies (PostgreSQL, Docker, Kubernetes) are evaluated independently of the OS result.

---

## 6. JSON Output

### 6.1 Output File

The Researcher writes its findings to a single JSON file:

```
hardenx_researcher_<timestamp>.json
```

The file is written to the directory specified by `--output-dir` (default: current directory). `hardenx.sh` reads this file immediately after the Researcher exits to determine which engines to invoke. It identifies the file by the `scan_id` it passed in, so files from earlier scans in the same directory are ignored.

### 6.2 Schema

```json
{
  "hardenx_version": "0.1",
  "scan_id": "<uuid>",
  "timestamp": "<ISO-8601>",
  "hostname": "<hostname>",
  "technologies": {
    "ubuntu": {
      "detected": true,
      "version": "24.04",
      "detection_method": "/etc/os-release",
      "notes": null
    },
    "rocky_linux": {
      "detected": false,
      "version": null,
      "detection_method": "/etc/os-release",
      "notes": null
    },
    "postgresql": {
      "detected": true,
      "version": "16.2",
      "detection_method": "pg_isready",
      "notes": null
    },
    "docker": {
      "detected": true,
      "version": "28.0.1",
      "detection_method": "docker info",
      "notes": null
    },
    "kubernetes": {
      "detected": false,
      "version": null,
      "detection_method": "systemctl, pgrep, kubectl",
      "notes": "kubelet not active, kube-apiserver not found, kubectl unreachable"
    }
  },
  "engines_to_invoke": ["ubuntu", "postgresql", "docker"]
}
```

### 6.3 Field Definitions

| Field | Description |
|---|---|
| `hardenx_version` | The version of HardenX producing this output. |
| `scan_id` | The UUID supplied by `hardenx.sh` via `--scan-id`, or generated by the Researcher when it is invoked directly. Shared across the Researcher output and all Engine reports produced in the same `hardenx.sh` invocation, enabling findings to be correlated back to a single scan session. |
| `timestamp` | ISO-8601 timestamp of when the Researcher completed detection. |
| `hostname` | The hostname of the target machine as returned by the OS. |
| `technologies` | Object containing one entry per supported technology. |
| `technologies.<name>.detected` | `true` if the technology is actively running; `false` otherwise. |
| `technologies.<name>.version` | The version of the technology detected, if determinable. `null` if not detected or version could not be read. |
| `technologies.<name>.detection_method` | The method or command that produced the detection result. |
| `technologies.<name>.notes` | Any additional context relevant to the detection result, such as why detection failed or which fallback method was used. `null` if not applicable. |
| `engines_to_invoke` | Array of technology names for which `detected` is `true`, using the same names as the keys under `technologies`. This is the field `hardenx.sh` reads to determine which engines to invoke. Rocky Linux appears here as `rocky_linux`; `hardenx.sh` maps it to its `rocky` engine. |

### 6.4 Unsupported OS Version

If an Ubuntu version other than 24.04 is detected, the entry is recorded as follows:

```json
"ubuntu": {
  "detected": false,
  "version": "22.04",
  "detection_method": "/etc/os-release",
  "notes": "Ubuntu detected but version 22.04 is not supported in v1. Supported version: 24.04 LTS."
}
```

The technology is not added to `engines_to_invoke` and the Ubuntu Engine is not invoked. The operator is informed via console output.

---

## 7. Console Output

As detection runs, the Researcher prints live output to the console.

### 7.1 Header

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 HardenX — Researcher
 Detecting active technologies on this host...
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### 7.2 Per-Technology Output

Each technology prints a single line as detection completes:

```
[DETECTED]      ubuntu        24.04 LTS
[NOT DETECTED]  rocky_linux
[DETECTED]      postgresql    16.2
[DETECTED]      docker        28.0.1
[NOT DETECTED]  kubernetes    kubelet not active, kube-apiserver not found, kubectl unreachable
```

For unsupported OS versions:

```
[UNSUPPORTED]   ubuntu        22.04 — supported version is 24.04 LTS
```

### 7.3 Summary Block

After all five technologies have been evaluated, a summary is printed:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 DETECTION SUMMARY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Technologies detected   : ubuntu, postgresql, docker
  Engines to be invoked   : ubuntu, postgresql, docker

  Detection report saved to: hardenx_researcher_2026-04-10T1143.json
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

If no supported technologies are detected:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 DETECTION SUMMARY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Technologies detected   : none

  No supported technologies were found running on this host.
  No engines will be invoked. HardenX will exit.

  Detection report saved to: hardenx_researcher_2026-04-10T1143.json
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## 8. Engine Invocation Order

Once `hardenx.sh` reads the Researcher JSON, it invokes engines in the following fixed priority order, regardless of the order technologies appear in `engines_to_invoke`:

| Priority | Engine | Rationale |
|---|---|---|
| 1 | Ubuntu or Rocky Linux | OS-level checks must run first. Docker and Kubernetes engines depend on OS engine output for `OS_DEPENDENT` checks. |
| 2 | PostgreSQL | Database checks are independent of container runtime checks. |
| 3 | Docker | Requires OS engine output for `OS_DEPENDENT` checks. |
| 4 | Kubernetes | Requires OS engine output for `OS_DEPENDENT` checks. |

If neither Ubuntu nor Rocky Linux is detected, Docker and Kubernetes engines proceed with all `OS_DEPENDENT` checks marked `SKIPPED: OS engine report not found` — consistent with the behaviour described in the Docker Engine design document.

---

## 9. Component Flow

```
hardenx.sh
        │
        ▼
researcher.sh
        │
        ├── Detect Ubuntu / Rocky Linux
        ├── Detect PostgreSQL
        ├── Detect Docker
        ├── Detect Kubernetes
        │
        ├── Write hardenx_researcher_<timestamp>.json
        └── Print detection summary to console
                │
                ▼
hardenx.sh reads engines_to_invoke from JSON
        │
        ├── [If OS detected]      → invoke Engine/ubuntu/cis_checks.sh or Engine/rocky-linux/cis_checks.sh
        ├── [If PostgreSQL]       → invoke Engine/postgres/postgres_cis_checks.sh
        ├── [If Docker detected]  → invoke Engine/docker/cis_checks.sh
        ├── [If Kubernetes]       → invoke Engine/kubernetes/cis_checks.sh
        └── [If nothing detected] → exit cleanly
```

Which flags each engine receives is described in the Orchestrator design document (Argument Pass-Through).

---

## 10. Assumptions & Constraints

- The Researcher runs on the target Linux host with `bash` available.
- `sudo` or root access is recommended for accurate service detection, particularly for systemctl-based checks.
- Only technologies in the confirmed v1 scope are detected. The Researcher does not report on technologies outside this list.
- Only one operating system can be detected per host. Ubuntu and Rocky Linux are mutually exclusive results.
- Only Ubuntu 24.04 LTS is supported in v1. Other Ubuntu versions are flagged but not passed to the Engine.
- All detected Rocky Linux versions are supported in v1. Version-specific restrictions for Rocky Linux are planned for a future iteration.
- The Researcher does not modify any system state. All detection is read-only.
- The Researcher does not invoke engines itself. Engine invocation is the responsibility of `hardenx.sh`.

---

## 11. Open Items

| # | Item | Status |
|---|---|---|
| 1 | Rocky Linux version enforcement — no version restriction in v1. All detected Rocky Linux versions are passed to the Engine. Limiting support to the latest version is planned for a future iteration. | Open — future iteration |
| 2 | `scan_id` generation method confirmed as standard `uuidgen`. | Closed |
| 3 | Researcher JSON file confirmed as a permanent scan artifact. It is retained alongside Engine and Reporter outputs at the end of every scan. | Closed |
| 4 | PostgreSQL version detection confirmed as `psql --version`. Works on both Ubuntu and Rocky Linux. Returns the client version, which is assumed to match the server version in v1. | Closed |
| 5 | Kubernetes is marked `DETECTED` when any one of kubelet, kube-apiserver or kubectl connectivity is found, but the v1 Kubernetes Engine only runs on control plane nodes and exits when `kube-apiserver` is not running. On worker nodes this surfaces in `hardenx.sh` as an engine failure. Decide whether detection should require `kube-apiserver` in v1. | Open |

---

*This document is a living design spec. Updates should be made in the issues tab and reflected here before implementation begins.*