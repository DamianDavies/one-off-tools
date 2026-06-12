<#
.SYNOPSIS
  Offline matcher for the WSRA (Worksite Risk Assessment) reconciliation.

.DESCRIPTION
  Reads three CSVs you export manually (no auth, no network calls) and
  produces two CSVs:

    wsra-report.csv     -- every work order classified
    wsra-toupdate.csv    -- just the rows ready to bulk-set Risk Assessment
                            Complete = Yes in Dynamics

  Match rule (agreed with the business):
    A work order should have Risk Assessment Complete = Yes if there is a
    STARTED WSRA (status <> NOT_STARTED) for its job whose created_at falls
    within the 12 months ending on the work order's date. The WO's date is
    its earliest non-cancelled booking Start Time, falling back to Date
    Window Start. WSRAs are dated by created_at because HOW's started_at is
    unreliable (it mirrors the last update; see README).

  Buckets:
    ToSetTrue       : flag is No, a started WSRA exists in the 12-month
                      window  -> bulk-set Yes
    AlreadyComplete : flag is already Yes -> nothing to do
    Expired         : a WSRA exists for the job but only OUTSIDE the window
                      (older than 12 months, or dated after the WO) -> review
                      (likely needs a fresh WSRA)
    NoWSRA          : no started WSRA for the job at all -> genuinely not done
    NoWoDate        : no booking and no Date Window Start -> review

.PARAMETER WsrasCsv
  HOW export (Export-WSRAs-from-HOW.sql). Default: .\wsras.csv

.PARAMETER WosCsv
  Dynamics work orders export. Default: .\wos.csv

.PARAMETER BookingsCsv
  Optional Bookable Resource Booking export. When present, the earliest
  non-cancelled booking Start Time per WO overrides Date Window Start.
  Default: .\bookings.csv

.PARAMETER ReportPath
  Output: full classification CSV. Default: .\wsra-report.csv

.PARAMETER ToUpdatePath
  Output: just the "ToSetTrue" rows. Default: .\wsra-toupdate.csv

.PARAMETER LookbackMonths
  WSRA validity window, in months. Default: 12.

.PARAMETER ForwardGraceDays
  Allow a WSRA dated up to this many days AFTER the WO date to still count.
  Default 0 (strict "12 months before the WO date"). Raise this if crews
  start the WSRA on a work day later than the earliest booking and you see
  false "Expired"s -- see README.

.EXAMPLE
  .\Match-WSRAs.ps1
#>

[CmdletBinding()]
param(
    [string]$WsrasCsv         = ".\wsras.csv",
    [string]$WosCsv           = ".\wos.csv",
    [string]$BookingsCsv      = ".\bookings.csv",
    [string]$ReportPath       = ".\wsra-report.csv",
    [string]$ToUpdatePath     = ".\wsra-toupdate.csv",
    [int]   $LookbackMonths   = 12,
    [int]   $ForwardGraceDays = 0
)

# --- Column names -------------------------------------------------------
# VERIFY these against your actual export headers before trusting a run.

# HOW export (wsras.csv). The SSMS grid save has NO header row, so we supply
# the column names explicitly (order matches Export-WSRAs-from-HOW.sql). If a
# header row IS present, it's harmless -- its created_at won't parse and the
# row is skipped.
$WsraHeader   = @('Job_Code','Form_Record_Id','Form_Status','created_at','started_at','completed_at','Form_Name')
$WsJobCol     = 'Job_Code'
$WsStatusCol  = 'Form_Status'
$WsCreatedCol = 'created_at'

# Dynamics work orders export (wos.csv)
$WoIdCol      = '(Do Not Modify) WO Number'    # the GUID, for the bulk update
$WoNameCol    = 'Work Order Number'            # msdyn_name, starts with the job code e.g. "JM0075 ..."
$WoFlagCol    = 'Risk Assessment Complete'     # hig_riskassessmentcomplete
$WoDateCol    = 'Date Window Start'
$WoStatusCol  = 'System Status'

