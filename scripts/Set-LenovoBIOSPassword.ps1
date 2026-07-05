#Requires -RunAsAdministrator

# ============================================================================
# CONFIGURATION
# ============================================================================
$TenantID     = "<your-tenant-id>"
$AppID        = "<your-app-id>"
$AppSecret    = "<your-client-secret>"
$VaultName    = "<your-keyvault-name>"

# Secret naming: <prefix><serial>. Keep consistent across all four scripts.
$SecretPrefix = "BIOS-"

# Shared BIOS password on devices before onboarding. Set to "" once fleet is migrated.
$LegacyPassword = ""

# Password policy
$PasswordLength  = 16
$PasswordCharset = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#$%&*'

# Won't rotate more than once per this many days
$MinRotationDaysInterval = 1

# Retry settings for Key Vault operations
$KVRetryCount    = 3
$KVRetryDelaySec = 5

# ============================================================================
# PATHS
# ============================================================================
$LogDir        = "$env:SystemRoot\Debug"
$LogDate       = Get-Date -Format "yyyyMMdd"
$LogFile       = "$LogDir\BIOS_Password_$LogDate.log"
$CacheFile     = "$LogDir\BIOS_Current.dat"
$RecoveryFile  = "$LogDir\BIOS_Recovery.dat"
$LastRunMarker = "$LogDir\BIOS_LastRun.marker"

If (!(Test-Path $LogDir))  { New-Item $LogDir -ItemType Directory -Force | Out-Null }
If (!(Test-Path $LogFile)) { New-Item $LogFile -ItemType File -Force | Out-Null }

# ============================================================================
# LOGGING
# ============================================================================
function Write-Log {
    param(
        [ValidateSet("INFO","SUCCESS","ERROR","WARN","DEBUG")]
        [string]$Level,
        [string]$Message
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Entry = "[$Timestamp] [$Level] $Message"
    try { Add-Content -Path $LogFile -Value $Entry -ErrorAction Stop } catch {}
    Write-Host $Entry
}

function Exit-Script {
    param([int]$Code = 0, [string]$Message = "")
    if ($Message) { Write-Output $Message }
    exit $Code
}

# ============================================================================
# CONFIGURATION VALIDATION
# ============================================================================
function Test-Configuration {
    $Missing = @()
    if ($TenantID  -match '^<' -or [string]::IsNullOrWhiteSpace($TenantID))  { $Missing += "TenantID"  }
    if ($AppID     -match '^<' -or [string]::IsNullOrWhiteSpace($AppID))     { $Missing += "AppID"     }
    if ($AppSecret -match '^<' -or [string]::IsNullOrWhiteSpace($AppSecret)) { $Missing += "AppSecret" }
    if ($VaultName -match '^<' -or [string]::IsNullOrWhiteSpace($VaultName)) { $Missing += "VaultName" }
    if ($Missing.Count -gt 0) {
        Write-Log -Level "ERROR" -Message "Missing required configuration: $($Missing -join ', ')"
        Exit-Script -Code 1 -Message "Configuration incomplete"
    }
}

# ============================================================================
# CRYPTO / FILE HELPERS
# ============================================================================
function New-CryptoPassword {
    param([int]$Length, [string]$Charset)
    $RNG    = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $Bytes  = New-Object byte[] $Length
    $Result = New-Object char[] $Length
    $RNG.GetBytes($Bytes)
    for ($i = 0; $i -lt $Length; $i++) {
        $Result[$i] = $Charset[$Bytes[$i] % $Charset.Length]
    }
    $RNG.Dispose()
    return -join $Result
}

function Save-EncryptedFile {
    param([string]$Password, [string]$FilePath)
    $TempPath = "$FilePath.tmp"
    $Password | ConvertTo-SecureString -AsPlainText -Force |
        ConvertFrom-SecureString |
        Set-Content -Path $TempPath -Force -Encoding ASCII

    $Acl = Get-Acl $TempPath
    $Acl.SetAccessRuleProtection($true, $false)
    $Rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "NT AUTHORITY\SYSTEM", "FullControl", "Allow")
    $Acl.SetAccessRule($Rule)
    Set-Acl -Path $TempPath -AclObject $Acl

    Move-Item -Path $TempPath -Destination $FilePath -Force
}

