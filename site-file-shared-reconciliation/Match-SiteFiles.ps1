<#
.SYNOPSIS
  Offline matcher for the Site File Shared reconciliation.

.DESCRIPTION
  Reads two CSVs you exported manually (no auth, no network calls) and
  produces two CSVs:

    site-file-shared-report.csv    -- every WO classified with its match status
    site-file-shared-toupdate.csv  -- just the rows ready to bulk-set in Dynamics

  Match rule: take the first 6 characters of the Dynamics Work Order Number
  (uppercased) and find any SharePoint row whose Title also starts with that
  prefix. Among those, keep only ones whose Created date is within +/- 3
  months of the work order's Date Window Start. Bucket the result:

    Single            : exactly one SP match in range -> bulk-set Yes
    Ambiguous         : multiple SP matches in range  -> still bulk-set Yes
                        (recurring shares are valid as long as one is in range)
    OutOfDateRange    : prefix exists in SP but no date in range -> human review
    NoSharePointEntry : prefix not in SP at all -> not yet shared
    NoWoDate          : Date Window Start is blank -> human review

.PARAMETER WosCsv
  Path to the Dynamics work orders export. Default: .\wos.csv

.PARAMETER SpCsv
  Path to the SharePoint list export. Default: .\sp.csv

.PARAMETER BookingsCsv
  Optional. Path to a Bookable Resource Booking export. When present, the
  earliest non-cancelled booking Start Time per WO overrides Date Window
  Start as the date used for matching. When absent or the WO has no
  matching booking, Date Window Start is used. Default: .\bookings.csv

.PARAMETER ReportPath
  Output: full classification CSV. Default: .\site-file-shared-report.csv

.PARAMETER ToUpdatePath
  Output: just the "Update" rows. Default: .\site-file-shared-toupdate.csv

.PARAMETER DateToleranceMonths
  Tolerance for the date match, in months. Default: 3.

.EXAMPLE
  .\Match-SiteFiles.ps1
#>

[CmdletBinding()]
param(
    [string]$WosCsv             = ".\wos.csv",
    [string]$SpCsv              = ".\sp.csv",
    [string]$BookingsCsv        = ".\bookings.csv",
    [string]$ReportPath         = ".\site-file-shared-report.csv",
    [string]$ToUpdatePath       = ".\site-file-shared-toupdate.csv",
    [int]   $DateToleranceMonths = 3
)

# Dynamics export columns we read
$WoIdCol     = '(Do Not Modify) WO Number'   # this is actually the GUID
$WoNumberCol = 'Work Order Number'           # e.g. VM6235E
$WoDateCol   = 'Date Window Start'
$WoStatusCol = 'System Status'

# Skip WOs whose System Status is in this list -- they're not really
# planned, so matching against SP shares produces false positives (their
# Date Window Start is usually a stale contract-setup default).
$SkipStatuses = @('Unscheduled')

# SharePoint export columns we read
$SpTitleCol  = 'Title'
$SpDateCol   = 'Created'

# Bookings export columns we read (optional; only used if bookings.csv exists)
$BkWoCol     = 'Work Order'       # lookup column showing the WO Number text
$BkStartCol  = 'Start Time'
$BkStatusCol = 'Booking Status'   # filtered against $CancelledStatuses below
$CancelledStatuses = @('Canceled','Cancelled')

# Australian date export format. Some cells have time, some don't.
$DateFormats = @(
    'd/M/yyyy H:mm', 'd/M/yyyy HH:mm', 'd/M/yyyy',
    'dd/MM/yyyy H:mm', 'dd/MM/yyyy HH:mm', 'dd/MM/yyyy'
)

function ConvertTo-AuDate {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $parsed  = [datetime]::MinValue
    foreach ($f in $DateFormats) {
        if ([datetime]::TryParseExact($Value, $f, $culture, 'AssumeLocal', [ref]$parsed)) {
            return $parsed
        }
    }
    return $null
}

function Get-Prefix {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $v = $Value.Trim()
    return $v.Substring(0, [Math]::Min(6, $v.Length)).ToUpper()
}

# --- Load SharePoint list -------------------------------------------------
Write-Host "Loading SharePoint list: $SpCsv" -ForegroundColor Cyan
$spRows = Import-Csv -Path $SpCsv

