# Adhiambo — Ubuntu Engine Design Document
### Component: `engine/ubuntu.sh` + `reporter_ubuntu.sh`
**Benchmark Reference:** CIS Ubuntu Linux 24.04 LTS Benchmark v2.0.0
**Ubuntu Support:** 24.04 LTS only
**Deployment Target:** Ubuntu Server — desktop deployments are out of scope
**Status:** Design — Pre-Implementation (Rewrite)
**Version:** 0.1

---

## 1. Purpose

This document defines the redesigned Adhiambo Ubuntu Engine (`engine/ubuntu.sh`) and its accompanying temporary reporting helper (`reporter_ubuntu.sh`). It **supersedes the prior Ubuntu engine implementation**, which is currently inactive pending the completion of this rewrite. References to the Ubuntu engine as "under maintenance" in the Docker and Kubernetes engine design documents relate to this rewrite; once this design is implemented, the `OS_DEPENDENT` skip placeholders in those engines must be replaced with live OS engine report lookups as described in each engine's open items.

The Ubuntu Engine implements automated CIS Benchmark v2.0.0 compliance checks against a target Ubuntu 24.04 LTS **server** host, covering initial setup, services, network configuration, logging and auditing, access controls, and system maintenance. It produces findings at Level 1 (foundational controls) or Level 2 (defence-in-depth controls), depending on the scan level specified at invocation.

**This engine targets server deployments only.** Desktop-specific components — primarily the GNOME Display Manager and associated GUI configuration — are treated as hardening concerns rather than optional configuration paths: their presence on a server is a finding, not a supported state. Checks that exist solely to configure desktop software that should not be present on a server are marked `N/A: server deployment` unconditionally. If a desktop environment is detected at pre-flight, the operator is warned before the scan proceeds.

Beyond its own compliance report, the Ubuntu Engine has a second responsibility unique to OS engines: it produces a **structured JSON sidecar** — the OS engine report — that is consumed by the Docker and Kubernetes engines when they evaluate their `OS_DEPENDENT` checks. The format of this sidecar is defined in full in Section 6. The Ubuntu Engine is the sole producer of this file; Docker and Kubernetes engines are read-only consumers. The Rocky Linux Engine will produce an equivalent file in the same schema — the format defined here is the agreed contract for all OS engines.

The reporting helper is a stopgap component produced ahead of the main Adhiambo Reporter (`reporter.sh`) and will be retired once the main Reporter is ready. It mirrors the intended Reporter interface to ensure a clean handover.

---

## 2. Role in the Architecture

The Ubuntu Engine sits between the Researcher and the container/database engines in the standard scan flow. Because OS-level checks must complete before Docker and Kubernetes engines can resolve their `OS_DEPENDENT` findings, the Ubuntu Engine is always invoked first in the engine priority order (see `README-orchestrator.md`, Section 6).

```
adhiambo.sh (entrypoint & orchestrator)
        │
        ▼
researcher.sh  →  adhiambo_researcher_<timestamp>.json
        │
        ▼  [ubuntu detected]
engine/ubuntu.sh
        │
        ├── reporter_ubuntu.sh
        │         └── adhiambo_ubuntu_<timestamp>.csv         (human-readable compliance report)
        │
        ├── adhiambo_ubuntu_os_<timestamp>.json               (OS engine report — consumed by
        │                                                      Docker and Kubernetes engines
        │                                                      for OS_DEPENDENT checks)
        │
        └── adhiambo_ubuntu_manual_<timestamp>.txt            (manual review workbook —
                                                               all MANUAL_REVIEW checks
                                                               collected in one file for audit)
```

If neither the Ubuntu nor the Rocky Linux engine has run, Docker and Kubernetes engines mark all `OS_DEPENDENT` checks as `SKIPPED: OS engine report not found`. If this engine is under maintenance, those checks are marked `SKIPPED: OS engine under maintenance`. The resolution of both skip states depends on this engine being fully implemented and producing valid output.

---

## 3. Invocation

The Ubuntu Engine is invoked from the main `adhiambo.sh` entrypoint or directly by the operator. The following flags are supported:

```bash
bash engine/ubuntu.sh [OPTIONS]

Options:
  --level <1|2>         Scan level. Defaults to 1 if not specified.
  --output-dir <path>   Directory to write output files.
                        Defaults to the current directory if not specified.
  --scan-id <uuid>      Scan ID to embed in all output files, passed from adhiambo.sh.
                        If not provided, the engine generates its own UUID.
  --help                Display the help menu and exit. The scan does not run.
```

**Default behaviour:** If invoked with no arguments, the engine runs a Level 1 scan and writes output to the current directory. No confirmation is required.

```bash
# Equivalent — both run a Level 1 scan with defaults
bash engine/ubuntu.sh
bash engine/ubuntu.sh --level 1
```

**Help menu:** Invoking `--help` prints usage information and exits without running any checks.

```bash
bash engine/ubuntu.sh --help
```

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Adhiambo — Ubuntu CIS Benchmark Engine
 Benchmark : CIS Ubuntu Linux 24.04 LTS Benchmark v2.0.0
 Supported : Ubuntu 24.04 LTS only
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

USAGE
  bash engine/ubuntu.sh [OPTIONS]

OPTIONS
  --level <1|2>
      Scan level to run.
      Level 1 — Essential, foundational CIS controls. (default)
      Level 2 — Defence-in-depth controls. Includes all Level 1 checks.

  --output-dir <path>
      Directory to write all output files.
      Defaults to the current directory if not specified.

  --scan-id <uuid>
      Scan ID to embed in output files. Passed automatically by adhiambo.sh.
      If not provided, the engine generates its own UUID.

  --help
      Display this help menu and exit.

DEFAULTS
  If invoked with no arguments:
    --level 1  --output-dir .

EXAMPLES
  Run a Level 1 scan with default output directory:
    bash engine/ubuntu.sh

  Run a Level 2 scan and write output to a specific directory:
    bash engine/ubuntu.sh --level 2 --output-dir /opt/adhiambo/output

NOTES
  - sudo or root access is required for the majority of checks.
  - This engine targets Ubuntu 24.04 LTS server deployments only.
    Running it against Ubuntu Desktop, other Ubuntu versions, or other
    Linux distributions will fail pre-flight and produce no output.
    Desktop environments detected on a supposedly server host will
    trigger a warning before the scan proceeds.
  - Three output files are produced per scan:
      adhiambo_ubuntu_<timestamp>.csv      — human-readable compliance report
      adhiambo_ubuntu_os_<timestamp>.json  — structured findings consumed by
                                             the Docker and Kubernetes engines
      adhiambo_ubuntu_manual_<timestamp>.txt — manual review workbook for
                                               all MANUAL_REVIEW checks

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## 4. Pre-Flight Checks

Before any CIS checks run, the engine performs four sequential pre-flight phases: OS version verification, privilege check, desktop environment detection, and host profile detection. The host profile (Section 4.4) is built once before any benchmark section runs and referenced by all check evaluations throughout the scan.

### 4.1 OS Version Verification

The engine confirms it is running on Ubuntu 24.04 LTS by reading `/etc/os-release`:

```bash
. /etc/os-release
echo "$ID $VERSION_ID"
```

- **If `ID=ubuntu` and `VERSION_ID=24.04`:** The scan proceeds.
- **If Ubuntu is detected but the version is not 24.04:** The engine exits without running any checks.

```
[ERROR] This engine targets Ubuntu 24.04 LTS only.
        Detected : Ubuntu 22.04
        Supported: Ubuntu 24.04 LTS

        Running this engine against a different Ubuntu version may produce
        incorrect results. No checks were run. No report has been generated.
```

- **If the host is not Ubuntu:** The engine exits.

```
[ERROR] This engine targets Ubuntu 24.04 LTS only.
        The current host does not appear to be running Ubuntu.

        No checks were run. No report has been generated.
```

This pre-flight mirrors the detection logic in the Researcher (`README-researcher.md`, Section 5.2). When invoked via `adhiambo.sh` in auto-detection mode, the Researcher has already confirmed Ubuntu 24.04 is present — this check is a safety net for direct operator invocations.

### 4.2 Privilege Check

The engine checks whether it is running as root, since the majority of checks require elevated privileges to read system files, inspect running processes, and query service states.

```bash
[ "$EUID" -eq 0 ]
```

- **If running as root:** The scan proceeds without warning.
- **If not running as root:** A warning is printed and the scan still proceeds. Individual checks that fail due to insufficient permissions are recorded as `SKIPPED: Insufficient privileges` rather than causing the engine to abort.

```
[WARN] Adhiambo is not running as root. Checks requiring elevated privileges
       will be marked SKIPPED: Insufficient privileges rather than FAIL.
       For a complete scan, re-run with sudo or as root.
```

### 4.3 Desktop Environment Detection

Because this engine targets server deployments only, the presence of a desktop environment on the host is itself a hardening concern. This check runs after the privilege check and before the host profile is built.

The engine checks for desktop environment indicators:

```bash
dpkg -l ubuntu-desktop gnome-shell gdm3 xorg 2>/dev/null | grep -q ^ii
```

- **If no desktop packages are detected:** The scan proceeds normally.
- **If desktop packages are detected:** A prominent warning is printed. The scan still proceeds — the engine does not abort — but the operator is informed that results may reflect a mixed server/desktop configuration that falls outside this engine's intended scope.

```
[WARN] Desktop environment packages detected on this host (ubuntu-desktop / gdm3 / gnome-shell).
       This engine is designed for Ubuntu Server deployments only.

       GDM and desktop packages increase the attack surface of a server.
       Recommendation: remove GDM and desktop packages after the scan.

       Section 1.7 (GNOME Display Manager) benchmark checks will run normally
       since GDM is present. A custom advisory (SERVER-GDM-01) will be recorded
       recommending removal. Proceeding with server-scoped scan.
```

`DESKTOP_ENV_DETECTED` is set as a profile attribute for reference in the OS engine report.

### 4.4 Host Profile Detection

The host profile is built immediately after the desktop environment check, before any CIS benchmark section runs. It interrogates the host across five domains — infrastructure, active services, installed clients, network configuration, and package presence — to determine which conditional checks apply to this environment. All five domains are evaluated in every scan regardless of level.

The completed profile is printed to the console before the first CIS section begins, so the operator can see what the engine detected and understand in advance why certain checks will be skipped or adjusted.

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 HOST PROFILE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Infrastructure  : Azure (cloud-hosted VM, Hyper-V hypervisor)
  Services active : nginx (web server), LDAP client (sssd)
  Network         : IPv6 in active use
  Packages        : snap active, cron installed, at not installed
  Firewall        : UFW (active)

  Conditional checks will be applied based on the above profile.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

#### 4.4.1 Infrastructure Detection

**Cloud provider:**

The engine detects the cloud provider using DMI system vendor information and, where available, instance metadata endpoints. Detection is attempted in the following order. Metadata endpoint probes use a 2-second timeout and do not block or affect scan output if they time out.

| Priority | Provider | Detection method |
|---|---|---|
| 1 | Azure | DMI vendor matches `Microsoft Corporation`; or metadata endpoint `http://169.254.169.254/metadata/instance` responds with `Metadata: true` header |
| 2 | AWS | DMI vendor matches `Amazon EC2`; or `http://169.254.169.254/latest/meta-data/` responds |
| 3 | GCP | DMI vendor matches `Google`; or `http://169.254.169.254/computeMetadata/v1/` responds with `Metadata-Flavor: Google` header |
| 4 | Other cloud | DMI vendor is unrecognised but a metadata endpoint at `169.254.169.254` responds |
| — | Not cloud-hosted | None of the above respond within the timeout |

