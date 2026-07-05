# Lenovo BIOS Password Manager

**LAPS-style rotation for Lenovo BIOS System Management Passwords, using Microsoft Intune and Azure Key Vault.**

Every laptop in your fleet gets its own unique, cryptographically random BIOS password. Passwords rotate automatically every N days. The current password is always retrievable from Azure Key Vault. No PowerShell modules required on endpoints. No Az/NuGet/PSGallery dependencies.

---

## Why This Exists

Most organisations manage Lenovo BIOS passwords one of three ways:

1. **A shared password across the whole fleet.** One leak compromises every device.
2. **Manually per-device**, tracked in a spreadsheet. Doesn't scale.
3. **Not at all.** The BIOS is unprotected.

This project is a fourth option: automated, per-device, cloud-backed, and free.

## What You Get

- Unique 16-character cryptographic password per device
- Central storage in Azure Key Vault (secret naming: `BIOS-<Serial>`)
- Automatic rotation on your chosen schedule (default: 180 days)
- Detection-driven Intune Remediation, no unnecessary rotations
- Full audit trail (Key Vault version history + Entra sign-in logs)
- Rollback path (revert to shared password)
- DaaS return path (remove password entirely)
- Diagnostic tools included

## How It Works

```
+------------------+                            +--------------------+
| Lenovo Endpoint  |   1. Bearer token          |  Microsoft         |
| (Intune managed) |--------------------------->|  Entra ID          |
|                  |<---------------------------|                    |
|                  |                            +--------------------+
|                  |
|                  |   2. Read/Write secret     +--------------------+
|                  |--------------------------->|  Azure Key Vault   |
|                  |<---------------------------|  (IP restricted)   |
|                  |                            |                    |
|                  |                            | Secrets:           |
|                  |                            |  BIOS-<serial> ->  |
|                  |                            |  <unique password> |
+------------------+                            +--------------------+
```

1. Intune runs the detection script on a schedule (e.g. daily)
2. Detection checks: has this device rotated recently? Is local state consistent?
3. If rotation is due, Intune invokes the rotation script
4. Rotation probes Key Vault reachability. If unreachable, exits cleanly. **No offline rotation.**
5. If reachable, reads current password from Key Vault
6. Generates a new random password
7. Changes the BIOS SMP via WMI
8. Uploads the new password to Key Vault
9. Updates the local encrypted cache
10. Done. All state consistent.

Read the [Architecture doc](docs/Architecture.md) for the full design.

## Requirements

**On the endpoint:**
- Windows 10/11
- PowerShell 5.1 (default on Windows) - no PowerShell 7 needed
- Lenovo ThinkPad, 2020 or newer (uses `Lenovo_WmiOpcodeInterface`)
- Managed by Microsoft Intune

**In Azure:**
- Entra ID tenant
- An App Registration with client secret
- An Azure Key Vault
- Network path from endpoints to `login.microsoftonline.com` and your vault FQDN

**Zero PowerShell module dependencies on endpoints.** Scripts use native `Invoke-RestMethod` for all Azure operations.

## Quick Start

### 1. Set up Azure

Follow [docs/Azure-Setup.md](docs/Azure-Setup.md) - it's a 15-minute walkthrough covering:
- App Registration (with client secret)
- Key Vault (with IP firewall)
- RBAC role assignment
- How to find each value the scripts need

### 2. Configure the Scripts

Open each of the four production scripts in `scripts/` and fill in the top config block:

```powershell
$TenantID    = "<your-tenant-id>"       # from Azure > Entra ID > Overview
$AppID       = "<your-app-id>"          # from Azure > App Registrations
$AppSecret   = "<your-client-secret>"   # the Value field, not the ID
$VaultName   = "<your-keyvault-name>"   # e.g. kv-biospw-prod (no FQDN)
$SecretPrefix = "BIOS-"                 # keep consistent across all scripts
```

For `Set-LenovoBIOSPassword.ps1` (rotation), also set:

```powershell
$LegacyPassword = ""    # if your fleet has a shared BIOS password today, put it here
                        # leave empty if devices have no BIOS password yet
```

For `Rollback-BIOSToSharedPassword.ps1`, also set:

```powershell
$SharedPassword = "<your-shared-password>"   # the rollback target
```

### 3. Test Access From Your Network

Run `scripts/Test-KeyVaultAccess.ps1` from a machine on the corporate network. You should see:

```
[PASS] FQDN resolves
[PASS] Got bearer token
[PASS] List secrets

[OK] Key Vault is REACHABLE from this network
```

If any fail, fix them before deploying to Intune.

### 4. Deploy via Intune Remediation

**Intune** > **Devices** > **Remediations** > **+ Create script package**

| Setting | Value |
|---|---|
| Name | BIOS Password Rotation |
| Detection script | `Detect-BIOSRotationDue.ps1` |
| Remediation script | `Set-LenovoBIOSPassword.ps1` |
| Run this script using the logged-on credentials | **No** |
| Run script in 64-bit PowerShell | **Yes** |
| Enforce script signature check | No (or Yes if you sign it) |

