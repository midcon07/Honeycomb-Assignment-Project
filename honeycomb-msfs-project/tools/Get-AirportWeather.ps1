<#
.SYNOPSIS
    Current METAR and TAF for an airport, from aviationweather.gov.

.DESCRIPTION
    Asks the FAA/NOAA Aviation Weather Center data API for the airport's
    latest METAR and its TAF. Many small fields report no weather at all; when
    the airport has no METAR and its position is known, the nearest reporting
    station within 100 NM is used instead, and the result says so plainly -
    which station, and how far away. The reader must never be left thinking
    a neighbour's weather is the field's own.

    Written for the launcher (-Json <file> -Quiet), usable by hand without.

.PARAMETER Icao
    Four-letter ICAO identifier (KDPA). Three-letter FAA ids are prefixed
    with K when they look American.
.PARAMETER Lat
.PARAMETER Lon
    The airport's position, decimal degrees. Only needed for the fallback.
.PARAMETER Label
    Free text handed back unchanged ("Departure"), so the caller can match
    the answer to the button that asked.
.PARAMETER Json
    Write the result as JSON to this file.
.PARAMETER Quiet
    No console output.

.EXAMPLE
    .\Get-AirportWeather.ps1 -Icao KDPA
    .\Get-AirportWeather.ps1 -Icao KSUE -Lat 44.84 -Lon -87.42
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Icao,
    [double] $Lat = [double]::NaN,
    [double] $Lon = [double]::NaN,
    [string] $Label = '',
    [string] $Json,
    [switch] $Quiet
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$base = 'https://aviationweather.gov/api/data'
$id = $Icao.Trim().ToUpper()
if ($id.Length -eq 3) { $id = 'K' + $id }

$result = [ordered]@{
    Status     = 'Unavailable'   # OK | NoStation | Unavailable
    Label      = $Label
    Requested  = $id
    Station    = $null
    StationName = $null
    DistanceNm = 0
    Metar      = $null
    Taf        = $null
    ObsTime    = $null
    Note       = $null
    FetchedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Fetch-Json([string] $u) {
    # Invoke-WebRequest + ConvertFrom-Json, not Invoke-RestMethod: on Windows
    # PowerShell 5.1 the latter hands a JSON array back as ONE object whose
    # every property is an array (measured 2026-09-05: icaoId = 49 ids in one
    # value), which then fails the first arithmetic on lat/lon.
    $r = Invoke-WebRequest -UseBasicParsing -Uri $u -TimeoutSec 20 -Headers @{ 'User-Agent' = 'HoneycombPreflight/1.0' }
    # ConvertFrom-Json (5.1) emits a JSON array as ONE Object[] item; piping the
    # variable enumerates it, so callers get stations, not a box of stations.
    $data = $r.Content | ConvertFrom-Json
    return @($data | ForEach-Object { $_ })
}

function Get-Station([string] $ids) {
    # One call gives the latest METAR and, with taf=true, the TAF alongside.
    $u = '{0}/metar?ids={1}&format=json&taf=true' -f $base, $ids
    $r = Fetch-Json $u
    return @($r)
}

function Get-DistanceNm([double] $lat1, [double] $lon1, [double] $lat2, [double] $lon2) {
    $R = 3440.065
    $p1 = $lat1 * [math]::PI / 180; $p2 = $lat2 * [math]::PI / 180
    $dp = ($lat2 - $lat1) * [math]::PI / 180; $dl = ($lon2 - $lon1) * [math]::PI / 180
    $a = [math]::Sin($dp / 2) * [math]::Sin($dp / 2) + [math]::Cos($p1) * [math]::Cos($p2) * [math]::Sin($dl / 2) * [math]::Sin($dl / 2)
    return [math]::Round($R * 2 * [math]::Atan2([math]::Sqrt($a), [math]::Sqrt(1 - $a)), 1)
}

function Fill([object] $ob, [string] $note) {
    $result.Status      = 'OK'
    $result.Station     = $ob.icaoId
    $result.StationName = $ob.name
    $result.Metar       = $ob.rawOb
    $result.Taf         = if ($ob.PSObject.Properties['rawTaf'] -and $ob.rawTaf) { $ob.rawTaf } else { $null }
    $result.ObsTime     = $ob.reportTime
    $result.Note        = $note
}

try {
    $own = @(Get-Station $id)   # @() because a lone PSCustomObject has no .Count in PowerShell 5.1
    if ($own.Count -gt 0 -and $own[0].rawOb) {
        Fill $own[0] $null
        if (-not $result.Taf) { $result.Note = ('{0} reports a METAR but issues no TAF.' -f $id) }
    }
    elseif (-not [double]::IsNaN($Lat) -and -not [double]::IsNaN($Lon)) {
        # No METAR at the field: every station in a box about 100 NM across,
        # nearest first. bbox is lat0,lon0,lat1,lon1.
        $u = '{0}/metar?bbox={1},{2},{3},{4}&format=json' -f $base, ($Lat - 1.5), ($Lon - 2), ($Lat + 1.5), ($Lon + 2)
        $near = @(Fetch-Json $u)
        $ranked = @($near | Where-Object { $_.rawOb -and $_.icaoId -ne $id } |
            ForEach-Object { [pscustomobject]@{ ob = $_; d = (Get-DistanceNm $Lat $Lon ([double]$_.lat) ([double]$_.lon)) } } |
            Sort-Object d)
        if ($ranked.Count -gt 0 -and $ranked[0].d -le 100) {
            $best = $ranked[0]
            # Fetch again by id so the TAF comes with it (bbox answers carry no TAF).
            $full = @(Get-Station $best.ob.icaoId)
            $ob = if ($full.Count -gt 0) { $full[0] } else { $best.ob }
            Fill $ob ('{0} has no weather reporting. This is {1} ({2}), {3} NM away - the nearest station that does.' -f $id, $ob.icaoId, $ob.name, $best.d)
            $result.DistanceNm = $best.d
            if (-not $result.Taf) { $result.Note += ' It issues no TAF.' }
        }
        else {
            $result.Status = 'NoStation'
            $result.Note = ('{0} has no weather reporting and no station within 100 NM reports either.' -f $id)
        }
    }
    else {
        $result.Status = 'NoStation'
        $result.Note = ('{0} has no METAR, and without its position no nearest station can be looked up.' -f $id)
    }
}
catch {
    $result.Status = 'Unavailable'
    $result.Note = 'aviationweather.gov could not be reached: ' + $_.Exception.Message
}

if ($Json) {
    $dir = Split-Path -Parent $Json
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [pscustomobject]$result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Json -Encoding UTF8
}
if (-not $Quiet) {
    Write-Host ('{0}: {1}' -f $result.Requested, $result.Status)
    if ($result.Note)  { Write-Host $result.Note -ForegroundColor Yellow }
    if ($result.Metar) { Write-Host ''; Write-Host 'METAR'; Write-Host $result.Metar }
    if ($result.Taf)   { Write-Host ''; Write-Host 'TAF';   Write-Host $result.Taf }
}