`CLOUD_HOSTED` is set to `true` if any cloud provider is detected. `CLOUD_PROVIDER` is set to `azure`, `aws`, `gcp`, `other`, or `none`.

**Hypervisor:**

```bash
systemd-detect-virt --vm 2>/dev/null
```

`HYPERVISOR_DETECTED` is set to `true` if the result is anything other than `none`.

#### 4.4.2 Active Service Detection

The engine checks whether specific server-role services are actively running. These determine which "service not installed" checks are marked N/A because the host intentionally runs the service the check would otherwise flag.

| Profile attribute | Detection command |
|---|---|
| `CONTAINERIZED_SERVICES` | `systemctl is-active docker` or `pgrep -x containerd` or `pgrep -x kubelet` |
| `DHCP_SERVER` | `systemctl is-active isc-dhcp-server` or `systemctl is-active dhcpd` or `systemctl is-active kea-dhcp4` |
| `LDAP_SERVER` | `systemctl is-active slapd` |
| `POP_IMAP_SERVER` | `systemctl is-active dovecot` or `systemctl is-active cyrus-imap` |
| `WEB_SERVER` | `systemctl is-active apache2` or `systemctl is-active nginx` |
| `CLUSTER_NODE` | `pgrep -x kubelet` or `systemctl is-active kubelet` |

#### 4.4.3 Installed Client Detection

| Profile attribute | Detection command |
|---|---|
| `LDAP_CLIENT` | `dpkg -l libpam-ldapd sssd-ldap libnss-ldap 2>/dev/null \| grep -q ^ii` |

#### 4.4.4 Network Configuration Detection

| Profile attribute | Detection method |
|---|---|
| `IPV6_IN_USE` | `sysctl -n net.ipv6.conf.all.disable_ipv6` returns `0` AND `ip -6 addr show` shows at least one inet6 address |

IPv6 is considered in active use only if both conditions are true — the kernel parameter permits it and an address is actually assigned.

#### 4.4.5 Package and Feature Detection

| Profile attribute | Detection method |
|---|---|
| `SNAP_ACTIVE` | `command -v snap` succeeds AND `snap list 2>/dev/null` returns at least one non-header line |
| `SQUASHFS_BUILTIN` | squashfs present in `/proc/filesystems` AND `modinfo squashfs 2>/dev/null` fails (not a loadable module — built into kernel) |
| `CRON_INSTALLED` | `dpkg -l cron cronie 2>/dev/null \| grep -q ^ii` |
| `AT_INSTALLED` | `dpkg -l at 2>/dev/null \| grep -q ^ii` |
| `ACTIVE_FIREWALL` | `ufw status` returns `active`; or `nft list ruleset` returns content; or `iptables -L` returns non-default rules. Evaluated in this order; first match wins. `none` if no utility is active. |
| `SUDO_LDAP_INSTALLED` | `dpkg -l sudo-ldap 2>/dev/null \| grep -q ^ii` |
| `DESKTOP_ENV_DETECTED` | Set by pre-flight phase 3 (Section 4.3); carried into the profile for inclusion in the OS engine report sidecar. |

---

## 5. CIS Benchmark v2.0.0 Check Structure

### 5.1 Sections and Check Register

Checks are organised into seven top-level sections following the CIS Ubuntu Linux 24.04 LTS Benchmark v2.0.0 structure. The complete check register below lists every check in the benchmark with its assessment type (Automated/Manual) and Server profile level (L1 or L2). This register is the authoritative source for implementation — check IDs, titles, and level assignments are taken directly from the benchmark PDF.

**Section 1 — Initial Setup**

| Check ID | Title | Type | Server Level |
|---|---|---|---|
| 1.1.1.1 | Ensure cramfs kernel module is not available | Automated | L1 |
| 1.1.1.2 | Ensure freevxfs kernel module is not available | Automated | L1 |
| 1.1.1.3 | Ensure hfs kernel module is not available | Automated | L1 |
| 1.1.1.4 | Ensure hfsplus kernel module is not available | Automated | L1 |
| 1.1.1.5 | Ensure jffs2 kernel module is not available | Automated | L1 |
| 1.1.1.6 | Ensure overlay kernel module is not available | Automated | L2 |
| 1.1.1.7 | Ensure squashfs kernel module is not available | Automated | L1 |
| 1.1.1.8 | Ensure udf kernel module is not available | Automated | L2 |
| 1.1.1.9 | Ensure firewire-core kernel module is not available | Automated | L1 |
| 1.1.1.10 | Ensure usb-storage kernel module is not available | Automated | L1 |
| 1.1.1.11 | Ensure unused filesystems kernel modules are not available | Manual | L1 |
| 1.1.2.1.1 | Ensure /tmp is tmpfs or a separate partition | Automated | L1 |
| 1.1.2.1.2 | Ensure nodev option set on /tmp partition | Automated | L1 |
| 1.1.2.1.3 | Ensure nosuid option set on /tmp partition | Automated | L1 |
| 1.1.2.1.4 | Ensure noexec option set on /tmp partition | Automated | L1 |
| 1.1.2.2.1 | Ensure /dev/shm is tmpfs or a separate partition | Automated | L1 |
| 1.1.2.2.2 | Ensure nodev option set on /dev/shm partition | Automated | L1 |
| 1.1.2.2.3 | Ensure nosuid option set on /dev/shm partition | Automated | L1 |
| 1.1.2.2.4 | Ensure noexec option set on /dev/shm partition | Automated | L1 |
| 1.1.2.3.1 | Ensure separate partition exists for /home | Automated | L2 |
| 1.1.2.3.2 | Ensure nodev option set on /home partition | Automated | L1 |
| 1.1.2.3.3 | Ensure nosuid option set on /home partition | Automated | L1 |
| 1.1.2.4.1 | Ensure separate partition exists for /var | Automated | L2 |
| 1.1.2.4.2 | Ensure nodev option set on /var partition | Automated | L1 |
| 1.1.2.4.3 | Ensure nosuid option set on /var partition | Automated | L1 |
| 1.1.2.5.1 | Ensure separate partition exists for /var/tmp | Automated | L1 |
| 1.1.2.5.2 | Ensure nodev option set on /var/tmp partition | Automated | L1 |
| 1.1.2.5.3 | Ensure nosuid option set on /var/tmp partition | Automated | L1 |
| 1.1.2.5.4 | Ensure noexec option set on /var/tmp partition | Automated | L1 |
| 1.1.2.6.1 | Ensure separate partition exists for /var/log | Automated | L2 |
| 1.1.2.6.2 | Ensure nodev option set on /var/log partition | Automated | L1 |
| 1.1.2.6.3 | Ensure nosuid option set on /var/log partition | Automated | L1 |
| 1.1.2.6.4 | Ensure noexec option set on /var/log partition | Automated | L1 |
| 1.1.2.7.1 | Ensure separate partition exists for /var/log/audit | Automated | L1 |
| 1.1.2.7.2 | Ensure nodev option set on /var/log/audit partition | Automated | L1 |
| 1.1.2.7.3 | Ensure nosuid option set on /var/log/audit partition | Automated | L1 |
| 1.1.2.7.4 | Ensure noexec option set on /var/log/audit partition | Automated | L1 |
| 1.2.1.1 | Ensure the source.list and .source files use the Signed-By option | Manual | L1 |
| 1.2.1.2 | Ensure weak dependencies are configured | Automated | L2 |
| 1.2.1.3 | Ensure access to gpg key files are configured | Automated | L1 |
| 1.2.1.4 | Ensure access to /etc/apt/trusted.gpg.d directory is configured | Automated | L1 |
| 1.2.1.5 | Ensure access to /etc/apt/auth.conf.d directory is configured | Automated | L1 |
| 1.2.1.6 | Ensure access to files in the /etc/apt/auth.conf.d/ directory is configured | Automated | L1 |
| 1.2.1.7 | Ensure access to /usr/share/keyrings directory is configured | Automated | L1 |
| 1.2.1.8 | Ensure access to /etc/apt/sources.list.d directory is configured | Automated | L1 |
| 1.2.1.9 | Ensure access to files in /etc/apt/sources.list.d are configured | Automated | L1 |
| 1.2.2.1 | Ensure updates, patches, and additional security software are installed | Manual | L1 |
| 1.3.1.1 | Ensure apparmor packages are installed | Automated | L1 |
| 1.3.1.2 | Ensure AppArmor is enabled | Automated | L1 |
| 1.3.1.3 | Ensure all AppArmor Profiles are enforcing | Automated | L2 |
| 1.3.1.4 | Ensure apparmor_restrict_unprivileged_unconfined is enabled | Automated | L1 |
| 1.4.1 | Ensure bootloader password is set | Automated | L1 |
| 1.4.2 | Ensure access to bootloader config is configured | Automated | L1 |
| 1.5.1 | Ensure fs.protected_hardlinks is configured | Automated | L1 |
| 1.5.2 | Ensure fs.protected_symlinks is configured | Automated | L2 |
| 1.5.3 | Ensure kernel.yama.ptrace_scope is configured | Automated | L1 |
| 1.5.4 | Ensure fs.suid_dumpable is configured | Automated | L1 |
| 1.5.5 | Ensure kernel.dmesg_restrict is configured | Automated | L1 |
| 1.5.6 | Ensure prelink is not installed | Automated | L1 |
| 1.5.7 | Ensure Automatic Error Reporting is configured | Automated | L1 |
| 1.5.8 | Ensure kernel.kptr_restrict is configured | Automated | L1 |
| 1.5.9 | Ensure kernel.randomize_va_space is configured | Automated | L1 |
| 1.5.11 | Ensure systemd-coredump ProcessSizeMax is configured | Automated | L1 |
| 1.5.12 | Ensure systemd-coredump Storage is configured | Automated | L1 |
| 1.6.1 | Ensure /etc/motd is configured | Automated | L1 |
| 1.6.2 | Ensure /etc/issue is configured | Automated | L1 |
| 1.6.3 | Ensure /etc/issue.net is configured | Automated | L1 |
| 1.6.4 | Ensure pam_motd is configured | Automated | L1 |
| 1.6.5 | Ensure sshd warning Banner is configured | Automated | L1 |
| 1.6.6 | Ensure access to /etc/motd is configured | Automated | L1 |
| 1.6.7 | Ensure access to /etc/issue is configured | Automated | L1 |
| 1.6.8 | Ensure access to /etc/issue.net is configured | Automated | L1 |
| 1.6.9 | Ensure access to pam_motd file is configured | Automated | L1 |
| 1.6.10 | Ensure access to sshd warning banner is configured | Automated | L1 |
| 1.7.1 | Ensure GDM login banner is configured | Automated | L1 |
| 1.7.2 | Ensure GDM disable-user-list is configured | Automated | L1 |
| 1.7.3 | Ensure GDM screen lock is configured | Automated | L1 |
| 1.7.4 | Ensure GDM automount is configured | Automated | L1 |
| 1.7.5 | Ensure GDM autorun-never is configured | Automated | L1 |
| 1.7.6 | Ensure XDMCP is not enabled | Automated | L1 |
| 1.7.7 | Ensure Xwayland is configured | Automated | L2 |

