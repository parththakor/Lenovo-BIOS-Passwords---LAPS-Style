# Azure Setup Guide

Complete walkthrough for setting up the Azure side of this project. About 15 minutes end to end.

You need:
- Access to an Azure subscription
- Global Administrator or Application Administrator role in Entra ID (to create the App Registration)
- Owner or Contributor role on a resource group (to create the Key Vault)

---

## Overview

You will create three things:

1. **App Registration** - the identity the scripts use to authenticate to Key Vault
2. **Key Vault** - where per-device BIOS passwords are stored
3. **RBAC role assignment** - grants the App Registration permission to read/write secrets

That's it. No Azure Functions, no Automation Accounts, no other services required.

---

## Step 1: Create the App Registration

### 1.1 Create the app

1. Go to **portal.azure.com**
2. Search for and open **Microsoft Entra ID**
3. Left menu > **App registrations** > **+ New registration**
4. Fill in:
   - **Name:** `BIOS-Password-Manager` (or anything descriptive)
   - **Supported account types:** *Accounts in this organizational directory only (Single tenant)*
   - **Redirect URI:** leave blank
5. Click **Register**

### 1.2 Note down IDs

On the app's Overview page, copy these two values - you'll need them:

| Field | Where to paste it in the scripts |
|---|---|
| Application (client) ID | `$AppID` |
| Directory (tenant) ID | `$TenantID` |

### 1.3 Create a client secret

1. Left menu > **Certificates & secrets**
2. Under **Client secrets** > **+ New client secret**
3. Description: `BIOS Password Manager - <date>`
4. Expires: pick your window (6 months recommended for POC, 12-24 months for prod)
5. Click **Add**
6. **Copy the "Value" column immediately** - it disappears after you leave the page
7. This is your `$AppSecret`

> The "Secret ID" column is not what you want. Copy the "Value" column.

### 1.4 API permissions

**Leave the default `User.Read` permission alone. Do NOT add any Key Vault permissions here.**

Key Vault access is controlled by Azure RBAC on the vault itself, not by App Registration API permissions. You'll grant that in Step 3.

---

## Step 2: Create the Key Vault

### 2.1 Create the vault

1. Search for **Key vaults** in the portal
2. Click **+ Create**
3. Fill in:
   - **Subscription:** pick yours
   - **Resource group:** pick or create one (e.g. `rg-bios-password-manager`)
   - **Key vault name:** something unique, e.g. `kv-biospw-prod-abc` (this becomes your `$VaultName`; do not include `.vault.azure.net`)
   - **Region:** pick your closest region
   - **Pricing tier:** **Standard**
4. Click **Next: Access configuration**
5. **Permission model:** select **Azure role-based access control** (RBAC)
6. Leave **Access policies** empty (we use RBAC)
7. Click **Next: Networking**

### 2.2 Configure networking (IP firewall)

This is important - it restricts vault access to your corporate networks only.

