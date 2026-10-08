# HardenX — Kubernetes Engine Design Document
### Component: `engine/kubernetes.sh` + `reporter_kubernetes.sh`
**Benchmark Reference:** CIS Kubernetes Benchmark v1.9.0 (via kube-bench)
**Kubernetes Support:** v1.24 and above
**Scope:** Control Plane (v1) — kube-apiserver, etcd, controller-manager, scheduler
**Status:** Design — Pre-Implementation
**Version:** 0.1

---

## 1. Purpose

This document defines the design for the HardenX Kubernetes Engine (`engine/kubernetes.sh`) and its accompanying temporary reporting helper (`reporter_kubernetes.sh`). Rather than implementing individual CIS checks natively, the Kubernetes Engine delegates all benchmark execution to **kube-bench** — the widely-used CIS Kubernetes Benchmark tool maintained by Aqua Security — and is responsible for invoking it correctly, parsing its JSON output, mapping results into the HardenX status model, calculating compliance scores, and writing findings in the standard four-column format that the Reporter expects.

This design keeps the engine lean and leverages a well-maintained, community-validated check library. The engine's value is in the translation layer: structured, consistent output in the HardenX format, regardless of what is upstream.

The engine supports two invocation modes for kube-bench, selected automatically at pre-flight:

- **Binary Mode** — kube-bench is installed as a binary on the control plane host and invoked directly. The JSON output is written to a local file and parsed.
- **Job Mode** — kube-bench is not installed on the host. The engine deploys kube-bench as a Kubernetes Job onto the control plane node, waits for completion, retrieves the JSON output from the pod logs via `kubectl`, then deletes the Job. The result is handed to the same parsing pipeline as Binary Mode — everything downstream is identical.

The mode selection is fully automatic. The operator does not need to specify which mode to use.

The reporting helper is a stopgap component produced ahead of the main HardenX Reporter (`reporter.sh`) and will be retired once the main Reporter is ready. It mirrors the intended Reporter interface to ensure a clean handover.

---

## 2. Role in the Architecture

```
hardenx.sh (entrypoint & orchestrator)
        │
        ▼
engine/kubernetes.sh
        │
        ├── [Binary Mode — kube-bench found in PATH]
        │     └── kube-bench run --targets master,etcd,controlplane,policies --json
        │               └── /tmp/hardenx_kubebench_<timestamp>.json
        │
        ├── [Job Mode — kube-bench not in PATH, kubectl available]
        │     ├── kubectl apply → kube-bench Job on control plane node
        │     ├── kubectl wait  → Job completes (or timeout)
        │     ├── kubectl logs  → JSON streamed to /tmp/hardenx_kubebench_<timestamp>.json
        │     └── kubectl delete → Job cleaned up
        │
        ├── Parse JSON → map to HardenX status model → calculate scores
        │
        └── reporter_kubernetes.sh
                  │
                  └── hardenx_kubernetes_<timestamp>.csv
```

kube-bench is the source of truth for all check results. The engine does not re-implement any CIS logic. Both modes produce identical JSON output — everything from the parsing stage onward is the same regardless of which mode ran. If kube-bench cannot be run via either mode, the engine exits without producing a report.

---

## 3. Invocation

The Kubernetes Engine is invoked from the main `hardenx.sh` entrypoint or directly by the operator. The following flags are supported:

```bash
bash engine/kubernetes.sh [OPTIONS]

Options:
  --level <1|2>           Scan level. Defaults to 1 if not specified.
  --kubeconfig <path>     Path to the kubeconfig file for API-dependent checks
                          and Job Mode. Defaults to /etc/kubernetes/admin.conf,
                          then ~/.kube/config. If neither is found and this flag
                          is omitted, API-dependent checks are marked SKIPPED and
                          Job Mode is unavailable.
  --namespace <name>      Kubernetes namespace in which to deploy the kube-bench
                          Job when running in Job Mode. Defaults to kube-system.
                          Ignored in Binary Mode.
  --output-dir <path>     Directory to write output files.
                          Defaults to the current directory if not specified.
  --help                  Display the help menu and exit. The scan does not run.
```

**Default behaviour:** If invoked with no arguments, the engine runs a Level 1 scan using the default kubeconfig lookup order and writes output to the current directory. No confirmation is required.

```bash
# Equivalent — both run a Level 1 scan with defaults
bash engine/kubernetes.sh
bash engine/kubernetes.sh --level 1
```

**Help menu:** Invoking `--help` prints usage information and exits without running any checks.

```bash
bash engine/kubernetes.sh --help
```

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 HardenX — Kubernetes CIS Benchmark Engine
 Benchmark : CIS Kubernetes Benchmark v1.9.0
 Scope     : Control Plane (v1)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

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

  --namespace <name>
      Kubernetes namespace in which to deploy the kube-bench Job.
      Applies to Job Mode only. Ignored when kube-bench binary is found.
      Defaults to kube-system.
      Example: --namespace hardenx

  --output-dir <path>
      Directory to write all output files.
      Defaults to the current directory if not specified.

  --help
      Display this help menu and exit.

DEFAULTS
  If invoked with no arguments:
    --level 1  --namespace kube-system  --output-dir .  (kubeconfig auto-detected, image: aquasec/kube-bench:v0.8.0)

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
  - sudo or root access is required for control plane file and process checks
    when running in Binary Mode.
  - kube-bench binary in PATH triggers Binary Mode automatically.
    If not found and kubectl is available, Job Mode is used automatically.
  - Job Mode requires permission to create, get, and delete Jobs and Pods
    in the target namespace (default: kube-system).
  - Report output: hardenx_kubernetes_<timestamp>.csv

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## 4. Pre-Flight Checks

