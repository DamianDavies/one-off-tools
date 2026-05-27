<#
.SYNOPSIS
  Sniff the matcher inputs and outputs for data-quality anomalies.

.DESCRIPTION
  Runs five independent scans against wos.csv, sp.csv, bookings.csv, and
  site-file-shared-report.csv. Each scan writes a section to the console
  and contributes rows to anomalies.csv with a Category column so you can
  filter / sort. Read-only -- doesn't change any data.

  Scans:
    1. MultiYearMixed     -- one prefix, mix of matched & unmatched WOs
                            (the EM1020 / VM6344 pattern)
    2. SpDuplicate        -- same site shared twice within a short window
    3. StaleDateWindow    -- WO's Date Window Start is far from its booking
    4. FarFutureBooking   -- bookings dated unusually far ahead
    5. WideAmbiguous      -- Ambiguous match where the in-range SP shares
                            are widely spread
#>

[CmdletBinding()]
param(
    [string]$WosCsv      = ".\wos.csv",
    [string]$SpCsv       = ".\sp.csv",
    [string]$BookingsCsv = ".\bookings.csv",
    [string]$ReportCsv   = ".\site-file-shared-report.csv",
    [string]$OutCsv      = ".\anomalies.csv",
    [int]$StaleMonths       = 6,    # Date Window Start vs Booking gap to flag
    [int]$FarFutureYears    = 5,    # bookings beyond now+N years
    [int]$SpDupWindowHours  = 24,   # SP shares within N hours of each other
    [int]$WideAmbiguousDays = 90    # Ambiguous SP spread > N days
)

$DateFormats = @(
    'd/M/yyyy H:mm','d/M/yyyy HH:mm','d/M/yyyy',
    'dd/MM/yyyy H:mm','dd/MM/yyyy HH:mm','dd/MM/yyyy'
)
function ConvertTo-AuDate {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $parsed  = [datetime]::MinValue
    foreach ($f in $DateFormats) {
        if ([datetime]::TryParseExact($Value, $f, $culture, 'AssumeLocal', [ref]$parsed)) { return $parsed }
    }
    return $null
}
function Get-Prefix {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $v = $Value.Trim()
    return $v.Substring(0, [Math]::Min(6, $v.Length)).ToUpper()
}

$findings = New-Object System.Collections.Generic.List[object]
function Add-Finding {
    param([string]$Category, [string]$Key, [string]$Detail, [string]$Severity = 'Info')
    $findings.Add([pscustomobject]@{
        Category = $Category
        Severity = $Severity
        Key      = $Key
        Detail   = $Detail
    })
}

# ===========================================================================
# Load inputs
# ===========================================================================
Write-Host "Loading inputs..." -ForegroundColor Cyan
$report   = Import-Csv $ReportCsv
$wos      = Import-Csv $WosCsv
$sp       = Import-Csv $SpCsv
$bookings = if (Test-Path $BookingsCsv) { Import-Csv $BookingsCsv } else { @() }

