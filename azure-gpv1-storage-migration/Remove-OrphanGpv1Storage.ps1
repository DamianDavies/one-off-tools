<#
.SYNOPSIS
    Decommission the two idle, orphaned GPv1 storage accounts that are NOT worth
    migrating to GPv2.

.DESCRIPTION
    These two accounts showed zero transactions over the last 30 days and are
    not bound to any Function App:
      - higctautofunctionapp01  (leftover; CT automation now uses higctautomationa68e)
      - dyn864c5ff1e0bc49f9     (orphaned Dynamics deployment artifact store)

    Deleting is cheaper and cleaner than migrating dead accounts. This script is
    kept SEPARATE from the migration so the destructive action is reviewed alone.

    SAFETY GATES (run every time, before any delete) - ALL fail CLOSED:
      1. 90-day transaction activity must be zero. A FAILED metrics query aborts
         the account (we never treat "query failed" as "no activity").
      2. The account name must not appear in any Function App OR Web App setting
         (app settings + connection strings). A failed index build aborts the
         whole run rather than risk a false "no references".
      3. The account must be EMPTY - no blob containers, queues, tables, or file
         shares. If contents cannot be verified (e.g. shared-key listing is
         disabled), the account is blocked unless -Force is given.
    Only accounts passing ALL gates are eligible, and only deleted with -Apply.

    KEY DESIGN POINT: this environment runs PowerShell with
    $PSNativeCommandUseErrorActionPreference = $false, so a non-zero `az` exit
    does NOT throw - it just sets $LASTEXITCODE. Every gate query therefore
    checks $LASTEXITCODE explicitly (via Invoke-Az) and fails closed. Do not
    re-introduce `2>$null` on a gate query: it would hide the failure and let an
    empty result read as "safe".

    NOT covered by the automated reference scan (check manually in the portal if
    in doubt): diagnostic settings, Logic Apps, Data Factory linked services,
    Event Grid, and VM boot diagnostics. The emptiness gate (#3) is the backstop
    - deleting a genuinely empty account loses no data even if such a reference
    exists.

    Dry-run by default. Deletion is permanent (subject to any soft-delete /
    resource-lock policy on the subscription).

.PARAMETER Apply
    Actually delete eligible accounts. Without it, the script only reports.

.PARAMETER Force
    Override the emptiness gate (#3) ONLY - e.g. you have manually confirmed the
    container contents are disposable. Does NOT override the activity or
    reference gates.

.NOTES
    Requires: az CLI, logged in (az login) to the Higgins tenant, with rights to
    list account keys (Microsoft.Storage/storageAccounts/listkeys/action) for
    the emptiness check.
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$SubId = '144944e1-e86f-4097-828c-c1eda1d015c6'

# Run an az command, fail CLOSED on a non-zero exit (this shell does not throw
# on native errors automatically). Returns stdout; stderr passes through to host.
function Invoke-Az {
    param(
        [Parameter(Mandatory)][string[]]$AzArgs,
        [Parameter(Mandatory)][string]$What
    )
    $out = az @AzArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI call failed during '$What' (exit $LASTEXITCODE)."
    }
    return $out
}

$Orphans = @(
    [pscustomobject]@{ name='higctautofunctionapp01'; rg='higctautomation01-prod-rg' }
    [pscustomobject]@{ name='dyn864c5ff1e0bc49f9';    rg='DynamicsDeployments-australiasoutheast' }
)

Write-Host "Subscription: $SubId" -ForegroundColor Cyan
Invoke-Az @('account','set','--subscription',$SubId) 'set subscription' | Out-Null
if (-not $Apply) {
    Write-Host "DRY-RUN: safety report only, nothing will be deleted.`n" -ForegroundColor Yellow
} else {
    Write-Host "APPLY MODE: eligible accounts WILL be deleted.`n" -ForegroundColor Magenta
}

# --- GATE 2 index: every Function App AND Web App setting + connection string ---
# Built once. Any failure here aborts the whole run (fail closed) - an
# incomplete index could miss a real reference and green-light a bad delete.
Write-Host "Indexing Function App + Web App settings for references..." -ForegroundColor Cyan
$settingsBlob = New-Object System.Text.StringBuilder
# functionapp exposes only 'config appsettings' (the storage binding lives there);
# webapp also exposes 'config connection-string', where a storage conn string may sit.
$appTypes = @(
    [pscustomobject]@{ type='functionapp'; conn=$false }
    [pscustomobject]@{ type='webapp';      conn=$true  }
)
foreach ($at in $appTypes) {
    $apps = Invoke-Az @($at.type,'list','--query','[].{name:name, rg:resourceGroup}','-o','json') "list $($at.type)" | ConvertFrom-Json
    foreach ($a in $apps) {
        $vals = Invoke-Az @($at.type,'config','appsettings','list','-n',$a.name,'-g',$a.rg,'--query','[].value','-o','tsv') "read $($at.type) '$($a.name)' appsettings"
        if ($vals) { [void]$settingsBlob.AppendLine(($vals -join "`n")) }
        if ($at.conn) {
            $conn = Invoke-Az @($at.type,'config','connection-string','list','-n',$a.name,'-g',$a.rg,'--query','[].value.value','-o','tsv') "read $($at.type) '$($a.name)' connection-strings"
            if ($conn) { [void]$settingsBlob.AppendLine(($conn -join "`n")) }
        }
    }
    Write-Host "  indexed $($apps.Count) $($at.type)(s)."
}
$allSettings = $settingsBlob.ToString()
Write-Host ""

# Snapshot of existing storage account names (no parens in the query, so
# PowerShell/az.cmd argument quoting is not an issue). Used for existence and
# post-delete confirmation via -contains rather than a jmespath length(@).
$existingNames = @(Invoke-Az @('storage','account','list','--query','[].name','-o','tsv') 'list storage account names')

# Count blob containers / queues / tables / file shares. Returns -1 if contents
# cannot be verified (so the caller blocks rather than assumes empty).
function Get-AccountObjectCount {
    param([string]$Name, [string]$Rg)
    try {
        $key = (Invoke-Az @('storage','account','keys','list','-n',$Name,'-g',$Rg,'--query','[0].value','-o','tsv') "list keys for $Name").Trim()
    } catch {
        Write-Host "    cannot list keys ($($_.Exception.Message)) - contents unverifiable." -ForegroundColor Red
        return -1
    }

    # Pass account+key via environment, NOT command-line args: on Windows az is a
    # .cmd batch wrapper and a base64 key (containing / + =) breaks cmd parsing.
    $prev = @{
        acct = $env:AZURE_STORAGE_ACCOUNT
        key  = $env:AZURE_STORAGE_KEY
        mode = $env:AZURE_STORAGE_AUTH_MODE
    }
    $env:AZURE_STORAGE_ACCOUNT   = $Name
    $env:AZURE_STORAGE_KEY       = $key
    $env:AZURE_STORAGE_AUTH_MODE = 'key'
    try {
        $total = 0
        foreach ($svc in @(
            @{ args=@('storage','container','list'); label='containers' }
            @{ args=@('storage','queue','list');     label='queues' }
            @{ args=@('storage','table','list');     label='tables' }
            @{ args=@('storage','share','list');     label='shares' }
        )) {
            try {
                # Return JSON and count in PowerShell. Do NOT use a jmespath
                # length(@): the bare token has no spaces, so PowerShell passes
                # it unquoted to az.cmd and cmd.exe breaks on the parentheses.
                $out = Invoke-Az (@($svc.args) + @('-o','json')) "list $($svc.label) on $Name"
                $n = @(($out -join "`n") | ConvertFrom-Json).Count
                if ($n -gt 0) { Write-Host "    $($svc.label): $n" -ForegroundColor Yellow }
                $total += $n
            } catch {
                Write-Host "    cannot list $($svc.label) ($($_.Exception.Message)) - contents unverifiable." -ForegroundColor Red
                return -1
            }
        }
        return $total
    } finally {
        $env:AZURE_STORAGE_ACCOUNT   = $prev.acct
        $env:AZURE_STORAGE_KEY       = $prev.key
        $env:AZURE_STORAGE_AUTH_MODE = $prev.mode
    }
}

foreach ($o in $Orphans) {
    Write-Host "==== $($o.name)  (rg: $($o.rg)) ====" -ForegroundColor White

    # Confirm it still exists (membership test against the snapshot above).
    if ($existingNames -notcontains $o.name) {
        Write-Host "  not found (already deleted?) - skipping." -ForegroundColor Green
        continue
    }
    $kind = Invoke-Az @('storage','account','show','-n',$o.name,'-g',$o.rg,'--query','kind','-o','tsv') "show kind of $($o.name)"
    Write-Host "  kind: $kind"

    # GATE 1: activity over the 90 days ENDING AT MIDNIGHT UTC TODAY (fail closed
    # - a failed query throws and aborts). We deliberately exclude the current day
    # so this script's own data-plane probing (GATE 3 lists containers/queues =
    # Transactions) and the operator's same-day az calls cannot self-trip the gate.
    # Fetch raw datapoints and count in PowerShell: an idle account returns an
    # empty timeseries -> 'null' (exit 0, genuinely zero); a real query failure is
    # non-zero and Invoke-Az throws. Do NOT use jmespath length() - length(null) errors.
    $endUtc   = (Get-Date).ToUniversalTime().Date          # today 00:00 UTC
    $startUtc = $endUtc.AddDays(-90)
    $fmt = 'yyyy-MM-ddTHH:mm:ssZ'
    $dataJson = Invoke-Az @('monitor','metrics','list','--resource',$o.name,'-g',$o.rg,
        '--resource-type','Microsoft.Storage/storageAccounts',
        '--metric','Transactions','--aggregation','Total',
        '--start-time',$startUtc.ToString($fmt),'--end-time',$endUtc.ToString($fmt),'--interval','1d',
        '--query','value[0].timeseries[0].data','-o','json') "metrics for $($o.name)"
    $data = $dataJson | ConvertFrom-Json
    $activeDays = @($data | Where-Object { $_.total -gt 0 }).Count
    Write-Host "  90-day active days (excl. today): $activeDays"
    if ($activeDays -gt 0) {
        Write-Host "  BLOCKED: shows recent activity - do NOT delete. Migrate instead." -ForegroundColor Red
        continue
    }

    # GATE 2: referenced by any Function App / Web App?
    if ($allSettings -match [regex]::Escape($o.name)) {
        Write-Host "  BLOCKED: referenced in an app's settings/connection strings - do NOT delete." -ForegroundColor Red
        continue
    }

    # GATE 3: account must be empty (or -Force to override).
    Write-Host "  checking contents..."
    $count = Get-AccountObjectCount -Name $o.name -Rg $o.rg
    if ($count -lt 0) {
        if ($Force) {
            Write-Host "  -Force: proceeding despite UNVERIFIABLE contents." -ForegroundColor Magenta
        } else {
            Write-Host "  BLOCKED: contents could not be verified - rerun with -Force only after manual check." -ForegroundColor Red
            continue
        }
    } elseif ($count -gt 0) {
        if ($Force) {
            Write-Host "  -Force: proceeding despite $count object(s) present." -ForegroundColor Magenta
        } else {
            Write-Host "  BLOCKED: account holds $count object(s) - not empty. Use -Force only if disposable." -ForegroundColor Red
            continue
        }
    } else {
        Write-Host "  empty (0 containers/queues/tables/shares)." -ForegroundColor Green
    }

    Write-Host "  passed all gates." -ForegroundColor Green

    if (-not $Apply) {
        Write-Host "  WOULD DELETE: az storage account delete -n $($o.name) -g $($o.rg) --yes" -ForegroundColor Yellow
        continue
    }

    Write-Host "  deleting..." -ForegroundColor Magenta
    Invoke-Az @('storage','account','delete','-n',$o.name,'-g',$o.rg,'--yes') "delete $($o.name)" | Out-Null
    $after = @(Invoke-Az @('storage','account','list','--query','[].name','-o','tsv') "confirm deletion of $($o.name)")
    if ($after -notcontains $o.name) { Write-Host "  OK: deleted." -ForegroundColor Green }
    else { Write-Host "  WARNING: still present (resource lock?) - check portal." -ForegroundColor Red }
    Write-Host ""
}

Write-Host "Done." -ForegroundColor Cyan