Before kube-bench is invoked, the engine runs five pre-flight checks. The order matters — kubeconfig and API connectivity are checked before kube-bench availability, because Job Mode depends on those results. A failure that leaves no viable execution mode exits with an informative message and produces no output.

### 4.1 Control Plane Detection

The engine verifies that a control plane is actively running on this host by checking for the `kube-apiserver` process:

```bash
pgrep -x kube-apiserver > /dev/null 2>&1
```

- **If found:** The scan proceeds.
- **If not found:** The engine exits cleanly.

```
[ERROR] No control plane detected on this host.
        kube-apiserver is not running. This engine targets control plane
        nodes only.

        If this is a worker node, worker node checks are outside the scope
        of the v1 Kubernetes Engine. If you expected a control plane to be
        running, verify the cluster status before re-running.

        No checks were run. No report has been generated.
```

This mirrors the Researcher's detection logic (see `README-researcher.md`, Section 5.2). When invoked via `hardenx.sh` in auto-detection mode, the Researcher has already confirmed `kube-apiserver` is present before invoking this engine — the check here provides a safety net for direct invocations.

### 4.2 kube-bench Availability & Mode Selection

The engine checks whether the kube-bench binary is available in `PATH`:

```bash
kube-bench version > /dev/null 2>&1
```

This check determines which invocation mode the engine uses for the rest of the scan. Modes are evaluated in priority order — the engine uses the first one that is viable:

| Priority | Mode | Condition |
|---|---|---|
| 1 | **Binary Mode** | `kube-bench` is already in `PATH` and exits cleanly. |
| 2 | **Job Mode** | Binary absent. A valid kubeconfig was found and the cluster API is reachable. |
| 3 | **Install Mode** | Binary absent. Job Mode unavailable (no kubeconfig or API unreachable). A supported package manager is detected on the host. |
| — | **Exit** | None of the above conditions are met. |

The selected mode is printed to the console before the scan begins:

```
[INFO] kube-bench binary found. Running in Binary Mode.
```

```
[INFO] kube-bench binary not found in PATH.
[INFO] kubectl is available and cluster API is reachable.
[INFO] Switching to Job Mode — kube-bench will be deployed as a Kubernetes Job.
```

```
[INFO] kube-bench binary not found in PATH.
[INFO] Job Mode unavailable — kubectl cannot reach the cluster API.
[INFO] Supported package manager detected. Switching to Install Mode.
[INFO] kube-bench will be installed, used for this scan, then removed.
```

If no mode is viable, the engine exits:

```
[ERROR] kube-bench cannot be run on this host.

        - Binary not found in PATH.
        - Job Mode unavailable: no kubeconfig or cluster API unreachable.
        - Install Mode unavailable: no supported package manager (checked: apt, dnf)
          or no download tool available (checked: curl, wget).

        To resolve, either:
          - Install kube-bench manually: https://github.com/aquasecurity/kube-bench
          - Provide a valid kubeconfig: --kubeconfig <path>
          - If running Job Mode in an air-gapped environment, mirror the kube-bench
            image to an internal registry and pass it with:
            --kube-bench-image registry.acme.internal/kube-bench:v0.8.0

        No checks were run. No report has been generated.
```

The mode selection happens after the kubeconfig lookup (Step 4.3) and API connectivity test (Step 4.4) because Job Mode depends on those results. The pre-flight order is therefore: control plane detection → kubeconfig lookup → API connectivity → kube-bench availability and mode selection.

### 4.3 kubeconfig Location

The engine determines which kubeconfig to use for API-dependent checks (Section 5). The lookup order is:

| Priority | Location | Notes |
|---|---|---|
| 1 | Value of `--kubeconfig` flag | Operator-specified path. Used if provided, regardless of whether defaults exist. |
| 2 | `/etc/kubernetes/admin.conf` | kubeadm default. Present on control plane nodes provisioned with kubeadm. |
| 3 | `~/.kube/config` | Standard user-level kubeconfig. |

- **If a kubeconfig is found:** Its path is recorded. API connectivity is tested in the next step.
- **If no kubeconfig is found:** A warning is printed. Section 5 checks will be marked `SKIPPED: No kubeconfig found`. The scan continues — Sections 1, 2, and 3 do not require kubeconfig access.

```
[WARN] No kubeconfig found at default locations and --kubeconfig was not provided.
       Section 5 (Policies) checks will be marked SKIPPED.
       Checks in Sections 1, 2, and 3 will proceed as normal.

       To enable Section 5 checks, provide a kubeconfig with:
         --kubeconfig <path>
```

### 4.4 API Connectivity Test

If a kubeconfig was found in Step 4.3, the engine tests whether `kubectl` can reach the cluster API:

```bash
kubectl cluster-info --kubeconfig <path> > /dev/null 2>&1
```

- **If reachable:** Section 5 API-dependent checks proceed normally.
- **If unreachable:** A warning is printed and Section 5 checks are marked `SKIPPED: kubectl cannot reach the cluster API`.

```
[WARN] kubectl cannot reach the cluster API using: /etc/kubernetes/admin.conf
       Section 5 (Policies) checks will be marked SKIPPED.
       Checks in Sections 1, 2, and 3 will proceed as normal.
```

The engine does not retry the connectivity test. If the API is unreachable at pre-flight, it is assumed to be unavailable for the duration of the scan.

---

## 5. kube-bench Invocation