# Values that mean the flag is already TRUE (Dynamics exports two-option
# fields as Yes/No; some exports use True/1).
$FlagTrueValues = @('Yes','True','1')

# Skip WOs whose System Status means they aren't really planned yet -- their
# Date Window Start is usually a stale setup default. (Same call as Site File.)
$SkipStatuses = @('Unscheduled')

# Bookings export (bookings.csv)
$BkWoCol      = 'Work Order'        # lookup text = the WO's msdyn_name
$BkStartCol   = 'Start Time'
$BkStatusCol  = 'Booking Status'
$BkResourceCol = 'Resource'
$CancelledStatuses = @('Canceled','Cancelled')

# Placeholder resources mark future maintenance years that aren't really
# scheduled yet (e.g. "Placeholder - Geelong", "Place Holders"). Bookings on
# these are ignored when dating a WO -- a WO whose ONLY bookings are
# placeholders is treated as not yet scheduled (NotScheduled bucket).
$PlaceholderResourcePattern = 'Placeholder|Place Holder'

# How many leading characters of the WO name identify the job (Jobpac codes
# are 2 letters + 4 digits, e.g. JM0075). This also makes "JM0075A ..." match
# job code "JM0075".
$JobCodeLength = 6

# --- Date parsing -------------------------------------------------------
# Dynamics/booking exports: Australian d/M/yyyy, sometimes with time.
$AuDateFormats = @(
    'd/M/yyyy H:mm', 'd/M/yyyy HH:mm', 'd/M/yyyy',
    'dd/MM/yyyy H:mm', 'dd/MM/yyyy HH:mm', 'dd/MM/yyyy'
)
function ConvertTo-AuDate {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $parsed  = [datetime]::MinValue
    foreach ($f in $AuDateFormats) {
        if ([datetime]::TryParseExact($Value, $f, $culture, 'AssumeLocal', [ref]$parsed)) { return $parsed }
    }
    return $null
}

# HOW export: ISO-ish "yyyy-MM-dd HH:mm:ss.fffffff". We only need the date.
function ConvertFrom-HowDate {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $v = $Value.Trim()
    if ($v.Length -ge 10) {
        $datePart = $v.Substring(0, 10)
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact($datePart, 'yyyy-MM-dd',
                [Globalization.CultureInfo]::InvariantCulture, 'AssumeLocal', [ref]$parsed)) {
            return $parsed
        }
    }
    return $null
}

function Get-JobCode {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $v = $Value.Trim()
    return $v.Substring(0, [Math]::Min($JobCodeLength, $v.Length)).ToUpper()
}

# --- Load started WSRAs from HOW ----------------------------------------
Write-Host "Loading WSRAs: $WsrasCsv" -ForegroundColor Cyan
$wsRows = Import-Csv -Path $WsrasCsv -Header $WsraHeader

$wsraByJob = @{}
$wsParsed = 0; $wsSkipped = 0
foreach ($r in $wsRows) {
    $job     = Get-JobCode $r.$WsJobCol
    $created = ConvertFrom-HowDate $r.$WsCreatedCol
    $status  = $r.$WsStatusCol
    if (-not $job -or -not $created) { $wsSkipped++; continue }
    # Defensive: the SQL already excludes NOT_STARTED, but enforce it here too.
    if ($status -and $status.Trim().ToUpper() -eq 'NOT_STARTED') { $wsSkipped++; continue }
    if (-not $wsraByJob.ContainsKey($job)) {
        $wsraByJob[$job] = New-Object System.Collections.Generic.List[object]
    }
    $wsraByJob[$job].Add([pscustomobject]@{ Created = $created; Status = $status })
    $wsParsed++
}
Write-Host ("  Parsed {0} started WSRAs ({1} skipped) across {2} job codes." -f $wsParsed, $wsSkipped, $wsraByJob.Keys.Count)

