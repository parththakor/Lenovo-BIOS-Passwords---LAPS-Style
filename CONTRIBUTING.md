# Contributing

Thanks for considering a contribution.

## What we're looking for

Priorities in rough order:

1. **Bug fixes** - especially edge cases in Lenovo WMI on specific models
2. **Dell / HP variants** of the rotation script (using DellBIOSProvider or HP_BIOSSettingInterface)
3. **Certificate-based auth** as an alternative to client secret
4. **Azure Function proxy sample** for organisations that can't put the client secret on endpoints
5. **Additional Lenovo model coverage** if the WMI interface differs
6. **Documentation improvements**

## Before you start

- Open an issue first for anything larger than a small fix, so we can align on approach
- For new features, describe the use case and target environment

## Development notes

### Testing

There is no automated test suite (the scripts talk to real hardware and real Azure). Test on:

- At least one Lenovo ThinkPad (2020 or newer)
- A real Azure Key Vault (a free-tier vault in a personal subscription works fine)
- Both on-network and off-network to verify the KV gate behavior

### Style

- PowerShell 5.1 compatible (no PowerShell 7-only syntax)
- ASCII only in script files (no em-dashes, unicode arrows, etc. - some environments read scripts as ANSI codepage)
- No PowerShell module dependencies on endpoints (`Invoke-RestMethod` for everything)
- Keep the config block at the top of each script
- Log meaningful state transitions to the log file

### Adding a new hardware vendor

If you want to add Dell or HP support, the cleanest pattern is:

1. Add a manufacturer check at Phase 2 preflight
2. Create vendor-specific helper functions (e.g. `Set-DellSMP`, `Set-HPSMP`) with the same signature as `Set-LenovoSMP`
3. Dispatch to the right helper based on `Get-CimInstance Win32_ComputerSystem`
4. Keep the Key Vault, detection, and Intune deployment model identical

The password source resolution (KV > legacy) and the KV-required gate should NOT change per vendor.

## Pull request process

1. Fork
2. Branch from `main`
3. Make your changes
4. Test on real hardware
5. Update the docs if behavior changes
6. Open a PR describing what you tested and on which model

## Reporting bugs

Include:
- Lenovo model number
- Windows version
- BIOS/UEFI version
- Which script you ran
- The log file from `C:\Windows\Debug\BIOS_Password_*.log`
- Redact any actual passwords or tenant IDs before pasting

## Security disclosure

If you find a security issue, please open a private security advisory on GitHub rather than a public issue.