Once pre-flight completes, the engine invokes kube-bench using whichever mode was selected in Step 4.2. Both modes produce an identical JSON file at `/tmp/hardenx_kubebench_<timestamp>.json`. Everything from Section 6 onward is the same regardless of mode.

### 5.1 Targets

Both modes run kube-bench against the same set of targets, corresponding to the v1 control plane scope:

| Target | CIS Section(s) | Description |
|---|---|---|
| `master` | 1 | Control plane component config files, API server, controller manager, scheduler |
| `etcd` | 2 | etcd configuration and file permissions |
| `controlplane` | 3 | Authentication, authorisation, and audit logging configuration |
| `policies` | 5 | RBAC, pod security, network policies, secrets management |

Worker node checks (target: `node`, CIS Section 4) are explicitly excluded from the v1 scope. The `node` target is not passed to kube-bench in either mode.

### 5.2 Level Mapping

CIS Kubernetes Benchmark checks are classified as either **scored** (Level 1 — mandatory controls) or **unscored** (Level 2 — advisory controls). kube-bench exposes this distinction in its JSON output via the `scored` field on each result.

The `--level` flag maps to kube-bench results as follows:

| `--level` | Checks included |
|---|---|
| `1` (default) | Scored checks only (`"scored": true`) |
| `2` | All checks — scored and unscored (`"scored": true` and `"scored": false`) |

Both levels run the same kube-bench command. Filtering by level is applied during result parsing (Section 6), not at the kube-bench invocation stage.

---

### 5.3 Binary Mode

When the kube-bench binary is found in `PATH`, the engine invokes it directly:

```bash
kube-bench run \
  --targets master,etcd,controlplane,policies \
  --json \
  > /tmp/hardenx_kubebench_<timestamp>.json
```

The raw JSON output is written to `/tmp` and retained as a permanent scan artifact.

If kube-bench exits with a non-zero status code, the engine treats this as a fatal error and exits:

```
[ERROR] kube-bench exited with a non-zero status (exit code: <n>).
        The Kubernetes scan cannot continue.

        Review the kube-bench output above for details.
        Scan ID: <scan_id>

        No report has been generated.
```

---

### 5.4 Job Mode

When the kube-bench binary is absent but kubectl and cluster API access are available, the engine deploys kube-bench as a Kubernetes Job on the control plane node. This follows the official Aqua Security Job-based deployment pattern.

#### 5.4.1 Job Manifest

The engine generates and applies the following Job manifest at runtime. The image tag is pinned to the version that supports CIS Kubernetes Benchmark v1.9.0 (see Open Item 1):

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: hardenx-kube-bench
  namespace: <namespace>          # --namespace flag, defaults to kube-system
  labels:
    app: hardenx
    scan-id: <scan_id>
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
          image: <image:tag>             # --kube-bench-image flag; defaults to aquasec/kube-bench:v0.8.0
          command:
            - kube-bench
            - run
            - --targets
            - master,etcd,controlplane,policies
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
```

The `hostPID`, `hostIPC`, and `hostNetwork` settings are required for kube-bench to inspect control plane processes and network configuration from inside the container. All host path volume mounts are read-only — kube-bench does not modify any files.

The `scan_id` label on the Job allows the engine to uniquely identify the Job it deployed, which is important for cleanup when multiple concurrent scans are not expected but is good hygiene regardless.

#### 5.4.2 Required Permissions

The kubeconfig used must have the following permissions in the target namespace:

| Resource | Verbs |
|---|---|
| `jobs` | `create`, `get`, `delete` |
| `pods` | `get`, `list` |
| `pods/log` | `get` |

If the kubeconfig lacks these permissions, the engine prints an error and exits before deploying the Job.

```
[ERROR] Insufficient permissions to deploy the kube-bench Job.
        The kubeconfig at <path> does not have the required permissions
        in namespace <namespace>.

        Required: create/get/delete jobs, get/list pods, get pods/log
        Namespace: <namespace>

        No checks were run. No report has been generated.
```

#### 5.4.3 Wait & Result Retrieval

After applying the Job manifest, the engine waits for the Job to reach a terminal state:

```bash
kubectl wait job/hardenx-kube-bench \
  --namespace <namespace> \
  --for=condition=complete \
  --timeout=120s \
  --kubeconfig <path>
```

The timeout is **120 seconds**. This is sufficient for kube-bench to complete in all normal conditions. If the Job does not reach a terminal state within the timeout, the engine treats it as a failure (see Section 5.4.4).

Once the Job completes successfully, the engine retrieves the results from the pod logs:

```bash
kubectl logs job/hardenx-kube-bench \
  --namespace <namespace> \
  --kubeconfig <path> \
  > /tmp/hardenx_kubebench_<timestamp>.json
```

The JSON written to `/tmp` is identical in structure to what Binary Mode produces. From this point, result parsing (Section 6) proceeds identically.

Progress is printed to the console while waiting:

```
[INFO] kube-bench Job deployed: hardenx-kube-bench (namespace: kube-system)
[INFO] Waiting for Job to complete (timeout: 120s)...
[INFO] Job complete. Retrieving results...
[INFO] Results written to: /tmp/hardenx_kubebench_2026-04-10T1143.json
```

#### 5.4.4 Job Failure

If the Job fails (pod exits non-zero) or times out, the engine prints an error and exits. The Job is still deleted as part of teardown (see Section 11):

```
[ERROR] kube-bench Job did not complete successfully.
        Status : <Failed | Timed out after 120s>
        Job    : hardenx-kube-bench
        Namespace: <namespace>
        Scan ID: <scan_id>

        The Job has been deleted. No report has been generated.
        If the pod failed due to an image pull error (ErrImagePull /
        ImagePullBackOff), the cluster cannot reach the default registry.
        Mirror the image to an internal registry and retry with:
          --kube-bench-image registry.acme.internal/kube-bench:v0.8.0

        To investigate, re-run with verbose kubectl output or inspect
        pod events in the <namespace> namespace.