Assign to a pilot group first. Verify results in the Intune report before rolling out to the full fleet.

### 5. Retrieving a Password

Via Azure Portal:
1. Key Vaults > your vault > Secrets
2. Find `BIOS-<SerialNumber>`
3. Click the secret > current version > **Show Secret Value**

Or via PowerShell (from a network with KV access):

```powershell
$Token = (Invoke-RestMethod -Method POST `
    -Uri "https://login.microsoftonline.com/$TenantID/oauth2/v2.0/token" `
    -Body @{
        client_id     = $AppID
        scope         = "https://vault.azure.net/.default"
        client_secret = $AppSecret
        grant_type    = "client_credentials"
    } -UseBasicParsing).access_token

$Secret = Invoke-RestMethod -Method GET `
    -Uri "https://$VaultName.vault.azure.net/secrets/BIOS-PC0K1234?api-version=7.4" `
    -Headers @{ Authorization = "Bearer $Token" } -UseBasicParsing

$Secret.value
```

## What's in This Repo

```
scripts/
  Set-LenovoBIOSPassword.ps1          Main rotation script (Intune remediation)
  Detect-BIOSRotationDue.ps1          Intune detection script
  Rollback-BIOSToSharedPassword.ps1   Revert fleet to a shared password
  Remove-BIOSPassword.ps1             Strip BIOS password (DaaS returns)
  Test-KeyVaultAccess.ps1             Network diagnostic (no admin required)
  Check-KeyVaultSecrets.ps1           Bulk-check secret existence from CSV

docs/
  Architecture.md                     Full As-Built with diagrams
  Script-Flow.md                      Phase-by-phase script behavior + Mermaid flows
  Operations-Guide.md                 Runbook for service desk / operations
  Azure-Setup.md                      Step-by-step Azure configuration

examples/
  devices.csv                         Sample input for Check-KeyVaultSecrets
```

## Design Choices Worth Knowing

**No offline rotation.** The script refuses to rotate when Key Vault is unreachable. This is intentional. Offline rotation with delayed sync can lose passwords if the disk fails before sync completes. The tradeoff: devices permanently off the corporate network never rotate. For a BIOS password, that is fine.

**Local cache is informational only.** The BIOS_Current.dat file exists so the detection script can spot drift. The rotation script never uses it as the authoritative password source. Key Vault is authoritative.

**Circuit-breaker for wiped devices.** If a device is reimaged and the detection script sees no local state AND Key Vault is unreachable, detection returns compliant (no rotation triggered). This prevents the rotation script from falling back to a stale legacy password and triggering firmware-level lockouts on Lenovo hardware. When Key Vault becomes reachable again, detection triggers rotation which uses the KV password to restore state.

**Native REST, not Az modules.** Zero dependencies on the endpoint. No NuGet, no PSGallery, no Install-Module prompts. Works out of the box on any Windows device.

## Security Notes

- The App Registration client secret is stored in plaintext in the deployed script. Anyone with local admin on a device can extract it.
- Mitigate: scope the App Registration to one Key Vault only, one Azure subscription only, and rotate the client secret every 6 months.
- Consider certificate-based auth for higher security tiers.
- All local state files are DPAPI-encrypted, SYSTEM-only ACL.

Full risk register is in [Architecture.md](docs/Architecture.md).

## FAQ

**Q: Does this work on non-Lenovo devices?**
No. This uses Lenovo-specific WMI classes (`Lenovo_WmiOpcodeInterface`, `Lenovo_BiosPasswordSettings`). It would need adaptation for Dell (using `DellBIOSProvider` module) or HP (using `HP_BIOSSettingInterface`).

**Q: What about older ThinkPads (pre-2020)?**
The script has a fallback to `Lenovo_SetBiosPassword` for first-time password setting, but the change flow uses the 2020+ opcode interface. On very old ThinkPads it may need adjustment. PRs welcome.

**Q: Can I use a Managed Identity instead of client secret?**
Not directly on the endpoint (Managed Identity requires the caller to be an Azure resource). If you want to eliminate the client secret from endpoints, put an Azure Function in front of Key Vault - endpoints authenticate to the Function, the Function uses its Managed Identity to hit KV. This adds infrastructure but is more secure.

**Q: How much does it cost to run?**
Under $1/year for 2000+ devices. Key Vault charges $0.03 per 10,000 operations. Secret storage and version history are free.

**Q: What if my Intune remediation runs while the device is on a coffee shop network?**
Detection returns compliant (holds rotation). Rotation script refuses to run. Everything waits for the next cycle when the device is on corporate network. No orphan state, no lockout risk.

## Contributing

PRs welcome for:
- Dell / HP variants
- Certificate-based auth
- Azure Function proxy sample
- Additional hardware model coverage
- Bug fixes and improvements

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).

