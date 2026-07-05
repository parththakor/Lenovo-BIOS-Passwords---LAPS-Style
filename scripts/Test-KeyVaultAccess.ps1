# ============================================================================
# CONFIGURATION
# ============================================================================
$TenantID    = "<your-tenant-id>"
$AppID       = "<your-app-id>"
$AppSecret   = "<your-client-secret>"
$VaultName   = "<your-keyvault-name>"

# ============================================================================
# HELPERS
# ============================================================================
function Write-Result {
    param(
        [string]$Label,
        [string]$Status,
        [string]$Detail = ""
    )
    $Color = switch ($Status) {
        "PASS"  { "Green" }
        "FAIL"  { "Red" }
        "WARN"  { "Yellow" }
        default { "White" }
    }
    Write-Host ("  [{0}] {1}" -f $Status, $Label) -ForegroundColor $Color
    if ($Detail) { Write-Host "         $Detail" -ForegroundColor Gray }
}

function Get-StatusCodeFromException {
    param($Exception)
    if ($Exception.Exception -and $Exception.Exception.Response) {
        return [int]$Exception.Exception.Response.StatusCode
    }
    return $null
}

function Get-ResponseBodyFromException {
    param($Exception)
    try {
        $Stream = $Exception.Exception.Response.GetResponseStream()
        $Stream.Position = 0
        $Reader = New-Object System.IO.StreamReader($Stream)
        $Body = $Reader.ReadToEnd()
        $Reader.Close()
        return $Body
    } catch {
        return $null
    }
}

# ============================================================================
# HEADER
# ============================================================================
Write-Host ""
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host "  Key Vault Access Test (authenticated)" -ForegroundColor Cyan
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# CONTEXT
# ============================================================================
Write-Host "Context:" -ForegroundColor White
Write-Host "  Hostname      : $env:COMPUTERNAME" -ForegroundColor Gray

# Public IP
$PublicIP = $null
try {
    $PublicIP = (Invoke-RestMethod -Uri "https://api.ipify.org?format=json" -TimeoutSec 5 -UseBasicParsing).ip
} catch {
    try { $PublicIP = (Invoke-RestMethod -Uri "https://ifconfig.me/ip" -TimeoutSec 5 -UseBasicParsing).Trim() } catch {}
}
if ($PublicIP) {
    Write-Host "  Public IP     : $PublicIP" -ForegroundColor Gray
} else {
    Write-Host "  Public IP     : (could not determine)" -ForegroundColor Yellow
}

$Adapter = Get-NetIPConfiguration -ErrorAction SilentlyContinue |
    Where-Object { $_.NetAdapter.Status -eq "Up" -and $_.IPv4Address } |
    Select-Object -First 1
if ($Adapter) {
    Write-Host "  Interface     : $($Adapter.InterfaceAlias)" -ForegroundColor Gray
    Write-Host "  Local IP      : $($Adapter.IPv4Address.IPAddress)" -ForegroundColor Gray
}
Write-Host "  Vault         : $VaultName.vault.azure.net" -ForegroundColor Gray
Write-Host ""

# ============================================================================
# CONFIG CHECK
# ============================================================================
$ConfigOk = $true
foreach ($Var in @('VaultName','TenantID','AppID','AppSecret')) {
    $Value = (Get-Variable -Name $Var -ValueOnly)
    if ($Value -match '^<' -or [string]::IsNullOrWhiteSpace($Value)) {
        Write-Host "  [!] $Var is not set - fill it in at the top of the script" -ForegroundColor Red
        $ConfigOk = $false
    }
}
if (-not $ConfigOk) {
    Write-Host ""
    exit 1
}

# ============================================================================
# TEST 1: DNS Resolution
# ============================================================================
Write-Host "Test 1: DNS Resolution" -ForegroundColor White
$DnsOk = $false
try {
    $Resolved = Resolve-DnsName -Name "$VaultName.vault.azure.net" -Type A -ErrorAction Stop
    $IPs = ($Resolved | Where-Object { $_.IPAddress }).IPAddress -join ", "
    Write-Result -Label "FQDN resolves" -Status "PASS" -Detail "Resolved to: $IPs"
    $DnsOk = $true
} catch {
    Write-Result -Label "FQDN resolves" -Status "FAIL" -Detail $_.Exception.Message
}
Write-Host ""