**Section 2 — Services**

| Check ID | Title | Type | Server Level |
|---|---|---|---|
| 2.1.1 | Ensure autofs services are not in use | Automated | L1 |
| 2.1.2 | Ensure mail transfer agents are configured for local-only mode | Automated | L1 |
| 2.1.3 | Ensure avahi daemon services are not in use | Automated | L1 |
| 2.1.4 | Ensure only approved services are listening on a network interface | Manual | L1 |
| 2.1.5 | Ensure dhcp server services are not in use | Automated | L1 |
| 2.1.6 | Ensure web server services are not in use | Automated | L1 |
| 2.1.7 | Ensure dns server services are not in use | Automated | L1 |
| 2.1.8 | Ensure ftp server services are not in use | Automated | L1 |
| 2.1.9 | Ensure dnsmasq services are not in use | Automated | L1 |
| 2.1.10 | Ensure ldap server services are not in use | Automated | L1 |
| 2.1.11 | Ensure message access server services are not in use | Automated | L1 |
| 2.1.12 | Ensure network file system services are not in use | Automated | L1 |
| 2.1.13 | Ensure nis server services are not in use | Automated | L1 |
| 2.1.14 | Ensure print server services are not in use | Automated | L1 |
| 2.1.15 | Ensure rpcbind services are not in use | Automated | L1 |
| 2.1.16 | Ensure rsync services are not in use | Automated | L1 |
| 2.1.17 | Ensure samba file server services are not in use | Automated | L1 |
| 2.1.18 | Ensure snmp services are not in use | Automated | L1 |
| 2.1.19 | Ensure telnet server services are not in use | Automated | L1 |
| 2.1.20 | Ensure tftp server services are not in use | Automated | L1 |
| 2.1.21 | Ensure web proxy server services are not in use | Automated | L1 |
| 2.1.22 | Ensure xinetd services are not in use | Automated | L1 |
| 2.1.23 | Ensure X window server services are not in use | Automated | L1 |
| 2.2.1 | Ensure nis client is not installed | Automated | L1 |
| 2.2.2 | Ensure rsh client is not installed | Automated | L1 |
| 2.2.3 | Ensure talk client is not installed | Automated | L1 |
| 2.2.4 | Ensure telnet client is not installed | Automated | L1 |
| 2.2.5 | Ensure ldap client is not installed | Automated | L1 |
| 2.2.6 | Ensure ftp client is not installed | Automated | L1 |
| 2.3.1.1 | Ensure a single time synchronization daemon is in use | Automated | L1 |
| 2.3.2.1 | Ensure systemd-timesyncd configured with authorized timeserver | Automated | L1 |
| 2.3.2.2 | Ensure systemd-timesyncd is enabled and running | Automated | L1 |
| 2.3.3.1 | Ensure chrony is configured | Automated | L1 |
| 2.3.3.2 | Ensure chrony is running as user _chrony | Automated | L1 |
| 2.3.3.3 | Ensure chrony is enabled and running | Automated | L1 |
| 2.4.1.1 | Ensure cron daemon is enabled and active | Automated | L1 |
| 2.4.1.2 | Ensure access to /etc/crontab is configured | Automated | L1 |
| 2.4.1.3 | Ensure access to /etc/cron.hourly is configured | Automated | L1 |
| 2.4.1.4 | Ensure access to /etc/cron.daily is configured | Automated | L1 |
| 2.4.1.5 | Ensure access to /etc/cron.weekly is configured | Automated | L1 |
| 2.4.1.6 | Ensure access to /etc/cron.monthly is configured | Automated | L1 |
| 2.4.1.7 | Ensure access to /etc/cron.yearly is configured | Automated | L1 |
| 2.4.1.8 | Ensure access to /etc/cron.d is configured | Automated | L1 |
| 2.4.1.9 | Ensure access to crontab is configured | Automated | L1 |
| 2.4.2.1 | Ensure access to at is configured | Automated | L1 |

**Section 3 — Network**

| Check ID | Title | Type | Server Level |
|---|---|---|---|
| 3.1.1 | Ensure IPv6 status is identified | Manual | L1 |
| 3.1.2 | Ensure wireless interfaces are not available | Automated | L1 |
| 3.1.3 | Ensure bluetooth services are not in use | Automated | L1 |
| 3.2.1 | Ensure atm kernel module is not available | Automated | L1 |
| 3.2.2 | Ensure can kernel module is not available | Automated | L1 |
| 3.2.3 | Ensure dccp kernel module is not available | Automated | L1 |
| 3.2.4 | Ensure rds kernel module is not available | Automated | L1 |
| 3.2.5 | Ensure sctp kernel module is not available | Automated | L1 |
| 3.2.6 | Ensure tipc kernel module is not available | Automated | L1 |
| 3.3.1.1 | Ensure net.ipv4.ip_forward is configured | Automated | L2 |
| 3.3.1.2 | Ensure net.ipv4.conf.all.forwarding is configured | Automated | L1 |
| 3.3.1.3 | Ensure net.ipv4.conf.default.forwarding is configured | Automated | L1 |
| 3.3.1.4 | Ensure net.ipv4.conf.all.send_redirects is configured | Automated | L1 |
| 3.3.1.5 | Ensure net.ipv4.conf.default.send_redirects is configured | Automated | L1 |
| 3.3.1.6 | Ensure net.ipv4.icmp_ignore_bogus_error_responses is configured | Automated | L1 |
| 3.3.1.7 | Ensure net.ipv4.icmp_echo_ignore_broadcasts is configured | Automated | L1 |
| 3.3.1.8 | Ensure net.ipv4.conf.all.accept_redirects is configured | Automated | L1 |
| 3.3.1.9 | Ensure net.ipv4.conf.default.accept_redirects is configured | Automated | L1 |
| 3.3.1.10 | Ensure net.ipv4.conf.all.secure_redirects is configured | Automated | L1 |
| 3.3.1.11 | Ensure net.ipv4.conf.default.secure_redirects is configured | Automated | L1 |
| 3.3.1.12 | Ensure net.ipv4.conf.all.rp_filter is configured | Automated | L1 |
| 3.3.1.13 | Ensure net.ipv4.conf.default.rp_filter is configured | Automated | L1 |
| 3.3.1.14 | Ensure net.ipv4.conf.all.accept_source_route is configured | Automated | L1 |
| 3.3.1.15 | Ensure net.ipv4.conf.default.accept_source_route is configured | Automated | L1 |
| 3.3.1.16 | Ensure net.ipv4.conf.all.log_martians is configured | Automated | L1 |
| 3.3.1.17 | Ensure net.ipv4.conf.default.log_martians is configured | Automated | L1 |
| 3.3.1.18 | Ensure net.ipv4.tcp_syncookies is configured | Automated | L1 |
| 3.3.2.1 | Ensure net.ipv6.conf.all.forwarding is configured | Automated | L1 |
| 3.3.2.2 | Ensure net.ipv6.conf.default.forwarding is configured | Automated | L1 |
| 3.3.2.3 | Ensure net.ipv6.conf.all.accept_redirects is configured | Automated | L1 |
| 3.3.2.4 | Ensure net.ipv6.conf.default.accept_redirects is configured | Automated | L1 |
| 3.3.2.5 | Ensure net.ipv6.conf.all.accept_source_route is configured | Automated | L1 |
| 3.3.2.6 | Ensure net.ipv6.conf.default.accept_source_route is configured | Automated | L1 |
| 3.3.2.7 | Ensure net.ipv6.conf.all.accept_ra is configured | Automated | L1 |
| 3.3.2.8 | Ensure net.ipv6.conf.default.accept_ra is configured | Automated | L1 |

**Section 4 — Host Based Firewall**

The benchmark v2.0.0 covers UFW as the sole firewall utility in Section 4. The benchmark explicitly notes that if an organisation uses a different utility, it should verify the resulting rules meet the section's intent. The engine implements the approach described in Section 5.6 below, which extends this with a firewall inventory check before Section 4 runs.

| Check ID | Title | Type | Server Level |
|---|---|---|---|
| 4.1.1 | Ensure ufw is installed | Automated | L1 |
| 4.1.2 | Ensure ufw service is configured | Automated | L1 |
| 4.1.3 | Ensure ufw incoming default is configured | Automated | L1 |
| 4.1.4 | Ensure ufw outgoing default is configured | Automated | L1 |
| 4.1.5 | Ensure ufw routed default is configured | Automated | L1 |

**Section 5 — Access Control**

