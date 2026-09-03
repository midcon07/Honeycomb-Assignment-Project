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
      * The line format is documented in "FSUIPC7 for Advanced Users", under
        Axis Assignments:

            n=ja,(R)delta(/delay),ForD,ctl1,ctl2,ctl3,ctl4

        j is the joystick, a the axis letter from XYZRUVSTPQMN, and ForD is F
        for an FS control or D for FSUIPC's own calibration.

    NOT RAW MODE. An R before the delta selects Raw mode, and a hand assignment
    produced exactly that - "BY,R0,F,..." - which drove the throttle over only a
    fraction of the lever's travel. The User Guide is explicit about why:

        "When FSUIPC is asked to apply RAW input to a normal analogue control,
         it scales it by a factor of 256 or 512 to bring it up from its 7 or 8
         bit range to a full 16 bit value."

    The Bravo is 10-bit, 0-1023, so that assumption is simply wrong for it. The
    guide's advice for any ordinary lever is to avoid Raw, and the default delta
    for calibrated input is 256 - Raw's default is 1.

    Raw is a property of the whole joystick, not of one axis: "All 6 axes on a
    specific joystick must be read in the one mode." Every line written here is
    calibrated, so that holds by construction - but a hand-assigned Raw axis on
    the same device would break it, and FSUIPC will not say so.

    THE AXIS LETTERS ARE NOT WHAT THE OBVIOUS CONVENTION PREDICTS.

    Two levers were assigned by hand and read back:

        lever 1  ->  BY      (HID usage Y)
        lever 3  ->  BR      (HID usage Rz)

    Lever 1 matches usage. Lever 3 does not: the naive reading of the
    DirectInput convention says Rz becomes V, and it is R.

    What fits both measurements is that the linear axes keep their usage
    letters while the ROTATIONAL axes are lettered in the order they appear in
    the report descriptor. The prober reads the Bravo's axes in the order
    Y, X, Rz, Ry, Rx, Z - so the rotational ones appear as Rz, Ry, Rx and take
    R, U, V in that order.

    That gives lever letters  Y  X  R  U  V  Z.

    Levers 1 and 3 are measured. Levers 2, 4, 5 and 6 follow from the theory
    that explains those two, and are not yet confirmed. Levers 3 and 5 are the
    ones that swap between the two theories, so assigning lever 5 by hand would
    settle it: R-U-V predicts V there, the naive reading predicts R.

    Any wrong letter fails loudly - a lever visibly drives the wrong thing - and
    -AxisLetters corrects it without editing this file.

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
    # MEASURED, not predicted, for levers 1 and 3. See the notes below.
    [string[]] $AxisLetters    = @('Y','X','R','U','V','Z'),
    [int]      $Delta          = 256,
    # MEASURED, both of these, and both properties of the quadrant rather than
    # of any one lever - all six sit on one device and travel the same way.
    #
    # The negative scale reverses direction: forward on the lever gave idle.
    # The halving and offset fold the full -16384..+16383 control range down to
    # 0..16383, so the whole lever travel is forward thrust. Without it the
    # bottom half of the travel sends negative values, which are the control's
    # reverse zone and simply read as idle - the throttle did not begin to move
    # until halfway up the lever.
    [double]   $AxisScale      = -0.5,
    [int]      $AxisOffset     = 8192,
    [string]   $FsuipcRoot     = 'C:\FSUIPC7',
    [switch]   $WaitForExit,
    [int]      $TimeoutSeconds = 300
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Control numbers, read from "Controls List for MSFS Build 122.txt".
#
# The plain _SET family, NOT the AXIS_ family. FSUIPC was asked to assign one
# axis by hand and it chose THROTTLE1_SET (65820) rather than
# AXIS_THROTTLE1_SET (66420). The two take different value ranges, so this is
# not cosmetic - guessing the AXIS_ variant is why the first attempt did
# nothing.
$CTRL = @{
    ThrottleAll = 65697; PropAll = 65767; MixtureAll = 65773
    Throttle1   = 65820; Throttle2 = 65821; Throttle3 = 65822; Throttle4 = 65823
    Prop1       = 65923; Prop2     = 65924; Prop3     = 65925; Prop4     = 65926
    Mixture1    = 65919; Mixture2  = 65920; Mixture3  = 65921; Mixture4  = 65922
    Spoiler     = 65786; Flaps     = 65698
}