```

### 5.5 Install Mode

Install Mode is used when the kube-bench binary is absent and Job Mode is unavailable — typically in air-gapped clusters or environments with no kubeconfig access. The engine installs kube-bench from the official GitHub release, runs it exactly as Binary Mode does, then uninstalls it, leaving the host in the same state it was in before the scan.

#### 5.5.1 OS Detection

The engine identifies the host OS and package manager using the Researcher JSON if available, falling back to `/etc/os-release` and direct package manager detection otherwise:

| Check | Command |
|---|---|
| Researcher JSON present | Read `technologies.ubuntu` or `technologies.rocky_linux` from the Researcher output in `--output-dir` |
| Fallback — OS release file | `cat /etc/os-release` |
| Fallback — apt available | `command -v apt-get` |
| Fallback — dnf available | `command -v dnf` |

If none of these resolve to a supported OS, Install Mode is unavailable and the engine exits (see Section 4.2 exit message).

#### 5.5.2 Installation

The engine downloads and installs the kube-bench release package directly from the official GitHub releases page. The version installed is the minimum version confirmed to support CIS Kubernetes Benchmark v1.9.0 (see Open Item 1).

Before downloading, the engine prompts the operator for explicit confirmation. The scan does not proceed until the operator responds:

```
[INSTALL] kube-bench was not found on this host.
          HardenX can install it automatically to complete this scan,
          then remove it once the scan is finished.

          Package : kube-bench v0.8.0
          Source  : https://github.com/aquasecurity/kube-bench/releases
          Host    : <hostname>

          Proceed with installation? [y/N]:
```

- **y** — installation proceeds. The engine continues with the download and install sequence below.
- **N** (default) — installation is cancelled. The engine exits cleanly without running any checks.

```
[INFO] Installation cancelled by operator. No changes were made to this host.
       No checks were run. No report has been generated.
```

If the engine is running non-interactively (e.g. piped input, no TTY), the prompt cannot be displayed and Install Mode is treated as unavailable. The engine falls through to the no-viable-mode exit rather than proceeding without consent.

Before downloading, the engine checks for an available download tool in the following order:

| Priority | Tool | Detection |
|---|---|---|
| 1 | `curl` | `command -v curl` |
| 2 | `wget` | `command -v wget` |

If neither is found, Install Mode is unavailable and the engine falls through to the no-viable-mode exit (see Section 4.2).

**Ubuntu (apt):**

```bash
# curl
curl -LO https://github.com/aquasecurity/kube-bench/releases/download/v0.8.0/kube-bench_0.8.0_linux_amd64.deb

# wget fallback
wget -q https://github.com/aquasecurity/kube-bench/releases/download/v0.8.0/kube-bench_0.8.0_linux_amd64.deb

apt-get install -y ./kube-bench_0.8.0_linux_amd64.deb
rm -f ./kube-bench_0.8.0_linux_amd64.deb
```

**Rocky Linux (dnf/rpm):**

```bash
# curl
curl -LO https://github.com/aquasecurity/kube-bench/releases/download/v0.8.0/kube-bench_0.8.0_linux_amd64.rpm

# wget fallback
wget -q https://github.com/aquasecurity/kube-bench/releases/download/v0.8.0/kube-bench_0.8.0_linux_amd64.rpm

dnf install -y ./kube-bench_0.8.0_linux_amd64.rpm
rm -f ./kube-bench_0.8.0_linux_amd64.rpm
```

Installation requires `sudo` or root access and outbound internet access to `github.com`. If the download fails regardless of which tool was used, the engine exits before running any checks:

```
[ERROR] Failed to download kube-bench from GitHub.
        URL    : https://github.com/aquasecurity/kube-bench/releases/...
        Tool   : <curl|wget>
        Reason : <exit message>

        Check outbound internet access to github.com and try again.
        Alternatively, install kube-bench manually before running this engine.

        No checks were run. No report has been generated.
```

The console confirms each installation step as it completes:

```
[INSTALL] Downloading kube-bench v0.8.0 for linux/amd64...
[INSTALL] Installing package...
[INSTALL] kube-bench installed successfully.
[INSTALL] Note: kube-bench will be uninstalled at the end of this scan.
```

#### 5.5.3 Execution

Once installed, the engine runs kube-bench identically to Binary Mode:

```bash
kube-bench run \
  --targets master,etcd,controlplane,policies \
  --json \
  > /tmp/hardenx_kubebench_<timestamp>.json
```

From this point, result parsing (Section 6) proceeds identically to Binary Mode.

#### 5.5.4 Uninstall

After the scan completes — and as part of the SIGINT/SIGTERM trap if interrupted — the engine uninstalls kube-bench:

**Ubuntu:**

```bash
apt-get remove -y kube-bench
```

**Rocky Linux:**

```bash
dnf remove -y kube-bench
```

The uninstall is tracked via a runtime flag set when installation succeeds. If installation failed or was never attempted, the uninstall step is skipped. This prevents the teardown logic from attempting to remove a package that was never installed.

If the uninstall fails, the engine prints a warning with the manual removal command rather than treating it as a fatal error — the scan has already completed at this point:

```
[WARN] Failed to uninstall kube-bench automatically.
       To remove it manually, run:
         apt-get remove -y kube-bench    # Ubuntu
         dnf remove -y kube-bench        # Rocky Linux
