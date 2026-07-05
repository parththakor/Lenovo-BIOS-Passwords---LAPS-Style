# Script Flow Reference: BIOS Password Management (v5)

**Version:** 3.0
**Date:** 2026-05-13

---

## High-Level Architecture

```mermaid
flowchart LR
    subgraph Endpoint["Lenovo Endpoint"]
        S[Rotation Script v5]
        C[(BIOS_Current.dat<br/>cache - informational)]
        R[(BIOS_Recovery.dat<br/>transient crash safety)]
    end

    subgraph Azure["Azure"]
        E[Microsoft Entra ID]
        K[(Key Vault<br/>BIOS-serial secrets)]
    end

    S -->|1. Get token| E
    E -->|bearer token| S
    S -->|2. Read/Write secret| K
    S <-->|DPAPI| C
    S -->|on mid-run crash| R
    R -->|drained next run| S

    note["No background sync task in v5"]
```

---

## Script 1: Set-LenovoBIOSPassword.ps1

### Purpose

Rotates the BIOS System Management Password (SMP) to a unique cryptographic value per device. Stores in Azure Key Vault. **Requires Key Vault reachability.** Refuses to rotate when KV is unreachable.

### Top-Level Flow

```mermaid
flowchart TD
    Start([Intune invokes script as SYSTEM]) --> P1[Phase 1: Validate config]
    P1 --> P2[Phase 2: Preflight - Lenovo check, serial number]
    P2 --> P3[Phase 3: Rate limiting - skip if rotated less than 1 day ago]
    P3 --> P4[Phase 4: Probe Key Vault reachability]
    P4 --> KVOk{KV<br/>reachable?}
    KVOk -->|No| ExitDeferred[Exit 0 - KV unreachable<br/>rotation deferred]
    KVOk -->|Yes| P5{Recovery file<br/>from previous crash?}
    P5 -->|Yes| Drain[Upload recovery to KV<br/>exit successfully]
    P5 -->|No| P6[Phase 6: Read current password from Key Vault]
    P6 --> P7[Phase 7: Query BIOS state]
    P7 --> P8{KV had record?}
    P8 -->|Yes| UseKV[Use KV value as old password]
    P8 -->|No, SMP set| UseLegacy[Use legacy password]
    P8 -->|No, SMP not set| FirstSet[Initial set, no old password]
    UseKV --> P9
    UseLegacy --> P9
    FirstSet --> P9[Phase 9: Enable BIOSPasswordAtBootDeviceList<br/>if not already]
    P9 --> P10[Phase 10: Generate new password]
    P10 --> P11[Phase 11: Write recovery file - crash safety]
    P11 --> P12[Phase 12: Change BIOS SMP]
    P12 --> P13[Phase 13: Update local cache]
    P13 --> P14[Phase 14: Upload to Key Vault]
    P14 --> P15[Phase 15: Delete recovery file<br/>write marker, done]
    P15 --> Done([Exit 0])
```

### Phase Details

| Phase | Purpose | What It Does |
|---|---|---|
| 1 | Validate config | Fail fast if `$TenantID`, `$AppID`, `$AppSecret`, `$VaultName` are placeholders |
| 2 | Preflight | Confirm Lenovo, get serial, build secret name `BIOS-<serial>` |
| 3 | Rate limiting | Skip if `BIOS_LastRun.marker` is less than 1 day old |
| 4 | **KV reachability -- HARD GATE** | Get token, attempt authenticated list. **If 403/network failure, exit 0 without rotating.** |
| 5 | Drain recovery | If a previous run crashed mid-rotation, upload that recovery file's password and exit |
| 6 | Read KV | Pull current password for this device |
| 7 | BIOS state | Query `Lenovo_BiosPasswordSettings.PasswordState` |
| 8 | Resolve old password | KV value > legacy fallback (only if SMP set and KV had no record) |
| 9 | BIOS setting | Enable `BIOSPasswordAtBootDeviceList` if not already enabled |
| 10 | Generate password | 16-char cryptographic random |
| 11 | Write recovery file | Crash-safety net before BIOS change |
| 12 | Change SMP | Use 2020+ `Lenovo_WmiOpcodeInterface` flow |
| 13 | Update cache | Informational only - used by detection |
| 14 | Upload to KV | Always attempted (KV verified reachable in Phase 4) |
| 15 | Finalize | Delete recovery file, update marker, exit |

### Decision Tree: Should We Rotate?

```mermaid
flowchart TD
    Run[Script starts] --> Probe[Probe Key Vault reachability]
    Probe --> Reach{Reachable?}
    Reach -->|NO - Off-network/blocked| ExitClean[Exit 0 cleanly<br/>NO rotation attempted<br/>no orphan state created]
    Reach -->|YES| ProceedFull[Full rotation flow<br/>BIOS change + KV upload<br/>both succeed or none]
    ProceedFull --> Done[Done - state consistent across<br/>BIOS, cache, KV]
```

