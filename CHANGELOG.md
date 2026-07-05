# Changelog

All notable changes to this project.

## [1.0.0] - Initial public release

### Features

- Per-device unique BIOS Supervisor Password rotation for Lenovo (2020+ ThinkPad)
- Storage in Azure Key Vault, one secret per device (`BIOS-<Serial>`)
- Intune Remediation deployment model (detection + remediation scripts)
- KV-required rotation: script refuses to rotate when Key Vault is unreachable
- Circuit-breaker: detection holds rotation on state-loss when KV unreachable, preventing firmware lockouts on wiped devices
- DPAPI-encrypted local cache (informational only)
- Rollback path to a shared password
- DaaS return path to remove BIOS password
- Diagnostic tools: Test-KeyVaultAccess, Check-KeyVaultSecrets
- Zero PowerShell module dependencies on endpoints (native REST only)
- Full documentation: Architecture, Script Flow, Operations Guide, Azure Setup