- **Public network access:** **Allow public access from specific virtual networks and IP addresses**
- **Firewall:**
  - Add your corporate public IP ranges (office egress IPs, VPN egress IPs)
  - You can add CIDR ranges like `203.0.113.0/24` or single IPs like `203.0.113.5`
  - **Also add your own current IP** (there's a "Add my IP address" checkbox) so you can access the vault yourself
- **Allow trusted Microsoft services:** check this box

### 2.3 Enable soft-delete and purge protection

Under **Recovery options**:
- **Soft-delete:** Enabled (default)
- **Purge protection:** **Enabled** (prevents accidental permanent deletion)
- Retention: 90 days (default is fine)

### 2.4 Create

Skip through the remaining tabs (or add tags if you want), then **Review + create** > **Create**.

Once created, on the vault's **Overview** page:
- The **Vault name** is your `$VaultName`
- The **Vault URI** is `https://<name>.vault.azure.net` (you don't put this in the scripts, just the name)

---

## Step 3: Grant the App Registration Access

This is where a lot of people get stuck. You do this on the **Key Vault**, not on the App Registration.

1. Open your Key Vault
2. Left menu > **Access control (IAM)**
3. Click **+ Add** > **Add role assignment**
4. **Role** tab: search for **Key Vault Secrets Officer**
   - This role lets the app read, write, and delete secrets
   - Do NOT use "Key Vault Secrets User" - that's read-only, insufficient
5. Click **Next**
6. **Members** tab:
   - **Assign access to:** *User, group, or service principal*
   - Click **+ Select members**
   - Search for the name of your App Registration (`BIOS-Password-Manager`)
   - Click on it, then click **Select**
7. Click **Review + assign** > **Review + assign**

### Also grant yourself access (so you can look up passwords)

Repeat the same steps but this time assign to yourself (or an admin group):

- Role: **Key Vault Secrets Officer** (or **Key Vault Administrator** for full control)
- Member: your account

---

## Step 4: Verify Everything Works

Copy `scripts/Test-KeyVaultAccess.ps1` to a machine on your corporate network. Fill in the config block at the top:

```powershell
$TenantID    = "<paste from Step 1.2>"
$AppID       = "<paste from Step 1.2>"
$AppSecret   = "<paste from Step 1.3 - the Value field>"
$VaultName   = "<paste from Step 2.4 - the vault name only, no domain>"
```

Run it. You should see:

```
Test 1: DNS Resolution
  [PASS] FQDN resolves

Test 2: Token Acquisition (Entra ID)
  [PASS] Got bearer token

Test 3: Authenticated KV Probe (the real test)
  [PASS] List secrets   Retrieved 0 secret(s)

  [OK] Key Vault is REACHABLE from this network
```

If it says the token was acquired but the KV probe returned **403**, one of these is wrong:
- Your public IP is not in the firewall allowlist (Step 2.2)
- The App Registration was not granted the Secrets Officer role on the vault (Step 3)

If token acquisition itself fails with a 400/401, then:
- Wrong TenantID, AppID, or AppSecret
- The client secret has expired
- You copied the Secret ID column instead of the Value column (very common)

---

## Step 5: Configure the Production Scripts

Now that you know the four values, put them into the top of each of these scripts:

- `scripts/Set-LenovoBIOSPassword.ps1`
- `scripts/Detect-BIOSRotationDue.ps1`
- `scripts/Rollback-BIOSToSharedPassword.ps1` (only if you'll use rollback)
- `scripts/Remove-BIOSPassword.ps1` (only if you'll use DaaS returns)

Same four values in all of them:

```powershell
$TenantID    = "..."
$AppID       = "..."
$AppSecret   = "..."
$VaultName   = "..."
$SecretPrefix = "BIOS-"    # keep this consistent across all scripts
```

For the rotation script also set:

```powershell
$LegacyPassword = "..."    # if your fleet has a shared BIOS password today
```

For the rollback script also set:

```powershell
$SharedPassword = "..."    # the target password to revert to
```

---

## Ongoing Maintenance

### Rotate the client secret every 6-12 months

Before the client secret expires:

1. Entra ID > App registrations > your app > **Certificates & secrets**
2. **+ New client secret** with a fresh expiry
3. Copy the new Value
4. Update `$AppSecret` in all four scripts
5. Redeploy via Intune
6. After confirming new secret works, delete the old client secret from Entra ID

If you forget and the secret expires, all rotations will fail with `token acquisition failed`. Nothing gets damaged - you just fix the secret and rotations resume.

### Review firewall IPs quarterly

If your office IPs or VPN egress ranges change, update the Key Vault firewall.

### Monitor Key Vault access logs

Optionally enable **Diagnostic settings** on the vault to send `AuditEvent` logs to a Log Analytics workspace. Then you can query who accessed which secrets when.

Example KQL:

```kql
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.KEYVAULT"
| where OperationName == "SecretGet"
| project TimeGenerated, identity_claim_upn_s, identity_claim_appid_g, id_s, CallerIPAddress
| order by TimeGenerated desc
```

---

## Cost Estimate

For a fleet of 2000+ devices with 180-day rotation:

| Item | Monthly cost |
|---|---|
| Key Vault base fee | $0 (Pay-as-you-go) |
| Secret operations | < $0.05 |
| Secret storage + versions | $0 (free) |
| **Total** | **< $1/year** |

Cheaper than a coffee.

---

## Troubleshooting

### Test-KeyVaultAccess returns 401 on token acquisition

- Wrong `$AppSecret`, or expired secret. Verify you copied the "Value" not the "Secret ID".
- Wrong `$AppID` or `$TenantID`.

### Test-KeyVaultAccess returns 403 on KV probe

- Public IP not in vault firewall allowlist.
- OR App Registration has no RBAC role on the vault.

Check both.

### Devices can't reach the vault but they can reach login.microsoftonline.com

That means Entra ID works from their network, but the Key Vault firewall is blocking them. Either add their egress IP to the vault firewall, or accept that the rotation script will hold until they're on the corporate network (which is the intended behavior).

### Getting "vault not found" or "subscription not found" errors

The App Registration may have access to multiple subscriptions and picking the wrong one. Either:
- Restrict the App Registration to a single subscription (recommended)
- Or add `$SubscriptionID` explicitly (not currently supported by the scripts; open an issue if you need this)

---

## Next Steps

Read the [Operations Guide](Operations-Guide.md) for day-to-day operational scenarios (looking up passwords, handling wipes, rollbacks, DaaS returns).