# ============================================================================
# TEST 2: Token Acquisition
# ============================================================================
Write-Host "Test 2: Token Acquisition (Entra ID)" -ForegroundColor White
$AccessToken = $null
try {
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
    $AccessToken = $TokenResponse.access_token
    $TokenPreview = $AccessToken.Substring(0, 20) + "..."
    Write-Result -Label "Got bearer token" -Status "PASS" -Detail "Token: $TokenPreview"
} catch {
    $StatusCode = Get-StatusCodeFromException $_
    $Body = Get-ResponseBodyFromException $_
    if ($Body) {
        try {
            $ErrJson = $Body | ConvertFrom-Json
            Write-Result -Label "Got bearer token" -Status "FAIL" -Detail "$($ErrJson.error): $($ErrJson.error_description)"
        } catch {
            Write-Result -Label "Got bearer token" -Status "FAIL" -Detail "HTTP $StatusCode - $($_.Exception.Message)"
        }
    } else {
        Write-Result -Label "Got bearer token" -Status "FAIL" -Detail $_.Exception.Message
    }
}
Write-Host ""

# ============================================================================
# TEST 3: Authenticated Probe (the only reliable test)
# ============================================================================
Write-Host "Test 3: Authenticated KV Probe (the real test)" -ForegroundColor White

if (-not $AccessToken) {
    Write-Result -Label "List secrets" -Status "WARN" -Detail "Skipped (no token)"
    Write-Host ""
} else {
    $KVReachable = $false
    $FirewallBlocked = $false
    $ProbeError = ""
    $SecretCount = 0

    try {
        $Headers = @{ Authorization = "Bearer $AccessToken" }
        $SecretsList = Invoke-RestMethod -Method GET `
            -Uri "https://$VaultName.vault.azure.net/secrets?api-version=7.4&maxresults=25" `
            -Headers $Headers -ErrorAction Stop -TimeoutSec 10 -UseBasicParsing
        if ($SecretsList.value) { $SecretCount = $SecretsList.value.Count }
        $KVReachable = $true
        Write-Result -Label "List secrets" -Status "PASS" -Detail "Retrieved $SecretCount secret(s)"
    } catch {
        $StatusCode = Get-StatusCodeFromException $_
        $Body = Get-ResponseBodyFromException $_
        $ErrorSummary = ""
        if ($Body) {
            try {
                $ErrJson = $Body | ConvertFrom-Json
                $ErrorSummary = "$($ErrJson.error.code): $($ErrJson.error.message)"
            } catch {
                $ErrorSummary = ($Body -replace '\s+', ' ')
                if ($ErrorSummary.Length -gt 200) { $ErrorSummary = $ErrorSummary.Substring(0,200) + "..." }
            }
        }

        switch ($StatusCode) {
            403 {
                $FirewallBlocked = $true
                Write-Result -Label "List secrets" -Status "FAIL" -Detail "403 Forbidden - firewall blocked OR missing RBAC role"
                if ($ErrorSummary) { Write-Host "         $ErrorSummary" -ForegroundColor DarkGray }
                $ProbeError = $ErrorSummary
            }
            401 {
                Write-Result -Label "List secrets" -Status "FAIL" -Detail "401 Unauthorized - token rejected"
                if ($ErrorSummary) { Write-Host "         $ErrorSummary" -ForegroundColor DarkGray }
            }
            default {
                Write-Result -Label "List secrets" -Status "FAIL" -Detail "HTTP $StatusCode - $($_.Exception.Message)"
                if ($ErrorSummary) { Write-Host "         $ErrorSummary" -ForegroundColor DarkGray }
            }
        }
    }
    Write-Host ""
}

# ============================================================================
# VERDICT
# ============================================================================
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host "  Verdict" -ForegroundColor Cyan
Write-Host "=======================================================" -ForegroundColor Cyan

if (-not $DnsOk) {
    Write-Host "  DNS resolution failed - check basic internet connectivity" -ForegroundColor Red
} elseif (-not $AccessToken) {
    Write-Host "  Could not get bearer token - check app registration credentials" -ForegroundColor Red
    Write-Host "  (Entra ID login endpoint is NOT subject to your KV firewall)" -ForegroundColor Gray
} elseif ($KVReachable) {
    Write-Host "  [OK] Key Vault is REACHABLE from this network" -ForegroundColor Green
    if ($PublicIP) {
        Write-Host "  Public IP $PublicIP is ALLOWED by the firewall" -ForegroundColor Green
    }
    Write-Host "  Secrets accessible: $SecretCount" -ForegroundColor Green
} elseif ($FirewallBlocked) {
    Write-Host "  [X] Key Vault is BLOCKED from this network" -ForegroundColor Red
    if ($PublicIP) {
        Write-Host "  Public IP $PublicIP is NOT in the firewall allowlist" -ForegroundColor Red
    }
    Write-Host "  (Or the app registration lacks a Key Vault role assignment)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  To add this IP to the allowlist:" -ForegroundColor Gray
    Write-Host "    Portal > Key Vault > Networking > Firewalls > Add IP" -ForegroundColor Gray
} else {
    Write-Host "  [X] Key Vault is UNREACHABLE" -ForegroundColor Red
    Write-Host "  Check logs above for the specific error" -ForegroundColor Gray
}
Write-Host ""

