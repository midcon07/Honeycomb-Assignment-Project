<#
.SYNOPSIS
    Writes Bravo lever assignments into FSUIPC7.ini for one lever layout.

.DESCRIPTION
    Generates the [Axes] section FSUIPC uses to map the throttle quadrant to
    simulator controls, for whichever of the eleven layouts is asked for.

    Nothing about this is guessed at where it could be measured:

      * The lever-to-HID-axis map came from sweeping the levers one at a time
        with Probe-HoneycombDevices and watching which axis moved.
      * The joystick letter is read from FSUIPC's own [JoyNames] on every run,
        by looking the Bravo up by name. It is assigned per machine - here it
        is B only because a vJoy device took A - and it was hardcoded to B for
        a week. On a machine without vJoy the Bravo will most likely be A,
        and "BY" there aims every assignment at whatever holds B, or at
        nothing, with no error from FSUIPC. If the Bravo is not in [JoyNames],
        nothing is written.
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

    THE AXIS LETTERS ARE MEASURED. DO NOT DERIVE THEM.

        lever   1   2   3   4   5   6
        HID     Y   X   Rz  Ry  Rx  Z
        FSUIPC  Y   X   R   V   U   Z

    FSUIPC's own device scan (FSUIPC7.log) lists the Bravo as exactly six
    axes, "Max=R1023,U1023,V1023,X1023,Y1023,Z1023", so the letters are that
    closed set. Five were tied to levers by wiring candidate letters to
    throttle 1 and throttle 2 and pushing levers; lever 4 is the one letter
    left over. Two theories were tried first - "letters follow HID usage" and
    "rotational axes are lettered in descriptor order" - and each predicted
    lever 5 wrong. There is no rule here worth writing down; the table is the
    fact.

    If a lever ever drives the wrong control, -AxisLetters corrects it without
    editing this file. Prefer measuring again over reasoning about why.

.PARAMETER Layout
    Which of the eleven layouts to write. See data/lever-layouts.json.

.PARAMETER JoystickLetter
    Override only. Left blank, the Bravo is looked up in FSUIPC's [JoyNames]
    by name, and the run refuses if it is not there. Given, the letter must
    still name a device FSUIPC knows, and that device is printed so a wrong
    letter is visible rather than silent.