# --- Load bookings (optional) -------------------------------------------
$bookingsByWo  = @{}    # real (non-placeholder) bookings, for dating
$anyBookingWos = @{}    # every WO that has any non-cancelled booking, incl. placeholder
if (Test-Path $BookingsCsv) {
    Write-Host "Loading bookings: $BookingsCsv" -ForegroundColor Cyan
    $bkRows = Import-Csv -Path $BookingsCsv
    $bkUsed = 0; $bkPlace = 0; $bkCancel = 0; $bkOther = 0
    foreach ($bk in $bkRows) {
        $woName = $bk.$BkWoCol
        $start  = ConvertTo-AuDate $bk.$BkStartCol
        if (-not $woName -or -not $start) { $bkOther++; continue }
        $hasStatus = $bk.PSObject.Properties.Name -contains $BkStatusCol
        if ($hasStatus -and ($CancelledStatuses -contains $bk.$BkStatusCol)) { $bkCancel++; continue }
        $key = $woName.Trim()
        $anyBookingWos[$key] = $true
        $resource = if ($bk.PSObject.Properties.Name -contains $BkResourceCol) { $bk.$BkResourceCol } else { '' }
        if ($resource -and $resource -match $PlaceholderResourcePattern) { $bkPlace++; continue }
        if (-not $bookingsByWo.ContainsKey($key)) {
            $bookingsByWo[$key] = New-Object System.Collections.Generic.List[datetime]
        }
        $bookingsByWo[$key].Add($start)
        $bkUsed++
    }
    Write-Host ("  Parsed {0} real bookings across {1} WOs ({2} placeholder, {3} cancelled, {4} other skipped)." -f $bkUsed, $bookingsByWo.Keys.Count, $bkPlace, $bkCancel, $bkOther)
} else {
    Write-Host "No bookings.csv at $BookingsCsv -- using Date Window Start for all rows." -ForegroundColor Yellow
}

# --- Load work orders ---------------------------------------------------
Write-Host "Loading work orders: $WosCsv" -ForegroundColor Cyan
$woRows = Import-Csv -Path $WosCsv
Write-Host ("  Loaded {0} work order rows." -f $woRows.Count)

# --- Match --------------------------------------------------------------
$results = New-Object System.Collections.Generic.List[object]

