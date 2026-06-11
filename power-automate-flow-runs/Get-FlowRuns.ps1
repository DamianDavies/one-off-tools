# ------------------------------------------------------------
# Power Automate flow runs for 30/04/2026 (Brisbane time)
# Environment: 13fc2039-7ced-413b-9bd1-371d5a1abbe2
# Flow:        09f39d25-0e48-f011-877a-000d3ad2a454
# ------------------------------------------------------------

$environmentId = "13fc2039-7ced-413b-9bd1-371d5a1abbe2"
$workflowId    = "09f39d25-0e48-f011-877a-000d3ad2a454"

# Brisbane timezone
# Windows PowerShell / PowerShell 7 on Windows:
$tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("E. Australia Standard Time")

# Target local date boundaries (Brisbane)
$localStart = [datetime]"2026-05-01T00:00:00"
$localEnd   = [datetime]"2026-05-02T00:00:00"

# Convert Brisbane boundaries to UTC
$utcStart = [System.TimeZoneInfo]::ConvertTimeToUtc($localStart, $tz)
$utcEnd   = [System.TimeZoneInfo]::ConvertTimeToUtc($localEnd, $tz)

Write-Host "Local Brisbane range : $localStart to $localEnd"
Write-Host "UTC range used       : $utcStart to $utcEnd"

# Sign in if needed
if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    Write-Error "Az.Accounts module not installed. Run: Install-Module Az.Accounts -Scope CurrentUser"
    return
}

Import-Module Az.Accounts

# This prompts sign-in if needed
Connect-AzAccount -TenantId "3e99b06f-c9f3-4edb-b682-5a0e24daa41c" | Out-Null

# Get bearer token for Power Automate API
$token = (Get-AzAccessToken -ResourceUrl "https://service.flow.microsoft.com/").Token

$headers = @{
    Authorization = "Bearer $token"
    "Content-Type" = "application/json"
}

# Power Automate (Flow) API endpoint — pairs with service.flow.microsoft.com token
$nextUrl = "https://api.flow.microsoft.com/providers/Microsoft.ProcessSimple/environments/$environmentId/flows/$workflowId/runs?api-version=2016-11-01"

$runs = @()

while ($nextUrl) {
    Write-Host "Fetching: $nextUrl"
    $resp = Invoke-RestMethod -Method Get -Uri $nextUrl -Headers $headers

    if ($resp.value) {
        $runs += $resp.value
    }

    # Paging support
    if ($resp.PSObject.Properties.Name -contains "nextLink" -and $resp.nextLink) {
        $nextUrl = $resp.nextLink
    }
    elseif ($resp.PSObject.Properties.Name -contains "@odata.nextLink" -and $resp.'@odata.nextLink') {
        $nextUrl = $resp.'@odata.nextLink'
    }
    else {
        $nextUrl = $null
    }
}

Write-Host "Total runs returned by API: $($runs.Count)"

# Filter to the Brisbane-local day by comparing UTC start times
$filtered = $runs | Where-Object {
    $start = [datetime]$_.properties.startTime
    $start -ge $utcStart -and $start -lt $utcEnd
}

# Shape output and generate direct run URLs
$output = $filtered | ForEach-Object {
    $startUtc = [datetime]$_.properties.startTime
    $endUtc   = if ($_.properties.endTime) { [datetime]$_.properties.endTime } else { $null }

    $startLocal = [System.TimeZoneInfo]::ConvertTimeFromUtc($startUtc, $tz)
    $endLocal   = if ($endUtc) { [System.TimeZoneInfo]::ConvertTimeFromUtc($endUtc, $tz) } else { $null }

    [pscustomobject]@{
        RunId            = $_.name
        Status           = $_.properties.status
        StartTimeUTC     = $startUtc.ToString("yyyy-MM-dd HH:mm:ss")
        StartTimeBrisbane= $startLocal.ToString("yyyy-MM-dd HH:mm:ss")
        EndTimeUTC       = if ($endUtc) { $endUtc.ToString("yyyy-MM-dd HH:mm:ss") } else { $null }
        EndTimeBrisbane  = if ($endLocal) { $endLocal.ToString("yyyy-MM-dd HH:mm:ss") } else { $null }
        RunUrl           = "https://make.powerautomate.com/environments/$environmentId/flows/$workflowId/runs/$($_.name)"
    }
} | Sort-Object StartTimeUTC

# Export to CSV
$csvPath = ".\FlowRuns-2026-04-30-Brisbane.csv"
$output | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "Filtered runs on 2026-04-30 (Brisbane): $($output.Count)"
Write-Host "CSV written to: $csvPath"
Write-Host ""

# Show a quick list in console
$output | Format-Table -AutoSize