```

---

## 6. Result Interpretation

### 6.1 kube-bench JSON Structure

kube-bench produces output as one or more concatenated JSON objects in the same file — one per target. Each object has a `Controls` wrapper key containing an array of section objects. Each section object contains a `tests` array of subsection groups, and each subsection group contains a `results` array of individual check outcomes.

The actual on-disk format is:

```
{"Controls":[{...}]}{"Controls":[{...}]}{"Controls":[{...}]}
```

This is not a valid single JSON document. The parser uses `JSONDecoder.raw_decode()` to walk the file and yield each object in sequence.

The fields used by the HardenX parser are:

| Field | Location | Used for |
|---|---|---|
| `id` | `Controls[]` entry | Subsection number (e.g. `"1.1"`, `"1.2"`) |
| `text` or `desc` | `Controls[]` entry | Subsection title. kube-bench v0.8.0 uses `desc` at the subsection level — the parser checks `text` first and falls back to `desc`. |
| `section` | `tests[]` entry | Subsection identifier within a controls block |
| `test_number` | `result` | Check ID (e.g. `"1.2.3"`) |
| `test_desc` | `result` | Check description |
| `status` | `result` | kube-bench result: `PASS`, `FAIL`, `WARN`, `INFO` |
| `remediation` | `result` | Remediation text provided by kube-bench |
| `scored` | `result` | `true` = Level 1 scored check; `false` = Level 2 unscored check |

Controls entries where `id` is empty or absent (e.g. summary nodes appended by kube-bench) are silently skipped. Results where `test_number` is empty are similarly skipped.

### 6.2 Status Mapping

kube-bench uses four status values. These are mapped to the five HardenX status values as follows:

| kube-bench status | HardenX status | Rationale |
|---|---|---|
| `PASS` | `PASS` | Check passed. Configuration meets the CIS control. |
| `FAIL` | `FAIL` | Check failed. Configuration does not meet the CIS control. |
| `WARN` | `MANUAL_REVIEW` | kube-bench cannot fully automate this check. The remediation text from kube-bench is captured and written to the Remediation column for operator review. |
| `INFO` | `MANUAL_REVIEW` | Informational — requires operator assessment. Treated the same as `WARN`. |

No kube-bench result maps to HardenX's `N/A` or `SKIPPED` statuses at the result level. `SKIPPED` is used only by the engine itself for checks that could not be evaluated at all (e.g. Section 5 checks when no kubeconfig is available).

### 6.3 Remediation Column Population

The Remediation column in the CSV is populated as follows per status:

| HardenX status | Remediation column content |
|---|---|
| `PASS` | Empty |
| `FAIL` | Remediation text from kube-bench `remediation` field |
| `MANUAL_REVIEW` | Remediation text from kube-bench `remediation` field, prefixed with `[MANUAL REVIEW REQUIRED] ` |
| `SKIPPED` | The skip reason (e.g. `No kubeconfig found`, `kubectl cannot reach the cluster API`) |
| `N/A` | Empty |

### 6.4 Level Filtering

After parsing the full kube-bench JSON output, the engine applies level filtering before producing the report:

- **Level 1:** Only results where `"scored": true` are included. Unscored results are silently dropped.
- **Level 2:** All results are included regardless of the `scored` field.

Results dropped by level filtering do not appear in the CSV, console output, or score calculation. They are not counted as `SKIPPED`.

---

## 7. Scoring Model

After result parsing and level filtering, the engine calculates a compliance score. Scores are calculated at three levels: per-section, per-target, and overall.

### 7.1 Score Formula

The score formula is identical at all three levels:

```
Score = (PASS count / (PASS count + FAIL count)) × 100
```

`MANUAL_REVIEW`, `SKIPPED`, and `N/A` results are excluded from both the numerator and denominator. The score reflects only checks that produced a definitive automated result. If no checks produced a `PASS` or `FAIL` result, the score for that scope is reported as `N/A (no scoreable results)`.

Scores are rounded to one decimal place.

Sections where all results are `MANUAL_REVIEW` or `SKIPPED` produce no `PASS` or `FAIL` counts. The denominator for those sections is zero, so they are excluded from the score table entirely rather than being reported as `0%`. The score table includes a note to this effect so the operator understands the absence of a section is not a data loss — it means every check in that section requires manual review or was skipped.

### 7.2 Score Output

Scores are printed in the scan summary block (Section 8.5) and written to a dedicated row at the end of the CSV output (Section 10.3). They are not written as check rows — they are metadata rows appended after all finding rows.

**Example score block in summary:**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 COMPLIANCE SCORES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Section 1  (Control Plane Components)   : 87.5%
  Section 2  (Etcd)                       : 100.0%
  Section 3  (Control Plane Configuration): 66.7%
  Section 5  (Policies)                   : 72.4%
  ─────────────────────────────────────────────────
  Overall Score                           : 79.2%
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## 8. OS Engine Dependency

### Architecture

The CIS Kubernetes Benchmark includes file and directory permission checks for control plane configuration files (kubeconfig files, PKI certificates, static pod manifests). kube-bench evaluates many of these directly using `stat` and process inspection. However, some host-level checks — specifically auditd rules covering Kubernetes-related paths — depend on OS-level configuration that is already assessed by the Ubuntu or Rocky Linux engine.

For these checks, the same approach used by the Docker engine applies: the Kubernetes engine reads the relevant finding from the OS engine report rather than re-running the check. Each OS-dependent finding in the Kubernetes CSV cites the source OS engine check ID so the finding is traceable.

### OS Engine Report Lookup

For each `OS_DEPENDENT` check, the engine looks for the OS engine report in the output directory:

```
Is the Ubuntu or Rocky engine report present in the output directory?
        │
        ├── Yes -> Read the relevant finding and reference it in the Kubernetes report
        │
        └── No  -> Is the OS engine marked as under maintenance?
                      ├── Yes -> SKIPPED: OS engine under maintenance
                      └── No  -> SKIPPED: OS engine report not found —
                                 run the Ubuntu or Rocky engine first
