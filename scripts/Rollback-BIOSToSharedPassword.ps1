#Requires -RunAsAdministrator

# ============================================================================
# CONFIGURATION
# ============================================================================
$TenantID       = "<your-tenant-id>"
$AppID          = "<your-app-id>"
$AppSecret      = "<your-client-secret>"
$VaultName      = "<your-keyvault-name>"

# Must match SecretPrefix in the rotation script
$SecretPrefix   = "BIOS-"

# BIOS password to set on all devices (the rollback target)
$SharedPassword = "<your-shared-password>"

# ============================================================================
# PATHS
# ============================================================================
$LogDir       = "$env:SystemRoot\Debug"
$LogFile      = "$LogDir\BIOS_Rollback_$(Get-Date -Format 'yyyyMMdd').log"
$CacheFile    = "$LogDir\BIOS_Current.dat"
$RecoveryFile = "$LogDir\BIOS_Recovery.dat"
$MarkerFile   = "$LogDir\BIOS_LastRun.marker"

If (!(Test-Path $LogDir))  { New-Item $LogDir -ItemType Directory -Force | Out-Null }
If (!(Test-Path $LogFile)) { New-Item $LogFile -ItemType File -Force | Out-Null }

# ============================================================================
# HELPERS
# ============================================================================
function Write-Log {
    param([string]$Level, [string]$Message)
    $Entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $LogFile -Value $Entry
    Write-Host $Entry
}

function Get-KeyVaultToken {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $TokenBody = @{
        client_id     = $AppID
        scope         = "https://vault.azure.net/.default"
        client_secret = $AppSecret
        grant_type    = "client_credentials"
    }
    $TokenResponse = Invoke-RestMethod -Method POST `
        -Uri "https://login.microsoftonline.com/$TenantID/oauth2/v2.0/token" `
        -Body $TokenBody -ErrorAction Stop -TimeoutSec 10 -UseBasicParsing
    return $TokenResponse.access_token
}

function Read-KeyVaultSecret {
    param([string]$SecretName, [string]$AccessToken)
    $Uri = "https://" + $VaultName + ".vault.azure.net/secrets/" + $SecretName + "?api-version=7.4"
    $Headers = @{ Authorization = "Bearer $AccessToken" }
    try {
        $Response = Invoke-RestMethod -Method GET -Uri $Uri -Headers $Headers `
            -ErrorAction Stop -TimeoutSec 15 -UseBasicParsing
        return $Response.value
    } catch {
        $StatusCode = $null
        if ($_.Exception.Response) { $StatusCode = [int]$_.Exception.Response.StatusCode }
        if ($StatusCode -eq 404) { return $null }
        throw
    }
}

function Remove-AllLocalState {
    foreach ($f in @($CacheFile, $RecoveryFile, $MarkerFile)) {
        if (Test-Path $f) {
            Remove-Item $f -Force -ErrorAction SilentlyContinue
            Write-Log "INFO" "Deleted: $f"
        }
    }
}

# ============================================================================
# MAIN
# ============================================================================
Write-Log "INFO" "======== BIOS Rollback to Shared Password ========"

$Manufacturer = (Get-CimInstance Win32_ComputerSystem).Manufacturer
if ($Manufacturer -notlike "*Lenovo*") {
    Write-Log "ERROR" "Not a Lenovo device: $Manufacturer"
    Write-Output "Not a Lenovo device"
    exit 1
}

$Serial = (Get-CimInstance Win32_BIOS).SerialNumber.Trim()
$SecretName = $SecretPrefix + ($Serial -replace '[^a-zA-Z0-9-]', '')
Write-Log "INFO" "Device: $Serial | Secret: $SecretName"

$PasswordState = (Get-CimInstance -Namespace root/wmi -ClassName Lenovo_BiosPasswordSettings).PasswordState
if ($PasswordState -eq 0) {
    Write-Log "INFO" "No BIOS password currently set. Nothing to roll back."
    Remove-AllLocalState
    Write-Output "No password set - cleanup done"
    exit 0
}

$AccessToken = $null
try {
    $AccessToken = Get-KeyVaultToken
} catch {
    Write-Log "ERROR" "Cannot acquire Key Vault token: $_"
    Write-Output "Cannot reach Entra ID - rollback deferred"
    exit 1
}

$OldPassword = $null
try {
    $OldPassword = Read-KeyVaultSecret -SecretName $SecretName -AccessToken $AccessToken
} catch {
    Write-Log "ERROR" "Cannot read from Key Vault: $_"
    Write-Output "Key Vault unreachable - rollback deferred"
    exit 1
}

if ([string]::IsNullOrEmpty($OldPassword)) {
    Write-Log "ERROR" "No password in Key Vault for $SecretName but BIOS has SMP set"
    Write-Output "Cannot determine current password (KV has no record)"
    exit 1
}

Write-Log "INFO" "Retrieved current password from Key Vault"

Write-Log "INFO" "Changing BIOS SMP to shared password..."
try {
    $WMI = Get-WmiObject -Namespace root\wmi -Class Lenovo_WmiOpcodeInterface
    $r = $WMI.WmiOpcodeInterface("WmiOpcodePasswordType:smp");               if ($r.Return -notmatch "Success") { throw "Type: $($r.Return)" }
    $r = $WMI.WmiOpcodeInterface("WmiOpcodePasswordCurrent01:$OldPassword"); if ($r.Return -notmatch "Success") { throw "Current: $($r.Return)" }
    $r = $WMI.WmiOpcodeInterface("WmiOpcodePasswordNew01:$SharedPassword");  if ($r.Return -notmatch "Success") { throw "New: $($r.Return)" }
    $r = $WMI.WmiOpcodeInterface("WmiOpcodePasswordSetUpdate");              if ($r.Return -notmatch "Success") { throw "Update: $($r.Return)" }
    Write-Log "SUCCESS" "BIOS password rolled back to shared password"
} catch {
    Write-Log "ERROR" "BIOS rollback failed: $_"
    Write-Output "Rollback failed"
    exit 1
}

Remove-AllLocalState
Write-Log "INFO" "Local state cleaned up"

Write-Log "SUCCESS" "Rollback complete for $Serial"
Write-Output "Rollback complete - BIOS set to shared password"
exit 0