### Password Source Resolution (v5 simplified)

```mermaid
flowchart TD
    Start[Need old BIOS password] --> KV{KV has<br/>secret?}
    KV -->|Yes| UseKV[Use KV value]
    KV -->|No| SMP{BIOS has<br/>SMP set?}
    SMP -->|Yes| Legacy{Legacy<br/>configured?}
    SMP -->|No| Blank[First set - no old password needed]
    Legacy -->|Yes| UseLegacy[Use legacy password<br/>first migration only]
    Legacy -->|No| Fail[Exit - cannot resolve]
```

Note: v5 does NOT use the local cache as a password source. Cache is informational only.

### State File Lifecycle (within a single successful run)

```mermaid
sequenceDiagram
    participant Script
    participant BIOS
    participant Cache
    participant Recovery
    participant KV

    Script->>KV: Probe reachability + read current pwd
    KV-->>Script: current password
    Script->>Recovery: Write new password (crash safety)
    Script->>BIOS: Change SMP from old to new
    Script->>Cache: Update with new password
    Script->>KV: Upload new password
    KV-->>Script: 200 OK
    Script->>Recovery: Delete (no longer needed)
```

### Crash Recovery Within Same Day

```mermaid
sequenceDiagram
    participant Run1 as Run 1 (crashes)
    participant Recovery as Recovery File
    participant BIOS
    participant Run2 as Run 2 (next day)
    participant KV

    Run1->>Recovery: Write new password
    Run1->>BIOS: Change SMP
    Note over Run1: SCRIPT CRASHES HERE<br/>(power loss, kill, etc)
    Note over Recovery: File persists on disk

    Run2->>Recovery: Found recovery file
    Run2->>KV: Upload pending password
    KV-->>Run2: 200 OK
    Run2->>Recovery: Delete
    Note over Run2: State reconciled
```

---

## Script 2: Detect-BIOSRotationDue.ps1

### Purpose

Intune Remediation detection script. Determines whether rotation should run. Includes KV verification on state-loss scenarios to prevent firmware lockouts.

### Flow

```mermaid
flowchart TD
    Start([Detection runs]) --> Lenovo{Lenovo?}
    Lenovo -->|No| Skip[Exit 0 - skip non-Lenovo]
    Lenovo -->|Yes| Rec{Recovery<br/>file?}
    Rec -->|Yes| NC1[Exit 1 - pending crash recovery]
    Rec -->|No| StateLoss{State loss?<br/>marker/cache missing<br/>or cache corrupt}
    StateLoss -->|No| Age{Age less<br/>than 180 days?}
    StateLoss -->|Yes| KVProbe[Probe Key Vault]
    KVProbe --> KVResult{KV status}
    KVResult -->|Exists| NCKV[Exit 1 - rotation will restore from KV]
    KVResult -->|NotFound| NCFirst[Exit 1 - first-run rotation needed]
    KVResult -->|Unreachable| Hold[Exit 0 - holding rotation<br/>until KV reachable<br/>PREVENTS LOCKOUT]
    Age -->|No| NC2[Exit 1 - rotation due]
    Age -->|Yes| State{BIOS has<br/>password?}
    State -->|No| NC3[Exit 1 - drift detected]
    State -->|Yes| OK[Exit 0 - compliant]
```

### Key Safety: State-Loss + KV-Unreachable Path

This is the critical addition in v5. When local state is missing (reimage, disk failure, wipe, manual deletion) AND Key Vault is unreachable, detection returns **compliant** rather than triggering rotation.

**Why this matters:**
- v4 behavior: Trigger rotation. Rotation tries legacy password. Legacy is wrong on a previously-rotated device. BIOS rejects. Repeats daily. Firmware lockout.
- v5 behavior: Wait until KV is reachable. Then trigger rotation, which uses the KV value. No wrong-password attempts ever.

### Exit Codes

| Exit | Meaning | Action |
|---|---|---|
| 0 | Compliant or N/A | No remediation runs |
| 1 | Non-compliant | Rotation script runs |

---

## Script 3: Rollback-BIOSToSharedPassword.ps1

### Purpose

Reverts devices to the shared password. Used for project rollback.

**Requires Key Vault reachability** -- refuses to run if KV is unreachable.

### Flow

```mermaid
flowchart TD
    Start([Rollback invoked]) --> PF[Preflight: Lenovo, serial]
    PF --> SMP{SMP<br/>set?}
    SMP -->|No| Clean[Clean local files, exit 0]
    SMP -->|Yes| Token{Got KV<br/>token?}
    Token -->|No| Defer[Exit 1 - defer]
    Token -->|Yes| Read[Read current pwd from KV]
    Read --> Got{Found?}
    Got -->|No| Err[Exit 1 - cannot resolve]
    Got -->|Yes| Change[Change BIOS SMP to shared password]
    Change --> CleanAll[Delete cache, recovery,<br/>marker]
    CleanAll --> Done([Exit 0])
```