```

### Current Maintenance State

> **Note for implementers:** At the time this document was written, both the Ubuntu and Rocky Linux engines are undergoing a significant rewrite and are not available. All `OS_DEPENDENT` checks should currently be marked:
>
> `SKIPPED: OS engine under maintenance`
>
> This is a **temporary placeholder**. Once the OS engine rewrites are complete and stable reports are available, the skip logic must be replaced with live report lookups as described above. This item is tracked in the open items (see Section 12, item 4).

In practice, the number of `OS_DEPENDENT` checks in the Kubernetes engine is small — kube-bench handles the majority of file permission checks directly. The OS engine dependency is limited to audit rule checks (auditd configuration for Kubernetes-related paths) that are outside kube-bench's scope.

---

## 9. Reporting Helper (`reporter_kubernetes.sh`)

### 9.1 Purpose

`reporter_kubernetes.sh` is a temporary component that produces the CSV report from the parsed kube-bench results. It will be retired and replaced by the main `reporter.sh` when that component is ready. It is designed to be interface-compatible with the intended Reporter so that the handover requires minimal changes.

### 9.2 Input Contract

The engine passes findings to the reporting helper as a structured array in the same format used by `reporter_docker.sh`. The helper does not read the kube-bench JSON directly — it receives only the parsed, mapped, level-filtered results. This keeps the reporter interface consistent and technology-agnostic.

### 9.3 Output

The helper produces a single CSV file:

```
hardenx_kubernetes_<timestamp>.csv
```

The file is written to the directory specified by `--output-dir`.

### 9.4 CSV Fields

The CSV follows the four-column schema defined across all HardenX engines:

| Column | Description |
|---|---|
| `Check Name` | The kube-bench check number (e.g. `1.2.3`, `5.1.1`). |
| `Description` | The check description from the kube-bench `test_desc` field. |
| `Status` | `PASS`, `FAIL`, `MANUAL_REVIEW`, `SKIPPED`, or `N/A`. |
| `Remediation` | Populated per the rules in Section 6.3. Empty for `PASS` and `N/A`. |

### 9.5 Score Rows

After all finding rows, the helper appends score metadata rows to the CSV. These rows use a reserved `Check Name` prefix of `SCORE:` to distinguish them from finding rows and allow the Reporter (and any downstream tooling) to parse them separately without ambiguity.

```
SCORE:section_1,Control Plane Components,87.5%,
SCORE:section_2,Etcd,100.0%,
SCORE:section_3,Control Plane Configuration,66.7%,
SCORE:section_5,Policies,72.4%,
SCORE:overall,Overall Compliance Score,79.2%,
```

The `Status` column contains the score value. The `Remediation` column is empty for all score rows.

---

## 10. Console Output

### 10.1 Purpose

As kube-bench runs and results are parsed, the engine streams live output to the console. This allows the operator to follow progress and understand results without waiting for the final CSV.

### 10.2 Section Headers

Before printing results for each CIS section, a header is printed:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 SECTION 1 — Control Plane Components
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Note: The console output is derived from the parsed kube-bench JSON, not streamed live as kube-bench runs. kube-bench completes its full run first and writes the JSON to `/tmp`. The engine then parses and prints results section by section. The operator will see a brief pause while kube-bench executes, followed by results being printed rapidly.

### 10.3 Per-Check Output

Each check prints a single line as it is processed. The format matches all other HardenX engines:

```
[<STATUS>]  <Check ID>  <Check Description>
```

For `SKIPPED`, the reason is included inline:

```
[SKIPPED: <reason>]  <Check ID>  <Check Description>
```

**Example output for Section 1.2:**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 SECTION 1.2 — API Server
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[PASS]           1.2.1   Ensure that the --anonymous-auth argument is set to false
[PASS]           1.2.2   Ensure that the --token-auth-file parameter is not set
[FAIL]           1.2.5   Ensure that the --kubelet-certificate-authority argument is set
[MANUAL_REVIEW]  1.2.13  Ensure that the admission control plugin AlwaysPullImages is set
[PASS]           1.2.16  Ensure that the --authorization-mode argument is not set to AlwaysAllow
[SKIPPED: OS engine under maintenance]  1.2.31  Ensure that the API Server only makes use of strong cryptographic ciphers
```

### 10.4 Manual Review Block

Checks mapped to `MANUAL_REVIEW` collect their remediation text and are printed as a block at the end of the section in which they appear. The format matches the Docker engine:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 MANUAL REVIEW REQUIRED — SECTION 1.2
 The following checks require operator review.
 Output has also been captured in the CSV report.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

--- 1.2.13  Ensure that the admission control plugin AlwaysPullImages is set ---
Action  : Review the API server admission control configuration and confirm
          AlwaysPullImages is included in the --enable-admission-plugins list.
