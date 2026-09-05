<#
.SYNOPSIS
    Records that someone has confirmed MSFS is using an EMPTY Bravo profile.

.DESCRIPTION
    FSUIPC drives the levers, and MSFS must not also bind them or the two
    fight silently. That MSFS setting lives in a cloud-synced binary container
    this program cannot read, so it cannot be verified - only confirmed by a
    person who has looked. This writes that confirmation into config.json so
    the preflight gate's "Bravo profile in MSFS" check turns from TODO to PASS
    on this machine, and records who looked and when.

    Everything else in config.json is preserved. This is the one place, other
    than the app itself, that writes the file, and it touches two fields only.

.PARAMETER By
    Who looked. Defaults to the Windows user name.

.PARAMETER Clear
    Remove the confirmation, so the gate asks again. Use after changing MSFS
    controller profiles.

.EXAMPLE
    .\Confirm-SimBravoProfile.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $By = $env:USERNAME,
    # The MSFS controller profile that must be selected for the Bravo. Named,
    # so the gate can tell the user exactly which one to pick rather than "an
    # empty one". "Claude Empty" is the one created for this program.
    [string] $ProfileName = 'Claude Empty',
    [switch] $Clear
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$path = [System.IO.Path]::Combine($env:LOCALAPPDATA, 'HoneycombAssignment', 'config.json')
if (-not (Test-Path -LiteralPath $path)) {
    Write-Host ''
    Write-Host ('No configuration file at {0}, so nothing was recorded.' -f $path) -ForegroundColor Red
    Write-Host 'Run the program once first; it writes this file.' -ForegroundColor Yellow
    exit 2
}

$raw = Get-Content -LiteralPath $path -Raw
try { $cfg = $raw | ConvertFrom-Json } catch {
    Write-Host ''
    Write-Host ('The configuration file cannot be read as JSON, so nothing was recorded: {0}' -f $path) -ForegroundColor Red
    Write-Host 'Nothing was changed. Restore the file rather than deleting it.' -ForegroundColor Yellow
    exit 2
}

$stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

function Set-Field {
    param([object] $Obj, [string] $Name, [object] $Value)
    if ($Obj.PSObject.Properties[$Name]) { $Obj.$Name = $Value }
    else { $Obj | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

if ($Clear) {
    foreach ($n in @('msfsBravoProfileConfirmedUtc', 'msfsBravoProfileConfirmedBy', 'msfsBravoProfileName')) {
        if ($cfg.PSObject.Properties[$n]) { $cfg.PSObject.Properties.Remove($n) }
    }
    $what = 'clear the Bravo profile confirmation'
} else {
    Set-Field $cfg 'msfsBravoProfileConfirmedUtc' $stamp
    Set-Field $cfg 'msfsBravoProfileConfirmedBy'  $By
    Set-Field $cfg 'msfsBravoProfileName'         $ProfileName
    $what = ('record that {0} confirmed the empty Bravo profile in MSFS' -f $By)
}

if (-not $PSCmdlet.ShouldProcess($path, $what)) { return }

# Same conventions as the app: indented JSON, UTF-8 without a BOM.
$json = $cfg | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($path, $json + "`r`n", (New-Object System.Text.UTF8Encoding($false)))

if ($Clear) { Write-Host 'Cleared. The preflight gate will ask for the confirmation again.' -ForegroundColor Green }
else        { Write-Host ('Recorded: MSFS Bravo profile "{0}" confirmed selected by {1} at {2}.' -f $ProfileName, $By, $stamp) -ForegroundColor Green }
