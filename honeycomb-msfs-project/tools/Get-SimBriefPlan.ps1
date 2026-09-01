<#
.SYNOPSIS
    Fetches the user's latest SimBrief flight plan and reports whether it is
    recent enough to be today's flight.

.DESCRIPTION
    Step two of the launcher flow. Deliberately NOT part of the preflight gate:
    the gate answers "is this machine healthy" and may say NO-GO, whereas this
    answers "what are we flying today" and can only ever be advisory. A network
    hiccup must never look like a broken installation, and the user must always
    be able to fly without SimBrief.

    This script therefore never fails. Every problem - no internet, wrong id,
    SimBrief down, no plan ever made - produces a status and a plain sentence,
    and the caller carries on.

    Fetching a user's own latest OFP needs no API key. Only generating plans
    through the API does.

    IMPORTANT: SimBrief has no concept of a "current" flight plan. The endpoint
    always returns the user's MOST RECENT plan, with a success status, however
    old it is. Recency has to be judged here, from params.time_generated.

.PARAMETER PilotId
    SimBrief Pilot ID. Preferred: usernames can change, ids do not.

.PARAMETER Username
    Used only to discover the Pilot ID the first time. Ask the user for the name
    they log in with, resolve it once, then store the id and never ask again.

.PARAMETER FreshHours
    At or under this age, treat as today's flight. Default 6.

.PARAMETER StaleHours
    Beyond this age, require explicit confirmation. Default 24.

.PARAMETER Json
    Write the summary here.

.OUTPUTS
    An object with Status, and where a plan was found, the route, aircraft and
    age. Always exits 0 - this step cannot block a flight.

.EXAMPLE
    .\Get-SimBriefPlan.ps1 -PilotId 24481

.EXAMPLE
    .\Get-SimBriefPlan.ps1 -Username someone   # one-time, to learn the id

.NOTES
    Field names below were verified against a real response on 2026-09-01, not
    taken from documentation:
      fetch.status / fetch.userid / fetch.static_id / fetch.time
      params.user_id / params.time_generated (Unix) / params.airac /
        params.ofp_layout / params.request_id / params.xml_file
      aircraft.icao_code / .icaocode / .base_type / .name / .reg /
        .engines (engine MODEL, not a count) / .is_custom
      origin.icao_code / .name / .plan_rwy   (same shape for destination)
      times.sched_out / .est_out / .est_time_enroute   (all Unix seconds)
      general.flight_number / .route_distance / .initial_altitude
#>
[CmdletBinding(DefaultParameterSetName = 'ById')]
param(
    [Parameter(Mandatory, ParameterSetName = 'ById')]   [string] $PilotId,
    [Parameter(Mandatory, ParameterSetName = 'ByName')] [string] $Username,
    [int]    $FreshHours = 6,
    [int]    $StaleHours = 24,
    [string] $Json,
    [switch] $Quiet
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function New-PlanResult {
    param([string] $Status, [string] $Message, [hashtable] $Extra = @{})
    $o = [ordered]@{ Status = $Status; Message = $Message }
    foreach ($k in $Extra.Keys) { $o[$k] = $Extra[$k] }
    return [pscustomobject]$o
}

# ------------------------------------------------------------------- fetch --

$uri = if ($PSCmdlet.ParameterSetName -eq 'ById') {
    "https://www.simbrief.com/api/xml.fetcher.php?userid=$PilotId&json=1"
} else {
    "https://www.simbrief.com/api/xml.fetcher.php?username=$([uri]::EscapeDataString($Username))&json=1"
}

$plan = $null
$result = $null
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $plan = Invoke-RestMethod -Uri $uri -TimeoutSec 20 -ErrorAction Stop
} catch {
    # 400 means SimBrief rejected the user; anything else is usually the network.
    $status = $null
    try { $status = [int]$_.Exception.Response.StatusCode } catch { }
    if ($status -eq 400) {
        $who = if ($PilotId) { "Pilot ID $PilotId" } else { "username '$Username'" }
        $result = New-PlanResult 'NoSuchUser' `
            "SimBrief does not recognise that $who, or it has no saved flight plans."
    } else {
        $result = New-PlanResult 'Unavailable' `
            'Could not reach SimBrief. This does not stop you flying - the flight plan step is simply skipped.'
    }
}

if (-not $result) {
    $ok = $false
    try { $ok = ($plan.fetch.status -eq 'Success') } catch { }
    if (-not $ok) {
        $said = try { $plan.fetch.status } catch { 'no status returned' }
        $result = New-PlanResult 'NoPlan' "SimBrief returned no usable flight plan ($said)."
    }
}

# -------------------------------------------------------------- interpret --