| Check ID | Title | Type | Server Level |
|---|---|---|---|
| 5.1.1 | Ensure access to /etc/ssh/sshd_config is configured | Automated | L1 |
| 5.1.2 | Ensure access to SSH private host key files is configured | Automated | L1 |
| 5.1.3 | Ensure access to SSH public host key files is configured | Automated | L1 |
| 5.1.4 | Ensure sshd access is configured | Automated | L1 |
| 5.1.5 | Ensure sshd Banner is configured | Automated | L1 |
| 5.1.6 | Ensure sshd Ciphers are configured | Automated | L1 |
| 5.1.7 | Ensure sshd ClientAliveInterval and ClientAliveCountMax are configured | Automated | L1 |
| 5.1.8 | Ensure sshd DisableForwarding is enabled | Automated | L2 |
| 5.1.9 | Ensure sshd GSSAPIAuthentication is disabled | Automated | L2 |
| 5.1.10 | Ensure sshd HostbasedAuthentication is disabled | Automated | L1 |
| 5.1.11 | Ensure sshd IgnoreRhosts is enabled | Automated | L1 |
| 5.1.12 | Ensure sshd KexAlgorithms is configured | Automated | L1 |
| 5.1.13 | Ensure sshd LoginGraceTime is configured | Automated | L1 |
| 5.1.14 | Ensure sshd LogLevel is configured | Automated | L1 |
| 5.1.15 | Ensure sshd MACs are configured | Automated | L1 |
| 5.1.16 | Ensure sshd MaxAuthTries is configured | Automated | L1 |
| 5.1.17 | Ensure sshd MaxStartups is configured | Automated | L1 |
| 5.1.18 | Ensure sshd MaxSessions is configured | Automated | L1 |
| 5.1.19 | Ensure sshd PermitEmptyPasswords is disabled | Automated | L1 |
| 5.1.20 | Ensure sshd PermitRootLogin is disabled | Automated | L1 |
| 5.1.21 | Ensure sshd PermitUserEnvironment is disabled | Automated | L1 |
| 5.1.22 | Ensure sshd UsePAM is enabled | Automated | L1 |
| 5.1.23 | Ensure sshd post-quantum cryptography key exchange algorithms are configured | Automated | L1 |
| 5.1.24 | Ensure sshd ListenAddress is configured | Automated | L2 |
| 5.2.1 | Ensure sudo is installed | Automated | L1 |
| 5.2.2 | Ensure sudo commands use pty | Automated | L1 |
| 5.2.3 | Ensure sudo log file exists | Automated | L1 |
| 5.2.4 | Ensure users must provide password for escalation | Automated | L1 |
| 5.2.5 | Ensure re-authentication for privilege escalation is not disabled globally | Automated | L1 |
| 5.2.6 | Ensure sudo timestamp_timeout is configured | Automated | L1 |
| 5.2.7 | Ensure access to the su command is restricted | Automated | L1 |
| 5.3.1.1 | Ensure latest version of pam is installed | Automated | L1 |
| 5.3.1.2 | Ensure latest version of libpam-modules is installed | Automated | L1 |
| 5.3.1.3 | Ensure latest version of libpam-pwquality is installed | Automated | L1 |
| 5.3.1.4 | Ensure latest version of cracklib-runtime is installed | Automated | L1 |
| 5.3.2.1 | Ensure pam_unix module is enabled | Automated | L1 |
| 5.3.2.2 | Ensure pam_faillock module is enabled | Automated | L1 |
| 5.3.2.3 | Ensure pam_pwquality module is enabled | Automated | L1 |
| 5.3.2.4 | Ensure pam_pwhistory module is enabled | Automated | L1 |
| 5.3.3.1.1 | Ensure password failed attempts lockout is configured | Automated | L1 |
| 5.3.3.1.2 | Ensure password unlock time is configured | Automated | L1 |
| 5.3.3.1.3 | Ensure password failed attempts lockout includes root account | Automated | L1 |
| 5.3.3.2.1 | Ensure password number of changed characters is configured | Automated | L1 |
| 5.3.3.2.2 | Ensure password length is configured | Automated | L1 |
| 5.3.3.2.3 | Ensure password complexity is configured | Manual | L1 |
| 5.3.3.2.4 | Ensure password same consecutive characters is configured | Automated | L1 |
| 5.3.3.2.5 | Ensure password maximum sequential characters is configured | Automated | L1 |
| 5.3.3.2.6 | Ensure password dictionary check is enabled | Automated | L1 |
| 5.3.3.2.7 | Ensure password quality checking is enforced | Automated | L1 |
| 5.3.3.2.8 | Ensure password quality is enforced for the root user | Automated | L1 |
| 5.3.3.3.1 | Ensure password history remember is configured | Automated | L1 |
| 5.3.3.3.2 | Ensure password history is enforced for the root user | Automated | L1 |
| 5.3.3.3.3 | Ensure pam_pwhistory includes use_authtok | Automated | L1 |
| 5.3.3.4.1 | Ensure pam_unix does not include nullok | Automated | L1 |
| 5.3.3.4.2 | Ensure pam_unix does not include remember | Automated | L1 |
| 5.3.3.4.3 | Ensure pam_unix includes a strong password hashing algorithm | Automated | L1 |
| 5.3.3.4.4 | Ensure pam_unix includes use_authtok | Automated | L1 |
| 5.4.1.1 | Ensure password expiration is configured | Automated | L1 |
| 5.4.1.2 | Ensure minimum password days is configured | Manual | L2 |
| 5.4.1.3 | Ensure password expiration warning days is configured | Automated | L1 |
| 5.4.1.4 | Ensure strong password hashing algorithm is configured | Automated | L1 |
| 5.4.1.5 | Ensure inactive password lock is configured | Automated | L1 |
| 5.4.1.6 | Ensure all users last password change date is in the past | Automated | L1 |
| 5.4.2.1 | Ensure root is the only UID 0 account | Automated | L1 |
| 5.4.2.2 | Ensure root is the only GID 0 account | Automated | L1 |
| 5.4.2.3 | Ensure group root is the only GID 0 group | Automated | L1 |
| 5.4.2.4 | Ensure root account access is controlled | Automated | L1 |
| 5.4.2.5 | Ensure root path integrity | Automated | L1 |
| 5.4.2.6 | Ensure root user umask is configured | Automated | L1 |
| 5.4.2.7 | Ensure system accounts do not have a valid login shell | Automated | L1 |
| 5.4.2.8 | Ensure accounts without a valid login shell are locked | Automated | L1 |
| 5.4.3.1 | Ensure nologin is not listed in /etc/shells | Automated | L2 |
| 5.4.3.2 | Ensure default user shell timeout is configured | Automated | L1 |
| 5.4.3.3 | Ensure default user umask is configured | Automated | L1 |

**Section 6 — Logging and Auditing**

| Check ID | Title | Type | Server Level |
|---|---|---|---|
| 6.1.1.1.1 | Ensure journald service is active | Automated | L1 |
| 6.1.1.1.2 | Ensure systemd-journal-remote service is not in use | Automated | L1 |
| 6.1.1.1.3 | Ensure journald is configured to send logs to rsyslog | Automated | L1 |
| 6.1.1.1.4 | Ensure journald log file access is configured | Manual | L1 |
| 6.1.1.1.5 | Ensure journald log file rotation is configured | Manual | L1 |
| 6.1.1.1.6 | Ensure journald Storage is configured | Automated | L1 |
| 6.1.1.1.7 | Ensure journald Compress is configured | Automated | L1 |
| 6.1.2.1 | Ensure rsyslog is installed | Automated | L1 |
| 6.1.2.2 | Ensure rsyslog service is enabled and active | Automated | L1 |
| 6.1.2.3 | Ensure rsyslog log file creation mode is configured | Automated | L1 |
| 6.1.2.4 | Ensure rsyslog logging is configured | Manual | L1 |
| 6.1.2.5 | Ensure rsyslog is configured to send logs to a remote log host | Manual | L1 |
| 6.1.2.6 | Ensure rsyslog is not configured to receive logs from a remote client | Automated | L1 |
| 6.1.2.7 | Ensure logrotate is configured | Manual | L1 |
| 6.1.2.8 | Ensure rsyslog-gnutls is installed | Automated | L2 |
| 6.1.2.9 | Ensure rsyslog forwarding uses gtls | Automated | L2 |
| 6.1.2.10 | Ensure rsyslog CA certificates are configured | Manual | L2 |
| 6.1.3.1 | Ensure access to all logfiles has been configured | Automated | L1 |
| 6.2.1.1 | Ensure auditd packages are installed | Automated | L1 |
| 6.2.1.2 | Ensure auditd service is enabled and active | Automated | L1 |
| 6.2.1.3 | Ensure auditing for processes that start prior to auditd is enabled | Automated | L1 |
| 6.2.1.4 | Ensure audit_backlog_limit is configured | Automated | L1 |
| 6.2.2.1 | Ensure audit log storage size is configured | Automated | L1 |
| 6.2.2.2 | Ensure audit logs are not automatically deleted | Automated | L1 |
| 6.2.2.3 | Ensure system is disabled when audit logs are full | Automated | L1 |
| 6.2.2.4 | Ensure system warns when audit logs are low on space | Automated | L1 |
| 6.2.3.1 | Ensure changes to system administration scope (sudoers) is collected | Automated | L2 |
| 6.2.3.2 | Ensure actions as another user are always logged | Automated | L2 |
| 6.2.3.3 | Ensure events that modify the sudo log file are collected | Automated | L2 |
| 6.2.3.4 | Ensure events that modify date and time information are collected | Automated | L2 |
| 6.2.3.5 | Ensure events that modify sethostname and setdomainname are collected | Automated | L2 |
| 6.2.3.6 | Ensure events that modify /etc/issue and /etc/issue.net are collected | Automated | L2 |
| 6.2.3.7 | Ensure events that modify /etc/hosts and /etc/hostname are collected | Automated | L2 |
| 6.2.3.8 | Ensure events that modify /etc/network and /etc/networks are collected | Automated | L2 |
| 6.2.3.9 | Ensure events that modify /etc/netplan are collected | Automated | L2 |
| 6.2.3.10 | Ensure use of privileged commands are collected | Automated | L2 |
| 6.2.3.11 | Ensure events that modify /etc/group information are collected | Automated | L2 |
| 6.2.3.12 | Ensure events that modify /etc/passwd information are collected | Automated | L2 |
| 6.2.3.13 | Ensure events that modify /etc/shadow and /etc/gshadow are collected | Automated | L2 |
| 6.2.3.14 | Ensure events that modify /etc/security/opasswd are collected | Automated | L2 |
| 6.2.3.15 | Ensure events that modify /etc/nsswitch.conf file are collected | Automated | L2 |
| 6.2.3.16 | Ensure events that modify /etc/pam.conf and /etc/pam.d/ are collected | Automated | L2 |
| 6.2.3.17 | Ensure unsuccessful file access attempts are collected | Automated | L2 |
| 6.2.3.18 | Ensure discretionary access control permission modification events are collected | Automated | L2 |
| 6.2.3.19 | Ensure successful file system mounts are collected | Automated | L2 |
| 6.2.3.20 | Ensure session initiation information is collected | Automated | L2 |
| 6.2.3.21 | Ensure login and logout events are collected | Automated | L2 |
| 6.2.3.22 | Ensure file deletion events by users are collected | Automated | L2 |
| 6.2.3.23 | Ensure events that modify the system's Mandatory Access Controls are collected | Automated | L2 |
| 6.2.3.24 | Ensure successful and unsuccessful attempts to use the chcon command are collected | Automated | L2 |
| 6.2.3.25 | Ensure successful and unsuccessful attempts to use the setfacl command are collected | Automated | L2 |
| 6.2.3.26 | Ensure successful and unsuccessful attempts to use the chacl command are collected | Automated | L2 |
| 6.2.3.27 | Ensure successful and unsuccessful attempts to use the usermod command are collected | Automated | L2 |
| 6.2.3.28 | Ensure kernel module loading unloading and modification is collected | Automated | L2 |
| 6.2.3.29 | Ensure the audit configuration is immutable | Automated | L2 |
| 6.2.3.30 | Ensure the running and on disk configuration is the same | Manual | L2 |
| 6.2.4.1 | Ensure the audit log file directory mode is configured | Automated | L1 |
| 6.2.4.2 | Ensure audit log files mode is configured | Automated | L2 |
| 6.2.4.3 | Ensure audit log files owner is configured | Automated | L2 |
| 6.2.4.4 | Ensure audit log files group owner is configured | Automated | L1 |
| 6.2.4.5 | Ensure audit configuration files mode is configured | Automated | L1 |
| 6.2.4.6 | Ensure audit configuration files owner is configured | Automated | L1 |
| 6.2.4.7 | Ensure audit configuration files group owner is configured | Automated | L1 |
| 6.2.4.8 | Ensure audit tools mode is configured | Automated | L2 |
| 6.2.4.9 | Ensure audit tools owner is configured | Automated | L2 |
| 6.2.4.10 | Ensure audit tools group owner is configured | Automated | L1 |
| 6.3.1 | Ensure AIDE is installed | Automated | L1 |
| 6.3.2 | Ensure filesystem integrity is regularly checked | Automated | L1 |
| 6.3.3 | Ensure cryptographic mechanisms are used to protect the integrity of audit tools | Automated | L1 |

**Section 7 — System Maintenance**

