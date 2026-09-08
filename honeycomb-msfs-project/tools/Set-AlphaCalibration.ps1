<#
.SYNOPSIS
    Recalibrates the Alpha yoke: measures where its pots really rest and reach,
    and stores that where Windows keeps the calibration the simulator uses.

.DESCRIPTION
    Guided, in a console window. Three measurements, each from the raw USB
    report of the yoke (nothing calibrated in between):

      1. Hands off: the resting value of both pots, sampled for three seconds
         and required to be steady. That is the new CENTRE.
      2. Roll only: turn the yoke fully left and fully right. Exactly one pot
         must move, and that pot IS the roll pot - measured, not assumed. Its
         lowest and highest values are the new MIN and MAX.
      3. Pitch only: push fully forward and pull fully back. The other pot must
         be the one that moves.

    Then it writes the three numbers for each pot into the registry slot Windows
    reads them from (slot 0 = X, slot 1 = Y - measured 2026-09-07 by writing a
    centre into slot 1 and watching the pitch reading move), after saving what
    was there to a backup file, and reads the calibrated result back from a
    fresh process so the "after" numbers are what the simulator will get.

    Programs that already have the yoke open keep the old calibration until
    they open it again. The launcher closes FSUIPC before running this and
    starts it again after; the simulator, if running, must be restarted.

.PARAMETER Restore
    Path of a backup file written by an earlier run. Puts those bytes back and
    verifies. For undoing a recalibration.
.PARAMETER RegistryKey
    Where the calibration slots live. The default is the Alpha's. Overridden
    only by the self-test, which writes to a scratch key.
.PARAMETER Library
    Define the functions and stop; for the self-test.
#>
[CmdletBinding()]
param(
    [string] $Restore = '',
    [string] $RegistryKey = '',
    [switch] $Library
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
# Remembered BEFORE the dot-sourcing below: a dot-sourced script's parameters
# land as variables in THIS scope, so ". probe -Library" sets $Library here
# to $true and this script would then stop at its own library gate, every
# time, silently, with exit code 0 (2026-09-07: the first press of
# "Recalibrate the Alpha" did exactly that).
$runAsLibrary = [bool]$Library
$wantRegistryKey = $RegistryKey
. (Join-Path $here 'Probe-HoneycombDevices.ps1') -Library
. (Join-Path $here 'Test-AlphaCalibration.ps1') -Library
$RegistryKey = if ($wantRegistryKey) { $wantRegistryKey } else { $script:AlphaCalibrationKey }

$BackupDir = Join-Path $env:LOCALAPPDATA 'HoneycombAssignment'
$Slots = @{ X = 0; Y = 1 }

function Write-Line { param([string] $Text = '', [string] $Color = 'Gray') Write-Host $Text -ForegroundColor $Color }

function ConvertTo-CalibrationBytes {
    param([int] $Min, [int] $Centre, [int] $Max)
    $b = New-Object byte[] 12
    [BitConverter]::GetBytes($Min).CopyTo($b, 0); [BitConverter]::GetBytes($Centre).CopyTo($b, 4); [BitConverter]::GetBytes($Max).CopyTo($b, 8)
    return ,$b
}

function Read-SlotBytes {
    param([int] $Slot)
    try { $b = (Get-ItemProperty -LiteralPath (Join-Path $RegistryKey ([string]$Slot)) -ErrorAction Stop).Calibration; if ($b -is [byte[]]) { return ,$b } } catch { }
    return $null
}

function Write-SlotBytes {
    param([int] $Slot, [byte[]] $Bytes)
    $k = Join-Path $RegistryKey ([string]$Slot)
    if (-not (Test-Path -LiteralPath $k)) { $null = New-Item -Path $k -Force }
    Set-ItemProperty -LiteralPath $k -Name Calibration -Value $Bytes -Type Binary
    $back = (Get-ItemProperty -LiteralPath $k).Calibration
    if (-not $back -or ($back -join ',') -ne ($Bytes -join ',')) { throw "slot $Slot did not read back what was written" }
}

function Read-CentredFresh {
    # The calibrated reading from a NEW process, because a process keeps the
    # calibration it loaded when it opened the yoke.
    $tmp = Join-Path $env:TEMP ('alpha-centred-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'Test-AlphaCalibration.ps1') -Json $tmp | Out-Null
        if (Test-Path -LiteralPath $tmp) { return (Get-Content -LiteralPath $tmp -Raw | ConvertFrom-Json) }
    } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } }
    return $null
}

