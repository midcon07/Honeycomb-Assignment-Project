<#
.SYNOPSIS
    Waits for FSUIPC7 to close, then prints the sections it owns.

.DESCRIPTION
    This project learns FSUIPC's ini syntax by asking FSUIPC to write it,
    rather than by guessing. The technique has been right every time and
    guessing has not: the first attempt at an [Axes] line invented a format,
    and FSUIPC silently discarded every line - a wrong format looks exactly
    like a lever that does nothing.

    So the workflow is: do one thing by hand in FSUIPC's own dialogs, close
    FSUIPC, run this, and copy what it actually wrote.

    FSUIPC keeps its settings in memory and writes the whole file out when it
    closes, so reading the file while it runs shows a stale copy. This waits
    rather than reporting one.

.PARAMETER FsuipcRoot
    Where FSUIPC7.ini lives.

.PARAMETER TimeoutSeconds
    How long to wait for FSUIPC to close before giving up.

.EXAMPLE
    .\Read-FsuipcConfig.ps1
#>
[CmdletBinding()]
param(
    [string] $FsuipcRoot     = 'C:\FSUIPC7',
    [int]    $TimeoutSeconds = 300
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ini = [System.IO.Path]::Combine($FsuipcRoot, 'FSUIPC7.ini')
if (-not (Test-Path -LiteralPath $ini)) { throw "No FSUIPC7.ini at $ini" }

if (Get-Process -Name 'FSUIPC7' -ErrorAction SilentlyContinue) {
    Write-Host ''
    Write-Host 'FSUIPC7 is still running. Close it from its tray icon.' -ForegroundColor Yellow
    Write-Host 'It writes its settings out on exit, so until then this file is stale.' -ForegroundColor Yellow
    Write-Host ''

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (Get-Process -Name 'FSUIPC7' -ErrorAction SilentlyContinue) {
        if ((Get-Date) -gt $deadline) {
            Write-Host ("Gave up after {0} seconds - FSUIPC7 is still running." -f $TimeoutSeconds) -ForegroundColor Red
            Write-Host 'Nothing was read, because what is on disk now is not what FSUIPC holds.' -ForegroundColor Red
            exit 2
        }
        Start-Sleep -Milliseconds 500
    }
    # The file is written during shutdown, not before it. Give that a moment.
    Start-Sleep -Milliseconds 750
    Write-Host 'FSUIPC7 closed - settings written.' -ForegroundColor Green
}

$all = @(Get-Content -LiteralPath $ini)

function Show-Section {
    param([string] $Name)

    $out   = New-Object System.Collections.ArrayList
    $inIt  = $false
    foreach ($line in $all) {
        if ($line -match ('^\s*\[' + [regex]::Escape($Name) + '\]\s*$')) { $inIt = $true; [void]$out.Add($line); continue }
        if ($inIt -and $line -match '^\s*\[') { break }
        if ($inIt) { [void]$out.Add($line) }
    }

    Write-Host ''
    if ($out.Count -eq 0) {
        # An absent section is a real answer, not an error: it means FSUIPC has
        # nothing of that kind configured. Saying so beats printing nothing.
        Write-Host ("[{0}]  - not present" -f $Name) -ForegroundColor DarkGray
        return
    }
    $out | ForEach-Object { Write-Host $_ }
}

Write-Host ''
Write-Host ('--- ' + $ini + ' ---') -ForegroundColor Cyan

Show-Section 'JoyNames'
Show-Section 'Axes'
Show-Section 'JoystickCalibration'

# Per-aircraft sections only exist once profiles are in use. List whichever are
# there rather than assuming a naming scheme.
$profiles = @($all | Where-Object { $_ -match '^\s*\[(Profile|Axes|JoystickCalibration)\.' })
if ($profiles.Count -gt 0) {
    Write-Host ''
    Write-Host '--- per-aircraft sections ---' -ForegroundColor Cyan
    foreach ($p in $profiles) {
        Show-Section ($p.Trim() -replace '^\[|\]$', '')
    }
}

Write-Host ''