| Check ID | Title | Type | Server Level |
|---|---|---|---|
| 7.1.1 | Ensure access to /etc/passwd is configured | Automated | L1 |
| 7.1.2 | Ensure access to /etc/passwd- is configured | Automated | L1 |
| 7.1.3 | Ensure access to /etc/group is configured | Automated | L1 |
| 7.1.4 | Ensure access to /etc/group- is configured | Automated | L1 |
| 7.1.5 | Ensure access to /etc/shadow is configured | Automated | L1 |
| 7.1.6 | Ensure access to /etc/shadow- is configured | Automated | L1 |
| 7.1.7 | Ensure access to /etc/gshadow is configured | Automated | L1 |
| 7.1.8 | Ensure access to /etc/gshadow- is configured | Automated | L1 |
| 7.1.9 | Ensure access to /etc/shells is configured | Automated | L1 |
| 7.1.10 | Ensure access to /etc/security/opasswd is configured | Automated | L1 |
| 7.1.11 | Ensure world writable files and directories are secured | Automated | L1 |
| 7.1.12 | Ensure no files or directories without an owner and a group exist | Automated | L1 |
| 7.1.13 | Ensure SUID and SGID files are reviewed | Manual | L1 |
| 7.2.1 | Ensure accounts in /etc/passwd use shadowed passwords | Automated | L1 |
| 7.2.2 | Ensure /etc/shadow password fields are not empty | Automated | L1 |
| 7.2.3 | Ensure all groups in /etc/passwd exist in /etc/group | Automated | L1 |
| 7.2.4 | Ensure shadow group is empty | Automated | L1 |
| 7.2.5 | Ensure no duplicate UIDs exist | Automated | L1 |
| 7.2.6 | Ensure no duplicate GIDs exist | Automated | L1 |
| 7.2.7 | Ensure no duplicate user names exist | Automated | L1 |
| 7.2.8 | Ensure no duplicate group names exist | Automated | L1 |
| 7.2.9 | Ensure local interactive user home directories are configured | Automated | L1 |
| 7.2.10 | Ensure local interactive user dot files access is configured | Automated | L1 |

> **Implementation note:** Checks not found in the above register (e.g. 1.1.2.4.x partition checks not listed above under /var) are covered by the benchmark but were confirmed L1 from the PDF. Implementers should cross-reference the full benchmark text for any check whose audit command is complex before implementing. The register above is authoritative for level assignment; the benchmark PDF is authoritative for audit procedure.

### 5.2 Check Classification

Each check has one of the following types:

| Type | Meaning |
|---|---|
| `AUTOMATED` | The engine can fully evaluate the check and determine `PASS` or `FAIL` using shell commands, file reads, and service queries. |
| `MANUAL` | The check cannot be fully automated. The engine runs the relevant command, captures the output, marks the status `MANUAL_REVIEW`, and writes the output to both the CSV Remediation column and the manual review TXT file. |

The Ubuntu Engine has no `IMAGE` or `OS_DEPENDENT` check types. It has no image scanning dependency and no dependency on any other engine's output — it is the OS layer that other engines depend on.

### 5.3 Status Values

| Status | Description |
|---|---|
| `PASS` | Check evaluated and the configuration meets the CIS control. |
| `FAIL` | Check evaluated and the configuration does not meet the CIS control. |
| `N/A` | Check is not applicable to this host. Used when a host profile attribute confirms the check is irrelevant (e.g. the host intentionally runs the service the check would flag, or the optional component the check targets is absent). |
| `SKIPPED` | Check was not run. Reason is recorded in the Remediation column (e.g. `Insufficient privileges`). |
| `MANUAL_REVIEW` | Check cannot be fully automated. Relevant command output is captured in the CSV and the manual review TXT file for operator assessment. |

### 5.4 Environment-Based Conditional Checks

The host profile (Section 4.4) drives a set of conditional check behaviours. The table below defines the full mapping of profile attributes to the checks they affect, using the confirmed check IDs from the v2.0.0 benchmark register in Section 5.1. All profile-driven N/A results include a brief note in the Description column explaining the skip reason so the operator can confirm the profile detection was correct.

| Profile attribute | Value | Checks affected | Result |
|---|---|---|---|
| `CONTAINERIZED_SERVICES` | `true` | 1.1.1.6 — Ensure overlay kernel module is not available | `N/A`: Containerised services are active on this host; the overlay module is required by the container runtime. |
| `SNAP_ACTIVE` + `SQUASHFS_BUILTIN` | both `true` | 1.1.1.7 — Ensure squashfs kernel module is not available | `PASS` with note: squashfs is compiled into the kernel and cannot be disabled as a module; snap is in active use. This is expected behaviour. |
| `SNAP_ACTIVE` + squashfs is a module | `true` + not built-in | 1.1.1.7 — Ensure squashfs kernel module is not available | `MANUAL_REVIEW`: snap requires squashfs but the module can be unloaded. Confirm whether snap is an organisational requirement. If snap is to be removed, disable squashfs after removal. |
| `SNAP_ACTIVE` | `false` | 1.1.1.7 — Ensure squashfs kernel module is not available | Normal evaluation: check that squashfs module is disabled. |
| `CLOUD_PROVIDER` | `azure` | 1.1.1.8 — Ensure udf kernel module is not available | `N/A`: Azure requires the UDF kernel module for platform operations. Note included in report. |
| `CLOUD_HOSTED` | `true` | 1.1.1.10 — Ensure usb-storage kernel module is not available | `N/A`: Physical USB access is not available in cloud-hosted environments. |
| `DHCP_SERVER` | `true` | 2.1.5 — Ensure dhcp server services are not in use | `N/A`: This host is a DHCP server; the service is intentionally running. |
| `WEB_SERVER` | `true` | 2.1.6 — Ensure web server services are not in use | `N/A`: This host is a web server; the service is intentionally running. |
| `LDAP_SERVER` | `true` | 2.1.10 — Ensure ldap server services are not in use | `N/A`: This host is an LDAP server; the service is intentionally running. |
| `POP_IMAP_SERVER` | `true` | 2.1.11 — Ensure message access server services are not in use | `N/A`: This host provides POP/IMAP services; the service is intentionally running. |
| `LDAP_CLIENT` | `true` | 2.2.5 — Ensure ldap client is not installed | `N/A`: This host is configured as an LDAP client; the client is intentionally installed. |
| `LDAP_SERVER` or `LDAP_CLIENT` | `true` | sudo-ldap check (Section 5.9) | Evaluate: verify `sudo-ldap` is installed, not `sudo`. |
| `HYPERVISOR_DETECTED` | `true` | 2.3.1.1 — Ensure a single time synchronization daemon is in use | `N/A`: Host is running in a virtualised environment; time synchronization requirements may differ. |
| `CRON_INSTALLED` | `false` | 2.4.1.1 through 2.4.1.9 — all cron configuration checks | `N/A`: cron is not installed on this host. |
| `AT_INSTALLED` | `false` | 2.4.2.1 — Ensure access to at is configured | `N/A`: at is not installed on this host. |
| `IPV6_IN_USE` | `true` | 3.1.1 — Ensure IPv6 status is identified | `N/A`: IPv6 is in active use on this host; this manual check is informational — note included in report confirming IPv6 is enabled by design. |
| `CLUSTER_NODE` | `true` | 3.3.1.1 — Ensure net.ipv4.ip_forward is configured | `N/A`: Host is a cluster node; IP forwarding is required for cluster networking. |
| `ACTIVE_FIREWALL` | `ufw` | 4.1.1 through 4.1.5 — all UFW checks | Run all Section 4 checks normally. UFW is the benchmark-covered utility. |
| `ACTIVE_FIREWALL` | `nftables`, `iptables`, or other | 4.1.1 through 4.1.5 | Run Section 4 checks against the installed utility's effective rules to verify equivalent coverage. Mark each check with a note: `Evaluated against <utility> — benchmark covers UFW. Verify equivalent rule is in place.` See Section 5.6 for the multi-firewall inventory check that precedes Section 4. |
| `ACTIVE_FIREWALL` | `none` | 4.1.1 through 4.1.5 | All Section 4 checks `FAIL`; consolidated finding notes the complete absence of active firewall configuration. |

### 5.5 Check Dependency Chains

Some checks form a dependency chain where the result of one check determines whether subsequent checks run. These are distinct from environment-based conditionals (Section 5.4) — they are triggered by the outcome of a check during the scan itself, not by the pre-built host profile.

#### 5.5.1 GNOME Display Manager (Section 1.7)

The v2.0.0 benchmark notes that Section 1.7 can be skipped if GDM is not installed. All 1.7.x checks are about configuring GDM correctly — the benchmark does not include a "Ensure GDM is removed" check. For this engine's server-only scope, the engine adds a **custom pre-check** before Section 1.7 runs that is not a benchmark check ID:

```
Custom pre-check: Is GDM installed?
        │
        ├── No (expected for a server)
        │     └── All 1.7.x checks → N/A: GDM not installed — Section 1.7 skipped per benchmark
        │
        └── Yes (GDM present on a server)
              ├── Engine records: ADVISORY — GDM is installed on a server deployment.
              │   GDM is not required on a server and increases attack surface.
              │   Recommendation: remove GDM (apt remove gdm3 ubuntu-desktop).
              │   This advisory appears in the CSV and the manual review TXT.
              └── All 1.7.x benchmark checks evaluate normally
                  (if GDM is present, its configuration should at least be correct
                  while removal is being planned)
```

This approach means the engine does not fabricate a check ID that does not exist in the benchmark. The GDM-present advisory is surfaced as a finding with status `MANUAL_REVIEW` and a custom check name of `SERVER-GDM-01` so it is visible in the report without being confused with a real benchmark check. If GDM is absent, no benchmark checks in Section 1.7 run and no check IDs appear in the output for that section — consistent with the benchmark's own skip instruction.

#### 5.5.2 Firewall Section Resolution

The firewall handling is driven by `ACTIVE_FIREWALL` from the host profile and the firewall inventory pre-check (Section 5.6). The console prints a summary line before Section 4 checks begin so the operator sees the detection result upfront:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 SECTION 4 — Host Based Firewall
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[INFO] Active firewall: UFW. Section 4 checks will be evaluated normally.
```

### 5.6 Firewall Inventory Check (Pre-Section 4)

The benchmark v2.0.0 covers UFW as the Host Based Firewall utility and explicitly states that only one firewall method should be active. Before Section 4 checks run, the engine performs a firewall inventory check that is independent of the benchmark's check IDs. It serves two purposes: detecting which utility is active (feeding `ACTIVE_FIREWALL` in the host profile), and surfacing any situation where multiple firewall utilities are installed or active simultaneously.

**Detection sequence:**

The engine checks for the presence and active state of each utility in the following order:

```bash
# UFW
dpkg -l ufw 2>/dev/null | grep -q ^ii && ufw status | grep -q "Status: active"

# nftables
dpkg -l nftables 2>/dev/null | grep -q ^ii && nft list ruleset 2>/dev/null | grep -q .

# iptables (direct — not via UFW backend)
dpkg -l iptables 2>/dev/null | grep -q ^ii && iptables -L 2>/dev/null | grep -qv "^Chain\|^target\|^$"
```

**Outcomes:**

| Condition | Engine action |
|---|---|
| Exactly one utility active (UFW) | Proceed to Section 4. No advisory needed. |
| Exactly one utility active (not UFW) | Proceed to Section 4 with adapted evaluation (see conditional check table). Print `[INFO]` noting the active utility and that the benchmark covers UFW. |
| Multiple utilities installed and active | Print `[WARN]` advising the operator to consolidate to a single firewall utility. Evaluate Section 4 against the highest-precedence active utility (UFW > nftables > iptables). Mark all Section 4 checks with a note that multiple firewalls were detected. |
| No utility active | Set `ACTIVE_FIREWALL=none`. All Section 4 checks `FAIL`. |

**Console output when multiple firewalls are detected:**

```
[WARN] Multiple firewall utilities are installed and active on this host:
         Active : UFW, nftables
       The CIS Benchmark recommends using only one firewall utility. Running
       multiple firewall managers simultaneously can produce unexpected rule
       interactions and leave the host in an inconsistent security state.

       Recommendation: Disable and uninstall all firewall utilities except
       the one your organisation has standardised on. If you are using UFW,
       disable nftables directly and ensure UFW is the sole manager of the
       NFTables backend.

       Section 4 will be evaluated against UFW (highest-precedence active utility).
       All Section 4 findings will note that multiple firewalls were detected.
