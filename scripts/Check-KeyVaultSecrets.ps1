# Input CSV format:
#   DeviceName
#   BIOS-PC0K1234
#   BIOS-PC0K5678

# ============================================================================
# CONFIGURATION
# ============================================================================
$TenantID    = "<your-tenant-id>"
$AppID       = "<your-app-id>"
$AppSecret   = "<your-client-secret>"
$VaultName   = "<your-keyvault-name>"

# Input/output paths - change as needed
$InputCsv    = ".\devices.csv"
$OutputCsv   = ".\devices-result.csv"

# ============================================================================
# VALIDATE
# ============================================================================
if (-not (Test-Path $InputCsv)) {
    Write-Host "Input CSV not found: $InputCsv" -ForegroundColor Red
    exit 1
}

$Devices = Import-Csv -Path $InputCsv
if ($Devices.Count -eq 0) {
    Write-Host "No rows found in $InputCsv" -ForegroundColor Yellow
    exit 0
}
if (-not ($Devices[0].PSObject.Properties.Name -contains "DeviceName")) {
    Write-Host "CSV is missing 'DeviceName' column" -ForegroundColor Red
    exit 1
}

Write-Host "Loaded $($Devices.Count) device(s) from $InputCsv" -ForegroundColor Cyan

# ============================================================================
# GET TOKEN
# ============================================================================
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

try {
    $TokenResponse = Invoke-RestMethod -Method POST `
        -Uri "https://login.microsoftonline.com/$TenantID/oauth2/v2.0/token" `
        -Body @{
            client_id     = $AppID
            scope         = "https://vault.azure.net/.default"
            client_secret = $AppSecret
            grant_type    = "client_credentials"
        } -ErrorAction Stop -TimeoutSec 10 -UseBasicParsing
    $Token = $TokenResponse.access_token
    Write-Host "Got Key Vault token" -ForegroundColor Green
} catch {
    Write-Host "Failed to get token: $_" -ForegroundColor Red
    exit 1
}

$Headers = @{ Authorization = "Bearer $Token" }

# ============================================================================
# CHECK EACH DEVICE
# ============================================================================
$Results = @()
$ExistsCount = 0
$MissingCount = 0
$ErrorCount = 0

Write-Host ""
foreach ($Device in $Devices) {
    $Name = $Device.DeviceName.Trim()
    if ([string]::IsNullOrEmpty($Name)) { continue }

    $Uri = "https://" + $VaultName + ".vault.azure.net/secrets/" + $Name + "?api-version=7.4"
    $Status = ""
    $Detail = ""
    $LastRotated = ""

    try {
        $Response = Invoke-RestMethod -Method GET -Uri $Uri -Headers $Headers `
            -ErrorAction Stop -TimeoutSec 10 -UseBasicParsing
        $Status = "Exists"
        if ($Response.tags -and $Response.tags.LastRotated) {
            $LastRotated = $Response.tags.LastRotated
        }
        $Detail = "version $($Response.id -split '/' | Select-Object -Last 1)"
        $ExistsCount++
        Write-Host ("  [EXISTS]   {0,-30}  {1}" -f $Name, $LastRotated) -ForegroundColor Green
    } catch {
        $StatusCode = $null
        if ($_.Exception.Response) { $StatusCode = [int]$_.Exception.Response.StatusCode }

        if ($StatusCode -eq 404) {
            $Status = "NotFound"
            $Detail = "no secret with this name"
            $MissingCount++
            Write-Host ("  [MISSING]  {0,-30}" -f $Name) -ForegroundColor Yellow
        } else {
            $Status = "Error"
            $Detail = "HTTP $StatusCode - $($_.Exception.Message)"
            $ErrorCount++
            Write-Host ("  [ERROR]    {0,-30}  {1}" -f $Name, $Detail) -ForegroundColor Red
        }
    }

    $Results += [PSCustomObject]@{
        DeviceName  = $Name
        Status      = $Status
        LastRotated = $LastRotated
        Detail      = $Detail
    }
}

# ============================================================================
# SUMMARY
# ============================================================================
Write-Host ""
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host "  Summary" -ForegroundColor Cyan
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host ("  Total checked: {0}" -f ($ExistsCount + $MissingCount + $ErrorCount))
Write-Host ("  Exists:        {0}" -f $ExistsCount) -ForegroundColor Green
Write-Host ("  Missing:       {0}" -f $MissingCount) -ForegroundColor Yellow
Write-Host ("  Errors:        {0}" -f $ErrorCount)  -ForegroundColor Red
Write-Host ""

# ============================================================================
# WRITE OUTPUT
# ============================================================================
$Results | Export-Csv -Path $OutputCsv -NoTypeInformation -Force
Write-Host "Results written to: $OutputCsv" -ForegroundColor Cyan
