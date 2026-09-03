<#
.SYNOPSIS
    Writes Bravo lever assignments into FSUIPC7.ini for one lever layout.

.DESCRIPTION
    Generates the [Axes] section FSUIPC uses to map the throttle quadrant to
    simulator controls, for whichever of the eleven layouts is asked for.

    Nothing about this is guessed at where it could be measured:

      * The lever-to-HID-axis map came from sweeping the levers one at a time
        with Probe-HoneycombDevices and watching which axis moved.
      * The joystick letter came from FSUIPC's own [JoyNames].
      * The control numbers came from the Controls List that ships with
        FSUIPC, not from memory.
      * The ini line format is  <n>=<joy><axis>,256,D,<control>,0,0,0

    ONE THING IS STILL A PREDICTION. Which FSUIPC axis LETTER corresponds to
    each HID axis follows the standard DirectInput ordering - X, Y, Z map to
    X, Y, Z and Rx, Ry, Rz map to R, U, V. That is a documented convention
    rather than a wild guess, and if it is wrong it is wrong loudly: a lever
    visibly drives the wrong thing and the fix is one letter. It is exposed as
    -AxisLetters so it can be corrected without editing this file.

.PARAMETER Layout
    Which of the eleven layouts to write. See data/lever-layouts.json.

.PARAMETER JoystickLetter
    The letter FSUIPC gave the quadrant, from its [JoyNames]. Default B.

.PARAMETER AxisLetters
    FSUIPC axis letters for levers 1 to 6, in order. The default follows the
    measured HID order Y, X, Rz, Ry, Rx, Z through the DirectInput convention.

.PARAMETER FsuipcRoot
    Where FSUIPC7.ini lives.

.PARAMETER WhatIf
    Show what would be written and change nothing.

.EXAMPLE
    .\Set-LeverAssignments.ps1 -Layout jet_2 -WhatIf

.EXAMPLE
    .\Set-LeverAssignments.ps1 -Layout prop_2_cs
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('prop_1_fixed','prop_1_cs','prop_2_fixed','prop_2_cs',
                 'fadec_1','fadec_2','jet_1','jet_2','jet_3','jet_4','glider')]
    [string]   $Layout,
    [string]   $JoystickLetter = 'B',
    [string[]] $AxisLetters    = @('Y','X','V','U','R','Z'),
    [string]   $FsuipcRoot     = 'C:\FSUIPC7'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Control numbers, read from "Controls List for MSFS Build 122.txt".
$CTRL = @{
    ThrottleAll = 65765; PropAll = 66291; MixtureAll = 66292
    Throttle1   = 66420; Throttle2 = 66423; Throttle3 = 66426; Throttle4 = 66429
    Prop1       = 66421; Prop2     = 66424; Prop3     = 66427; Prop4     = 66430
    Mixture1    = 66422; Mixture2  = 66425; Mixture3  = 66428; Mixture4  = 66431
    Spoiler     = 66382; Flaps     = 66534
}

# What each lever drives, per layout. Index 0-5 is lever 1-6; $null means the
# lever is unused and gets no assignment at all.
$LAYOUTS = @{
    prop_1_fixed = @($CTRL.ThrottleAll, $CTRL.MixtureAll, $null, $null, $null, $null)
    prop_1_cs    = @($CTRL.ThrottleAll, $CTRL.PropAll, $CTRL.MixtureAll, $null, $null, $null)
    prop_2_fixed = @($CTRL.Throttle1, $CTRL.Throttle2, $CTRL.Mixture1, $CTRL.Mixture2, $null, $null)
    prop_2_cs    = @($CTRL.Throttle1, $CTRL.Throttle2, $CTRL.Prop1, $CTRL.Prop2, $CTRL.Mixture1, $CTRL.Mixture2)
    fadec_1      = @($CTRL.ThrottleAll, $null, $null, $null, $null, $null)
    fadec_2      = @($CTRL.Throttle1, $CTRL.Throttle2, $null, $null, $null, $null)
    jet_1        = @($CTRL.Spoiler, $null, $CTRL.Throttle1, $null, $null, $CTRL.Flaps)
    jet_2        = @($CTRL.Spoiler, $null, $CTRL.Throttle1, $CTRL.Throttle2, $null, $CTRL.Flaps)
    jet_3        = @($CTRL.Spoiler, $null, $CTRL.Throttle1, $CTRL.Throttle2, $CTRL.Throttle3, $CTRL.Flaps)
    jet_4        = @($CTRL.Spoiler, $CTRL.Throttle1, $CTRL.Throttle2, $CTRL.Throttle3, $CTRL.Throttle4, $CTRL.Flaps)
    glider       = @($CTRL.Spoiler, $null, $null, $null, $null, $null)
}