$spByPrefix = @{}
$spParsed = 0; $spSkipped = 0
foreach ($r in $spRows) {
    $title = $r.$SpTitleCol
    $date  = ConvertTo-AuDate $r.$SpDateCol
    if (-not $title -or -not $date) { $spSkipped++; continue }
    $prefix = Get-Prefix $title
    if (-not $prefix) { $spSkipped++; continue }
    if (-not $spByPrefix.ContainsKey($prefix)) { $spByPrefix[$prefix] = New-Object System.Collections.Generic.List[object] }
    $spByPrefix[$prefix].Add([pscustomobject]@{ Title = $title.Trim(); Date = $date })
    $spParsed++
}
Write-Host ("  Parsed {0} SP rows ({1} skipped) across {2} unique 6-char prefixes." -f $spParsed, $spSkipped, $spByPrefix.Keys.Count)

# --- Load bookings (optional) ---------------------------------------------
$bookingsByWo = @{}
if (Test-Path $BookingsCsv) {
    Write-Host "Loading bookings: $BookingsCsv" -ForegroundColor Cyan
    $bkRows = Import-Csv -Path $BookingsCsv
    $bkUsed = 0; $bkSkippedCancel = 0; $bkSkippedOther = 0
    foreach ($bk in $bkRows) {
        $woNum = $bk.$BkWoCol
        $start = ConvertTo-AuDate $bk.$BkStartCol
        if (-not $woNum -or -not $start) { $bkSkippedOther++; continue }
        # Skip cancelled bookings if Status column is present
        $hasStatus = $bk.PSObject.Properties.Name -contains $BkStatusCol
        if ($hasStatus -and ($CancelledStatuses -contains $bk.$BkStatusCol)) {
            $bkSkippedCancel++; continue
        }
        $key = $woNum.Trim()
        if (-not $bookingsByWo.ContainsKey($key)) {
            $bookingsByWo[$key] = New-Object System.Collections.Generic.List[datetime]
        }
        $bookingsByWo[$key].Add($start)
        $bkUsed++
    }
    Write-Host ("  Parsed {0} bookings across {1} unique WOs ({2} cancelled skipped, {3} other skipped)." `
        -f $bkUsed, $bookingsByWo.Keys.Count, $bkSkippedCancel, $bkSkippedOther)
} else {
    Write-Host "No bookings.csv found at $BookingsCsv -- using Date Window Start for all rows." -ForegroundColor Yellow
}

# --- Load work orders -----------------------------------------------------
Write-Host "Loading work orders: $WosCsv" -ForegroundColor Cyan
$woRows = Import-Csv -Path $WosCsv
Write-Host ("  Loaded {0} work order rows." -f $woRows.Count)

# --- Match ----------------------------------------------------------------
$results = New-Object System.Collections.Generic.List[object]

foreach ($wo in $woRows) {
    $woNum   = $wo.$WoNumberCol
    $woId    = $wo.$WoIdCol
    $status  = $wo.$WoStatusCol

    if (-not $woNum) { continue }

    $prefix = Get-Prefix $woNum

    # Skip WOs whose status means they aren't really planned yet.
    if ($SkipStatuses -contains $status) {
        $results.Add([pscustomobject]@{
            WorkOrderNumber = $woNum
            WorkOrderId     = $woId
            WoDate          = $null
            DateSource      = 'None'
            Prefix          = $prefix
            Match           = 'Unscheduled'
            SpDates         = $null
            MatchedSpDate   = $null
            Action          = 'Skip'
        })
        continue
    }

    # Prefer the earliest non-cancelled booking Start Time; fall back to
    # the WO's Date Window Start if no booking exists for this WO.
    $bookingDate = $null
    if ($bookingsByWo.ContainsKey($woNum.Trim())) {
        $bookingDate = ($bookingsByWo[$woNum.Trim()] | Sort-Object | Select-Object -First 1)
    }
    if ($bookingDate) {
        $woDate     = $bookingDate
        $dateSource = 'Booking'
    } else {
        $woDate     = ConvertTo-AuDate $wo.$WoDateCol
        $dateSource = 'DateWindowStart'
    }

    if (-not $woDate) {
        $results.Add([pscustomobject]@{
            WorkOrderNumber = $woNum
            WorkOrderId     = $woId
            WoDate          = $null
            DateSource      = 'None'
            Prefix          = $prefix
            Match           = 'NoWoDate'
            SpDates         = $null
            MatchedSpDate   = $null
            Action          = 'Skip'
        })
        continue
    }

    $earliest = $woDate.AddMonths(-$DateToleranceMonths)
    $latest   = $woDate.AddMonths( $DateToleranceMonths)

    if (-not $spByPrefix.ContainsKey($prefix)) {
        $results.Add([pscustomobject]@{
            WorkOrderNumber = $woNum
            WorkOrderId     = $woId
            WoDate          = $woDate.ToString('yyyy-MM-dd')
            DateSource      = $dateSource
            Prefix          = $prefix
            Match           = 'NoSharePointEntry'
            SpDates         = $null
            MatchedSpDate   = $null
            Action          = 'Skip'
        })
        continue
    }

    $candidates = $spByPrefix[$prefix]
    $hits = @($candidates | Where-Object { $_.Date -ge $earliest -and $_.Date -le $latest })

    switch ($hits.Count) {
        0 {
            $results.Add([pscustomobject]@{
                WorkOrderNumber = $woNum
                WorkOrderId     = $woId
                WoDate          = $woDate.ToString('yyyy-MM-dd')
                DateSource      = $dateSource
                Prefix          = $prefix
                Match           = 'OutOfDateRange'
                SpDates         = ($candidates.Date | ForEach-Object { $_.ToString('yyyy-MM-dd') }) -join '; '
                MatchedSpDate   = $null
                Action          = 'Skip'
            })
        }
        1 {
            $results.Add([pscustomobject]@{
                WorkOrderNumber = $woNum
                WorkOrderId     = $woId
                WoDate          = $woDate.ToString('yyyy-MM-dd')
                DateSource      = $dateSource
                Prefix          = $prefix
                Match           = 'Single'
                SpDates         = $hits[0].Date.ToString('yyyy-MM-dd')
                MatchedSpDate   = $hits[0].Date.ToString('yyyy-MM-dd')
                Action          = 'Update'
            })
        }
        default {
            # Multiple in-range SP entries = recurring shares; still valid.
            # Use the most recent in-range date as the matched date for the
            # to-update worksheet; full list stays in SpDates for audit.
            $latestHit = ($hits | Sort-Object Date -Descending | Select-Object -First 1).Date
            $results.Add([pscustomobject]@{
                WorkOrderNumber = $woNum
                WorkOrderId     = $woId
                WoDate          = $woDate.ToString('yyyy-MM-dd')
                DateSource      = $dateSource
                Prefix          = $prefix
                Match           = 'Ambiguous'
                SpDates         = ($hits.Date | ForEach-Object { $_.ToString('yyyy-MM-dd') }) -join '; '
                MatchedSpDate   = $latestHit.ToString('yyyy-MM-dd')
                Action          = 'Update'
            })
        }
    }
}

# --- Outputs --------------------------------------------------------------
$results | Export-Csv -Path $ReportPath -NoTypeInformation -Encoding UTF8
$results | Where-Object Action -eq 'Update' |
    Select-Object WorkOrderNumber, WorkOrderId, WoDate, MatchedSpDate |
    Export-Csv -Path $ToUpdatePath -NoTypeInformation -Encoding UTF8

# --- Summary --------------------------------------------------------------
Write-Host ""
Write-Host "===== Summary =====" -ForegroundColor Green
$single    = ($results | Where-Object Match -eq 'Single').Count
$ambiguous = ($results | Where-Object Match -eq 'Ambiguous').Count
Write-Host ("  To update (total)        : {0}  (Single: {1}  +  Ambiguous: {2})" -f ($single + $ambiguous), $single, $ambiguous)
Write-Host ("  Out of date range        : {0}  (review)" -f ($results | Where-Object Match  -eq 'OutOfDateRange').Count)
Write-Host ("  No SharePoint entry      : {0}  (not yet shared)" -f ($results | Where-Object Match  -eq 'NoSharePointEntry').Count)
Write-Host ("  No WO date               : {0}  (review)" -f ($results | Where-Object Match  -eq 'NoWoDate').Count)
Write-Host ("  Unscheduled (skipped)    : {0}" -f ($results | Where-Object Match  -eq 'Unscheduled').Count)

# Show split between booking-driven and fallback dates.
$bySource = $results | Group-Object DateSource | Sort-Object Name
Write-Host ""
Write-Host "Date source:" -ForegroundColor Cyan
foreach ($g in $bySource) {
    Write-Host ("  {0,-18}: {1}" -f $g.Name, $g.Count)
}

# List the (small) NoWoDate set inline so it's actionable from the console.
$noDate = $results | Where-Object Match -eq 'NoWoDate'
if ($noDate.Count -gt 0) {
    Write-Host ""
    Write-Host "Work orders with no Date Window Start:" -ForegroundColor Yellow
    $noDate | Select-Object WorkOrderNumber, WorkOrderId | Format-Table -AutoSize | Out-String | Write-Host
}
Write-Host ""
Write-Host "Report:    $ReportPath" -ForegroundColor Green
Write-Host "To update: $ToUpdatePath" -ForegroundColor Green
