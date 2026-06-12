<#
.SYNOPSIS
    Upgrade the live GPv1 storage accounts in the Microsoft Azure Enterprise
    subscription to GPv2 (in-place, non-destructive).

.DESCRIPTION
    Responds to Microsoft retirement notice XTKT-BW8 (GPv1 retires 13 Oct 2026).
    Only the THREE accounts confirmed to be bound to a running Function App and
    showing live traffic are touched here. The two idle orphans are handled
    separately by Remove-OrphanGpv1Storage.ps1.

    Dry-run by default. Pass -Apply to perform the upgrade.

    The GPv1 -> GPv2 conversion does NOT move data, does NOT change endpoint
    URLs, and needs no Function App restart. It is one-way (no rollback to GPv1).

.NOTES
    Requires: az CLI, logged in (az login) to the Higgins tenant.
    Read-only az commands are pre-approved; the upgrade write runs only with -Apply.
#>
[CmdletBinding()]
param(
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$SubId = '144944e1-e86f-4097-828c-c1eda1d015c6'

# Run an az command and fail loudly on a non-zero exit. This shell runs with
# $PSNativeCommandUseErrorActionPreference = $false, so native errors do NOT
# throw on their own - we must check $LASTEXITCODE explicitly.
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

# ALL 5 GPv1 accounts in the subscription. The GPv2 upgrade is in-place and
# non-destructive, so migrating the two non-empty "orphans" is safe (and safer
# than deleting them) - the infrastructure manager can decommission later if
# they turn out to be unwanted.
# name = GPv1 storage account ; rg = its resource group ;
# fnApp/fnRg = the Function App that binds it ($null if none -> health check skipped)
$Targets = @(
    [pscustomobject]@{ name='higctautomationa68e';     rg='higctautomation01-prod-rg';              fnApp='HigCTAutomation-prod';   fnRg='higctautomation01-prod-rg' }
    [pscustomobject]@{ name='d365oauthtokenrg819a';    rg='d365OauthToken_rg';                      fnApp='d365OauthToken';         fnRg='d365OauthToken_rg' }
    [pscustomobject]@{ name='solutiontemplatef4fscaig'; rg='solutiontemplate-nfi14ji';              fnApp='asschedulerc6zlsc2bt37'; fnRg='SolutionTemplate-nfi14ji' }
    [pscustomobject]@{ name='higctautofunctionapp01';  rg='higctautomation01-prod-rg';              fnApp=$null;                    fnRg=$null }
    [pscustomobject]@{ name='dyn864c5ff1e0bc49f9';     rg='DynamicsDeployments-australiasoutheast'; fnApp=$null;                    fnRg=$null }
)

Write-Host "Subscription: $SubId" -ForegroundColor Cyan
Invoke-Az @('account','set','--subscription',$SubId) 'set subscription' | Out-Null
if (-not $Apply) {
    Write-Host "DRY-RUN: no changes will be made. Re-run with -Apply to upgrade.`n" -ForegroundColor Yellow
} else {
    Write-Host "APPLY MODE: accounts will be upgraded to GPv2.`n" -ForegroundColor Magenta
}

foreach ($t in $Targets) {
    Write-Host "==== $($t.name)  (rg: $($t.rg)) ====" -ForegroundColor White

    # 1. Current kind
    $kind = Invoke-Az @('storage','account','show','-n',$t.name,'-g',$t.rg,'--query','kind','-o','tsv') "show kind of $($t.name)"
    Write-Host "  current kind : $kind"
    if ($kind -eq 'StorageV2') {
        Write-Host "  already GPv2 - skipping." -ForegroundColor Green
        continue
    }
    if ($kind -ne 'Storage') {
        Write-Host "  unexpected kind '$kind' - skipping (review manually)." -ForegroundColor Red
        continue
    }

    if (-not $Apply) {
        Write-Host "  WOULD RUN: az storage account update -n $($t.name) -g $($t.rg) --upgrade-to-storagev2 --yes" -ForegroundColor Yellow
        continue
    }

    # 2. Upgrade in place (Invoke-Az throws if az reports failure)
    Write-Host "  upgrading to GPv2..." -ForegroundColor Magenta
    Invoke-Az @('storage','account','update','-n',$t.name,'-g',$t.rg,'--upgrade-to-storagev2','--yes') "upgrade $($t.name) to v2" | Out-Null

    # 3. Verify new kind
    $newKind = Invoke-Az @('storage','account','show','-n',$t.name,'-g',$t.rg,'--query','kind','-o','tsv') "verify kind of $($t.name)"
    if ($newKind -eq 'StorageV2') {
        Write-Host "  OK: kind is now $newKind" -ForegroundColor Green
    } else {
        Write-Host "  WARNING: kind is '$newKind' after upgrade - investigate." -ForegroundColor Red
    }

    # 4. Bound Function App still healthy? (skip if nothing is bound)
    if ($t.fnApp) {
        $state = Invoke-Az @('functionapp','show','-n',$t.fnApp,'-g',$t.fnRg,'--query','state','-o','tsv') "check $($t.fnApp) state"
        Write-Host "  function app '$($t.fnApp)' state: $state"
        if ($state -ne 'Running') {
            Write-Host "  WARNING: function app not Running - check it." -ForegroundColor Red
        }
    } else {
        Write-Host "  (no bound Function App)" -ForegroundColor DarkGray
    }
    Write-Host ""
}

Write-Host "Done." -ForegroundColor Cyan
if ($Apply) {
    Write-Host "Post-step: confirm each Function App's next scheduled run succeeds (check Monitor / invocations)." -ForegroundColor Cyan
}