# ===========================================================================
# 1. MultiYearMixed -- same prefix, mix of Update vs not-Update outcomes
# ===========================================================================
Write-Host ""
Write-Host "1. MultiYearMixed (one prefix, mixed match outcomes)" -ForegroundColor Yellow
$byPrefix = $report | Where-Object Prefix | Group-Object Prefix
$mixed = $byPrefix | Where-Object {
    $hasUpdate = $_.Group | Where-Object Action -eq 'Update'
    $hasOther  = $_.Group | Where-Object { $_.Action -ne 'Update' -and $_.Match -ne 'NoSharePointEntry' }
    $hasUpdate -and $hasOther
}
foreach ($g in $mixed) {
    $upd = ($g.Group | Where-Object Action -eq 'Update').WorkOrderNumber -join ', '
    $oor = ($g.Group | Where-Object Match -eq 'OutOfDateRange').WorkOrderNumber -join ', '
    Add-Finding -Category 'MultiYearMixed' -Severity 'Review' -Key $g.Name `
        -Detail ("Update: [{0}] | OutOfDateRange: [{1}]" -f $upd, $oor)
}
Write-Host ("  Flagged {0} prefixes." -f $mixed.Count)

# ===========================================================================
# 2. SpDuplicate -- same prefix uploaded twice by same user within N hours
# ===========================================================================
Write-Host ""
Write-Host "2. SpDuplicate (same site shared twice within $SpDupWindowHours hours)" -ForegroundColor Yellow
$spParsed = foreach ($r in $sp) {
    $d = ConvertTo-AuDate $r.Created
    if (-not $d -or -not $r.Title) { continue }
    [pscustomobject]@{
        Title = $r.Title.Trim()
        User  = $r.'User Email'
        Date  = $d
    }
}
$dupCount = 0
$spGroups = $spParsed | Group-Object Title, User
foreach ($g in $spGroups) {
    if ($g.Count -lt 2) { continue }
    $sorted = $g.Group | Sort-Object Date
    for ($i = 0; $i -lt $sorted.Count - 1; $i++) {
        $gap = ($sorted[$i+1].Date - $sorted[$i].Date).TotalHours
        if ($gap -le $SpDupWindowHours) {
            $dupCount++
            Add-Finding -Category 'SpDuplicate' -Severity 'Cleanup' -Key $sorted[$i].Title `
                -Detail ("by {0}: {1:yyyy-MM-dd HH:mm} & {2:yyyy-MM-dd HH:mm} ({3:N1}h apart)" `
                    -f $sorted[$i].User, $sorted[$i].Date, $sorted[$i+1].Date, $gap)
        }
    }
}
Write-Host ("  Flagged {0} pairs." -f $dupCount)

# ===========================================================================
# 3. StaleDateWindow -- WO field disagrees with booking by > N months
# ===========================================================================
Write-Host ""
Write-Host "3. StaleDateWindow (Date Window Start vs earliest booking gap > $StaleMonths months)" -ForegroundColor Yellow
$bookingsByWo = @{}
foreach ($bk in $bookings) {
    $wo = $bk.'Work Order'
    $d  = ConvertTo-AuDate $bk.'Start Time'
    if (-not $wo -or -not $d) { continue }
    if (($bk.PSObject.Properties.Name -contains 'Booking Status') -and
        ($bk.'Booking Status' -in @('Canceled','Cancelled'))) { continue }
    $key = $wo.Trim()
    if (-not $bookingsByWo.ContainsKey($key)) {
        $bookingsByWo[$key] = New-Object System.Collections.Generic.List[datetime]
    }
    $bookingsByWo[$key].Add($d)
}
$staleCount = 0
$threshold = [TimeSpan]::FromDays($StaleMonths * 30.44)
foreach ($w in $wos) {
    $woNum = $w.'Work Order Number'
    if (-not $woNum) { continue }
    $dws   = ConvertTo-AuDate $w.'Date Window Start'
    if (-not $dws) { continue }
    if (-not $bookingsByWo.ContainsKey($woNum.Trim())) { continue }
    $earliest = ($bookingsByWo[$woNum.Trim()] | Sort-Object | Select-Object -First 1)
    $gap = [Math]::Abs(($earliest - $dws).TotalDays)
    if ($gap -gt $threshold.TotalDays) {
        $staleCount++
        Add-Finding -Category 'StaleDateWindow' -Severity 'Source-Data' -Key $woNum `
            -Detail ("DWS={0:yyyy-MM-dd}  Booking={1:yyyy-MM-dd}  gap={2:N0} days" -f $dws, $earliest, $gap)
    }
}
Write-Host ("  Flagged {0} WOs." -f $staleCount)

# ===========================================================================
# 4. FarFutureBooking -- bookings beyond now + N years
# ===========================================================================
Write-Host ""
Write-Host "4. FarFutureBooking (bookings dated beyond +$FarFutureYears years)" -ForegroundColor Yellow
$cutoff = (Get-Date).AddYears($FarFutureYears)
$farCount = 0
foreach ($bk in $bookings) {
    $d  = ConvertTo-AuDate $bk.'Start Time'
    if (-not $d -or $d -le $cutoff) { continue }
    $farCount++
    Add-Finding -Category 'FarFutureBooking' -Severity 'Source-Data' -Key $bk.'Work Order' `
        -Detail ("Start={0:yyyy-MM-dd}  Resource={1}" -f $d, $bk.Resource)
}
Write-Host ("  Flagged {0} bookings." -f $farCount)

# ===========================================================================
# 5. WideAmbiguous -- Ambiguous match where SP shares span > N days
# ===========================================================================
Write-Host ""
Write-Host "5. WideAmbiguous (Ambiguous match with SP shares spread > $WideAmbiguousDays days)" -ForegroundColor Yellow
$wideCount = 0
foreach ($r in ($report | Where-Object Match -eq 'Ambiguous')) {
    if (-not $r.SpDates) { continue }
    $dates = $r.SpDates -split '; ' | ForEach-Object { ConvertTo-AuDate $_ } | Where-Object { $_ }
    if ($dates.Count -lt 2) { continue }
    $span = ($dates | Measure-Object -Maximum -Minimum)
    $spanDays = ($span.Maximum - $span.Minimum).TotalDays
    if ($spanDays -gt $WideAmbiguousDays) {
        $wideCount++
        Add-Finding -Category 'WideAmbiguous' -Severity 'Review' -Key $r.WorkOrderNumber `
            -Detail ("SpDates=[{0}]  WoDate={1}  spread={2:N0}d" -f $r.SpDates, $r.WoDate, $spanDays)
    }
}
Write-Host ("  Flagged {0} WOs." -f $wideCount)

# ===========================================================================
# Output
# ===========================================================================
$findings | Export-Csv -Path $OutCsv -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "===== Anomaly summary =====" -ForegroundColor Green
$findings | Group-Object Category | Sort-Object Name | ForEach-Object {
    Write-Host ("  {0,-20}: {1}" -f $_.Name, $_.Count)
}
Write-Host ""
Write-Host "Detail: $OutCsv" -ForegroundColor Green