# Names for the trailing comment, matching FSUIPC's own style.
$CTRL_NAME = @{
    65697 = 'THROTTLE_SET';  65767 = 'PROP_PITCH_SET'; 65773 = 'MIXTURE_SET'
    65820 = 'THROTTLE1_SET'; 65821 = 'THROTTLE2_SET';  65822 = 'THROTTLE3_SET'; 65823 = 'THROTTLE4_SET'
    65923 = 'PROP_PITCH1_SET'; 65924 = 'PROP_PITCH2_SET'; 65925 = 'PROP_PITCH3_SET'; 65926 = 'PROP_PITCH4_SET'
    65919 = 'MIXTURE1_SET'; 65920 = 'MIXTURE2_SET'; 65921 = 'MIXTURE3_SET'; 65922 = 'MIXTURE4_SET'
    65786 = 'SPOILERS_SET'; 65698 = 'FLAPS_SET'
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


if ($AxisLetters.Count -ne 6) { throw "AxisLetters needs exactly 6 entries, one per lever." }

$ini = [System.IO.Path]::Combine($FsuipcRoot, 'FSUIPC7.ini')
if (-not (Test-Path -LiteralPath $ini)) { throw "No FSUIPC7.ini at $ini" }

# FSUIPC holds its settings in memory and writes the whole ini out when it
# closes. Editing the file underneath a running copy does not fail - it is
# simply undone later, with no error and no clue as to why the assignments
# vanished. Refuse instead.
$running = Get-Process -Name 'FSUIPC7' -ErrorAction SilentlyContinue

if ($running -and $WaitForExit -and -not $WhatIfPreference) {
    Write-Host ''
    Write-Host 'Waiting for FSUIPC7 to close. Close it from its tray icon.' -ForegroundColor Yellow
    Write-Host 'The simulator can stay running - only FSUIPC needs to go.' -ForegroundColor Yellow
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (Get-Process -Name 'FSUIPC7' -ErrorAction SilentlyContinue) {
        if ((Get-Date) -gt $deadline) {
            Write-Host ("Gave up after {0} seconds. Nothing written." -f $TimeoutSeconds) -ForegroundColor Red
            exit 2
        }
        Start-Sleep -Milliseconds 500
    }
    # FSUIPC writes its settings during shutdown, not before it.
    Start-Sleep -Milliseconds 750
    $running = $null
    Write-Host 'FSUIPC7 closed.' -ForegroundColor Green
}

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
    # Documented format, FSUIPC7 for Advanced Users, "Axis Assignments":
    #   n=ja,(R)delta(/delay),ForD,ctl1,ctl2,ctl3,ctl4
    # An R prefix on the delta means Raw mode; no prefix means calibrated.
    # F sends an FS control, D sends to FSUIPC's calibration.
    #
    # A trailing ",*<number>" multiplies the axis value before it is sent and
    # ",+<number>" or ",-<number>" then shifts it. The manual requires the
    # multiply to come first, and performs it first.
    #
    # Formatted invariantly on purpose. This is a config file another program
    # parses, and a machine with a comma decimal separator would write "*-0,5",
    # which would be read as two parameters rather than one number.
    $axis = '{0}{1}' -f $JoystickLetter, $AxisLetters[$lever]

    $adj = ''
    if ($AxisScale -ne 1) {
        $adj += ',*' + $AxisScale.ToString([cultureinfo]::InvariantCulture)
    }
    if ($AxisOffset -ne 0) {
        $sign = if ($AxisOffset -gt 0) { '+' } else { '-' }
        $adj += ',' + $sign + [math]::Abs($AxisOffset)
    }

    [void]$lines.Add(("{0}={1},{2},F,{3},0,0,0{4}`t-{{ TO SIM: {5} }}-" -f `
        $n, $axis, $Delta, $c, $adj, $CTRL_NAME[$c]))
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

# No BOM. PowerShell's -Encoding UTF8 writes one on 5.1, and this file did not
# have one - adding invisible bytes to the front of a config file that another
# program parses is not a change to make by accident. Also CRLF, as Windows ini
# files are.
[System.IO.File]::WriteAllText($ini, (($out -join "`r`n") + "`r`n"),
    (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("Wrote {0} assignments to {1}" -f $n, $ini) -ForegroundColor Green
Write-Host ''
Write-Host 'Start FSUIPC7 again - it reads this file at startup.' -ForegroundColor Yellow
Write-Host ''
Write-Host 'Then move each lever and check it drives what the comment says, over its' -ForegroundColor Yellow
Write-Host 'whole travel. Levers 1 and 3 are measured; 2, 4, 5 and 6 are inferred. If' -ForegroundColor Yellow
Write-Host 'one drives the wrong thing, re-run with -AxisLetters in the right order.' -ForegroundColor Yellow
