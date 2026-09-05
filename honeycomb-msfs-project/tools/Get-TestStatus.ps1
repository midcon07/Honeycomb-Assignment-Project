<#
.SYNOPSIS
    Evaluates the automatic steps of the Bravo test and returns them, with
    the plan, as JSON for the app's test overlay.

.DESCRIPTION
    Read-only. Each 'auto' step in data/test-plan.json is a fact about this
    machine that a tool can establish without a person: is the Bravo on USB,
    has TO/GA been measured, is the button map written and does it include
    TO/GA, are the piston aircraft free of reverse lines, is FSUIPC running
    and started after the file was last changed, has FSUIPC rejected any
    button line. Manual steps are returned untouched - only a person in the
    cockpit can tick those, and the app keeps their ticks.

    Every check reports a reason string as well as a pass/fail, so the
    overlay can say WHY a step is not ticked rather than just that it is not.

.PARAMETER Json
    Write the result to this path (the app's way of calling tools).
.PARAMETER Quiet
    No console output.
#>
[CmdletBinding()]
param(
    [string] $Json  = '',
    [switch] $Quiet,
    [string] $FsuipcRoot = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'

$data    = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', 'data'))
$planP   = [System.IO.Path]::Combine($data, 'test-plan.json')
$btnP    = [System.IO.Path]::Combine($data, 'bravo-buttons.json')

if (-not $FsuipcRoot) {
    $cfgP = [System.IO.Path]::Combine($env:LOCALAPPDATA, 'HoneycombAssignment', 'config.json')
    try { $c = Get-Content -LiteralPath $cfgP -Raw -ErrorAction Stop | ConvertFrom-Json; if ($c.fsuipcRoot) { $FsuipcRoot = [string]$c.fsuipcRoot } } catch { }
}
if (-not $FsuipcRoot) { $FsuipcRoot = 'C:\FSUIPC7' }
$ini = [System.IO.Path]::Combine($FsuipcRoot, 'FSUIPC7.ini')

$plan = $null
try { $plan = Get-Content -LiteralPath $planP -Raw -ErrorAction Stop | ConvertFrom-Json } catch { }

$results = [ordered]@{}
function Set-Step { param([string]$Id, [bool]$Pass, [string]$Why) $results[$Id] = [ordered]@{ pass = $Pass; why = $Why } }

# --- facts gathered once ------------------------------------------------------
$iniLines = @()
$iniOk = Test-Path -LiteralPath $ini
if ($iniOk) {
    try {
        # Shared read: FSUIPC holds the file while running.
        $fs = [System.IO.File]::Open($ini, 'Open', 'Read', 'ReadWrite'); $sr = New-Object System.IO.StreamReader($fs)
        $iniLines = @(($sr.ReadToEnd()) -split "`r?`n"); $sr.Close()
    } catch { $iniOk = $false }
}
function Section-Lines { param([string]$Name)
    $o = New-Object System.Collections.ArrayList; $in = $false
    foreach ($l in $iniLines) {
        if ($l -match ('^\s*\[' + [regex]::Escape($Name) + '\]\s*$')) { $in = $true; continue }
        if ($in -and $l -match '^\s*\[') { break }
        if ($in -and $l -match '^\s*\d+\s*=') { [void]$o.Add($l) }
    }
    ,@($o)
}
function Has-Section { param([string]$Name) [bool]($iniLines | Where-Object { $_ -match ('^\s*\[' + [regex]::Escape($Name) + '\]\s*$') } | Select-Object -First 1) }

# bravo_connected
$bravo = $false
try { $bravo = [bool](Get-CimInstance Win32_PnPEntity -ErrorAction Stop | Where-Object { $_.PNPDeviceID -match '(?i)VID_294B&PID_1901' } | Select-Object -First 1) } catch { }
Set-Step 'bravo_connected' $bravo $(if ($bravo) { 'Seen on USB.' } else { 'Not seen on USB.' })

# toga_captured
$toga = $false; $togaWhy = 'Button table not found.'
try {
    $bt = Get-Content -LiteralPath $btnP -Raw -ErrorAction Stop | ConvertFrom-Json
    $t = $bt.controls.TOGA
    $toga = [bool]$t.verified -and ($null -ne $t.fsuipc)
    $togaWhy = if ($toga) { ('Measured: FSUIPC button {0}.' -f $t.fsuipc) } else { 'Not measured yet - run the capture.' }
} catch { }
Set-Step 'toga_captured' $toga $togaWhy

# buttons_written
$g = Section-Lines 'Buttons'
$hasToga = [bool]($g | Where-Object { $_ -match 'C65861,' } | Select-Object -First 1)
$bw = ($g.Count -ge 38) -and $hasToga
Set-Step 'buttons_written' $bw $(if (-not $iniOk) { 'FSUIPC7.ini not readable.' } elseif ($g.Count -lt 38) { ('Global [Buttons] has {0} line(s); the full map is 38 plus TO/GA.' -f $g.Count) } elseif (-not $hasToga) { ('{0} line(s) written but TO/GA is not among them.' -f $g.Count) } else { ('{0} line(s), TO/GA included.' -f $g.Count) })

# pistons_clean
$stale = @('DA62','Bonanza' | Where-Object { Has-Section ('Buttons.' + $_) })
Set-Step 'pistons_clean' ($stale.Count -eq 0) $(if ($stale.Count) { ('Still present: [Buttons.' + ($stale -join '], [Buttons.') + '].') } else { 'No piston aircraft carries a below-detent section.' })

# fsuipc_fresh
$fresh = $false; $fw = 'FSUIPC7 is not running.'
$p = Get-Process -Name FSUIPC7 -ErrorAction SilentlyContinue | Select-Object -First 1
if ($p) {
    try {
        $start = $p.StartTime; $mod = (Get-Item -LiteralPath $ini).LastWriteTime
        # FSUIPC rewrites the ini itself at startup and exit, so "started after
        # the last change" is judged with a small allowance for its own write.
        $fresh = $start -gt $mod.AddSeconds(-5)
        $fw = if ($fresh) { ('Running since {0:HH:mm:ss}; file last changed {1:HH:mm:ss}.' -f $start, $mod) } else { ('Running since {0:HH:mm:ss}, but the file changed later ({1:HH:mm:ss}) - it is on the old settings.' -f $start, $mod) }
    } catch { $fw = 'Running, but its start time could not be read.' }
}
Set-Step 'fsuipc_fresh' $fresh $fw

# no_rejected
$bad = @($iniLines | Where-Object { $_ -match '<< ERROR' })
Set-Step 'no_rejected' ($bad.Count -eq 0) $(if ($bad.Count) { ('Rejected: ' + (($bad | Select-Object -First 3) -join ' | ')) } else { 'No << ERROR markers in the file.' })

$out = [ordered]@{
    checkedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    fsuipcIni  = $ini
    steps      = $(if ($plan) { $plan.steps } else { @() })
    auto       = $results
}
$text = $out | ConvertTo-Json -Depth 8
if ($Json) { [System.IO.File]::WriteAllText($Json, $text + "`r`n", (New-Object System.Text.UTF8Encoding($false))) }
if (-not $Quiet) { foreach ($k in $results.Keys) { '{0,-18} {1}  {2}' -f $k, $(if ($results[$k].pass) { 'PASS' } else { '----' }), $results[$k].why } }
