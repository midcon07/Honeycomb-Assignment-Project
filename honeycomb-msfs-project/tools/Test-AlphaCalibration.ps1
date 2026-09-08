<#
.SYNOPSIS
    How far off centre the Alpha yoke sits, as the simulator sees it.

.DESCRIPTION
    Read-only. Asks the Windows joystick API (winmm, joyGetPosEx) for the
    yoke's roll and pitch positions. That API hands back the CALIBRATED value:
    the raw pot reading mapped through the min/centre/max Windows keeps for the
    device, which is the same mapping the simulator and FSUIPC get. A yoke whose
    pot has drifted reads off centre here even when nobody is touching it.

    Measured 2026-09-07 on Mark's Alpha: raw pitch pot 499 of 1023 against a
    stored centre of 511 read -2.2% here; writing 499 as the stored centre
    read 0.0%; writing 700 read -28.6%. So this number is the truth the
    simulator flies with, and the stored calibration is what a recalibration
    changes (tools/Set-AlphaCalibration.ps1).

    Two things about the API, both measured: the first reading after a process
    starts is a placeholder (exact centre) until the yoke sends a report, up to
    about a second at rest; and the calibration is loaded when the device is
    opened, so a change made while a process is running is not seen by that
    process. Every reading here waits for a real report, and the launcher
    restarts FSUIPC after a recalibration for the second reason.

    Which pot is roll and which is pitch is X and Y by every yoke's convention,
    and is MEASURED by the recalibration's sweep and recorded in
    %LOCALAPPDATA%\HoneycombAssignment\alpha-axes.json; the labels here come
    from that file when it exists.