.PARAMETER AxisLetters
    FSUIPC axis letters for levers 1 to 6, in order. The default, Y X R V U Z,
    was measured lever by lever - see the notes above. A comma-separated list
    works from a shell as well as a PowerShell array.

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
    # Blank on purpose. Resolved from [JoyNames] below; see the notes above.
    [string]   $JoystickLetter = '',
    # MEASURED, all six. See the notes above - two theories both got this wrong.
    [string[]] $AxisLetters    = @('Y','X','R','V','U','Z'),
    # Delta is the smallest change FSUIPC will act on, not a timing value, but
    # it reads as lag: move the lever slowly and nothing happens until the
    # threshold is crossed, then it jumps.
    #
    # 256 is the documented default for calibrated input, chosen for devices in
    # general. This one is 10-bit, and FSUIPC's input spans about 32768, so one
    # physical step of the lever is 32 units - and 256 means ignoring movement
    # until eight steps have gone by. 32 is therefore the finest value that
    # still corresponds to something real on the hardware.
    #
    # If a lever ever twitches while untouched, its pot is noisy and this is the
    # number to raise.
    [int]      $Delta          = 32,
    # Which family of sim controls to drive.
    #
    #   Axis    AXIS_THROTTLE1_SET and friends. Range -16383 (idle) to +16383,
    #           so the whole lever maps straight across with no folding.
    #   Legacy  THROTTLE1_SET and friends. 0 to 16383 forward, negative being
    #           the reverse zone, so the range has to be folded into its top
    #           half to keep the reverse zone out of the lever's travel.
    #
    # The reverse zone is what separates them, and this quadrant does not use
    # it - the axis saturates at 0 at the detent and the detent button is the
    # reverse signal. FSUIPC's own UseAxisControlsForNRZ setting exists to
    # switch to the AXIS_ family in exactly that no-reverse-zone case, which is
    # why Axis is the default here.
    [ValidateSet('Axis','Legacy')]
    [string]   $ControlFamily  = 'Axis',

    # Left unset these follow ControlFamily, because the right arithmetic is a
    # property of the control's range rather than a free choice. Set them only
    # to override.
    [nullable[double]] $AxisScale  = $null,
    [nullable[int]]    $AxisOffset = $null,
    [string]   $FsuipcRoot     = 'C:\FSUIPC7',
    [switch]   $WaitForExit,
    [int]      $TimeoutSeconds = 300
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Control numbers, read from "Controls List for MSFS Build 122.txt".
#
# The two families take different value ranges, so the family and the
# arithmetic below have to move together. Picking a control from one and a
# range from the other is silent: the lever moves, just not correctly.
#
#   Axis    -16383 idle .. +16383 max      scale -1,   offset 0
#   Legacy       0 idle .. +16383 max      scale -0.5, offset +8192
#           (negative being Legacy's reverse zone, which is why its range has
#            to be folded into the top half)
#
# THE INPUT RANGE IS +-16384. The manual says this in its worked example for
# these parameters, and it is correct. Elsewhere it describes calibrated
# DirectInput values as varying "between large numbers like -32767 and +32767",
# and that sentence does not apply here.
#
# Halving these scales was tried and is a regression: it sends only the middle
# half of the control's range, giving a throttle that jumps straight to about
# 15% and stops around 85%. Do not repeat it. The theory behind it was that
# output clamping explained a dead zone at both ends of the travel; the test
# disproved it in one attempt.
#
# The small dead regions at both extremes are not from this arithmetic, which
# covers the full range to within one unit at each end. They are mechanical -
# the lever keeps moving after the pot has reached its electrical limit - plus
# whatever idle and full-power detents the aircraft models. Neither is
# reachable from this file.
#
# The negative sign is the measured direction of this quadrant: FSUIPC reads
# positive at the detent and negative at full forward, opposite to the HID
# numbers.
$CTRL_BY_FAMILY = @{

    # The modern direct-axis controls. Range -16383 (idle) to +16383 (max).
    Axis = @{
        ThrottleAll = 65765; PropAll = 66291; MixtureAll = 66292
        Throttle1   = 66420; Throttle2 = 66423; Throttle3 = 66426; Throttle4 = 66429
        Prop1       = 66421; Prop2     = 66424; Prop3     = 66427; Prop4     = 66430
        Mixture1    = 66422; Mixture2  = 66425; Mixture3  = 66428; Mixture4  = 66431
        Spoiler     = 66382; Flaps     = 66534
    }

    # The older family, which carries the reverse zone below zero. Kept so the
    # two can be compared directly rather than swapped on a hunch.
    Legacy = @{
        ThrottleAll = 65697; PropAll = 65767; MixtureAll = 65773
        Throttle1   = 65820; Throttle2 = 65821; Throttle3 = 65822; Throttle4 = 65823
        Prop1       = 65923; Prop2     = 65924; Prop3     = 65925; Prop4     = 65926
        Mixture1    = 65919; Mixture2  = 65920; Mixture3  = 65921; Mixture4  = 65922
        Spoiler     = 65786; Flaps     = 65698
    }
}

# Names for the trailing comment, matching FSUIPC's own style.
$CTRL_NAME = @{
    65697 = 'THROTTLE_SET';  65767 = 'PROP_PITCH_SET'; 65773 = 'MIXTURE_SET'
    65820 = 'THROTTLE1_SET'; 65821 = 'THROTTLE2_SET';  65822 = 'THROTTLE3_SET'; 65823 = 'THROTTLE4_SET'
    65923 = 'PROP_PITCH1_SET'; 65924 = 'PROP_PITCH2_SET'; 65925 = 'PROP_PITCH3_SET'; 65926 = 'PROP_PITCH4_SET'
    65919 = 'MIXTURE1_SET'; 65920 = 'MIXTURE2_SET'; 65921 = 'MIXTURE3_SET'; 65922 = 'MIXTURE4_SET'
    65786 = 'SPOILERS_SET'; 65698 = 'FLAPS_SET'

    65765 = 'AXIS_THROTTLE_SET'; 66291 = 'AXIS_PROPELLER_SET'; 66292 = 'AXIS_MIXTURE_SET'
    66420 = 'AXIS_THROTTLE1_SET'; 66423 = 'AXIS_THROTTLE2_SET'; 66426 = 'AXIS_THROTTLE3_SET'; 66429 = 'AXIS_THROTTLE4_SET'
    66421 = 'AXIS_PROPELLER1_SET'; 66424 = 'AXIS_PROPELLER2_SET'; 66427 = 'AXIS_PROPELLER3_SET'; 66430 = 'AXIS_PROPELLER4_SET'
    66422 = 'AXIS_MIXTURE1_SET'; 66425 = 'AXIS_MIXTURE2_SET'; 66428 = 'AXIS_MIXTURE3_SET'; 66431 = 'AXIS_MIXTURE4_SET'
    66382 = 'AXIS_SPOILER_SET'; 66534 = 'AXIS_FLAPS_SET'
}