foreach ($wo in $woRows) {
    $woName = $wo.$WoNameCol
    $woId   = $wo.$WoIdCol
    $status = $wo.$WoStatusCol
    if (-not $woName) { continue }

    $job        = Get-JobCode $woName
    $flagRaw    = if ($wo.PSObject.Properties.Name -contains $WoFlagCol) { $wo.$WoFlagCol } else { $null }
    $alreadyYes = $flagRaw -and ($FlagTrueValues -contains $flagRaw.Trim())

    $row = [ordered]@{
        WorkOrder    = $woName
        WorkOrderId  = $woId
        JobCode      = $job
        FlagWas      = $flagRaw
        WoDate       = $null
        DateSource   = 'None'
        WsraDates    = $null
        MatchedWsra  = $null
        Match        = $null
        Action       = 'Skip'
    }

    if ($alreadyYes) {
        $row.Match = 'AlreadyComplete'
        $results.Add([pscustomobject]$row); continue
    }
    if ($SkipStatuses -contains $status) {
        $row.Match = 'Unscheduled'
        $results.Add([pscustomobject]$row); continue
    }

    # WO date: earliest non-cancelled REAL (non-placeholder) booking. A WO whose
    # only bookings are placeholders is a future maintenance year not really
    # scheduled yet -> NotScheduled. A WO with no bookings at all falls back to
    # Date Window Start.
    $key = $woName.Trim()
    $bookingDate = $null
    if ($bookingsByWo.ContainsKey($key)) {
        $bookingDate = ($bookingsByWo[$key] | Sort-Object | Select-Object -First 1)
    }
    if ($bookingDate) {
        $woDate = $bookingDate; $row.DateSource = 'Booking'
    }
    elseif ($anyBookingWos.ContainsKey($key)) {
        $row.DateSource = 'PlaceholderOnly'
        $row.Match = 'NotScheduled'
        $results.Add([pscustomobject]$row); continue
    }
    else {
        $woDate = ConvertTo-AuDate $wo.$WoDateCol; $row.DateSource = 'DateWindowStart'
    }

    if (-not $woDate) {
        $row.DateSource = 'None'
        $row.Match = 'NoWoDate'
        $results.Add([pscustomobject]$row); continue
    }
    $row.WoDate = $woDate.ToString('yyyy-MM-dd')

    if (-not $wsraByJob.ContainsKey($job)) {
        $row.Match = 'NoWSRA'
        $results.Add([pscustomobject]$row); continue
    }

    $windowStart = $woDate.AddMonths(-$LookbackMonths)
    $windowEnd   = $woDate.AddDays($ForwardGraceDays)

    $candidates = $wsraByJob[$job]
    $hits = @($candidates | Where-Object { $_.Created -ge $windowStart -and $_.Created -le $windowEnd })
    $row.WsraDates = ($candidates.Created | Sort-Object | ForEach-Object { $_.ToString('yyyy-MM-dd') }) -join '; '

    if ($hits.Count -eq 0) {
        # WSRA exists for the job but none inside the validity window.
        $row.Match = 'Expired'
        $results.Add([pscustomobject]$row); continue
    }

    # Any started WSRA in the window covers the WO. Record the most recent.
    $row.MatchedWsra = ($hits.Created | Sort-Object -Descending | Select-Object -First 1).ToString('yyyy-MM-dd')
    $row.Match  = 'ToSetTrue'
    $row.Action = 'Update'
    $results.Add([pscustomobject]$row)
}

# --- Outputs ------------------------------------------------------------
$results | Export-Csv -Path $ReportPath -NoTypeInformation -Encoding UTF8
$results | Where-Object Action -eq 'Update' |
    Select-Object WorkOrder, WorkOrderId, WoDate, MatchedWsra |
    Export-Csv -Path $ToUpdatePath -NoTypeInformation -Encoding UTF8

# --- Summary ------------------------------------------------------------
Write-Host ""
Write-Host "===== Summary =====" -ForegroundColor Green
Write-Host ("  To set Yes        : {0}  (bulk-update)" -f ($results | Where-Object Match -eq 'ToSetTrue').Count)
Write-Host ("  Already complete  : {0}" -f ($results | Where-Object Match -eq 'AlreadyComplete').Count)
Write-Host ("  Expired           : {0}  (review -- WSRA outside 12-month window)" -f ($results | Where-Object Match -eq 'Expired').Count)
Write-Host ("  No WSRA           : {0}  (genuinely not started)" -f ($results | Where-Object Match -eq 'NoWSRA').Count)
Write-Host ("  No WO date        : {0}  (review)" -f ($results | Where-Object Match -eq 'NoWoDate').Count)
Write-Host ("  Not scheduled     : {0}  (placeholder-only bookings -- future maintenance years)" -f ($results | Where-Object Match -eq 'NotScheduled').Count)
Write-Host ("  Unscheduled       : {0}  (skipped)" -f ($results | Where-Object Match -eq 'Unscheduled').Count)

$bySource = $results | Where-Object { $_.DateSource -ne 'None' } | Group-Object DateSource | Sort-Object Name
Write-Host ""
Write-Host "Date source:" -ForegroundColor Cyan
foreach ($g in $bySource) { Write-Host ("  {0,-16}: {1}" -f $g.Name, $g.Count) }

Write-Host ""
Write-Host "Report:    $ReportPath" -ForegroundColor Green
Write-Host "To update: $ToUpdatePath" -ForegroundColor Green