if (-not $result) {
    $generatedUtc = [DateTimeOffset]::FromUnixTimeSeconds([int64]$plan.params.time_generated).UtcDateTime
    $ageHours     = [math]::Round(((Get-Date).ToUniversalTime() - $generatedUtc).TotalHours, 1)

    # SimBrief always returns the most recent plan, so age is the only thing
    # separating "today's flight" from something made last month.
    if ($ageHours -le $FreshHours) {
        $freshness = 'Fresh'
        $msg = 'This looks like today''s flight.'
    } elseif ($ageHours -le $StaleHours) {
        $freshness = 'Recent'
        $msg = "Made {0} hours ago." -f $ageHours
    } else {
        $freshness = 'Stale'
        $msg = "This plan is {0} days old. Check it is still the flight you want." -f [math]::Round($ageHours / 24, 1)
    }

    $depUtc = $null
    try { $depUtc = [DateTimeOffset]::FromUnixTimeSeconds([int64]$plan.times.sched_out).UtcDateTime } catch { }

    $result = New-PlanResult $freshness $msg @{
        PilotId       = $plan.fetch.userid
        GeneratedUtc  = $generatedUtc.ToString('yyyy-MM-dd HH:mm:ss')
        AgeHours      = $ageHours
        AircraftIcao  = $plan.aircraft.icao_code
        AircraftName  = $plan.aircraft.name
        Registration  = $plan.aircraft.reg
        IsCustom      = ($plan.aircraft.is_custom -eq '1')
        OriginIcao    = $plan.origin.icao_code
        OriginName    = $plan.origin.name
        DestIcao      = $plan.destination.icao_code
        DestName      = $plan.destination.name
        DistanceNm    = $plan.general.route_distance
        CruiseAlt     = $plan.general.initial_altitude
        SchedOutUtc   = $(if ($depUtc) { $depUtc.ToString('yyyy-MM-dd HH:mm:ss') } else { $null })
        Airac         = $plan.params.airac
    }
}

# ------------------------------------------------- resolve the cap layout --
# SimBrief names the aircraft TYPE. It does not say whether that type has a
# prop control or a mixture control, so it cannot by itself pick a lever
# layout - aircraft.engines is the engine model ("AE 330 E4P-C"), not a count.
#
# The real classifier reads those facts from the aircraft's own MSFS config
# files (see data/README.md). Until that exists, this small seed table covers
# the types on hand. An unknown type must say so, never guess.

$layoutId = $null
$layoutName = $null
if ($result.PSObject.Properties['AircraftIcao'] -and $result.AircraftIcao) {
    $seed = @{
        'DA62' = 'fadec_2'; 'DA42' = 'fadec_2'; 'TBM9' = 'fadec_1'; 'TBM8' = 'fadec_1'
        'C172' = 'prop_1_fixed'; 'C152' = 'prop_1_fixed'
        'BE36' = 'prop_1_cs';  'C208' = 'prop_1_cs'
        'BE58' = 'prop_2_cs';  'BE20' = 'prop_2_cs'; 'B350' = 'prop_2_cs'
        'C25C' = 'jet_2'; 'B738' = 'jet_2'; 'B77L' = 'jet_2'; 'B77W' = 'jet_2'; 'A320' = 'jet_2'
        'B748' = 'jet_4'; 'B744' = 'jet_4'; 'A342' = 'jet_4'; 'A343' = 'jet_4'
        'B727' = 'jet_3'; 'MD11' = 'jet_3'; 'DC10' = 'jet_3'; 'L101' = 'jet_3'
    }
    $key = "$($result.AircraftIcao)".ToUpperInvariant()
    if ($seed.ContainsKey($key)) {
        $layoutId = $seed[$key]
        $layoutFile = [System.IO.Path]::Combine($PSScriptRoot, '..', 'data', 'lever-layouts.json')
        try {
            $layouts = (Get-Content -LiteralPath $layoutFile -Raw | ConvertFrom-Json).layouts
            $match = $layouts | Where-Object { $_.id -eq $layoutId } | Select-Object -First 1
            if ($match) { $layoutName = "$($match.group) - $($match.name)" }
        } catch { }
    }
}
$result | Add-Member -NotePropertyName LayoutId   -NotePropertyValue $layoutId
$result | Add-Member -NotePropertyName LayoutName -NotePropertyValue $layoutName

# ------------------------------------------------------------------ report --

if (-not $Quiet) {
    ''
    'SimBrief flight plan'
    ('=' * 70)
    switch ($result.Status) {
        'Unavailable' { Write-Host $result.Message -ForegroundColor Yellow }
        'NoSuchUser'  { Write-Host $result.Message -ForegroundColor Yellow }
        'NoPlan'      { Write-Host $result.Message -ForegroundColor Yellow }
        default {
            $colour = if ($result.Status -eq 'Fresh') { 'Green' } else { 'Yellow' }
            Write-Host ("  {0} to {1}" -f $result.OriginIcao, $result.DestIcao) -ForegroundColor Cyan
            Write-Host ("  {0} - {1}" -f $result.OriginName, $result.DestName)
            Write-Host ("  {0} ({1}), {2} nm at {3} ft" -f $result.AircraftName, $result.AircraftIcao, $result.DistanceNm, $result.CruiseAlt)
            ''
            Write-Host ("  {0}" -f $result.Message) -ForegroundColor $colour
            Write-Host ("  Made {0} UTC" -f $result.GeneratedUtc) -ForegroundColor DarkGray
            ''
            if ($layoutName) {
                Write-Host ("  Quadrant layout: {0}" -f $layoutName) -ForegroundColor Cyan
            } else {
                Write-Host ("  Quadrant layout for {0} is not known yet - it will have to be chosen by hand." -f $result.AircraftIcao) -ForegroundColor Yellow
            }
        }
    }
    ''
}

if ($Json) { $result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Json -Encoding UTF8 }

if ($Quiet) { $result }

# Always 0. This step is advisory and must never stop a flight.
exit 0