# What each lever drives, per layout. Index 0-5 is lever 1-6; $null means the
# lever is unused and gets no assignment at all.
$LAYOUTS = @{
    prop_1_fixed = @('ThrottleAll', 'MixtureAll', $null, $null, $null, $null)
    prop_1_cs    = @('ThrottleAll', 'PropAll', 'MixtureAll', $null, $null, $null)
    prop_2_fixed = @('Throttle1', 'Throttle2', 'Mixture1', 'Mixture2', $null, $null)
    prop_2_cs    = @('Throttle1', 'Throttle2', 'Prop1', 'Prop2', 'Mixture1', 'Mixture2')
    fadec_1      = @('ThrottleAll', $null, $null, $null, $null, $null)
    fadec_2      = @('Throttle1', 'Throttle2', $null, $null, $null, $null)
    jet_1        = @('Spoiler', $null, 'Throttle1', $null, $null, 'Flaps')
    jet_2        = @('Spoiler', $null, 'Throttle1', 'Throttle2', $null, 'Flaps')
    jet_3        = @('Spoiler', $null, 'Throttle1', 'Throttle2', 'Throttle3', 'Flaps')
    jet_4        = @('Spoiler', 'Throttle1', 'Throttle2', 'Throttle3', 'Throttle4', 'Flaps')
    glider       = @('Spoiler', $null, $null, $null, $null, $null)
}


# Through "powershell -File", a comma-separated argument arrives as ONE string
# rather than an array - the same trap Invoke-Preflight guards -Only against.
# Split it here so the tool behaves the same from a shell as from PowerShell.
if ($AxisLetters.Count -eq 1 -and $AxisLetters[0] -match ',') {
    $AxisLetters = @($AxisLetters[0] -split '\s*,\s*' | Where-Object { $_ })
}
$AxisLetters = @($AxisLetters | ForEach-Object { $_.Trim().ToUpper() })
if ($AxisLetters.Count -ne 6) {
    throw ("AxisLetters needs exactly 6 entries, one per lever - got {0}: {1}" -f $AxisLetters.Count, ($AxisLetters -join ' '))
}

$CTRL = $CTRL_BY_FAMILY[$ControlFamily]

# Defaulted here rather than in the param block because they depend on the
# family. An explicit value always wins, so an override is still possible.
if ($null -eq $AxisScale)  { $AxisScale  = if ($ControlFamily -eq 'Axis') { -1.0 } else { -0.5 } }
if ($null -eq $AxisOffset) { $AxisOffset = if ($ControlFamily -eq 'Axis') {    0 } else {  8192 } }

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

# --- which joystick is the Bravo? -------------------------------------------
# Read here, after the running check, so that with -WaitForExit the file is
# the one FSUIPC just wrote rather than a stale copy. Under -WhatIf FSUIPC may
# still be running and this is whatever is on disk.
#
# Only the letter entries are used. The numeric ids (3=Bravo...) are
# DirectInput's and change when devices are re-plugged; the JoyLetters
# facility - on by default in FSUIPC7 - exists so that assignments survive
# that. Letters run A-Z omitting I and O, and users may rename them, so any
# single letter is accepted. The .GUID lines are skipped by requiring a bare
# letter before the equals sign.
$existing = @(Get-Content -LiteralPath $ini)

$joyNames = @{}
$inJoy    = $false
foreach ($line in $existing) {
    if ($line -match '^\s*\[JoyNames\]\s*$') { $inJoy = $true; continue }
    if ($inJoy -and $line -match '^\s*\[') { break }
    if ($inJoy -and $line -match '^\s*([A-Za-z])\s*=\s*(.+?)\s*$') {
        $joyNames[$Matches[1].ToUpper()] = $Matches[2]
    }
}

