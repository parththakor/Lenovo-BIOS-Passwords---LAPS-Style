# ============================================================================
# CONFIGURATION
# ============================================================================

# Change to 90 to rotate every 90 days, 365 for yearly, etc.
$RotationIntervalDays = 180

$TenantID     = "<your-tenant-id>"
$AppID        = "<your-app-id>"
$AppSecret    = "<your-client-secret>"
$VaultName    = "<your-keyvault-name>"

# Must match SecretPrefix in the rotation script
$SecretPrefix = "BIOS-"

# ============================================================================
# PATHS
# ============================================================================
$LogDir       = "$env:SystemRoot\Debug"
$MarkerFile   = "$LogDir\BIOS_LastRun.marker"
$CacheFile    = "$LogDir\BIOS_Current.dat"
$RecoveryFile = "$LogDir\BIOS_Recovery.dat"

# ============================================================================
# HELPERS
# ============================================================================
function Test-KeyVaultSecretExists {
    param([string]$SecretName)

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $Token = $null
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
        $Token = $TokenResponse.access_token
    } catch {
        return "Unreachable"
    }

    $Uri = "https://" + $VaultName + ".vault.azure.net/secrets/" + $SecretName + "?api-version=7.4"
    $Headers = @{ Authorization = "Bearer $Token" }
    try {
        $null = Invoke-RestMethod -Method GET -Uri $Uri -Headers $Headers `
            -ErrorAction Stop -TimeoutSec 10 -UseBasicParsing
        return "Exists"
    } catch {
        $StatusCode = $null
        if ($_.Exception.Response) {
            $StatusCode = [int]$_.Exception.Response.StatusCode
        }
        switch ($StatusCode) {
            404 { return "NotFound" }
            403 { return "Unreachable" }
            401 { return "Unreachable" }
            default { return "Unreachable" }
        }
    }
}

# ============================================================================
# PREFLIGHT
# ============================================================================
try {
    $Manufacturer = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).Manufacturer
} catch {
    Write-Output "Cannot read manufacturer - skipping"
    exit 0
}

if ($Manufacturer -notlike "*Lenovo*") {
    Write-Output "Not a Lenovo device ($Manufacturer) - skipping"
    exit 0
}

try {
    $null = Get-CimInstance -Namespace root/wmi -ClassName Lenovo_BiosPasswordSettings -ErrorAction Stop
} catch {
    Write-Output "Lenovo BIOS WMI not available - skipping"
    exit 0
}

$Serial = $null
try { $Serial = (Get-CimInstance Win32_BIOS).SerialNumber.Trim() } catch {}
$SecretName = $SecretPrefix + ($Serial -replace '[^a-zA-Z0-9-]', '')

# ============================================================================
# CHECK 1: Pending recovery file (crash recovery)
# ============================================================================
if (Test-Path $RecoveryFile) {
    $RecoveryAge = ((Get-Date) - (Get-Item $RecoveryFile).LastWriteTime).TotalHours
    Write-Output "Recovery file present ($([math]::Round($RecoveryAge,1)) hours old) - previous run crashed mid-rotation, must drain"
    exit 1
}

# ============================================================================
# CHECK 2-4: State loss detection (reimage / wipe / corruption)
# ============================================================================
$MarkerMissing = -not (Test-Path $MarkerFile)
$CacheMissing  = -not (Test-Path $CacheFile)
$CacheCorrupt  = $false

if (-not $CacheMissing) {
    try {
        $Enc = Get-Content $CacheFile -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($Enc)) {
            $CacheCorrupt = $true
        } else {
            $null = $Enc | ConvertTo-SecureString -ErrorAction Stop
        }
    } catch {
        $CacheCorrupt = $true
    }
}

$StateLoss = $MarkerMissing -or $CacheMissing -or $CacheCorrupt

if ($StateLoss) {
    $Reasons = @()
    if ($MarkerMissing) { $Reasons += "no marker" }
    if ($CacheMissing)  { $Reasons += "no cache" }
    if ($CacheCorrupt)  { $Reasons += "cache corrupt" }
    $ReasonStr = $Reasons -join ", "

    $KVStatus = Test-KeyVaultSecretExists -SecretName $SecretName

    switch ($KVStatus) {
        "Exists" {
            Write-Output "State loss ($ReasonStr) but Key Vault has $SecretName - rotation will restore from KV"
            exit 1
        }
        "NotFound" {
            Write-Output "State loss ($ReasonStr) and Key Vault has no record for $SecretName - first-run rotation required"
            exit 1
        }
        "Unreachable" {
            Write-Output "State loss ($ReasonStr) BUT Key Vault unreachable - holding rotation until KV reachable"
            exit 0
        }
    }
}

# ============================================================================
# CHECK 5: Rotation age
# ============================================================================
$LastRun = (Get-Item $MarkerFile).LastWriteTime
$DaysSince = ((Get-Date) - $LastRun).TotalDays

if ($DaysSince -ge $RotationIntervalDays) {
    Write-Output "Last rotation was $([math]::Round($DaysSince,1)) days ago (threshold: $RotationIntervalDays) - rotation due"
    exit 1
}

# ============================================================================
# CHECK 6: BIOS state vs cache consistency
# ============================================================================
$BiosState = (Get-CimInstance -Namespace root/wmi -ClassName Lenovo_BiosPasswordSettings).PasswordState
$BiosHasPassword = $BiosState -ne 0

if (-not $BiosHasPassword) {
    Write-Output "BIOS has no password set but cache exists - rotation required to reconcile"
    exit 1
}

# ============================================================================
# COMPLIANT
# ============================================================================
$DaysRemaining = [math]::Round($RotationIntervalDays - $DaysSince, 1)
Write-Output "Compliant: Serial=$Serial, LastRotation=$($LastRun.ToString('yyyy-MM-dd')), DaysAgo=$([math]::Round($DaysSince,1)), NextRotation=~${DaysRemaining}d, BiosState=$BiosState"
exit 0