---

## Script 4: Remove-BIOSPassword.ps1

### Purpose

Removes BIOS password entirely. Used when returning DaaS devices.

**Requires Key Vault reachability.**

### Flow

```mermaid
flowchart TD
    Start([Removal invoked]) --> PF[Preflight: Lenovo, serial]
    PF --> SMP{SMP<br/>set?}
    SMP -->|No| CleanAll[Clean local files + logs, exit 0]
    SMP -->|Yes| Token{Got KV<br/>token?}
    Token -->|No| Defer[Exit 1 - defer]
    Token -->|Yes| Read[Read current pwd from KV]
    Read --> Got{Found?}
    Got -->|No| Err[Exit 1 - cannot resolve]
    Got -->|Yes| Remove[Change BIOS SMP to blank<br/>removes password]
    Remove --> Full[Delete all state files<br/>and rotation logs]
    Full --> Done([Exit 0])
```

---

## Script 5: Test-KeyVaultAccess.ps1

### Purpose

Diagnostic tool to verify Key Vault access from any network. Read-only, no admin rights.

### Flow

```mermaid
flowchart TD
    Start([Run diagnostic]) --> Ctx[Show context:<br/>hostname, public IP, interface]
    Ctx --> T1[Test 1: DNS resolution]
    T1 --> T2[Test 2: Token acquisition from Entra ID]
    T2 --> HasToken{Got token?}
    HasToken -->|No| Fail1[Fail - credentials issue]
    HasToken -->|Yes| T3[Test 3: Authenticated KV probe]
    T3 --> Resp{Response?}
    Resp -->|200 OK| Pass[PASS - vault reachable]
    Resp -->|403| Block[FAIL - firewall blocked]
    Resp -->|Other| Other[FAIL - investigate]
```

Note: Unauthenticated probes are unreliable. Key Vault returns 401 for anonymous requests regardless of firewall. Only authenticated probes reveal true firewall state.

---

## Script 6: Check-KeyVaultSecrets.ps1

### Purpose

Bulk-check the existence of secrets in Key Vault from a CSV of device names. Useful for fleet audits.

### Flow

```mermaid
flowchart TD
    Start([Run with CSV]) --> Load[Load CSV with DeviceName column]
    Load --> Token[Get bearer token]
    Token --> Loop[For each device name]
    Loop --> Probe[GET /secrets/<name>]
    Probe --> Result{Status}
    Result -->|200| Exists[Exists - record LastRotated tag]
    Result -->|404| Missing[NotFound]
    Result -->|Other| Error[Error]
    Exists --> Next{More?}
    Missing --> Next
    Error --> Next
    Next -->|Yes| Loop
    Next -->|No| CSV[Export results CSV]
    CSV --> Done([Done])
```

---

## Password Source Priority (All Scripts)

```
Priority 1:  Key Vault           Canonical source when reachable
Priority 2:  Recovery file       Crash-recovery within same script run
Priority 3:  Legacy password     Pre-migration fallback (first run only)
```

The local cache is NOT a password source for rotation. It's informational, used by the detection script for consistency checks.

---

## Exit Codes (All Scripts)

| Code | Meaning |
|---|---|
| 0 | Success, intentionally skipped, or deferred (waiting for KV) |
| 1 | Error (config missing, BIOS change failed, cannot resolve password) |
| 2 | Partial success (BIOS rotated but KV upload failed - rare crash window) |

---

## Intune Deployment Topology

```mermaid
flowchart LR
    subgraph Intune["Intune Remediation"]
        D[Detect-BIOSRotationDue.ps1]
        R[Set-LenovoBIOSPassword.ps1]
        D -->|Exit 1 triggers| R
    end
    Intune -->|Runs daily| Device[Lenovo Endpoints]
    subgraph OnDemand["On Demand"]
        Roll[Rollback-BIOSToSharedPassword.ps1]
        Rem[Remove-BIOSPassword.ps1]
    end
    OnDemand -->|Project rollback<br/>or DaaS return| Device
```

All deployments run as **SYSTEM** in **64-bit PowerShell**.

---

## What Changed from v4

| Aspect | v4 | v5 |
|---|---|---|
| Offline rotation | Allowed (uses local cache fallback) | **Refused** (KV reachable required) |
| Background sync task | BIOS-KV-Sync runs every 15 min | **Removed entirely** |
| Cache as password source | Used as fallback | Informational only |
| Detection on state loss | Always triggers rotation | Verifies KV first; holds if unreachable |
| Recovery file lifetime | Could persist for hours/days awaiting sync task | Only within a single run (seconds) |
| Risk: orphan rotation | Possible (offline rotation, then disk wipe) | Eliminated |
| Risk: firmware lockout from wrong-password retries | Possible (wiped device, no KV access) | Prevented by detection guard |
