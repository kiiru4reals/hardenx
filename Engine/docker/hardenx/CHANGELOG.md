# Changelog

## v1.0.0 - Initial Stable Release

### Added
- Automated container image scanning using Trivy
- Support for Docker images already pulled locally
- Support for Docker image TAR files (`*.tar`)
- Automatic import of TAR files from `/media/sf_Documents/`
- Interactive numbered image selection menu
- `Scan ALL images` option (menu option `1`)
- Bulk scanning via `--all`
- Cleanup mode via `--cleanup`
- Severity override via `--severity`
- Support for severity levels: CRITICAL, HIGH, MEDIUM, LOW
- Quiet Trivy execution
- Automatic overwrite of previous reports
- Enterprise-grade JSON reports
- Detailed CSV reports
- Executive Summary CSV reports
- Optional HTML reports using Trivy templates
- ZIP packaging of all report artifacts
- Logging to `scan.log`
- CI/CD-friendly exit codes (`10` when CRITICAL findings are detected)
- Centralized configuration through `config.sh`
- Support for exporting reports to Windows shared folders
- Docker and TAR images displayed in a unified menu

### Improved
- Multi-source image discovery (Docker daemon + TAR archives)
- Automatic import workflow for Windows → Kali VM environments
- Report organization under `reports/<image-name>/`
- Cleaner scan completion output
- Professional README and project documentation

### Notes
- This is the first public stable release of the project.
- The version is intentionally set to `v1.0.0`.