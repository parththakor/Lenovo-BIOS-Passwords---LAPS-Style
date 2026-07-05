# As-Built: Lenovo BIOS Password Management System

**Version:** 3.0 
**Date:** 2026-05-13
**Author:** IT Security / Endpoint Engineering
**Classification:** Internal - Restricted

---

## 1. Overview

Automated BIOS System Management Password (SMP) rotation for the Lenovo laptop fleet. Each device receives a unique, cryptographically generated 16-character password. Passwords are stored in Azure Key Vault and rotated every 180 days via Microsoft Intune Remediations.

**Key design rule (v5):** Rotation only occurs when Key Vault is reachable. The script refuses to rotate on devices that cannot contact Key Vault, eliminating any possibility of a rotation that leaves the new password unrecorded.

## 2. Architecture

```
+-------------------------+
|   Lenovo Endpoint       |
|  (Intune Managed)       |
|                         |
|  +-------------------+  |
|  |  Rotation Script  |  |     HTTPS             +--------------------+
|  |  (pure REST)      |---------token----------->| Microsoft Entra ID |
|  |                   |  |                       | login.microsoft... |
|  +-------------------+  |                       +--------------------+
|  |  Local State:     |  |                               |
|  |  - BIOS_Current   |  |                               | bearer token
|  |  - BIOS_Recovery  |  |     HTTPS                     v
|  |    (transient)    |------with bearer token---> +--------------------+
|  |  - LastRun marker |  |                         | Azure Key Vault    |
|  |  - Logs           |  |                         | (IP restricted)    |
|  +-------------------+  |                         |                    |
|                         |                         | Secrets:           |
|  No background tasks    |                         |  BIOS-<serial> -> pw|
+-------------------------+                         +--------------------+
```

### Key Design Choices

| Choice | Why |
|---|---|
| Native REST to Entra ID + Key Vault | No PowerShell modules required. No NuGet. No PSGallery. Works on fresh devices without network dependencies beyond HTTPS. |
| DPAPI-encrypted local cache | Informational only. Used by the detection script for consistency checks. Rotation does not depend on it. |
| Per-device serial keying | Each device reads and writes only its own secret. |
| **No offline rotation** | Rotation refuses to proceed if Key Vault is unreachable. No orphan state ever exists. |
| **No background sync task** | Single-run rotation. Either it succeeds with KV write, or it does nothing. |
| Crash-safety recovery file | Only used if the script itself crashes between BIOS change and KV upload (same run). Drained by the next run. |

## 3. Components

| Script | Purpose | Deployment |
|---|---|---|
| Set-LenovoBIOSPassword.ps1 | Main rotation | Intune Remediation (recurring) |
| Detect-BIOSRotationDue.ps1 | Detects rotation need with KV verification | Intune Remediation (detection script) |
| Rollback-BIOSToSharedPassword.ps1 | Reverts to shared password | Intune Remediation (on demand) |
| Remove-BIOSPassword.ps1 | Strips password (DaaS return) | Intune Remediation (on demand) |
| Test-KeyVaultAccess.ps1 | Diagnostic / access test | Manual |
| Check-KeyVaultSecrets.ps1 | Bulk check of secret existence from a CSV | Manual |

**Removed in v5:** the `BIOS-KV-Sync` scheduled task and its embedded sync script. v5 does not create background tasks. Any leftover v4 sync tasks on existing devices will self-drain when next on corporate network and remove themselves.

## 4. Azure Resources

### 4.1 Subscription

| Field | Value |
|---|---|
| Subscription Name | your-subscription |
| Subscription ID | your-subscription-id |
| Resource Group | your-resource-group |
| Region | your-region |

### 4.2 App Registration

| Field | Value |
|---|---|
| Display Name | your-app-registration-name |
| Application (Client) ID | your-app-id |
| Directory (Tenant) ID | your-tenant-id |
| Authentication | Client Secret |
| Secret Expiry | expiry-date |
| API Permissions | None (access controlled via Key Vault RBAC) |
| Subscription Access | Restricted to your-subscription only |

### 4.3 Key Vault

| Field | Value |
|---|---|
| Vault Name | your-keyvault-name |
| SKU | Standard |
| Permission Model | Azure RBAC |
| Soft Delete | Enabled |
| Purge Protection | Enabled |
| Public Network Access | Selected Networks |
| Private Endpoint | your-details |

#### Firewall Rules