Guidance: /etc/kubernetes/manifests/kube-apiserver.yaml
---------------------------------------------------------------------------
```

If a section has no `MANUAL_REVIEW` results, the block is omitted entirely for that section.

### 10.5 kube-bench Raw Output Reference

After all sections have been printed, the engine prints the path to the raw kube-bench JSON for operators who need to inspect the unprocessed output:

```
[INFO] Raw kube-bench output retained at: /tmp/hardenx_kubebench_2026-04-10T1143.json
```

### 10.6 Scan Summary Block

After all sections and the raw output reference, the summary block is printed. It combines the status counts and compliance scores in a single block.

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 SCAN SUMMARY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  PASS             41
  FAIL              9
  MANUAL_REVIEW     6
  SKIPPED           3
  N/A               0
  ──────────────────
  TOTAL            59

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 COMPLIANCE SCORES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Section 1  (Control Plane Components)   : 87.5%
  Section 2  (Etcd)                       : 100.0%
  Section 3  (Control Plane Configuration): 66.7%
  Section 5  (Policies)                   : 72.4%
  ─────────────────────────────────────────────────
  Overall Score                           : 79.2%

  Report saved to: hardenx_kubernetes_2026-04-10T1143.csv
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

The summary block appears **only in the console**. It is not written to the CSV, except for the score rows described in Section 9.5.

---

## 11. Teardown

### 11.1 Binary Mode

The engine has no sessions to revoke and no remote resources to clean up. Teardown is minimal:

- The raw kube-bench JSON at `/tmp/hardenx_kubebench_<timestamp>.json` is **retained** as a permanent scan artifact alongside the CSV report.
- No temporary files are deleted.

```
[TEARDOWN] Scan complete. No sessions to clear.
           Raw kube-bench output: /tmp/hardenx_kubebench_2026-04-10T1143.json
```

### 11.2 Job Mode

In Job Mode, teardown must delete the kube-bench Job from the cluster regardless of whether the scan succeeded, failed, or was interrupted. Leaving the Job in the cluster is not acceptable — it holds a privileged pod with host path mounts.

The teardown sequence is:

```bash
kubectl delete job hardenx-kube-bench \
  --namespace <namespace> \
  --kubeconfig <path> \
  --ignore-not-found
```

`--ignore-not-found` ensures teardown does not fail if the Job was already deleted or never fully created (e.g. the engine was interrupted before the Job was applied).

The SIGINT/SIGTERM trap registered at startup includes this deletion. If the operator interrupts the scan at any point during Job Mode — including during the wait, log retrieval, or parsing stages — the trap fires and the Job is deleted before the engine exits.

```
[TEARDOWN] Deleting kube-bench Job from cluster...
           ✓ Deleted: hardenx-kube-bench (namespace: kube-system)
[TEARDOWN] Raw kube-bench output: /tmp/hardenx_kubebench_2026-04-10T1143.json
[TEARDOWN] Done.
```

If the Job deletion fails (e.g. the cluster API became unreachable during teardown), the engine prints a warning with the deletion command so the operator can clean up manually:

```
[WARN] Failed to delete kube-bench Job automatically.
       To clean up manually, run:
         kubectl delete job hardenx-kube-bench -n kube-system
```

### 11.3 Install Mode

Install Mode teardown combines the Binary Mode teardown with a package uninstall. The uninstall always runs last, after the CSV has been written. It is also wired into the SIGINT/SIGTERM trap — if the scan is interrupted at any point after installation, the trap fires the uninstall before exiting.

```
[TEARDOWN] Scan complete.
           Raw kube-bench output: /tmp/hardenx_kubebench_2026-04-10T1143.json
[TEARDOWN] Uninstalling kube-bench...
           ✓ kube-bench removed.
[TEARDOWN] Done.
```

If the uninstall fails, a warning is printed with the manual removal command. This is not treated as a fatal error — the scan has already completed:

```
[WARN] Failed to uninstall kube-bench automatically.
       To remove it manually, run:
         apt-get remove -y kube-bench    # Ubuntu
         dnf remove -y kube-bench        # Rocky Linux
```

---

## 12. Component Flow

```
hardenx.sh --tech kubernetes --level <1|2> [--kubeconfig <path>] [--namespace <n>] [--output-dir <path>]
        │
        ▼