.PARAMETER Json
    Write the result to this path (the app's way of calling tools).
.PARAMETER LimitPercent
    Off-centre beyond this, on either axis, is a recommendation to recalibrate.
    Default 3: a couple of percent is within what a hand at rest does to the
    yoke; beyond that it is the pot, and it shows up as a trim that never sits.
.PARAMETER Library
    Define the functions and stop; for the preflight check and the
    recalibration tool, which dot-source this file.
#>
[CmdletBinding()]
param(
    [string] $Json = '',
    [double] $LimitPercent = 3.0,
    [switch] $Library
)

if (-not $Library) { Set-StrictMode -Version Latest; $ErrorActionPreference = 'Stop' }

$script:AlphaVid = 0x294B
$script:AlphaPid = 0x1900
$script:AlphaCalibrationKey = 'HKCU:\System\CurrentControlSet\Control\MediaProperties\PrivateProperties\DirectInput\VID_294B&PID_1900\Calibration\0\Type\Axes'
$script:AlphaAxesFile = Join-Path $env:LOCALAPPDATA 'HoneycombAssignment\alpha-axes.json'

function Initialize-WinMm {
    if ('WinMmJoy' -as [type]) { return }
    Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public static class WinMmJoy {
    [StructLayout(LayoutKind.Sequential)] public struct JOYINFOEX { public uint dwSize, dwFlags, dwXpos, dwYpos, dwZpos, dwRpos, dwUpos, dwVpos, dwButtons, dwButtonNumber, dwPOV, dwReserved1, dwReserved2; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct JOYCAPS {
        public ushort wMid, wPid; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szPname;
        public uint wXmin, wXmax, wYmin, wYmax, wZmin, wZmax, wNumButtons, wPeriodMin, wPeriodMax, wRmin, wRmax, wUmin, wUmax, wVmin, wVmax, wCaps, wMaxAxes, wNumAxes, wMaxButtons;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szRegKey; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szOEMVxD; }
    [DllImport("winmm.dll", CharSet = CharSet.Unicode)] public static extern uint joyGetDevCapsW(UIntPtr id, ref JOYCAPS caps, uint size);
    [DllImport("winmm.dll")] public static extern uint joyGetPosEx(uint id, ref JOYINFOEX info);
    public static int Find(ushort vid, ushort pid) {
        for (uint i = 0; i < 16; i++) { var c = new JOYCAPS(); if (joyGetDevCapsW((UIntPtr)i, ref c, (uint)Marshal.SizeOf(typeof(JOYCAPS))) == 0 && c.wMid == vid && c.wPid == pid) return (int)i; }
        return -1;
    }
    public static uint[] Read(int id) {
        var j = new JOYINFOEX(); j.dwSize = (uint)Marshal.SizeOf(typeof(JOYINFOEX)); j.dwFlags = 0xFF;
        uint r = joyGetPosEx((uint)id, ref j); if (r != 0) throw new Exception("joyGetPosEx returned " + r);
        return new uint[] { j.dwXpos, j.dwYpos };
    }
}
"@
}

function Get-AlphaJoystickId {
    Initialize-WinMm
    return [WinMmJoy]::Find($script:AlphaVid, $script:AlphaPid)
}

function Get-AlphaAxisNames {
    # Roll and pitch by measurement when the sweep has been done, by
    # convention (X roll, Y pitch) until then - and the result says which.
    $r = [pscustomobject]@{ Roll = 'X'; Pitch = 'Y'; Measured = $false; When = ''; SpreadRoll = $null; SpreadPitch = $null }
    try {
        if (Test-Path -LiteralPath $script:AlphaAxesFile) {
            $f = Get-Content -LiteralPath $script:AlphaAxesFile -Raw | ConvertFrom-Json
            if ($f.roll -in @('X', 'Y') -and $f.pitch -in @('X', 'Y') -and $f.roll -ne $f.pitch) {
                $r.Roll = [string]$f.roll; $r.Pitch = [string]$f.pitch; $r.Measured = $true; $r.When = [string]$f.measured
            }
            if ($f.PSObject.Properties['settleSpreadPercent']) { $r.SpreadRoll = [double]$f.settleSpreadPercent.roll; $r.SpreadPitch = [double]$f.settleSpreadPercent.pitch }
        }
    } catch { }
    return $r
}

function Read-AlphaCentred {
    <#
        One calibrated reading of both axes as percent off centre, after
        waiting for the yoke's first real report (the API returns exact
        centre as a placeholder until then). $null when the yoke is not a
        joystick Windows knows.
    #>
    param([double] $WaitSeconds = 2.0)
    $id = Get-AlphaJoystickId
    if ($id -lt 0) { return $null }
    $t0 = Get-Date; $p = $null
    while ($true) {
        $p = [WinMmJoy]::Read($id)
        if ($p[0] -ne 32767 -or $p[1] -ne 32767) { break }
        if (((Get-Date) - $t0).TotalSeconds -ge $WaitSeconds) { break }
        Start-Sleep -Milliseconds 100
    }
    $names = Get-AlphaAxisNames
    $pct = @{ X = ([double]$p[0] - 32767.5) / 32767.5 * 100.0; Y = ([double]$p[1] - 32767.5) / 32767.5 * 100.0 }
    return [pscustomobject]@{
        JoystickId   = $id
        X            = [int]$p[0]
        Y            = [int]$p[1]
        XPercent     = [math]::Round($pct.X, 1)
        YPercent     = [math]::Round($pct.Y, 1)
        RollAxis     = $names.Roll
        PitchAxis    = $names.Pitch
        RollPercent  = [math]::Round($pct[$names.Roll], 1)
        PitchPercent = [math]::Round($pct[$names.Pitch], 1)
        AxesMeasured = $names.Measured
        WaitedSeconds = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
    }
}

function Get-AlphaCalibrationStore {
    <#
        What Windows has stored for each axis slot: min, centre, max, twelve
        bytes as three little-endian integers. Slot 1 is the pitch pot (Y) and
        slot 0 the roll pot (X) - measured 2026-09-07 by writing a centre into
        slot 1 and watching the pitch reading move. Absent means Windows uses
        the pot's own range (0 to 1023, centre 511).
    #>
    $slots = @()
    for ($i = 0; $i -lt 2; $i++) {
        $k = Join-Path $script:AlphaCalibrationKey ([string]$i)
        $entry = [pscustomobject]@{ Slot = $i; Axis = $(if ($i -eq 0) { 'X' } else { 'Y' }); Stored = $false; Min = 0; Centre = 511; Max = 1023; Bytes = $null }
        try {
            $b = (Get-ItemProperty -LiteralPath $k -ErrorAction Stop).Calibration
            if ($b -is [byte[]] -and $b.Length -ge 12) {
                $entry.Stored = $true; $entry.Bytes = $b
                $entry.Min = [BitConverter]::ToInt32($b, 0); $entry.Centre = [BitConverter]::ToInt32($b, 4); $entry.Max = [BitConverter]::ToInt32($b, 8)
            }
        } catch { }
        $slots += $entry
    }
    return ,$slots
}

function Get-AlphaCalibrationVerdict {
    param([double] $Limit = 3.0)
    $r = Read-AlphaCentred
    if ($null -eq $r) {
        return [pscustomobject]@{ Found = $false; Ok = $false; Reading = $null
            Detail = 'Windows does not list the Alpha as a joystick, so its centre cannot be read.'
            Remedy = 'Plug the yoke in. If it is plugged in, unplug it, wait a few seconds, and plug it back in.' }
    }
    $worst = [math]::Max([math]::Abs($r.RollPercent), [math]::Abs($r.PitchPercent))
    $ok = $worst -le $Limit
    $names = Get-AlphaAxisNames
    $how = if ($r.AxesMeasured) { '' } else { ' (roll and pitch by convention until the first recalibration measures them)' }
    $spread = ''
    if ($null -ne $names.SpreadPitch) { $spread = '; on its own it settles within roll +/-{0}%, pitch +/-{1}%' -f $names.SpreadRoll, $names.SpreadPitch }
    $detail = 'At rest, as the simulator sees it: roll {0:+0.0;-0.0}%, pitch {1:+0.0;-0.0}% off centre, limit {2}%{3}{4}' -f $r.RollPercent, $r.PitchPercent, $Limit, $spread, $how
    $remedy = if ($ok) { '' } else {
        $mech = $null -ne $names.SpreadPitch -and ([math]::Abs($r.PitchPercent) -le $names.SpreadPitch + 0.6) -and ([math]::Abs($r.RollPercent) -le $names.SpreadRoll + 0.6)
        if ($mech) {
            'The yoke is off centre, but no further than it settles on its own after moving - that is the yoke''s centring mechanism, and a recalibration cannot narrow it. Turn and push the yoke through its travel, let it go, and this will read differently. If it is often this far off, that is what the yoke does.'
        } else {
            'The yoke is not reading centred with hands off, so the simulator flies it as if it were being held that way. Press "Recalibrate the Alpha" in the launcher and follow the window that opens: hands off first, then turn and push the yoke through its full travel.'
        }
    }
    return [pscustomobject]@{ Found = $true; Ok = $ok; Reading = $r; Detail = $detail; Remedy = $remedy }
}

if ($Library) { return }

$v = Get-AlphaCalibrationVerdict -Limit $LimitPercent
$store = Get-AlphaCalibrationStore
if ($Json) {
    $out = [ordered]@{
        found = $v.Found; ok = $v.Ok; detail = $v.Detail; remedy = $v.Remedy; limitPercent = $LimitPercent
        reading = $v.Reading
        stored = @($store | ForEach-Object { [ordered]@{ slot = $_.Slot; axis = $_.Axis; stored = $_.Stored; min = $_.Min; centre = $_.Centre; max = $_.Max } })
    }
    [System.IO.File]::WriteAllText($Json, (($out | ConvertTo-Json -Depth 6) + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
}
if (-not $v.Found) { Write-Host $v.Detail -ForegroundColor Red; exit 2 }
Write-Host $v.Detail -ForegroundColor $(if ($v.Ok) { 'Green' } else { 'Yellow' })
foreach ($s in $store) {
    Write-Host ('   stored for {0} (slot {1}): min {2}, centre {3}, max {4}{5}' -f $s.Axis, $s.Slot, $s.Min, $s.Centre, $s.Max, $(if ($s.Stored) { '' } else { '  (nothing stored; the pot range is used)' })) -ForegroundColor DarkGray
}
if (-not $v.Ok) { Write-Host $v.Remedy -ForegroundColor Yellow; exit 1 }
exit 0