| Allowed IP / CIDR | Description |
|---|---|
| office-ip-1 | Office - Primary |
| office-ip-2 | Office - Secondary / VPN Egress |

#### RBAC Role Assignments

| Principal | Role | Scope |
|---|---|---|
| your-app-registration-name | Key Vault Secrets Officer | This Key Vault |
| your-admin-group | Key Vault Secrets Officer | This Key Vault |

### 4.4 Secret Naming

Format: `BIOS-<SerialNumber>` (example: `BIOS-PC0K1234`)

Tags on each secret:

| Tag | Example |
|---|---|
| SerialNumber | PW0KBY70 |
| Manufacturer | LENOVO |
| Hostname | BIOS-PC0K1234 |
| LastRotated | 2026-05-13 10:15:00 UTC |

All versions retained indefinitely.

## 5. Intune Configuration

### 5.1 Remediation: Rotation

| Setting | Value |
|---|---|
| Name | BIOS Password Rotation |
| Detection Script | Detect-BIOSRotationDue.ps1 |
| Remediation Script | Set-LenovoBIOSPassword.ps1 |
| Run as | System |
| Run in 64-bit | Yes |
| Schedule | Daily |
| Assignment | your-device-group |

Detection returns non-compliant when:
- Last rotation > 180 days old
- Recovery file present (crash recovery)
- Local state lost AND Key Vault has a record (rotation will use KV)
- Local state lost AND Key Vault has no record (first run)
- BIOS state inconsistent with cache

Detection returns COMPLIANT (suppresses remediation) when:
- All checks pass normally
- Local state lost AND Key Vault is **unreachable** -- this is critical. It prevents rotation attempts on devices that cannot verify their state against KV, which is what previously caused firmware retry lockouts on wiped/reimaged devices.

### 5.2 Remediation: Rollback

| Setting | Value |
|---|---|
| Name | BIOS Password Rollback to Shared |
| Remediation Script | Rollback-BIOSToSharedPassword.ps1 |
| Run as | System, 64-bit |
| Assignment | On demand |

### 5.3 Remediation: Removal

| Setting | Value |
|---|---|
| Name | BIOS Password Removal (DaaS) |
| Remediation Script | Remove-BIOSPassword.ps1 |
| Run as | System, 64-bit |
| Assignment | DaaS return batch only |

## 6. Local State Files

