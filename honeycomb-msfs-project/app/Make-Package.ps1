<#
.SYNOPSIS
    Builds the launcher and produces a zip that runs on another computer.

.DESCRIPTION
    Builds Release, checks the output actually contains the things the program
    needs at runtime, and zips it with a read-me.

    The checks are the point. The app finds its scripts by walking up from the
    exe looking for a folder containing tools\Preflight; inside the repo that
    search succeeds several levels up even when the output is missing them, so
    a broken package looks perfectly fine here and fails on the target machine.
    This refuses to produce a zip in that case rather than shipping it.

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
$outBin  = [System.IO.Path]::Combine($proj, 'bin', 'Release', 'net8.0-windows')
$readMe  = [System.IO.Path]::Combine($PSScriptRoot, 'PACKAGE-READ-ME.txt')

# The exe is locked while it runs, and the build failure that produces is a
# wall of MSB3027 rather than anything readable.
$running = @(Get-Process -Name 'HoneycombLauncher' -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) {
    Write-Host 'HoneycombLauncher is running; closing it so the build can replace the exe.' -ForegroundColor Yellow
    $running | Stop-Process -Force
    Start-Sleep -Milliseconds 800
}

Write-Host 'Building...'
& dotnet build $proj -c Release --nologo -v q | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Build failed with exit code $LASTEXITCODE - nothing was packaged." }

# What the program needs at runtime, beyond its own assemblies.
$required = @(
    'HoneycombLauncher.exe',
    'ui\index.html',
    'tools\Preflight\Invoke-Preflight.ps1',
    'tools\Set-LeverAssignments.ps1',
    'tools\Get-SimBriefPlan.ps1',
    'tools\Confirm-SimBravoProfile.ps1',
    'data\lever-layouts.json'
)
$missing = @($required | Where-Object { -not (Test-Path -LiteralPath ([System.IO.Path]::Combine($outBin, $_))) })
if ($missing.Count -gt 0) {
    Write-Host ''
    Write-Host 'The build output is incomplete, so no package was made:' -ForegroundColor Red
    $missing | ForEach-Object { Write-Host ('  missing: ' + $_) -ForegroundColor Red }
    Write-Host 'The csproj is what copies tools\ and data\ into the output.' -ForegroundColor Yellow
    exit 2
}

$checks = @(Get-ChildItem -LiteralPath ([System.IO.Path]::Combine($outBin, 'tools', 'Preflight', 'Checks')) -Filter '*.ps1' -ErrorAction SilentlyContinue)
if ($checks.Count -lt 5) { throw "Only $($checks.Count) preflight checks in the output; expected all of them." }

# Stage, so the read-me sits alongside rather than inside the build folder.
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$stage = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'HoneycombLauncher-' + $stamp)
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage | Out-Null
Copy-Item -Path ([System.IO.Path]::Combine($outBin, '*')) -Destination $stage -Recurse -Force
Copy-Item -LiteralPath $readMe -Destination ([System.IO.Path]::Combine($stage, 'READ-ME-FIRST.txt')) -Force

# Debug symbols are of no use to anyone receiving this.
Get-ChildItem -LiteralPath $stage -Filter '*.pdb' -Recurse | Remove-Item -Force -ErrorAction SilentlyContinue

$zip = [System.IO.Path]::Combine($OutDir, 'HoneycombLauncher-' + $stamp + '.zip')
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path ([System.IO.Path]::Combine($stage, '*')) -DestinationPath $zip -Force
Remove-Item -LiteralPath $stage -Recurse -Force

$mb = [math]::Round((Get-Item -LiteralPath $zip).Length / 1MB, 1)
Write-Host ''
Write-Host ('Package ready: {0}  ({1} MB)' -f $zip, $mb) -ForegroundColor Green
Write-Host ('Checks included: {0}. Extract the whole folder before running.' -f $checks.Count) -ForegroundColor Green