function Read-EncryptedFile {
    param([string]$FilePath)
    if (-not (Test-Path $FilePath)) { return $null }
    try {
        $Encrypted = Get-Content -Path $FilePath -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($Encrypted)) { return $null }
        $SecureString = $Encrypted | ConvertTo-SecureString -ErrorAction Stop
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
        $Plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
        return $Plain
    } catch {
        Write-Log -Level "WARN" -Message "Failed to decrypt '$FilePath': $_"
        return $null
    }
}

function Remove-FileSafe {
    param([string]$FilePath)
    if (Test-Path $FilePath) {
        Remove-Item -Path $FilePath -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================================
# KEY VAULT
# ============================================================================
function Test-KeyVaultReachable {
    $Result = @{ Reachable = $false; AccessToken = $null; Reason = "" }

    try {
        $TokenBody = @{
            client_id     = $AppID
            scope         = "https://vault.azure.net/.default"
            client_secret = $AppSecret
            grant_type    = "client_credentials"
        }
        $TokenResponse = Invoke-RestMethod -Method POST `
            -Uri "https://login.microsoftonline.com/$TenantID/oauth2/v2.0/token" `
            -Body $TokenBody -ErrorAction Stop -TimeoutSec 10 -UseBasicParsing
        $Result.AccessToken = $TokenResponse.access_token
    } catch {
        $Result.Reason = "Token acquisition failed: $($_.Exception.Message)"
        return $Result
    }

    try {
        $Headers = @{ Authorization = "Bearer $($Result.AccessToken)" }
        $null = Invoke-RestMethod -Method GET `
            -Uri "https://$VaultName.vault.azure.net/secrets?api-version=7.4&maxresults=1" `
            -Headers $Headers -ErrorAction Stop -TimeoutSec 10 -UseBasicParsing
        $Result.Reachable = $true
        $Result.Reason = "Authenticated list succeeded"
    } catch [System.Net.WebException] {
        $StatusCode = $null
        if ($_.Exception.Response) { $StatusCode = [int]$_.Exception.Response.StatusCode }
        switch ($StatusCode) {
            403 { $Result.Reason = "Firewall blocked (403)" }
            401 { $Result.Reason = "Token rejected (401)" }
            default { $Result.Reason = "HTTP $StatusCode - $($_.Exception.Message)" }
        }
    } catch {
        $Result.Reason = "Network error: $($_.Exception.Message)"
    }

    return $Result
}

function Read-KeyVaultSecret {
    param([string]$SecretName, [string]$AccessToken)
    $Uri = "https://" + $VaultName + ".vault.azure.net/secrets/" + $SecretName + "?api-version=7.4"
    $Headers = @{ Authorization = "Bearer $AccessToken" }

    for ($i = 1; $i -le $KVRetryCount; $i++) {
        try {
            $Response = Invoke-RestMethod -Method GET -Uri $Uri -Headers $Headers `
                -ErrorAction Stop -TimeoutSec 15 -UseBasicParsing
            return $Response.value
        } catch {
            $StatusCode = $null
            if ($_.Exception.Response) { $StatusCode = [int]$_.Exception.Response.StatusCode }

            if ($StatusCode -eq 404) {
                Write-Log -Level "INFO" -Message "KV read '$SecretName': secret does not exist"
                return $null
            }

            if ($i -eq $KVRetryCount) {
                Write-Log -Level "ERROR" -Message "KV read '$SecretName' failed after $KVRetryCount attempts: $_"
                throw
            }
            Write-Log -Level "WARN" -Message "KV read '$SecretName' attempt $i failed: $_"
            Start-Sleep -Seconds ($KVRetryDelaySec * $i)
        }
    }
}

function Write-KeyVaultSecret {
    param(
        [string]$SecretName, [string]$Password,
        [string]$SerialNumber, [string]$Manufacturer, [string]$AccessToken
    )
    $Uri = "https://" + $VaultName + ".vault.azure.net/secrets/" + $SecretName + "?api-version=7.4"
    $Headers = @{ Authorization = "Bearer $AccessToken" }
    $Body = @{
        value = $Password
        tags  = @{
            SerialNumber = $SerialNumber
            Manufacturer = $Manufacturer
            Hostname     = $env:COMPUTERNAME
            LastRotated  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss UTC")
        }
    } | ConvertTo-Json -Depth 4

    for ($i = 1; $i -le $KVRetryCount; $i++) {
        try {
            $null = Invoke-RestMethod -Method PUT -Uri $Uri -Headers $Headers -Body $Body `
                -ContentType 'application/json' -ErrorAction Stop -TimeoutSec 15 -UseBasicParsing
            Write-Log -Level "SUCCESS" -Message "Key Vault updated: $SecretName"
            return
        } catch {
            if ($i -eq $KVRetryCount) {
                Write-Log -Level "ERROR" -Message "KV write '$SecretName' failed after $KVRetryCount attempts: $_"
                throw
            }
            Write-Log -Level "WARN" -Message "KV write '$SecretName' attempt $i failed: $_"
            Start-Sleep -Seconds ($KVRetryDelaySec * $i)
        }
    }
}

# ============================================================================
# LENOVO BIOS
# ============================================================================
function Get-LenovoSMPState {
    try {
        $State = (Get-CimInstance -Namespace root/wmi -ClassName Lenovo_BiosPasswordSettings -ErrorAction Stop).PasswordState
        Write-Log -Level "INFO" -Message "BIOS PasswordState raw: $State"
        return ($State -ne 0)
    } catch {
        Write-Log -Level "ERROR" -Message "Failed to query Lenovo BIOS state: $_"
        throw
    }
}

function Invoke-LenovoOpcode {
    param([string]$Command)
    $WMI = Get-WmiObject -Namespace root\wmi -Class Lenovo_WmiOpcodeInterface
    $Result = $WMI.WmiOpcodeInterface($Command)
    if ($Result.Return -notmatch "Success") {
        throw "WmiOpcodeInterface('$Command') returned: $($Result.Return)"
    }
}

function Set-LenovoSMP {
    param([string]$OldPassword, [string]$NewPassword, [bool]$CurrentlySet)

    if ($CurrentlySet) {
        Write-Log -Level "INFO" -Message "Changing SMP (existing -> new)"
        Invoke-LenovoOpcode -Command "WmiOpcodePasswordType:smp"
        Invoke-LenovoOpcode -Command "WmiOpcodePasswordCurrent01:$OldPassword"
        Invoke-LenovoOpcode -Command "WmiOpcodePasswordNew01:$NewPassword"
        Invoke-LenovoOpcode -Command "WmiOpcodePasswordSetUpdate"
    } else {
        Write-Log -Level "INFO" -Message "Setting SMP for the first time"
        $WMI = Get-WmiObject -Namespace root\wmi -Class Lenovo_SetBiosPassword
        $Result = $WMI.SetBiosPassword("smp,,$NewPassword,ascii,us")
        if ($Result.Return -notmatch "Success") { throw "SetBiosPassword returned: $($Result.Return)" }
        $SaveWMI = Get-WmiObject -Namespace root\wmi -Class Lenovo_SaveBiosSettings
        $SaveResult = $SaveWMI.SaveBiosSettings()
        if ($SaveResult.Return -notmatch "Success") { throw "SaveBiosSettings returned: $($SaveResult.Return)" }
    }
    Write-Log -Level "SUCCESS" -Message "SMP change committed"
}

function Set-LenovoBiosSetting {
    param([string]$Setting, [string]$Value, [string]$Password)

    $SetWMI = Get-WmiObject -Namespace root\wmi -Class Lenovo_SetBiosSetting
    $SetResult = $SetWMI.SetBiosSetting("$Setting,$Value")
    if ($SetResult.Return -notmatch "Success") {
        throw "SetBiosSetting('$Setting,$Value') returned: $($SetResult.Return)"
    }

    Invoke-LenovoOpcode -Command "WmiOpcodePasswordAdmin:$Password" | Out-Null

    $SaveWMI = Get-WmiObject -Namespace root\wmi -Class Lenovo_SaveBiosSettings
    $SaveResult = $SaveWMI.SaveBiosSettings()
    if ($SaveResult.Return -notmatch "Success") {
        throw "SaveBiosSettings returned: $($SaveResult.Return)"
    }
    Write-Log -Level "DEBUG" -Message "Setting $Setting=$Value saved"
}

# ============================================================================
# MAIN
# ============================================================================
Write-Log -Level "INFO" -Message "======== BIOS Password Rotation ========"

Test-Configuration

$Manufacturer = (Get-CimInstance -ClassName Win32_ComputerSystem).Manufacturer
if ($Manufacturer -notlike "*Lenovo*") {
    Write-Log -Level "ERROR" -Message "Not a Lenovo device: $Manufacturer"
    Exit-Script -Code 1 -Message "Not a Lenovo device"
}

$SerialNumber = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber.Trim()
if ([string]::IsNullOrWhiteSpace($SerialNumber)) {
    Write-Log -Level "ERROR" -Message "Could not determine serial number"
    Exit-Script -Code 1 -Message "No serial number"
}

$SecretName = $SecretPrefix + ($SerialNumber -replace '[^a-zA-Z0-9-]', '')
Write-Log -Level "INFO" -Message "Device: $Manufacturer | Serial: $SerialNumber | Secret: $SecretName"

if ($MinRotationDaysInterval -gt 0 -and (Test-Path $LastRunMarker)) {
    $LastRun = (Get-Item $LastRunMarker).LastWriteTime
    $DaysSince = (New-TimeSpan -Start $LastRun -End (Get-Date)).TotalDays
    if ($DaysSince -lt $MinRotationDaysInterval) {
        Write-Log -Level "INFO" -Message "Last rotation was $([math]::Round($DaysSince,2)) days ago"
        Exit-Script -Code 0 -Message "Rotation skipped (too recent)"
    }
}

$ProbeResult = Test-KeyVaultReachable
Write-Log -Level "INFO" -Message "Key Vault reachable: $($ProbeResult.Reachable) ($($ProbeResult.Reason))"

if (-not $ProbeResult.Reachable) {
    Write-Log -Level "WARN" -Message "Key Vault unreachable - rotation deferred to next run"
    Exit-Script -Code 0 -Message "KV unreachable - rotation deferred"
}

$AccessToken = $ProbeResult.AccessToken

$RecoveryPassword = Read-EncryptedFile -FilePath $RecoveryFile
if ($null -ne $RecoveryPassword) {
    Write-Log -Level "WARN" -Message "Recovery file detected - previous run crashed mid-rotation"
    try {
        Write-KeyVaultSecret -SecretName $SecretName -Password $RecoveryPassword `
            -SerialNumber $SerialNumber -Manufacturer $Manufacturer -AccessToken $AccessToken
        Remove-FileSafe -FilePath $RecoveryFile
        Save-EncryptedFile -Password $RecoveryPassword -FilePath $CacheFile
        New-Item -Path $LastRunMarker -ItemType File -Force | Out-Null
        Write-Log -Level "SUCCESS" -Message "Recovery upload complete"
        Exit-Script -Code 0 -Message "Pending recovery uploaded to KV"
    } catch {
        Write-Log -Level "ERROR" -Message "Recovery upload failed: $_"
        Exit-Script -Code 1 -Message "Recovery upload failed"
    }
}

$OldPassword    = ""
$PasswordSource = ""
try {
    $KVPwd = Read-KeyVaultSecret -SecretName $SecretName -AccessToken $AccessToken
    if ($null -ne $KVPwd) {
        $OldPassword    = $KVPwd
        $PasswordSource = "KeyVault"
        Write-Log -Level "INFO" -Message "Current password source: Key Vault"
    }
} catch {
    Write-Log -Level "ERROR" -Message "Failed to read from Key Vault: $_"
    Exit-Script -Code 1 -Message "KV read failed"
}

try {
    $IsSMPSet = Get-LenovoSMPState
} catch {
    Exit-Script -Code 1 -Message "Cannot query BIOS state"
}

if ($IsSMPSet -and [string]::IsNullOrEmpty($OldPassword)) {
    if (-not [string]::IsNullOrEmpty($LegacyPassword)) {
        $OldPassword    = $LegacyPassword
        $PasswordSource = "Legacy"
        Write-Log -Level "WARN" -Message "Using legacy password (first migration for this device)"
    } else {
        Write-Log -Level "ERROR" -Message "SMP is set but no password source available"
        Exit-Script -Code 1 -Message "Cannot resolve current password"
    }
}

if (-not $IsSMPSet) {
    Write-Log -Level "INFO" -Message "No SMP currently set -- will set fresh"
    $PasswordSource = "None (first set)"
}

try {
    $CurrentSetting = Get-WmiObject -Namespace root\wmi -Class Lenovo_BiosSetting |
        Where-Object { $_.CurrentSetting -like "BIOSPasswordAtBootDeviceList,*" } |
        Select-Object -ExpandProperty CurrentSetting -First 1
    if ($CurrentSetting -match "Enable") {
        Write-Log -Level "INFO" -Message "BIOSPasswordAtBootDeviceList already enabled -- skipping"
    } else {
        Write-Log -Level "INFO" -Message "Enabling BIOSPasswordAtBootDeviceList (current: $CurrentSetting)"
        if ($IsSMPSet) {
            Set-LenovoBiosSetting -Setting "BIOSPasswordAtBootDeviceList" -Value "Enable" -Password $OldPassword
        } else {
            $SetWMI = Get-WmiObject -Namespace root\wmi -Class Lenovo_SetBiosSetting
            $SetResult = $SetWMI.SetBiosSetting("BIOSPasswordAtBootDeviceList,Enable")
            if ($SetResult.Return -notmatch "Success") { throw "SetBiosSetting: $($SetResult.Return)" }
            $SaveWMI = Get-WmiObject -Namespace root\wmi -Class Lenovo_SaveBiosSettings
            $SaveResult = $SaveWMI.SaveBiosSettings()
            if ($SaveResult.Return -notmatch "Success") { throw "SaveBiosSettings: $($SaveResult.Return)" }
        }
        Write-Log -Level "SUCCESS" -Message "BIOSPasswordAtBootDeviceList enabled"
    }
} catch {
    Write-Log -Level "WARN" -Message "Could not configure BIOSPasswordAtBootDeviceList: $_"
}

$NewPassword = New-CryptoPassword -Length $PasswordLength -Charset $PasswordCharset
Write-Log -Level "INFO" -Message "Generated new $PasswordLength-char password"

try {
    Save-EncryptedFile -Password $NewPassword -FilePath $RecoveryFile
    Write-Log -Level "INFO" -Message "Recovery file written"
} catch {
    Write-Log -Level "ERROR" -Message "Cannot write recovery file: $_"
    Exit-Script -Code 1 -Message "Recovery file write failed"
}

try {
    Set-LenovoSMP -OldPassword $OldPassword -NewPassword $NewPassword -CurrentlySet $IsSMPSet
} catch {
    Write-Log -Level "ERROR" -Message "BIOS change failed: $_"
    Remove-FileSafe -FilePath $RecoveryFile
    Exit-Script -Code 1 -Message "BIOS change failed"
}

try {
    Save-EncryptedFile -Password $NewPassword -FilePath $CacheFile
    Write-Log -Level "SUCCESS" -Message "Local cache updated"
} catch {
    Write-Log -Level "WARN" -Message "Cache update failed: $_"
}

try {
    Write-KeyVaultSecret -SecretName $SecretName -Password $NewPassword `
        -SerialNumber $SerialNumber -Manufacturer $Manufacturer -AccessToken $AccessToken
} catch {
    Write-Log -Level "ERROR" -Message "Key Vault upload failed after BIOS change"
    Exit-Script -Code 2 -Message "BIOS rotated but KV upload failed"
}

Remove-FileSafe -FilePath $RecoveryFile
New-Item -Path $LastRunMarker -ItemType File -Force | Out-Null
Write-Log -Level "SUCCESS" -Message "Rotation complete for $SerialNumber"
Exit-Script -Code 0 -Message "BIOS password rotated and synced to Key Vault"