function Format-JoyNames {
    if ($joyNames.Count -eq 0) { return '(none - FSUIPC has not recorded any device with a letter)' }
    return (($joyNames.Keys | Sort-Object | ForEach-Object { '{0} = {1}' -f $_, $joyNames[$_] }) -join '; ')
}

# The HID product string is "Honeycomb Bravo Throttle Quadrant"; FSUIPC
# recorded it as "Bravo Throttle Quadrant". Match loosely on the two words
# rather than either exact string.
$BravoNamePattern = '(?i)bravo.*throttle'

if ($JoystickLetter) {
    $JoystickLetter = $JoystickLetter.Trim().ToUpper()
    if ($JoystickLetter.Length -ne 1 -or -not $joyNames.ContainsKey($JoystickLetter)) {
        Write-Host ''
        Write-Host ('-JoystickLetter {0} is not a device FSUIPC knows, so nothing was written.' -f $JoystickLetter) -ForegroundColor Red
        Write-Host ('FSUIPC lists: {0}' -f (Format-JoyNames)) -ForegroundColor Yellow
        exit 2
    }
    $deviceName = $joyNames[$JoystickLetter]
    if ($deviceName -notmatch $BravoNamePattern) {
        # Allowed, since it was asked for explicitly - but said out loud.
        Write-Host ''
        Write-Host ('Note: joystick {0} is "{1}", which is not the Bravo. Writing to it anyway because -JoystickLetter was given.' -f $JoystickLetter, $deviceName) -ForegroundColor Yellow
    }
} else {
    $found = @($joyNames.Keys | Where-Object { $joyNames[$_] -match $BravoNamePattern } | Sort-Object)

    if ($found.Count -eq 0) {
        Write-Host ''
        Write-Host 'FSUIPC has no record of the Bravo Throttle Quadrant, so nothing was written.' -ForegroundColor Red
        Write-Host ''
        Write-Host ('Devices FSUIPC does know: {0}' -f (Format-JoyNames)) -ForegroundColor Yellow
        Write-Host ''
        Write-Host 'FSUIPC records a device the first time it runs with that device plugged in.' -ForegroundColor Yellow
        Write-Host 'Plug the Bravo in, start FSUIPC7 once, close it, and run this again.' -ForegroundColor Yellow
        exit 2
    }
    if ($found.Count -gt 1) {
        # Two letters for one device happens when it was re-plugged with a new
        # instance GUID and FSUIPC gave it a fresh letter. Either could be the
        # live one; guessing would put the assignments on the dead one.
        Write-Host ''
        Write-Host ('FSUIPC lists the Bravo under more than one letter ({0}), so nothing was written.' -f ($found -join ', ')) -ForegroundColor Red
        Write-Host 'Only one of them is the device that is plugged in now, and there is no way to tell' -ForegroundColor Yellow
        Write-Host 'which from the file. Remove the stale entries from [JoyNames] in FSUIPC7.ini,' -ForegroundColor Yellow
        Write-Host 'with FSUIPC closed, then run this again.' -ForegroundColor Yellow
        exit 2
    }
    $JoystickLetter = $found[0]
    $deviceName     = $joyNames[$JoystickLetter]
}

# --- build the section -------------------------------------------------------
$controls = $LAYOUTS[$Layout]
$lines = New-Object System.Collections.ArrayList
[void]$lines.Add('[Axes]')
[void]$lines.Add('PollInterval=10')
[void]$lines.Add('RangeRepeatRate=10')

$n = 0
for ($lever = 0; $lever -lt 6; $lever++) {
    $role = $controls[$lever]
    if ($null -eq $role) { continue }
    $c = $CTRL[$role]
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
Write-Host ('Controls: {0} family, scale {1}, offset {2}, delta {3}' -f `
    $ControlFamily, $AxisScale.ToString([cultureinfo]::InvariantCulture), $AxisOffset, $Delta)
Write-Host ('Quadrant: joystick {0} = "{1}" per [JoyNames]; lever letters {2}' -f `
    $JoystickLetter, $deviceName, ($AxisLetters -join ' '))
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

# $existing was read above, after FSUIPC had closed, so it is current.
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