```

This advisory is written to the CSV Remediation column for every Section 4 check in a multi-firewall run, so it appears in the report even if no individual check fails.

### 5.7 Level Definitions

**Level 1 (default):** Essential, foundational security configurations with minimal operational impact. Automatically selected if `--level` is not specified.

**Level 2 (opt-in):** Defence-in-depth controls for environments requiring a more stringent posture. **Includes all Level 1 checks plus Level 2 additions.** Running `--level 2` runs everything — Level 2 is a strict superset of Level 1.

### 5.8 Password Policy

The engine verifies password policy configuration against the values prescribed in the CIS Ubuntu Linux 24.04 LTS Benchmark v2.0.0. These are `AUTOMATED` checks (except 5.3.3.2.3 and 5.4.1.2 which are `MANUAL`) and evaluate configuration across `/etc/security/pwquality.conf`, `/etc/login.defs`, and the PAM stack.

The benchmark-prescribed values extracted from the PDF are listed below. The engine checks that configured values meet or exceed these requirements. All password policy checks report their expected versus actual values in the Remediation column when they fail.

| Check | Parameter | Benchmark-prescribed value | Check ID |
|---|---|---|---|
| Password minimum length | `minlen` in pwquality.conf | ≥ 14 | 5.3.3.2.2 |
| Password complexity | `minclass` or individual class settings | Review required (Manual) | 5.3.3.2.3 |
| Changed characters (difok) | `difok` in pwquality.conf | ≥ 2 | 5.3.3.2.1 |
| Same consecutive characters (maxrepeat) | `maxrepeat` in pwquality.conf | ≤ 3 | 5.3.3.2.4 |
| Maximum sequential characters (maxsequence) | `maxsequence` in pwquality.conf | ≤ 3 | 5.3.3.2.5 |
| Dictionary check | `dictcheck` in pwquality.conf | = 1 (enabled) | 5.3.3.2.6 |
| Lockout threshold | `deny` in pam_faillock | ≤ 5 attempts | 5.3.3.1.1 |
| Unlock time | `unlock_time` in pam_faillock | ≥ 900 seconds | 5.3.3.1.2 |
| Password history | `remember` in pam_pwhistory | ≥ 24 | 5.3.3.3.1 |
| Maximum password age | `PASS_MAX_DAYS` in /etc/login.defs | ≤ 365 | 5.4.1.1 |
| Minimum password age | `PASS_MIN_DAYS` in /etc/login.defs | ≥ 1 (Manual check) | 5.4.1.2 |
| Password expiry warning | `PASS_WARN_AGE` in /etc/login.defs | ≥ 7 | 5.4.1.3 |
| Inactive password lock | `INACTIVE` in /etc/login.defs | ≤ 45 days | 5.4.1.5 |


### 5.9 sudo-ldap Check (LDAP Environments)

When the host profile indicates `LDAP_SERVER: true` or `LDAP_CLIENT: true`, the engine adds a check not present in the standard non-LDAP scan: it verifies that `sudo-ldap` is installed rather than the standard `sudo` package.

`sudo-ldap` is the LDAP-aware build of sudo that integrates with directory-based sudoers policy. Running standard `sudo` on a host that authenticates via LDAP means sudo policy cannot be centrally managed through the directory, creating a gap between local and directory-based privilege controls.

| Condition | Result |
|---|---|
| `sudo-ldap` installed | `PASS` |
| `sudo` installed, `sudo-ldap` not installed | `FAIL` — install `sudo-ldap` and remove `sudo` |
| Neither installed | `FAIL` — install `sudo-ldap` |

This check is inserted into Section 5.3 (Configure Privilege Escalation) and appears in both the CSV and the OS engine report.

### 5.10 GPG Key Validation

The engine performs a check of the APT repository signing keys present on the host. This check validates that the expected Ubuntu archive GPG keys are present and have not been augmented with unexpected keys. It is classified as `MANUAL_REVIEW` because the legitimate key set varies by organisation — hosts using internal mirrors or third-party repositories will have additional keys that require human judgement to validate.

The engine captures:

```bash
apt-key list 2>/dev/null || ls -la /etc/apt/trusted.gpg.d/ /usr/share/keyrings/
```

The output is written to the manual review TXT file. The check description instructs the operator to verify that all listed keys correspond to known, trusted repositories and to investigate and remove any unrecognised key. See Open Item 3 for the definition of expected keys for standard Ubuntu 24.04 setups.

---

## 6. OS Engine Report

### 6.1 Purpose

The OS engine report is a structured JSON file produced at the end of every Ubuntu Engine scan. It is the machine-readable findings artifact consumed by the Docker and Kubernetes engines when resolving their `OS_DEPENDENT` checks.

The Docker and Kubernetes engines look up individual Ubuntu check IDs in this file rather than re-running OS-level checks themselves. This eliminates duplication of check logic across engines and ensures that OS-dependent findings in the Docker and Kubernetes reports are traceable back to the Ubuntu Engine finding that sourced them.

The format defined here is the agreed schema for all OS engines. The Rocky Linux Engine will produce an equivalent file (`adhiambo_rocky_os_<timestamp>.json`) in the same structure. Downstream engines must handle both files using the same lookup logic, differentiating by the `engine` field in the JSON.

### 6.2 File Naming and Location

```
adhiambo_ubuntu_os_<timestamp>.json
```

The file is written to the same `--output-dir` as the CSV report. Downstream engines locate it by globbing `adhiambo_ubuntu_os_*.json` in the output directory. If multiple Ubuntu OS report files are present, the downstream engine uses the file whose `scan_id` matches the active scan. If no `scan_id` match is found, the most recently modified file is used as a fallback.

### 6.3 Schema

```json
{
  "adhiambo_version": "0.1",
  "engine": "ubuntu",
  "scan_id": "<uuid>",
  "timestamp": "<ISO-8601>",
  "hostname": "<hostname>",
  "os_version": "24.04",
  "level": 1,
  "host_profile": {
    "cloud_hosted": true,
    "cloud_provider": "azure",
    "hypervisor_detected": true,
    "containerized_services": false,
    "ipv6_in_use": true,
    "active_firewall": "ufw"
  },
  "findings": {
    "4.1.1.1": {
      "status": "PASS",
      "description": "Ensure auditd is installed"
    },
    "4.1.2.1": {
      "status": "FAIL",
      "description": "Ensure audit log storage size is configured",
      "remediation": "Set max_log_file = <MB> in /etc/audit/auditd.conf to a value appropriate for your retention requirements."
    },
    "4.1.4.11": {
      "status": "MANUAL_REVIEW",
      "description": "Ensure use of privileged commands is collected",
      "remediation": "[MANUAL REVIEW REQUIRED] Verify that each SUID/SGID binary returned by: find / -xdev \\( -perm -4000 -o -perm -2000 \\) -type f has a corresponding audit rule in /etc/audit/rules.d/"
    },
    "SERVER-GDM-01": {
      "status": "MANUAL_REVIEW",
      "description": "GDM is installed on a server deployment — removal is recommended to reduce attack surface",
      "remediation": "[MANUAL REVIEW REQUIRED] Remove GDM and desktop packages: apt remove gdm3 ubuntu-desktop && apt autoremove"
    },
    "1.7.1": {
      "status": "N/A",
      "description": "Ensure GDM login banner is configured — GDM not installed on this host (Section 1.7 skipped per benchmark)"
    }
  }
}
```

The `host_profile` object is included in the sidecar so downstream engines have context on why certain checks were skipped or adjusted. It is informational only — downstream engines use the `findings` map for their lookups, not the profile.

### 6.4 Schema Field Definitions

| Field | Description |
|---|---|
| `adhiambo_version` | The version of Adhiambo that produced this file. |
| `engine` | Always `"ubuntu"` for this file. Allows downstream engines to confirm they are reading the correct OS engine report type. |
| `scan_id` | The UUID shared across all components of the same scan invocation. |
| `timestamp` | ISO-8601 timestamp of when the Ubuntu Engine completed. |
| `hostname` | Hostname of the scanned host as returned by the OS. |
| `os_version` | The Ubuntu version confirmed at pre-flight. Always `"24.04"` for this engine. |
| `level` | The scan level that was run (`1` or `2`). Downstream engines must check this — a Level 1 OS report will not contain Level 2 check findings. See Section 6.6. |
| `host_profile` | A subset of the host profile built during pre-flight. Included for downstream context only. |
| `findings` | Object keyed by CIS Ubuntu check ID. Contains one entry per check evaluated during the scan. |
| `findings.<id>.status` | One of: `PASS`, `FAIL`, `N/A`, `SKIPPED`, `MANUAL_REVIEW`. |
| `findings.<id>.description` | Plain-language description of the check, including a brief note explaining `N/A` status where applicable. |
| `findings.<id>.remediation` | Present only when `status` is `FAIL`, `SKIPPED`, or `MANUAL_REVIEW`. **Absent** (key not present) for `PASS` and `N/A` — downstream engines must not assume this key exists. |

### 6.5 Downstream Engine Lookup Behaviour

When a Docker or Kubernetes engine encounters an `OS_DEPENDENT` check, it performs the following lookup:

```
1. Locate adhiambo_ubuntu_os_*.json in the output directory
       │
       ├── Match by scan_id if possible; fall back to most recently modified
       │
2. File found?
       │
       ├── Yes → Read findings[<ubuntu_check_id>].status
       │          Reference source in report row:
       │            "Source: Ubuntu Engine — check <id>"
       │          Use Ubuntu finding's status as the OS_DEPENDENT check result
       │
       └── No  → Is the OS engine marked as under maintenance?
                   ├── Yes → SKIPPED: OS engine under maintenance
                   └── No  → SKIPPED: OS engine report not found —
                              run the Ubuntu or Rocky engine first
```

### 6.6 Level Mismatch Handling

If a downstream engine runs at Level 2 but the OS engine report was produced at Level 1, any `OS_DEPENDENT` check requiring a Level 2 Ubuntu finding will not find its check ID in the `findings` map. The downstream engine marks that check:

```
SKIPPED: OS engine report was produced at Level 1 — re-run Ubuntu engine at Level 2 to enable this check
```

The downstream engine checks the `level` field before beginning evaluation and prints a warning if a mismatch is detected:

```
[WARN] OS engine report was produced at Level 1. This scan is running at Level 2.
       OS_DEPENDENT checks that require Level 2 Ubuntu findings will be marked SKIPPED.
       To resolve, re-run the Ubuntu engine at Level 2 before running this engine.
