<#
.SYNOPSIS
    Writes the Bravo's button assignments - trim wheel, autopilot panel, gear
    lever, switches - into FSUIPC7.ini's global [Buttons] section.

.DESCRIPTION
    Reads data/bravo-buttons.json. Its "controls" half is the physical map,
    measured by Probe-HoneycombDevices.ps1 -Capture; its "map" half is the
    choice of what each control does in the sim. This tool joins the two and
    writes them in FSUIPC's documented button syntax:

        n=P<joy>,<btn>,C<control>,<param>          on press
        n=U<joy>,<btn>,C<control>,<param>          on release
        n=CP(+<joy>,<cond>)<joy>,<btn>,C<control>,<param>
                                                   on press, only while the
                                                   condition button is down
                                                   (the INCR/DECR knob, whose
                                                   meaning is the mode selector)

    Three things it refuses to do, each loudly:
      * write a control whose button number has not been measured - a guessed
        number drives the wrong thing with no error from FSUIPC;
      * write while FSUIPC7 is running - it rewrites its whole ini on exit and
        the write would be silently undone;
      * assume the quadrant's joystick letter - it is per machine (B on one,
        C on another) and is read from [JoyNames] every time.

    Buttons are global, not per aircraft: the global [Buttons] section is what
    every aircraft gets. Aircraft that need something different (PMDG) get a
    [Buttons.<name>] section from a later tool, not from this one.

.PARAMETER DataFile
    The button table. Defaults to data/bravo-buttons.json beside this tool's
    folder.

.PARAMETER AllowUnverified
    Write controls whose number was typed rather than measured. For testing
    the writer, not for a machine anyone flies on.

.PARAMETER WhatIf
    Show the section and change nothing.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $DataFile       = '',
    [string] $JoystickLetter = '',
    [string] $FsuipcRoot     = 'C:\FSUIPC7',
    [switch] $AllowUnverified,
    [switch] $WaitForExit,
    [int]    $TimeoutSeconds = 300
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not $DataFile) { $DataFile = [System.IO.Path]::Combine($PSScriptRoot, '..', 'data', 'bravo-buttons.json') }
if (-not (Test-Path -LiteralPath $DataFile)) { throw "No button table at $DataFile" }
$table = Get-Content -LiteralPath $DataFile -Raw | ConvertFrom-Json

# The merge rules for files that are not ours (the ini's [Buttons], the
# presets file): this program owns its part and leaves the rest alone.
. ([System.IO.Path]::Combine($PSScriptRoot, 'FsuipcIni.ps1'))
$ini = [System.IO.Path]::Combine($FsuipcRoot, 'FSUIPC7.ini')
if (-not (Test-Path -LiteralPath $ini)) { throw "No FSUIPC7.ini at $ini - start FSUIPC7 once so it writes one." }