$NAMES = @{}
foreach ($k in $CTRL.Keys) { $NAMES[$CTRL[$k]] = $k }

if ($AxisLetters.Count -ne 6) { throw "AxisLetters needs exactly 6 entries, one per lever." }

$ini = [System.IO.Path]::Combine($FsuipcRoot, 'FSUIPC7.ini')
if (-not (Test-Path -LiteralPath $ini)) { throw "No FSUIPC7.ini at $ini" }

# FSUIPC holds its settings in memory and writes the whole ini out when it
# closes. Editing the file underneath a running copy does not fail - it is
# simply undone later, with no error and no clue as to why the assignments
# vanished. Refuse instead.
$running = Get-Process -Name 'FSUIPC7' -ErrorAction SilentlyContinue
if ($running -and -not $WhatIfPreference) {
    Write-Host ''
    Write-Host 'FSUIPC7 is running, so nothing was written.' -ForegroundColor Red
    Write-Host ''
    Write-Host 'It keeps its settings in memory and writes the whole file out when it' -ForegroundColor Yellow
    Write-Host 'closes, so anything written now would be quietly undone - no error, no' -ForegroundColor Yellow
    Write-Host 'sign of what happened. Close FSUIPC7 from its tray icon and run this again.' -ForegroundColor Yellow
    exit 2
}

# --- build the section -------------------------------------------------------
$controls = $LAYOUTS[$Layout]
$lines = New-Object System.Collections.ArrayList
[void]$lines.Add('[Axes]')
[void]$lines.Add('PollInterval=10')
[void]$lines.Add('RangeRepeatRate=10')

$n = 0
for ($lever = 0; $lever -lt 6; $lever++) {
    $c = $controls[$lever]
    if ($null -eq $c) { continue }
    $axis = '{0}{1}' -f $JoystickLetter, $AxisLetters[$lever]
    [void]$lines.Add(('{0}={1},256,D,{2},0,0,0    ; lever {3} -> {4}' -f `
        $n, $axis, $c, ($lever + 1), $NAMES[$c]))
    $n++
}

$section = $lines -join "`r`n"

Write-Host ''
Write-Host ('Layout: {0}' -f $Layout)
Write-Host ('Quadrant is joystick "{0}"; lever letters {1}' -f $JoystickLetter, ($AxisLetters -join ' '))
Write-Host ''
Write-Host $section
Write-Host ''

if ($WhatIfPreference) {
    Write-Host 'WhatIf: nothing written.' -ForegroundColor Yellow
    return
}

if (-not $PSCmdlet.ShouldProcess($ini, "replace the [Axes] section")) { return }

# --- write it back, replacing only our own section ---------------------------
# A dated backup every time. This file is the user's whole control setup and
# is not ours to lose.
$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = [System.IO.Path]::Combine($FsuipcRoot, "FSUIPC7.ini.$stamp.bak")
Copy-Item -LiteralPath $ini -Destination $backup -Force
Write-Host ("Backed up to {0}" -f $backup)

$existing = @(Get-Content -LiteralPath $ini)
$out      = New-Object System.Collections.ArrayList
$inAxes   = $false
$replaced = $false

foreach ($line in $existing) {
    if ($line -match '^\s*\[Axes\]\s*$') {
        $inAxes = $true; $replaced = $true
        [void]$out.AddRange([string[]]($section -split "`r`n"))
        continue
    }
    # Any other section header ends ours.
    if ($inAxes -and $line -match '^\s*\[') { $inAxes = $false }
    if (-not $inAxes) { [void]$out.Add($line) }
}
if (-not $replaced) {
    [void]$out.Add('')
    [void]$out.AddRange([string[]]($section -split "`r`n"))
}

Set-Content -LiteralPath $ini -Value $out -Encoding UTF8
Write-Host ("Wrote {0} assignments to {1}" -f $n, $ini) -ForegroundColor Green
Write-Host ''
Write-Host 'The axis letters are the one part not yet measured. Move each lever in' -ForegroundColor Yellow
Write-Host 'the simulator and check it drives what the comment says. If one is wrong,' -ForegroundColor Yellow
Write-Host 're-run with -AxisLetters and the corrected order.' -ForegroundColor Yellow