```

---

## 7. Console Output

### 7.1 Scan Header

The engine prints a header at the start of the scan. When invoked by `adhiambo.sh`, the orchestrator has already printed its own top-level header — the engine header identifies which engine is running and its benchmark reference.

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Adhiambo — Ubuntu CIS Benchmark Engine
 Benchmark : CIS Ubuntu Linux 24.04 LTS Benchmark v2.0.0
 Host      : prod-server-01
 Level     : 1
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

The host profile summary (Section 4.3) is printed immediately after the header, before the first section begins.

### 7.2 Section and Subsection Headers

Before each top-level section, a section header is printed:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 SECTION 4 — Logging and Auditing
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Named subsections print a lighter subheader before their checks:

```
 4.1 — Configure System Accounting (auditd)
```

### 7.3 Per-Check Output

Each check prints a single line as it completes:

```
[<STATUS>]  <Check ID>  <Check Name>
```

For `SKIPPED` and `N/A`, the reason is included inline:

```
[SKIPPED: <reason>]   <Check ID>  <Check Name>
[N/A: <reason>]       <Check ID>  <Check Name>
```

**Example output for Section 4.1:**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 SECTION 4 — Logging and Auditing
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

 4.1 — Configure System Accounting (auditd)
[PASS]           4.1.1.1   Ensure auditd is installed
[PASS]           4.1.1.2   Ensure auditd service is enabled and active
[FAIL]           4.1.2.1   Ensure audit log storage size is configured
[FAIL]           4.1.2.2   Ensure audit logs are not automatically deleted
[PASS]           4.1.2.3   Ensure system is disabled when audit logs are full
[MANUAL_REVIEW]  4.1.4.11  Ensure use of privileged commands is collected
[PASS]           4.1.4.12  Ensure successful file system mounts are collected
```

**Example output for Section 1.7 on a server with GDM absent (expected state):**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 SECTION 1.7 — GNOME Display Manager
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[INFO] GDM is not installed. Section 1.7 checks skipped (per benchmark skip instruction).

[N/A: GDM not installed]  1.7.1  Ensure GDM login banner is configured
[N/A: GDM not installed]  1.7.2  Ensure GDM disable-user-list is configured
[N/A: GDM not installed]  1.7.3  Ensure GDM screen lock is configured
[N/A: GDM not installed]  1.7.4  Ensure GDM automount is configured
[N/A: GDM not installed]  1.7.5  Ensure GDM autorun-never is configured
[N/A: GDM not installed]  1.7.6  Ensure XDMCP is not enabled
[N/A: GDM not installed]  1.7.7  Ensure Xwayland is configured
```

**Example output for Section 1.7 on a server with GDM unexpectedly present:**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 SECTION 1.7 — GNOME Display Manager
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[MANUAL_REVIEW]  SERVER-GDM-01  GDM is installed on a server deployment — removal recommended
[PASS]           1.7.1          Ensure GDM login banner is configured
[PASS]           1.7.2          Ensure GDM disable-user-list is configured
[FAIL]           1.7.3          Ensure GDM screen lock is configured
[PASS]           1.7.4          Ensure GDM automount is configured
```

**Example output for Section 4 on a UFW host (single firewall — normal case):**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 SECTION 4 — Host Based Firewall
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[INFO] Active firewall: UFW. Section 4 checks will be evaluated normally.

 4.1 — Configure Uncomplicated Firewall
[PASS]  4.1.1  Ensure ufw is installed
[PASS]  4.1.2  Ensure ufw service is configured
[FAIL]  4.1.3  Ensure ufw incoming default is configured
[PASS]  4.1.4  Ensure ufw outgoing default is configured
[PASS]  4.1.5  Ensure ufw routed default is configured
```

**Example output for Section 4 on a host with multiple active firewalls:**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 SECTION 4 — Host Based Firewall
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[WARN] Multiple firewall utilities active: UFW, nftables
       Evaluating against UFW (highest precedence).
       See CSV Remediation column for consolidation advisory.

 4.1 — Configure Uncomplicated Firewall
[PASS]  4.1.1  Ensure ufw is installed                [NOTE: multiple firewalls active]
[PASS]  4.1.2  Ensure ufw service is configured       [NOTE: multiple firewalls active]
[PASS]  4.1.3  Ensure ufw incoming default is configured [NOTE: multiple firewalls active]
```

### 7.4 Manual Review Block

Checks marked `MANUAL_REVIEW` collect their command output and print it as a block at the end of the section in which they appear. The same output is written to both the `Remediation` column of the CSV and the manual review TXT file (Section 8.4). The manual review block references the TXT file path so the operator knows where the consolidated output is.

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 MANUAL REVIEW REQUIRED — SECTION 4.1
 The following checks require operator review.
 Output captured in CSV and in:
   adhiambo_ubuntu_manual_2026-04-10T1143.txt
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

--- 4.1.4.11  Ensure use of privileged commands is collected ---
Action  : Verify that each SUID/SGID binary on the system has a corresponding
          audit rule in /etc/audit/rules.d/. The command below lists all SUID/SGID
          binaries. Cross-reference the output against the installed audit rules.
Command : find / -xdev \( -perm -4000 -o -perm -2000 \) -type f
Output  :
  /usr/bin/sudo
  /usr/bin/su
  /usr/bin/passwd
  /usr/bin/newgrp
  [... additional binaries ...]
---------------------------------------------------------------------
```

If a section has no `MANUAL_REVIEW` checks, the manual review block is omitted for that section.

### 7.5 Scan Summary Block

After all sections have completed, a summary block is printed. This is **console-only** — it is not written to any output file.

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 SCAN SUMMARY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  PASS             142
  FAIL              28
  MANUAL_REVIEW      8
  SKIPPED            4
  N/A               12
  ──────────────────
  TOTAL            194

  Report saved to   : adhiambo_ubuntu_2026-04-10T1143.csv
  OS engine report  : adhiambo_ubuntu_os_2026-04-10T1143.json
  Manual review     : adhiambo_ubuntu_manual_2026-04-10T1143.txt
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## 8. Reporting Helper (`reporter_ubuntu.sh`)

### 8.1 Purpose

`reporter_ubuntu.sh` is a temporary component that produces the human-readable CSV report from Ubuntu Engine findings. It will be retired and replaced by the main `reporter.sh` when that component is ready. It is designed to be interface-compatible with the intended Reporter so the handover requires minimal changes.

The OS engine report JSON (Section 6) and the manual review TXT file (Section 8.4) are written directly by `engine/ubuntu.sh` as final steps after all checks complete, not by the reporting helper. The helper is responsible only for the CSV.

### 8.2 Output

```
adhiambo_ubuntu_<timestamp>.csv
```

Written to the directory specified by `--output-dir`.

### 8.3 CSV Fields

The CSV follows the four-column schema defined across all Adhiambo engines:

| Column | Description |
|---|---|
| `Check Name` | The CIS control identifier (e.g. `4.1.1.1`, `5.2.7`). |
| `Description` | Plain-language explanation of what the check tests and why it matters. For `N/A` checks, includes the reason the check was not applicable. |
| `Status` | `PASS`, `FAIL`, `N/A`, `SKIPPED`, or `MANUAL_REVIEW`. |
| `Remediation` | The specific action required to resolve a failing check. For `SKIPPED`, contains the skip reason. For `MANUAL_REVIEW`, contains the captured command output. Blank for `PASS` and `N/A`. |

### 8.4 Manual Review Output File

All `MANUAL_REVIEW` checks are collected into a dedicated plain-text workbook written at the end of the scan:

```
adhiambo_ubuntu_manual_<timestamp>.txt
```

This file is intended as a standalone audit workbook. An operator can work through each manual check in sequence, record their findings in the space provided, and retain the completed file as evidence that manual review was performed. Each check entry is self-contained — it includes the CIS reference, the action required, the command that was run, the output captured at scan time, and a clearly labelled space for the operator's conclusion.

**File structure:**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 Adhiambo — Ubuntu Manual Review Workbook
 Host      : prod-server-01
 Scan ID   : a3f1c2d4-7e89-4b12-bc34-0f1e2d3a4c5b
 Level     : 1
 Generated : 2026-04-10T11:43:00Z
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

This file contains all checks from the scan that could not be
fully automated and require manual operator review. Each entry
includes the CIS control reference, the required action, the
command that was run, and the output captured at scan time.

Work through each check below, document your conclusion in the
space provided, and retain this file as evidence of review.

Total checks requiring manual review: 8
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

═══════════════════════════════════════════════════════════════
Check   : 4.1.4.11
Section : 4 — Logging and Auditing
Title   : Ensure use of privileged commands is collected
═══════════════════════════════════════════════════════════════

Action required:
  Verify that each SUID/SGID binary on the system has a
  corresponding audit rule in /etc/audit/rules.d/. The output
  below lists all SUID/SGID binaries found at scan time.
  Cross-reference each binary against the installed audit rules.

Command run at scan time:
  find / -xdev \( -perm -4000 -o -perm -2000 \) -type f

Output captured at scan time:
  /usr/bin/sudo
  /usr/bin/su
  /usr/bin/passwd
  /usr/bin/newgrp
  /usr/bin/chfn
  /usr/bin/chsh
  [... full output ...]

---------------------------------------------------------------
Operator finding:
  [ ] PASS — all binaries have corresponding audit rules
  [ ] FAIL — one or more binaries are missing audit rules
  Notes:



Reviewed by: ________________________  Date: ________________
---------------------------------------------------------------

[next check follows...]
```

The manual review TXT file is written by `engine/ubuntu.sh` directly, not by `reporter_ubuntu.sh`. It is a permanent scan artifact retained alongside the CSV and OS engine report.

### 8.5 Special Remediation Notes

The following check carries additional mandatory content in the Remediation column. This text must appear in the CSV output exactly as specified whenever the check fails. It must not be omitted or paraphrased during implementation.

**Bootloader password (check 1.4.1) — when FAIL:**

The Remediation column must include the following warning after the standard remediation instruction:

```
WARNING: Setting a bootloader password that is subsequently forgotten may prevent
the system from completing a reboot without physical console access or rescue media.
Before making this change, store the password securely in a password manager or
documented recovery procedure, and confirm that a tested recovery path exists for
this host. A forgotten bootloader password on a remote or unattended server may
result in prolonged downtime.
```

This warning applies only to the bootloader password check and must not appear on any other check's remediation output.

---

## 9. Component Flow