engine/kubernetes.sh
        │
        ├── [Pre-flight]
        │     ├── Check kube-apiserver is running
        │     │     └── Not found -> exit with message
        │     ├── Locate kubeconfig (flag → /etc/kubernetes/admin.conf → ~/.kube/config)
        │     │     └── Not found -> warn; Section 5 = SKIPPED; Job Mode unavailable
        │     ├── Test kubectl API connectivity
        │     │     └── Unreachable -> warn; Section 5 = SKIPPED; Job Mode unavailable
        │     ├── Check for OS engine report in output directory
        │     │     ├── Found   -> load for OS_DEPENDENT check lookups
        │     │     ├── Not found, engine under maintenance -> OS_DEPENDENT = SKIPPED: OS engine under maintenance
        │     │     └── Not found, engine available -> OS_DEPENDENT = SKIPPED: OS engine report not found
        │     └── Check kube-bench binary + select mode
        │           ├── Binary found                              -> Binary Mode
        │           ├── Binary not found + kubectl available      -> Job Mode
        │           ├── Binary not found + kubectl unavailable
        │           │     + apt or dnf detected                   -> Install Mode
        │           └── None of the above                        -> exit with message
        │
        ├── [kube-bench Execution — Binary Mode]
        │     ├── kube-bench run --targets master,etcd,controlplane,policies --json
        │     └── Write raw JSON -> /tmp/hardenx_kubebench_<timestamp>.json
        │
        ├── [kube-bench Execution — Job Mode]
        │     ├── Generate Job manifest (Section 5.4.1)
        │     ├── kubectl apply → deploy Job to <namespace> on control plane node
        │     ├── kubectl wait  → Job completes (timeout: 120s)
        │     │     └── Timeout or failure -> exit with message; Job deleted in teardown
        │     ├── kubectl logs  → stream JSON to /tmp/hardenx_kubebench_<timestamp>.json
        │     └── kubectl delete → remove Job from cluster
        │
        ├── [kube-bench Execution — Install Mode]
        │     ├── Detect OS (Researcher JSON → /etc/os-release → package manager check)
        │     ├── Prompt operator for installation consent
        │     │     ├── N or no TTY -> exit cleanly, no changes made to host
        │     │     └── y -> proceed
        │     ├── Download kube-bench release package from GitHub (curl → wget fallback)
        │     │     └── Download fails -> exit with message (no install attempted)
        │     ├── Install package (apt / dnf)
        │     ├── kube-bench run --targets master,etcd,controlplane,policies --json
        │     └── Write raw JSON -> /tmp/hardenx_kubebench_<timestamp>.json
        │
        ├── [Result Parsing — identical for all modes]
        │     ├── Parse /tmp/hardenx_kubebench_<timestamp>.json
        │     ├── Apply level filter (Level 1: scored only; Level 2: all)
        │     ├── Map kube-bench statuses to HardenX statuses (Section 6.2)
        │     └── Apply OS_DEPENDENT check overrides
        │
        ├── [Console Output — per section]
        │     ├── Print section header
        │     ├── Print per-check status lines
        │     └── Print manual review block (if any MANUAL_REVIEW in section)
        │
        ├── [Scoring]
        │     └── Calculate per-section and overall scores (Section 7)
        │
        ├── [Console Summary]
        │     └── Print status counts + compliance scores + raw JSON path
        │
        ├── [Reporter]
        │     └── reporter_kubernetes.sh -> hardenx_kubernetes_<timestamp>.csv
        │
        └── [Teardown]
              ├── Binary Mode  : print completion message
              ├── Job Mode     : kubectl delete job (also fires on SIGINT/SIGTERM)
              └── Install Mode : uninstall kube-bench via apt/dnf (also fires on SIGINT/SIGTERM)
```

---

## 13. Assumptions & Constraints

- The engine runs on the target Linux host with `bash` available.
- **Binary Mode** requires `sudo` or root access. kube-bench reads control plane configuration files and inspects processes that require elevated privileges.
- **Job Mode** does not require elevated privileges on the host. It requires only `kubectl` access and sufficient RBAC permissions to create and delete Jobs and read pod logs in the target namespace (see Section 5.4.2).
- **Install Mode** requires `sudo` or root access for package installation and uninstallation, and outbound internet access to `github.com`. It requires either `curl` or `wget` to be available on the host — `curl` is checked first, with `wget` as a fallback. If neither is present, Install Mode is unavailable.
- Mode selection is automatic and follows the priority order: Binary Mode → Job Mode → Install Mode. The operator cannot manually select a mode in v1.
- In Job Mode, the kube-bench container image must be pullable from the cluster. Air-gapped clusters without access to the container registry must use Binary Mode or Install Mode (see Open Item 7).
- In Install Mode, the package downloaded from GitHub is removed at the end of every scan via the teardown sequence and the SIGINT/SIGTERM trap. A failed uninstall produces a warning but does not affect the scan results.
- The engine targets **control plane nodes only** in v1. Worker node checks (kube-bench target: `node`, CIS Section 4) are out of scope. Running the engine on a worker-only node will exit at the control plane detection step.
- The `policies` target (Section 5) requires live API connectivity. If the API server is unreachable or no kubeconfig is available, Section 5 checks are skipped in their entirety. This applies to all modes.
- The engine does not store or persist any credentials. The kubeconfig path is used in-memory only.
- kube-bench's own CIS check library is the source of truth for check content. The version of the kube-bench binary or image used will affect check results without any change to this engine.
- The `OS_DEPENDENT` checks are currently marked `SKIPPED: OS engine under maintenance` pending the completion of the Ubuntu and Rocky Linux engine rewrites.

---

## 14. Open Items

| # | Item | Owner |
|---|---|---|
| 1 | Confirm whether the `policies` target should be run at Level 1 or gated to Level 2 only. Currently included at both levels. | Security team |
| 2 | Define the handover interface contract between `reporter_kubernetes.sh` and the future `reporter.sh`. The `SCORE:` row prefix (Section 9.5) must be agreed and consistent with how the Reporter will handle score metadata from all engines. | Security team |
| 3 | **Replace OS engine maintenance placeholders with live report lookups once Ubuntu and Rocky Linux engine rewrites are complete.** All `OS_DEPENDENT` checks currently marked `SKIPPED: OS engine under maintenance` must be revisited at that point. | Engineering |
| 4 | Confirm whether worker node checks should be added as a v1.1 scope extension or deferred to v2. Worker node detection logic is already present in the Researcher. | Product |
| 5 | Confirm Job Mode timeout value. 120 seconds is the current default. Environments with slow image pulls or constrained nodes may require a longer timeout. | Engineering |
| 6 | Confirm the RBAC requirements for Job Mode are acceptable to the security team and define whether a pre-created ServiceAccount and Role should be provided as a separate HardenX manifest, or whether the operator is expected to provision this independently. | Security team |

---

*This document is a living design spec. Updates should be made in the issues tab and reflected here before implementation begins.*