function Open-AlphaRaw {
    $dev = @(Get-CandidateDevices | Where-Object { $_.Path -match '(?i)VID_294B&PID_1900' } | Select-Object -First 1)
    if ($dev.Count -eq 0) { return $null }
    return [Honeycomb.HidDevice]::Open($dev[0].Path)
}

function Get-RawSamples {
    <#
        Raw X and Y from the yoke's own reports, for a fixed time or until a
        key. The yoke reports on every change and about once a second at rest.
        Returns @{ Samples = list of @{X;Y}; Key = the key pressed or $null }.
    #>
    param($Device, [double] $Seconds = 0, [switch] $UntilKey)
    $list = New-Object System.Collections.Generic.List[object]
    $t0 = Get-Date; $key = $null
    while ($true) {
        if ($UntilKey) {
            $k = Read-ConsoleKey -IfAvailable
            if ($null -ne $k) { $key = $k; break }
        }
        elseif (((Get-Date) - $t0).TotalSeconds -ge $Seconds) { break }
        $r = $Device.TryRead(150)
        if ($null -eq $r) { continue }
        $s = ConvertTo-DeviceState -Device $Device -Report $r
        if (-not $s.Axes.Contains('X') -or -not $s.Axes.Contains('Y')) { continue }
        $list.Add(@{ X = [int]$s.Axes['X'].Value; Y = [int]$s.Axes['Y'].Value })
    }
    return @{ Samples = $list; Key = $key }
}

function Get-Range { param($Samples, [string] $Axis) $v = @($Samples | ForEach-Object { $_[$Axis] }); if ($v.Count -eq 0) { return $null }; $s = @($v | Sort-Object); return @{ Min = $s[0]; Max = $s[-1]; Median = $s[[int][math]::Floor($s.Count / 2)]; Count = $s.Count } }

function Wait-Enter {
    # ENTER continues, Q stops. Anything else is ignored.
    while ($true) {
        $k = Read-ConsoleKey
        if ($null -eq $k) { return $false }
        if ($k.Key -eq 'Q') { return $false }
        if ($k.Key -eq 'Enter') { return $true }
    }
}