```
adhiambo.sh --level <1|2> [--output-dir <path>] [--scan-id <uuid>]
        │
        ▼
engine/ubuntu.sh
        │
        ├── [Pre-flight 1: OS Verification]
        │     ├── Read /etc/os-release
        │     ├── Confirm ID=ubuntu, VERSION_ID=24.04
        │     ├── Wrong Ubuntu version → exit with message
        │     └── Not Ubuntu           → exit with message
        │
        ├── [Pre-flight 2: Privilege Check]
        │     └── Not root → warn; privilege-dependent checks = SKIPPED: Insufficient privileges
        │
        ├── [Pre-flight 3: Desktop Environment Detection]
        │     ├── Check for ubuntu-desktop / gdm3 / gnome-shell / xorg packages
        │     ├── Detected   → warn operator; set DESKTOP_ENV_DETECTED=true; proceed
        │     └── Not detected → proceed normally
        │
        ├── [Pre-flight 4: Host Profile Detection]
        │     ├── Infrastructure  : cloud provider (Azure/AWS/GCP/other/none), hypervisor
        │     ├── Active services : containerised services, DHCP, LDAP server,
        │     │                     POP/IMAP, web server, cluster node
        │     ├── Clients         : LDAP client
        │     ├── Network         : IPv6 active use
        │     ├── Packages        : snap/squashfs, cron, at, active firewall, sudo-ldap
        │     └── Print host profile summary to console
        │
        ├── [Section 1 — Initial Setup]
        │     ├── 1.1  Filesystem Kernel Modules + Partitions
        │     │         ├── 1.1.1.6 (overlay): CONTAINERIZED_SERVICES → N/A if true
        │     │         ├── 1.1.1.7 (squashfs): SNAP_ACTIVE + SQUASHFS_BUILTIN → PASS with note
        │     │         │                        SNAP_ACTIVE + module → MANUAL_REVIEW
        │     │         │                        no snap → normal evaluation
        │     │         ├── 1.1.1.8 (udf): CLOUD_PROVIDER=azure → N/A
        │     │         └── 1.1.1.10 (usb-storage): CLOUD_HOSTED → N/A if true
        │     ├── 1.2  Package Management (APT key/repo checks)
        │     ├── 1.3  Mandatory Access Control (AppArmor)
        │     ├── 1.4  Configure Bootloader
        │     │         └── 1.4.1 (bootloader password): if FAIL, include safety warning in Remediation
        │     ├── 1.5  Additional Process Hardening
        │     ├── 1.6  Command Line Warning Banners
        │     └── 1.7  GNOME Display Manager
        │               ├── Custom pre-check: Is GDM installed?
        │               │     ├── No (expected) → all 1.7.x = N/A: GDM not installed (benchmark skip)
        │               │     └── Yes (unexpected on server)
        │               │           ├── Record SERVER-GDM-01 MANUAL_REVIEW advisory (removal recommended)
        │               │           └── Evaluate 1.7.1–1.7.7 normally
        │
        ├── [Section 2 — Services]
        │     ├── 2.1  Configure Server Services
        │     │         ├── 2.1.5  (DHCP):  DHCP_SERVER     → N/A if true
        │     │         ├── 2.1.6  (web):   WEB_SERVER      → N/A if true
        │     │         ├── 2.1.10 (LDAP):  LDAP_SERVER     → N/A if true
        │     │         └── 2.1.11 (IMAP):  POP_IMAP_SERVER → N/A if true
        │     ├── 2.2  Configure Client Services
        │     │         └── 2.2.5 (LDAP client): LDAP_CLIENT → N/A if true
        │     ├── 2.3  Configure Time Synchronization
        │     │         └── 2.3.1.1 (single daemon): HYPERVISOR_DETECTED → N/A if true
        │     └── 2.4  Job Schedulers
        │               ├── 2.4.1.x (cron): CRON_INSTALLED → N/A if false
        │               └── 2.4.2.x (at):   AT_INSTALLED   → N/A if false
        │
        ├── [Section 3 — Network]
        │     ├── 3.1  Configure Network Devices
        │     │         └── 3.1.1 (IPv6 status): IPV6_IN_USE → N/A with note if true
        │     ├── 3.2  Configure Network Kernel Modules
        │     └── 3.3  Configure Network Kernel Parameters
        │               └── Cluster node forwarding checks: CLUSTER_NODE → N/A if true
        │
        ├── [Section 4 — Host Based Firewall]
        │     ├── Firewall inventory pre-check (Section 5.6)
        │     │         ├── Detect all installed+active utilities (UFW, nftables, iptables)
        │     │         ├── Multiple active → WARN + advisory; evaluate against UFW
        │     │         ├── Single non-UFW  → INFO + adapted evaluation with notes
        │     │         └── None active     → all Section 4 = FAIL
        │     └── 4.1  Configure UFW (4.1.1–4.1.5)
        │               └── Results annotated with multi-firewall note if applicable
        │
        ├── [Section 5 — Access Control]
        │     ├── 5.1  Configure SSH Server
        │     ├── 5.2  Configure Privilege Escalation (sudo)
        │     │         └── LDAP_SERVER or LDAP_CLIENT → evaluate sudo-ldap check (Section 5.9)
        │     ├── 5.3  PAM configuration
        │     │         └── Password policy: verify against benchmark-prescribed values (Section 5.8)
        │     └── 5.4  User Accounts and Environment
        │               └── Password aging: /etc/login.defs vs benchmark values
        │
        ├── [Section 6 — Logging and Auditing]
        │     ├── 6.1  System Logging (journald, rsyslog, logrotate)
        │     ├── 6.2  System Auditing (auditd)
        │     └── 6.3  Configure Integrity Checking (AIDE)
        │               └── GPG key validation (MANUAL_REVIEW — Section 5.10)
        │
        ├── [Section 7 — System Maintenance]
        │     ├── 7.1  Configure system file and directory access
        │     └── 7.2  Local User and Group Settings
        │
        ├── [Console Summary]
        │     └── Print status counts and all three output file paths (console only)
        │
        ├── [Reporter]
        │     └── reporter_ubuntu.sh → adhiambo_ubuntu_<timestamp>.csv
        │
        ├── [OS Engine Report]
        │     └── Write adhiambo_ubuntu_os_<timestamp>.json
        │
        └── [Manual Review TXT]
              └── Write adhiambo_ubuntu_manual_<timestamp>.txt
```

---

## 10. Assumptions & Constraints

- **This engine is designed for Ubuntu Server deployments only.** It enforces a server hardening posture throughout — desktop components such as GDM are treated as findings, not as supported configuration targets. Running it against an Ubuntu Desktop system will produce results that reflect server hardening expectations, which may not be appropriate for that environment. The operator is warned at pre-flight if desktop packages are detected, but the scan proceeds with server-scoped logic regardless.
- The engine runs on the target Linux host with `bash` available.
- `sudo` or root access is strongly recommended. Checks that cannot be evaluated without elevated privileges are marked `SKIPPED: Insufficient privileges` rather than causing the engine to abort.
- This engine targets **Ubuntu 24.04 LTS only**. Running it on other Ubuntu versions or other Linux distributions will fail the pre-flight OS check and produce no output.
- All three output files — CSV, OS engine report JSON, and manual review TXT — are written to the same `--output-dir`. The OS engine report and manual review TXT are written directly by `engine/ubuntu.sh`, not by `reporter_ubuntu.sh`.
- Host profile detection (Section 4.3) uses a 2-second timeout for cloud metadata endpoint probes. On non-cloud hosts, these probes time out silently without affecting scan output or performance in any meaningful way.
- The engine does not modify any system state. All checks are read-only.
- When GDM is not installed, Section 1.7 checks are all marked N/A and no benchmark check IDs appear in the output for that section — consistent with the v2.0.0 benchmark's own skip instruction. When GDM is present on a server, a custom advisory (`SERVER-GDM-01`) is recorded alongside normal evaluation of 1.7.x checks.
- Firewall checks (Section 3.5) evaluate only the active firewall utility's subsection. All other firewall subsections are marked N/A.
- The manual review TXT file is a permanent scan artifact, retained alongside the CSV and OS engine report.
- The OS engine report schema defined in Section 6 is the agreed format for all OS engines. The Rocky Linux Engine must implement the same schema with `"engine": "rocky_linux"` and a corresponding `adhiambo_rocky_os_<timestamp>.json` filename pattern.

---

## 11. Open Items

| # | Item | Owner | Status |
|---|---|---|---|
| 1 | **Closed.** CIS Ubuntu Linux 24.04 LTS Benchmark v2.0.0 confirmed. Full check register with Server profile assignments extracted from the benchmark PDF and incorporated into Section 5.1. | Security team | **Closed** |
| 2 | **Closed.** Password policy values confirmed from the benchmark PDF and documented in Section 5.8. Key values: minlen ≥ 14, lockout after ≤ 5 attempts, unlock after ≥ 900s, history ≥ 24, PASS_MAX_DAYS ≤ 365, PASS_WARN_AGE ≥ 7, inactive lock ≤ 45 days. minlen = 14 is confirmed as the enforced floor — no exception applies. | Security team | **Closed** |
| 3 | Define the expected GPG key set for a standard Ubuntu 24.04 LTS setup (Section 5.10). Confirm whether the engine should flag any key outside the Ubuntu archive set, or only keys that are definitively unrecognised. | Security team | Open |
| 4 | **Closed.** When Docker is detected, the Docker engine inherits the following Ubuntu check findings directly from the OS engine report rather than re-running them: **AppArmor** (1.3.1.1–1.3.1.4), **auditd service** (6.2.1.1, 6.2.1.2), **auditd rules** (6.2.3.1–6.2.3.30), **auditd file access** (6.2.4.1–6.2.4.10), **IP forwarding** (3.3.1.1–3.3.1.3), and **kernel hardening parameters** (1.5.1–1.5.12). The Docker engine implementer references these IDs via the OS engine report `findings` map and cites the source check ID in each inherited finding row. | Engineering | **Closed** |
| 5 | Define the exact set of Ubuntu check IDs that the Kubernetes engine references via the OS engine report. To be resolved as part of the Kubernetes engine rewrite. | Engineering | **Open — pending Kubernetes engine rewrite** |
| 6 | **Closed.** The level mismatch mechanism is fully designed in Section 6.6 — message text, skip label, and warning are all defined. The specific check IDs unavailable in a Level 1 OS report / Level 2 downstream scan scenario resolve automatically from Item 4 (Docker, now closed) and Item 5 (Kubernetes, pending rewrite). No further action required on this item independently. | Security team | **Closed** |
| 7 | **Closed.** Multi-firewall detection and tiebreak logic defined in Section 5.6. When multiple utilities are active: evaluate Section 4 against UFW (highest precedence), print WARN advisory to console and CSV, recommend consolidation to operator. Priority order: UFW > nftables > iptables. | Engineering | **Closed** |
| 8 | **Closed.** GDM handling corrected to align with v2.0.0 benchmark: Section 1.7 is skipped (all checks N/A) when GDM is absent, per the benchmark's own skip instruction. When GDM is present on a server, a custom advisory `SERVER-GDM-01` is recorded and benchmark checks 1.7.1–1.7.7 evaluate normally. No fabricated benchmark check IDs are used. | Security team | **Closed** |
| 9 | Rocky Linux engine will produce its own OS engine report in the same JSON schema. Confirm the schema in Section 6.3 is frozen before Rocky Linux engine documentation begins — changes after Rocky implementation starts require coordinated updates across both OS engines and their downstream consumers. | Engineering | Open |
| 10 | **Closed.** No Ubuntu-specific considerations for the handover to `reporter.sh`. The standard four-column schema applies. | Security team | **Closed** |
| 11 | **v2 — Remediation scripts / emergency mode:** Design a v2 iteration in which the engine can offer to place the host in emergency mode to enable remounting of filesystems with correct options (e.g. check 1.1.2.x). Requires interactive operator confirmation, a tested recovery path, and a teardown step that returns the host to normal boot mode after remediation. Deferred to v2 — do not implement in v1. | Engineering | Open — v2 |
| 12 | **Unblock Docker and Kubernetes OS_DEPENDENT checks:** Once this engine is implemented and producing stable output, the `SKIPPED: OS engine under maintenance` placeholders in `engine/docker.sh` and `engine/kubernetes.sh` must be replaced with live report lookups. Tracked as Open Item 5 in `README-docker.md` and Open Item 3 in `README-kubernetes.md`. | Engineering | Pending Ubuntu engine implementation |

---

*This document is a living design spec. Updates should be made in the issues tab and reflected here before implementation begins.*