All files in `C:\Windows\Debug\` with SYSTEM-only ACLs.

| File | Purpose | Lifecycle |
|---|---|---|
| BIOS_Current.dat | DPAPI-encrypted current password (informational only) | Always present after first rotation |
| BIOS_Recovery.dat | DPAPI-encrypted pending password | Only between BIOS change and KV upload (typically <5 seconds within a single run) |
| BIOS_LastRun.marker | Timestamp of last successful rotation | Always present after first rotation |
| BIOS_Password_YYYYMMDD.log | Daily rotation log | Rolling, one per day |

**Removed in v5:**
- `BIOS_KVSync.ps1` -- no longer generated
- `BIOS_KVSync_YYYYMMDD.log` -- no longer generated

## 7. Password Policy

| Parameter | Value |
|---|---|
| Length | 16 characters |
| Charset | a-z (no l), A-Z (no I, O), 2-9 (no 0, 1), !@#$%&* |
| Entropy | ~95 bits |
| Generator | System.Security.Cryptography.RandomNumberGenerator |
| Rotation interval | 180 days (configured in detection script) |
| Minimum interval safety guard | 1 day (configured in rotation script) |

## 8. BIOS WMI Interface

Targets 2020+ Lenovo ThinkPad models using `Lenovo_WmiOpcodeInterface`.

### Password Change (2020+)

```
WmiOpcodeInterface("WmiOpcodePasswordType:smp")
WmiOpcodeInterface("WmiOpcodePasswordCurrent01:<old>")
WmiOpcodeInterface("WmiOpcodePasswordNew01:<new>")
WmiOpcodeInterface("WmiOpcodePasswordSetUpdate")
```

### Setting Change with SMP

```
Lenovo_SetBiosSetting.SetBiosSetting("<Setting>,<Value>")
Lenovo_WmiOpcodeInterface.WmiOpcodeInterface("WmiOpcodePasswordAdmin:<password>")
Lenovo_SaveBiosSettings.SaveBiosSettings()
```

### Applied Settings

| Setting | Value | Purpose |
|---|---|---|
| BIOSPasswordAtBootDeviceList | Enable | Requires SMP to change boot device order |

## 9. Network Requirements

| Source | Destination | Port | Purpose |
|---|---|---|---|
| Endpoint | login.microsoftonline.com | 443 | Bearer token from Entra ID |
| Endpoint | your-keyvault-name.vault.azure.net | 443 | Secret read/write (REST API) |
| Endpoint | api.ipify.org | 443 | Public IP detection (diagnostic only) |

No PSGallery, no PowerShell module downloads.

## 10. Security Controls

| Control | Implementation |
|---|---|
| Encryption at rest (local) | DPAPI, SYSTEM account binding |
| Encryption at rest (cloud) | Azure Key Vault platform encryption |
| Encryption in transit | TLS 1.2 |
| Local file ACL | SYSTEM-only, no inheritance |
| Key Vault access | Azure RBAC + IP firewall |
| Authentication | Entra ID service principal (client secret) |
| Audit trail | Local logs, Key Vault access logs, Entra sign-in logs |
| Version history | Automatic, retained indefinitely |
| Credential storage | Client secret embedded in script (SYSTEM context) |

### Known Risk: Client Secret in Script

The App Registration client secret is stored in plaintext in the deployed script. Anyone with local admin on a device can extract it.

**Mitigations:**
- Script runs only as SYSTEM; standard users cannot read it
- App Registration scoped to one Key Vault only
- App Registration limited to one Azure subscription
- Entra ID sign-in logs audit every token request
- Client secret rotated every 6 months

## 11. Failure Handling and Edge Cases

| Scenario | v5 Behavior |
|---|---|
| Device on corp network, healthy | Rotates, uploads to KV, done |
| Device off corp network | **No rotation attempted.** Exits cleanly. Retries next cycle. |
| Device wiped, on corp network | Detection probes KV. If secret exists, rotation uses KV value. |
| Device wiped, off corp network | Detection returns COMPLIANT. Rotation does not run until KV reachable. **Prevents firmware retry lockout.** |
| Brand new device, on corp network | Detection sees no KV record. Triggers rotation. Rotation uses legacy password fallback. |
| Brand new device, off corp network | Detection returns COMPLIANT. Waits for KV reachable. |
| Crash mid-rotation (between BIOS change and KV upload) | Recovery file preserved. Next run drains it to KV. |
| Disk failure between BIOS change and KV upload (<5 seconds) | Edge case. Password lost. Lenovo Service Desk recovery required. |

## 12. Disaster Recovery

| Scenario | Recovery Path |
|---|---|
| Key Vault deleted | Soft delete + purge protection (90-day window) |
| App secret expired | Generate new secret in Entra, update scripts, redeploy |
| Device disk failure with no KV record | Lenovo service desk reset (proof of ownership) |
| Local cache corrupt | Next on-network run restores from Key Vault |
| Fleet-wide rollback | Deploy Rollback-BIOSToSharedPassword.ps1 via Intune |
| Firewall misconfigured | Detection holds, rotation does not attempt. Fix firewall, normal cycle resumes. |

## 13. Migration from v4

Existing devices running v4 are compatible with v5. Local state files use the same format and locations.

| v4 Artifact | v5 Behavior |
|---|---|
| BIOS_Current.dat | Continues to be read and updated |
| BIOS_Recovery.dat | Continues to be drained by next run |
| BIOS_LastRun.marker | Continues to be used by detection |
| BIOS-KV-Sync scheduled task | v5 ignores it. The v4 sync script will continue to drain pending uploads and self-delete. No conflict. |
| BIOS_KVSync.ps1 (v4 sync script) | Will self-delete after final successful upload |

Optional one-time cleanup remediation can remove any orphaned v4 sync tasks, but they will self-clean naturally.

## 14. Maintenance Schedule

| Task | Frequency | Owner |
|---|---|---|
| Rotate App Registration secret | Every 6 months | owner-name |
| Review Key Vault access logs | Monthly | owner-name |
| Verify Intune remediation compliance | Monthly | owner-name |
| Review failed rotations in Intune | Weekly | owner-name |
| Test rollback on a pilot device | Annually | owner-name |
| Review/update firewall IP allowlist | After network changes | owner-name |

## 15. Cost

| Item | Cost |
|---|---|
| Key Vault (Standard) | Free (no monthly base fee) |
| Secret operations | $0.03 per 10,000 |
| Secret storage and versions | Free |
| Typical annual cost (2300 devices, 180-day rotation, daily detection) | < $1 |
