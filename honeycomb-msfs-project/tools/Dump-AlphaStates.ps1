<#
.SYNOPSIS
    Records the Alpha's raw HID report in a few known states, for reading
    the switch and hat layout off the bytes rather than guessing.

.DESCRIPTION
    Written 2026-09-06 when the guided capture recorded "button 0" for the
    Alpha's base switches and nothing for the hat. Two decoders in the probe
    already disagree by one on the resting buttons. The only honest way past
    that is the raw report: this asks for one state at a time, waits for
    Enter, and saves the probe's -Json snapshot (which carries ReportHex and
    the decoded button list) for each. Compare the files afterwards.

.EXAMPLE
    .\Dump-AlphaStates.ps1
    Files land in %LOCALAPPDATA%\HoneycombAssignment\alpha-dumps\
#>
[CmdletBinding()]
param(
    [string] $OutDir = [System.IO.Path]::Combine($env:LOCALAPPDATA, 'HoneycombAssignment', 'alpha-dumps')
)
$ErrorActionPreference = 'Stop'
$probe = [System.IO.Path]::Combine($PSScriptRoot, 'Probe-HoneycombDevices.ps1')
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$states = @(
    @{ id = '1-rest';        ask = 'Everything at rest: base switches DOWN, key at R, nothing held on the yoke.' },
    @{ id = '2-alt-up';      ask = 'Flip ALT UP and leave it.' },
    @{ id = '3-alt-down';    ask = 'Flip ALT back DOWN.' },
    @{ id = '4-hat-up';      ask = 'Push the hat straight UP and HOLD it while you press Enter.' },
    @{ id = '5-hat-right';   ask = 'Push the hat RIGHT and HOLD it while you press Enter.' },
    @{ id = '6-key-L';       ask = 'Turn the key to L and leave it.' },
    @{ id = '7-lh-left-up';  ask = 'Left horn: HOLD the LEFT black switch UP while you press Enter.' },
    @{ id = '8-red';         ask = 'Right horn: HOLD the RED button while you press Enter.' }
)

Write-Host ''
Write-Host 'Alpha raw-report dump. One state at a time; do what the line says, then press Enter.' -ForegroundColor Cyan
foreach ($s in $states) {
    Write-Host ''
    Write-Host ('>> ' + $s.ask) -ForegroundColor Yellow
    [void](Read-Host '   then press Enter')
    $f = [System.IO.Path]::Combine($OutDir, $s.id + '.json')
    & $probe -Json $f 2>$null | Out-Null
    if (Test-Path -LiteralPath $f) {
        $d = (Get-Content -LiteralPath $f -Raw | ConvertFrom-Json).Devices | Where-Object { $_.Name -match '(?i)alpha' } | Select-Object -First 1
        if ($d) { Write-Host ('   saved. buttons: [{0}]  report: {1}' -f (@($d.Buttons) -join ','), $d.ReportHex) -ForegroundColor Green }
        else    { Write-Host '   saved, but no Alpha in it - is it plugged in?' -ForegroundColor Red }
    } else { Write-Host '   nothing saved' -ForegroundColor Red }
}
Write-Host ''
Write-Host ('Done. Files are in ' + $OutDir) -ForegroundColor Green