function Invoke-Recalibration {
    <#
        The whole guided run. $Device is the open raw yoke. Returns 0 done,
        1 stopped or failed, and says why on the console.
    #>
    param($Device)

    Write-Line ''
    Write-Line 'Recalibrating the Alpha yoke.' Cyan
    Write-Line 'Three measurements, ENTER after each. Q at any prompt stops without changing anything.' Cyan
    Write-Line ''

    $before = Read-CentredFresh
    if ($null -ne $before -and $before.found) {
        Write-Line ('Before: roll {0:+0.0;-0.0}%, pitch {1:+0.0;-0.0}% off centre with hands off, as the simulator sees it.' -f $before.reading.RollPercent, $before.reading.PitchPercent) DarkGray
    }

    # ---- 1. centre ----------------------------------------------------------
    $centre = $null
    while ($null -eq $centre) {
        Write-Line '1. Let go of the yoke completely and keep your hands off it. Then press ENTER.' Yellow
        if (-not (Wait-Enter)) { Write-Line 'Stopped. Nothing was changed.' Yellow; return 1 }
        Write-Line '   measuring for three seconds - hands off...' DarkGray
        $r = Get-RawSamples -Device $Device -Seconds 3
        $rx = Get-Range $r.Samples 'X'; $ry = Get-Range $r.Samples 'Y'
        if ($null -eq $rx -or $rx.Count -lt 2) { Write-Line '   the yoke sent nothing in three seconds. Is it plugged in? Trying again.' Red; continue }
        if (($rx.Max - $rx.Min) -gt 6 -or ($ry.Max - $ry.Min) -gt 6) {
            Write-Line ('   it was moving (X {0}-{1}, Y {2}-{3}). Hands off, and let it settle. Trying again.' -f $rx.Min, $rx.Max, $ry.Min, $ry.Max) Red
            continue
        }
        $centre = @{ X = $rx.Median; Y = $ry.Median }
        Write-Line ('   at rest: X {0}, Y {1}  (of 0 to 1023)' -f $centre.X, $centre.Y) Green
    }

    # ---- 2 and 3. the sweeps, which also say which pot is which ---------------
    $sweep = @{}
    foreach ($step in @(
        @{ N = 2; Name = 'roll';  Ask = 'Turn the yoke fully LEFT, then fully RIGHT, slowly, twice. Do not push or pull it. Let it settle, then press ENTER.' },
        @{ N = 3; Name = 'pitch'; Ask = 'Push the yoke fully FORWARD, then pull it fully BACK, slowly, twice. Do not turn it. Let it settle, then press ENTER.' }
    )) {
        while (-not $sweep.ContainsKey($step.Name)) {
            Write-Line ('{0}. {1}' -f $step.N, $step.Ask) Yellow
            Write-Line '   measuring until you press ENTER...' DarkGray
            $r = Get-RawSamples -Device $Device -UntilKey
            if ($null -eq $r.Key -or $r.Key.Key -eq 'Q') { Write-Line 'Stopped. Nothing was changed.' Yellow; return 1 }
            $rx = Get-Range $r.Samples 'X'; $ry = Get-Range $r.Samples 'Y'
            if ($null -eq $rx) { Write-Line '   the yoke sent nothing. Move it through its full travel, then press ENTER.' Red; continue }
            $span = @{ X = $rx.Max - $rx.Min; Y = $ry.Max - $ry.Min }
            $moved = @($span.Keys | Where-Object { $span[$_] -ge 600 })
            $still = @($span.Keys | Where-Object { $span[$_] -le 80 })
            if ($moved.Count -ne 1 -or $still.Count -ne 1) {
                Write-Line ('   X moved {0} of 1023, Y moved {1}. Exactly one should travel most of its range and the other stay put. Trying again.' -f $span.X, $span.Y) Red
                continue
            }
            $axis = $moved[0]
            $other = @($sweep.Values | ForEach-Object { $_.Axis })
            if ($other -contains $axis) {
                Write-Line ('   that moved the same pot as the {0} sweep did ({1}). Only the other movement, please. Trying again.' -f $sweep.Keys[0], $axis) Red
                continue
            }
            $rng = if ($axis -eq 'X') { $rx } else { $ry }
            if ($centre[$axis] -le $rng.Min + 100 -or $centre[$axis] -ge $rng.Max - 100) {
                Write-Line ('   the resting value ({0}) is not between the ends seen ({1} to {2}). Was it at rest in step 1? Starting over.' -f $centre[$axis], $rng.Min, $rng.Max) Red
                return 1
            }
            $sweep[$step.Name] = @{ Axis = $axis; Min = $rng.Min; Max = $rng.Max; Centre = $centre[$axis] }
            Write-Line ('   {0} is pot {1}: {2} to {3}, rests at {4}' -f $step.Name, $axis, $rng.Min, $rng.Max, $centre[$axis]) Green
        }
    }

    # ---- write ---------------------------------------------------------------
    Write-Line ''
    Write-Line 'Storing:' Cyan
    $old = @{}; $new = @{}
    foreach ($name in @('roll', 'pitch')) {
        $s = $sweep[$name]; $slot = $Slots[$s.Axis]
        $ob = Read-SlotBytes -Slot $slot
        $old[$s.Axis] = $(if ($ob) { ($ob | ForEach-Object { $_.ToString('x2') }) -join ' ' } else { '' })
        $oldTxt = if ($ob) { 'min {0}, centre {1}, max {2}' -f [BitConverter]::ToInt32($ob, 0), [BitConverter]::ToInt32($ob, 4), [BitConverter]::ToInt32($ob, 8) } else { 'nothing stored' }
        $new[$s.Axis] = @{ Min = $s.Min; Centre = $s.Centre; Max = $s.Max }
        Write-Line ('   {0,-5} pot {1} slot {2}:  was {3}  ->  min {4}, centre {5}, max {6}' -f $name, $s.Axis, $slot, $oldTxt, $s.Min, $s.Centre, $s.Max)
    }
    $null = New-Item -ItemType Directory -Force -Path $BackupDir
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path $BackupDir ('alpha-calibration-backup-' + $stamp + '.json')
    $rec = [ordered]@{
        written = (Get-Date).ToString('s'); registryKey = $RegistryKey; machine = $env:COMPUTERNAME
        note = 'Bytes as they were before this recalibration, per slot (hex, or empty when nothing was stored). Restore with: Set-AlphaCalibration.ps1 -Restore <this file>'
        before = [ordered]@{ '0' = $old['X']; '1' = $old['Y'] }
        after  = [ordered]@{ X = $new['X']; Y = $new['Y'] }
        axes   = [ordered]@{ roll = $sweep.roll.Axis; pitch = $sweep.pitch.Axis }
    }
    [System.IO.File]::WriteAllText($backup, (($rec | ConvertTo-Json -Depth 5) + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Line ('   backup of the old values: {0}' -f $backup) DarkGray

    foreach ($axis in @('X', 'Y')) { Write-SlotBytes -Slot $Slots[$axis] -Bytes (ConvertTo-CalibrationBytes -Min $new[$axis].Min -Centre $new[$axis].Centre -Max $new[$axis].Max) }
    Write-Line '   written and read back.' Green

    # Which pot is which, measured, for the check's labels.
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:AlphaAxesFile)
    [System.IO.File]::WriteAllText($script:AlphaAxesFile, (([ordered]@{ roll = $sweep.roll.Axis; pitch = $sweep.pitch.Axis; measured = (Get-Date).ToString('s'); how = 'Set-AlphaCalibration sweep: the one pot that moved when the yoke was only turned, and the one that moved when it was only pushed and pulled' } | ConvertTo-Json) + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))

    # ---- verify from a fresh process -----------------------------------------
    Write-Line ''
    Write-Line 'Hands off again for the check...' DarkGray
    Start-Sleep -Milliseconds 800
    $after = Read-CentredFresh
    if ($null -eq $after -or -not $after.found) { Write-Line 'Could not read the result back. The values are stored; the launcher will show the centre on its next check.' Yellow; return 0 }
    $rp = [double]$after.reading.RollPercent; $pp = [double]$after.reading.PitchPercent
    $line = 'After: roll {0:+0.0;-0.0}%, pitch {1:+0.0;-0.0}% off centre with hands off, as the simulator will see it.' -f $rp, $pp
    if ([math]::Abs($rp) -le 1.0 -and [math]::Abs($pp) -le 1.0) { Write-Line $line Green }
    else { Write-Line $line Yellow; Write-Line '   Not centred. If a hand was on the yoke during the check, run this again; if not, the pot may be moving on its own - run it again and compare.' Yellow }
    Write-Line ''
    Write-Line 'Anything that already had the yoke open keeps the old calibration until it opens the yoke again. The launcher restarts FSUIPC for you; if the simulator is running, restart it.' Cyan
    return 0
}

function Invoke-Restore {
    param([string] $Path)
    $rec = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    foreach ($slot in @('0', '1')) {
        $hex = [string]$rec.before.$slot
        if (-not $hex) {
            $k = Join-Path $RegistryKey $slot
            if (Test-Path -LiteralPath $k) { Remove-ItemProperty -LiteralPath $k -Name Calibration -ErrorAction SilentlyContinue }
            Write-Line ('slot {0}: nothing was stored before; the stored value is removed' -f $slot)
            continue
        }
        $bytes = [byte[]]@($hex -split ' ' | ForEach-Object { [Convert]::ToByte($_, 16) })
        Write-SlotBytes -Slot ([int]$slot) -Bytes $bytes
        Write-Line ('slot {0}: restored min {1}, centre {2}, max {3}' -f $slot, [BitConverter]::ToInt32($bytes, 0), [BitConverter]::ToInt32($bytes, 4), [BitConverter]::ToInt32($bytes, 8)) Green
    }
    return 0
}

if ($runAsLibrary) { return }

if ($Restore) {
    if (-not (Test-Path -LiteralPath $Restore)) { Write-Line "No backup file at $Restore" Red; exit 1 }
    exit (Invoke-Restore -Path $Restore)
}

# Everything this window shows is also written to a log, so a run that went
# wrong can be read afterwards instead of retold (2026-09-07: the first run
# from the launcher closed in seconds with nothing to read).
$logDir = Join-Path $env:LOCALAPPDATA 'HoneycombAssignment\logs'
$null = New-Item -ItemType Directory -Force -Path $logDir
$logPath = Join-Path $logDir ('recalibrate-alpha-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
try { Start-Transcript -LiteralPath $logPath | Out-Null } catch { }
Write-Line ('Log: {0}' -f $logPath) DarkGray

if (-not (Test-ConsoleInput)) {
    Write-Line 'This needs a PowerShell window of its own: keyboard input is not available here.' Red
    Write-Line 'Press ENTER to close this window.' DarkGray; $null = Read-ConsoleKey
    exit 2
}
$device = Open-AlphaRaw
if ($null -eq $device) {
    Write-Line 'The Alpha is not plugged in, or Windows cannot open it. Plug it in and run this again.' Red
    Write-Line 'Press ENTER to close this window.' DarkGray; $null = Read-ConsoleKey
    exit 2
}
$rc = 1
try { $rc = [int](Invoke-Recalibration -Device $device) }
catch { Write-Line ('Failed: ' + $_.Exception.Message) Red; Write-Line ('   at ' + $_.ScriptStackTrace) DarkGray; $rc = 1 }
finally { $device.Dispose() }
Write-Line ''
Write-Line ('Finished with code {0}. Press ENTER to close this window.' -f $rc) DarkGray
$null = Read-ConsoleKey
try { Stop-Transcript | Out-Null } catch { }
exit $rc
