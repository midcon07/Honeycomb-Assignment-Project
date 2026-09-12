<#
.SYNOPSIS
    Builds the launcher and produces a zip that runs on another computer.

.DESCRIPTION
    Builds Release into a folder of its own, checks the output actually
    contains the things the program needs at runtime, and zips it with a
    read-me.

    The checks are the point. The app finds its scripts by walking up from the
    exe looking for a folder containing tools\Preflight; inside the repo that
    search succeeds several levels up even when the output is missing them, so
    a broken package looks perfectly fine here and fails on the target machine.
    This refuses to produce a zip in that case rather than shipping it.

    The build goes to a folder of its own, not bin\Release, so a launcher that
    is running (its exe locked) is left alone: the earlier version closed it
    under whoever was using it (Mark, 2026-09-11: never pull the launcher out
    from under the user).

.PARAMETER OutDir
    Where to put the zip. Defaults to the Desktop.
#>
[CmdletBinding()]
param(
    [string] $OutDir = [Environment]::GetFolderPath('Desktop')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$proj    = [System.IO.Path]::Combine($PSScriptRoot, 'HoneycombLauncher')
$readMe  = [System.IO.Path]::Combine($PSScriptRoot, 'PACKAGE-READ-ME.txt')
$stamp   = Get-Date -Format 'yyyyMMdd-HHmm'
$outBin  = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'HoneycombLauncher-build-' + $stamp)
if (Test-Path -LiteralPath $outBin) { Remove-Item -LiteralPath $outBin -Recurse -Force }

# The commit this package was built from, so a report from the other machine
# can be matched to the code. Written into the zip as VERSION.txt.
$commit = ''
try { $commit = (& git -C $PSScriptRoot log -1 --format='%h %ci %s' 2>$null) } catch { }
$dirty = ''
try { if ((& git -C $PSScriptRoot status --porcelain 2>$null | Measure-Object).Count -gt 0) { $dirty = ' (with uncommitted changes)' } } catch { }

Write-Host ('Building into ' + $outBin + ' ...')
& dotnet build $proj -c Release --nologo -v q -o $outBin | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Build failed with exit code $LASTEXITCODE - nothing was packaged." }

# What the program needs at runtime, beyond its own assemblies: every script
# the app runs, every data file those scripts read, and the fonts the page
# uses (bundled since 2026-09-10 so nothing is fetched from the internet).
$required = @(
    'HoneycombLauncher.exe',
    'ui\index.html',
    'ui\fonts',
    'tools\Preflight\Invoke-Preflight.ps1',
    'tools\Set-LeverAssignments.ps1',
    'tools\Set-BravoButtons.ps1',
    'tools\FsuipcIni.ps1',
    'tools\Set-AlphaCalibration.ps1',
    'tools\Test-AlphaCalibration.ps1',
    'tools\Probe-HoneycombDevices.ps1',
    'tools\Get-SimBriefPlan.ps1',
    'tools\Get-AirportWeather.ps1',
    'tools\Get-TestStatus.ps1',
    'tools\Confirm-SimBravoProfile.ps1',
    'data\lever-layouts.json',
    'data\bravo-buttons.json',
    'data\alpha-buttons.json',
    'data\myevents.txt'
)
$missing = @($required | Where-Object { -not (Test-Path -LiteralPath ([System.IO.Path]::Combine($outBin, $_))) })
if ($missing.Count -gt 0) {
    Write-Host ''
    Write-Host 'The build output is incomplete, so no package was made:' -ForegroundColor Red
    $missing | ForEach-Object { Write-Host ('  missing: ' + $_) -ForegroundColor Red }
    Write-Host 'The csproj is what copies tools\ and data\ into the output.' -ForegroundColor Yellow
    exit 2
}

# Every check file in the repo must be in the output - a check that is
# missing from the package is a fault that is never reported.
$repoChecks = @(Get-ChildItem -LiteralPath ([System.IO.Path]::Combine($PSScriptRoot, '..', 'tools', 'Preflight', 'Checks')) -Filter '*.ps1')
$checks     = @(Get-ChildItem -LiteralPath ([System.IO.Path]::Combine($outBin, 'tools', 'Preflight', 'Checks')) -Filter '*.ps1' -ErrorAction SilentlyContinue)
if ($checks.Count -ne $repoChecks.Count -or $checks.Count -lt 5) {
    throw "$($checks.Count) preflight checks in the output; the repo has $($repoChecks.Count). Nothing was packaged."
}

# Stage, so the read-me sits alongside rather than inside the build folder.
$stage = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'HoneycombLauncher-' + $stamp)
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage | Out-Null
Copy-Item -Path ([System.IO.Path]::Combine($outBin, '*')) -Destination $stage -Recurse -Force
Copy-Item -LiteralPath $readMe -Destination ([System.IO.Path]::Combine($stage, 'READ-ME-FIRST.txt')) -Force
Set-Content -LiteralPath ([System.IO.Path]::Combine($stage, 'VERSION.txt')) -Value @(
    ('Honeycomb Launcher package ' + $stamp),
    ('Built from commit: ' + $(if ($commit) { $commit + $dirty } else { '(not a git checkout)' })),
    ('Built on: ' + $env:COMPUTERNAME + ' by ' + $env:USERNAME + ' at ' + (Get-Date -Format 'yyyy-MM-dd HH:mm'))
)

# Debug symbols are of no use to anyone receiving this. Neither are the
# developer test harnesses, which need hardware and a console.
Get-ChildItem -LiteralPath $stage -Filter '*.pdb' -Recurse | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -LiteralPath ([System.IO.Path]::Combine($stage, 'tools')) -Filter 'Test-*Logic.ps1' | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -LiteralPath ([System.IO.Path]::Combine($stage, 'tools')) -Filter 'Test-FsuipcIniMerge.ps1' | Remove-Item -Force -ErrorAction SilentlyContinue

$zip = [System.IO.Path]::Combine($OutDir, 'HoneycombLauncher-' + $stamp + '.zip')
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path ([System.IO.Path]::Combine($stage, '*')) -DestinationPath $zip -Force
Remove-Item -LiteralPath $stage -Recurse -Force
Remove-Item -LiteralPath $outBin -Recurse -Force

$mb = [math]::Round((Get-Item -LiteralPath $zip).Length / 1MB, 1)
Write-Host ''
Write-Host ('Package ready: {0}  ({1} MB)' -f $zip, $mb) -ForegroundColor Green
Write-Host ('Built from: {0}{1}' -f $commit, $dirty) -ForegroundColor Green
Write-Host ('Checks included: {0}. Extract the whole folder before running.' -f $checks.Count) -ForegroundColor Green