# --- FSUIPC must not be running (same rule and same reason as the lever tool)
$running = $null
$fsuipc  = @(Get-Process -Name 'FSUIPC7' -ErrorAction SilentlyContinue)
if ($fsuipc.Count -gt 0) {
    $iniDir   = [System.IO.Path]::GetFullPath($FsuipcRoot).TrimEnd('\')
    $procDirs = @($fsuipc | ForEach-Object { try { [System.IO.Path]::GetDirectoryName($_.Path) } catch { $null } } | Where-Object { $_ })
    if ($procDirs.Count -eq 0 -or @($procDirs | Where-Object { $_.TrimEnd('\') -ieq $iniDir }).Count -gt 0) { $running = $fsuipc }
}
if ($running -and $WaitForExit -and -not $WhatIfPreference) {
    Write-Host 'Waiting for FSUIPC7 to close. Close it from its tray icon.' -ForegroundColor Yellow
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (Get-Process -Name 'FSUIPC7' -ErrorAction SilentlyContinue) {
        if ((Get-Date) -gt $deadline) { Write-Host 'Gave up. Nothing written.' -ForegroundColor Red; exit 2 }
        Start-Sleep -Milliseconds 500
    }
    Start-Sleep -Milliseconds 750; $running = $null
    Write-Host 'FSUIPC7 closed.' -ForegroundColor Green
}
if ($running -and -not $WhatIfPreference) {
    Write-Host 'FSUIPC7 is running, so nothing was written. It rewrites its settings on exit and' -ForegroundColor Red
    Write-Host 'would undo this. Close it from its tray icon and run this again.' -ForegroundColor Yellow
    exit 2
}

# --- which joystick is the Bravo (per machine, read every time) ---------------
$existing = @(Get-Content -LiteralPath $ini)
$joyNames = @{}; $inJoy = $false
foreach ($line in $existing) {
    if ($line -match '^\s*\[JoyNames\]\s*$') { $inJoy = $true; continue }
    if ($inJoy -and $line -match '^\s*\[') { break }
    if ($inJoy -and $line -match '^\s*([A-Za-z])\s*=\s*(.+?)\s*$') { $joyNames[$Matches[1].ToUpper()] = $Matches[2] }
}
if ($JoystickLetter) {
    $JoystickLetter = $JoystickLetter.Trim().ToUpper()
    if (-not $joyNames.ContainsKey($JoystickLetter)) { Write-Host ("-JoystickLetter {0} is not a device FSUIPC knows." -f $JoystickLetter) -ForegroundColor Red; exit 2 }
} else {
    $found = @($joyNames.Keys | Where-Object { $joyNames[$_] -match '(?i)bravo.*throttle' } | Sort-Object)
    if ($found.Count -ne 1) {
        Write-Host ("FSUIPC lists the Bravo under {0} letter(s), so nothing was written." -f $found.Count) -ForegroundColor Red
        Write-Host ('Devices FSUIPC knows: ' + (($joyNames.Keys | Sort-Object | ForEach-Object { '{0} = {1}' -f $_, $joyNames[$_] }) -join '; ')) -ForegroundColor Yellow
        exit 2
    }
    $JoystickLetter = $found[0]
}
$J = $JoystickLetter

# --- join the physical map to the sim map ------------------------------------
function Get-Btn {
    # The measured FSUIPC number for a physical control, or a refusal.
    param([string] $Name)
    if (-not $table.controls.PSObject.Properties[$Name]) { throw "Button table has no control named '$Name'." }
    $c = $table.controls.$Name
    $verified = [bool]$c.verified
    if ($null -eq $c.fsuipc -or ($c.fsuipc -is [string] -and -not $c.fsuipc)) { return $null }
    if (-not $verified -and -not $AllowUnverified) { return $null }
    return [int]$c.fsuipc
}

# The control field of a line: a number is an FSUIPC control (C<n>), anything
# else is a preset name (CP<name>) from events.txt or our own myevents.txt.
# First use: the parking brake on switch 6, which has no plain ON/OFF control
# in FSUIPC's list and is driven by calculator code on PARKING_BRAKE_SET.
function Ctl([object] $x) {
    $t = [string]$x
    if ($t -match '^\d+$') { return 'C' + $t }
    return 'CP' + $t
}

$lines   = New-Object System.Collections.ArrayList
$skipped = New-Object System.Collections.ArrayList
$n = 0
$order = @($table.map.PSObject.Properties | ForEach-Object { $_.Name })
foreach ($name in $order) {
    $m   = $table.map.$name
    $btn = Get-Btn $name
    if ($null -eq $btn) { [void]$skipped.Add($name); continue }

    if ($m.PSObject.Properties['press'] -and $m.press) {
        # 'repeat' writes the same press line N times. FSUIPC fires every line
        # that names a button, so one pulse of the trim wheel becomes N trim
        # clicks - the wheel sends one pulse per notch, and one MSFS trim click
        # per notch is far too slow to be useful.
        $rep = if ($m.PSObject.Properties['repeat'] -and [int]$m.repeat -gt 1) { [int]$m.repeat } else { 1 }
        for ($r = 1; $r -le $rep; $r++) {
            $why = if ($rep -gt 1) { (' ({0} of {1} per pulse)' -f $r, $rep) } else { '' }
            [void]$lines.Add(('P{0},{1},{2},{3}' -f $J, $btn, (Ctl $m.press[0]), $m.press[1]) + "`t; " + $name + ' -> ' + $m.press[2] + $why)
        }
    }
    if ($m.PSObject.Properties['release'] -and $m.release) {
        [void]$lines.Add(('U{0},{1},{2},{3}' -f $J, $btn, (Ctl $m.release[0]), $m.release[1]) + "`t; " + $name + ' released -> ' + $m.release[2])
    }
    if ($m.PSObject.Properties['when'] -and $m.when) {
        foreach ($cond in @($m.when.PSObject.Properties | ForEach-Object { $_.Name })) {
            $cb = Get-Btn $cond
            if ($null -eq $cb) { [void]$skipped.Add($name + ' while ' + $cond); continue }
            $act = $m.when.$cond
            [void]$lines.Add(('CP(+{0},{1}){0},{2},{3},{4}' -f $J, $cb, $btn, (Ctl $act[0]), $act[1]) + "`t; " + $name + ' while ' + $cond + ' -> ' + $act[2])
        }
    }
}

# Merge into the existing section: every line that acts on the quadrant's
# joystick is this program's to replace; every line for any other device is
# the user's and is kept, in its order, ahead of ours (audit 2026-09-05,
# finding 1 - the section used to be replaced wholesale). PollInterval is
# forced to 10 ms (FSUIPC default 25): the trim wheel spun fast sends pulses
# closer together than 25 ms and a slower poll drops them. ButtonRepeat is
# left as the user has it, and given a default only when absent.
$merge   = Merge-FsuipcButtons -IniLines $existing -Section 'Buttons' -OwnedLines @($lines) -OwnedJoystick $J -PollInterval 10 -ButtonRepeat '20,10'
$section = $merge.Section
# Which replaced lines were ours from an earlier write (they carry our
# "; CONTROL ->" comment) and which were somebody's own assignment on the
# quadrant, which is replaced too - the program owns the quadrant - but never
# without saying so.
$theirs = @($merge.Replaced | Where-Object { -not ($_ -match ';\s*(\S+)' -and $order -contains $Matches[1]) })

Write-Host ''
Write-Host ('Quadrant: joystick {0} = "{1}" per [JoyNames]' -f $J, $joyNames[$J])
Write-Host ('Writing {0} button line(s); {1} control(s) skipped as not yet measured{2}' -f $lines.Count, $skipped.Count, $(if ($skipped.Count) { ': ' + ($skipped -join ', ') } else { '' }))
if ($merge.Kept.Count -gt 0) { Write-Host ('Keeping {0} line(s) for other devices, as they are.' -f $merge.Kept.Count) }
if ($merge.Replaced.Count -gt $theirs.Count) { Write-Host ('Replacing {0} line(s) this program wrote before.' -f ($merge.Replaced.Count - $theirs.Count)) }
if ($theirs.Count -gt 0) {
    Write-Host ('Replacing {0} line(s) on joystick {1} that this program did not write (the quadrant is set up here; the backup keeps them):' -f $theirs.Count, $J) -ForegroundColor Yellow
    $theirs | ForEach-Object { Write-Host ('   ' + $_) -ForegroundColor Yellow }
}
Write-Host ''
$section | ForEach-Object { Write-Host $_ }
Write-Host ''

if ($lines.Count -eq 0) {
    Write-Host 'No measured controls to write. Run Probe-HoneycombDevices.ps1 -Capture first.' -ForegroundColor Yellow
    exit 2
}
if ($WhatIfPreference) { Write-Host 'WhatIf: nothing written.' -ForegroundColor Yellow; return }
if (-not $PSCmdlet.ShouldProcess($ini, 'replace the global [Buttons] section')) { return }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
Copy-Item -LiteralPath $ini -Destination ([System.IO.Path]::Combine($FsuipcRoot, "FSUIPC7.ini.$stamp.bak")) -Force

$out = $merge.Lines
[System.IO.File]::WriteAllText($ini, (($out -join "`r`n").TrimEnd("`r", "`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ('Wrote {0} button line(s) to {1}. Start FSUIPC7 again - it reads this file at startup.' -f $lines.Count, $ini) -ForegroundColor Green

# The map uses presets (parking brake), which live in data/myevents.txt and
# are read by FSUIPC from its own folder at startup. Installed here as well
# as by the lever writer, so whichever runs first puts them in place - as
# the managed block of that file, never over a user's own presets (audit
# 2026-09-05, finding 2).
$srcEv = [System.IO.Path]::Combine($PSScriptRoot, '..', 'data', 'myevents.txt')
$dstEv = [System.IO.Path]::Combine($FsuipcRoot, 'myevents.txt')
if (Test-Path -LiteralPath $srcEv) {
    $r = Merge-PresetBlock -Path $dstEv -Block (Get-Content -LiteralPath $srcEv -Raw)
    switch ($r.Action) {
        'created'   { Write-Host ("Installed presets: {0} (FSUIPC reads it at startup)" -f $dstEv) -ForegroundColor Green }
        'appended'  { Write-Host ("Added this program's presets to your {0}, below your own (FSUIPC reads it at startup)" -f $dstEv) -ForegroundColor Green }
        'replaced'  { Write-Host ("Updated this program's presets in {0}; your own are untouched" -f $dstEv) -ForegroundColor Green }
        'converted' { Write-Host ("Fenced this program's presets in {0} (it held an older copy of them and nothing else)" -f $dstEv) -ForegroundColor Green }
        'unchanged' { }
        'refused'   { Write-Host ("Presets NOT installed in {0}: {1}" -f $dstEv, $r.Reason) -ForegroundColor Red; Write-Host 'The parking brake switch needs them; the button lines above are written and will work once this is fixed.' -ForegroundColor Yellow }
    }
}
