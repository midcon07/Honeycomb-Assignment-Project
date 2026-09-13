<#
.SYNOPSIS
    Runs the Alpha recalibration against scripted hands and a scratch
    registry key, and checks what it wrote and said.

.DESCRIPTION
    Set-AlphaCalibration.ps1 reads the yoke's raw pots and the keyboard, and
    writes Windows' calibration store. Here all three are stood in for: the
    pots by scripted samples (hands off, a roll sweep, a pitch sweep), the
    keyboard by scripted keys, the store by a key under HKCU:\Software that is
    deleted afterwards. The real yoke's calibration is never touched.

    Scenarios: a clean run; a yoke wired the other way round (the pot that
    moves when turned is Y) to prove the identity is measured not assumed;
    the mistakes the prompts are written for (hands on during the rest
    measurement, both axes moved in one sweep, the same pot swept twice);
    Q at each prompt; and -Restore putting a backup back.

    Exit 0 when every check passes, 1 otherwise.
#>
[CmdletBinding()]
param([switch] $Show)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$ScratchKey = 'HKCU:\Software\HoneycombAssignmentSelfTest\Calibration\Axes'
$work = Join-Path $env:TEMP ('hc-cal-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Force -Path $work

. (Join-Path $here 'Set-AlphaCalibration.ps1') -Library -RegistryKey $ScratchKey
# Both files publish paths in this scope now; point them at scratch.
$script:AlphaAxesFile = Join-Path $work 'alpha-axes.json'
$BackupDir = $work

function Out-Line { param([string] $Text, [string] $Color = 'Gray') Microsoft.PowerShell.Utility\Write-Host $Text -ForegroundColor $Color }

# ---- stand-ins --------------------------------------------------------------
$Fake = @{ Out = New-Object System.Collections.Generic.List[string]; Calls = New-Object System.Collections.Generic.List[object]; Keys = New-Object System.Collections.Generic.Queue[string]; After = $null }
function Write-Host { param([Parameter(Position = 0)] $Object = '', $ForegroundColor = $null, [switch] $NoNewline) $Fake.Out.Add([string]$Object); if ($Show) { Microsoft.PowerShell.Utility\Write-Host ([string]$Object) } }
function Read-ConsoleKey { param([switch] $IfAvailable) if ($Fake.Keys.Count -eq 0) { throw 'hands ran out of keys' }; return [pscustomobject]@{ Key = [ConsoleKey]$Fake.Keys.Dequeue() } }
function Get-RawSamples {
    # Each call hands back the next scripted measurement.
    param($Device, [double] $Seconds = 0, [switch] $UntilKey)
    if ($Fake.Calls.Count -eq 0) { throw 'hands ran out of measurements' }
    $m = $Fake.Calls[0]; $Fake.Calls.RemoveAt(0)
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($s in $m.Samples) { $list.Add(@{ X = [int]$s[0]; Y = [int]$s[1] }) }
    $key = $null
    if ($UntilKey) { $key = [pscustomobject]@{ Key = [ConsoleKey]$m.Key } }
    return @{ Samples = $list; Key = $key }
}
function Read-CentredFresh { return $Fake.After }
function Start-Sleep { param([int] $Milliseconds = 0) }

function Reset-Fake {
    $Fake.Out.Clear(); $Fake.Calls.Clear(); $Fake.Keys.Clear()
    $Fake.After = [pscustomobject]@{ found = $true; reading = [pscustomobject]@{ RollPercent = 0.0; PitchPercent = -0.1 } }
    if (Test-Path $ScratchKey) { Remove-Item -LiteralPath (Split-Path (Split-Path $ScratchKey -Parent) -Parent) -Recurse -Force }
    if (Test-Path -LiteralPath $script:AlphaAxesFile) { Remove-Item -LiteralPath $script:AlphaAxesFile -Force }
    Get-ChildItem $work -Filter 'alpha-calibration-backup-*.json' | Remove-Item -Force
}
function Rest    { param([int] $X, [int] $Y, [int] $Wobble = 0) $x2 = $X + $Wobble; $y2 = $Y - $Wobble; @{ Samples = @(@($X, $Y), @($x2, $Y), @($X, $y2)); Key = 'Enter' } }
function Sweep   { param([string] $Axis, [int] $Lo, [int] $Hi, [int] $RestX, [int] $RestY, [string] $Key = 'Enter')
    $pts = @()
    foreach ($v in @($RestX, $Lo, $RestX, $Hi, $RestX)) { if ($Axis -eq 'X') { $pts += ,@($v, $RestY) } }
    foreach ($v in @($RestY, $Lo, $RestY, $Hi, $RestY)) { if ($Axis -eq 'Y') { $pts += ,@($RestX, $v) } }
    @{ Samples = $pts; Key = $Key }
}
function Both    { param([int] $RestX, [int] $RestY) @{ Samples = @(@($RestX, $RestY), @(30, 40), @(1000, 990), @($RestX, $RestY)); Key = 'Enter' } }
function Slot    { param([int] $N) try { $b = (Get-ItemProperty -LiteralPath (Join-Path $ScratchKey ([string]$N)) -ErrorAction Stop).Calibration; if ($b -is [byte[]]) { return @([BitConverter]::ToInt32($b, 0), [BitConverter]::ToInt32($b, 4), [BitConverter]::ToInt32($b, 8)) } } catch { }; return $null }

$script:Failures = New-Object System.Collections.Generic.List[string]; $script:Checks = 0
function Check { param([bool] $Ok, [string] $What) $script:Checks++; if (-not $Ok) { $script:Failures.Add($What); Out-Line ('   FAIL: ' + $What) Red } }
function Said { param([string] $Pattern) return [bool]($Fake.Out | Where-Object { $_ -match $Pattern } | Select-Object -First 1) }
function SaidCount { param([string] $Pattern) return @($Fake.Out | Where-Object { $_ -match $Pattern }).Count }

$Scenarios = [ordered]@{}

$Scenarios['clean'] = {
    Reset-Fake
    $Fake.Keys.Enqueue('Enter'); $Fake.Keys.Enqueue('Enter'); $Fake.Keys.Enqueue('Enter')   # steps 1, 4, 5
    $Fake.Calls.Add((Rest 511 495 2))                          # hands off, tiny wobble
    $Fake.Calls.Add((Sweep X 20 1010 511 495))                 # roll: X moves
    $Fake.Calls.Add((Sweep Y 15 1005 511 495))                 # pitch: Y moves
    $Fake.Calls.Add((Rest 509 492))                            # settled from forward-left
    $Fake.Calls.Add((Rest 513 508))                            # settled from back-right
    $rc = Invoke-Recalibration -Device $null
    Check ($rc -eq 0) "rc 0 (was $rc)"
    $s0 = Slot 0; $s1 = Slot 1
    Check ($null -ne $s0 -and ($s0 -join ',') -eq '20,511,1010') "slot 0 (X) = 20/511/1010 (midpoint of 509 and 513), is $($s0 -join '/')"
    Check ($null -ne $s1 -and ($s1 -join ',') -eq '15,500,1005') "slot 1 (Y) = 15/500/1005 (midpoint of 492 and 508, not the first rest 495), is $($s1 -join '/')"
    $axes = Get-Content -LiteralPath $script:AlphaAxesFile -Raw | ConvertFrom-Json
    Check ($axes.roll -eq 'X' -and $axes.pitch -eq 'Y') 'axes file says roll X, pitch Y'
    Check ($axes.settleSpreadPercent.roll -eq 0.4 -and $axes.settleSpreadPercent.pitch -eq 1.6) "axes file records the settling spread (roll 0.4, pitch 1.6; is $($axes.settleSpreadPercent.roll), $($axes.settleSpreadPercent.pitch))"
    Check (Said 'pot Y: settles between 492 and 508') 'says where pitch settles'
    Check (Said 'Within the yoke') 'after reading judged against the spread'
    $bk = @(Get-ChildItem $work -Filter 'alpha-calibration-backup-*.json')
    Check ($bk.Count -eq 1) 'one backup written'
    if ($bk.Count -eq 1) {
        $b = Get-Content -LiteralPath $bk[0].FullName -Raw | ConvertFrom-Json
        Check ($b.before.'0' -eq '' -and $b.before.'1' -eq '') 'backup records that nothing was stored before'
        Check ($b.after.X.Centre -eq 511 -and $b.after.Y.Centre -eq 500) 'backup records the new centres'
        Check ($b.registryKey -eq $ScratchKey) 'backup names the key it wrote'
    }
    Check (Said 'roll is pot X: 20 to 1010, rests at 511') 'says which pot roll is'
    Check (Said 'pitch is pot Y: 15 to 1005, rests at 495') 'says which pot pitch is'
    Check (Said 'written and read back') 'says written'
    Check (Said 'After: roll \+0\.0%, pitch -0\.1%') 'shows the after reading'
    Check (-not (Said 'Trying again|Starting over|Stopped')) 'no complaint on a clean run'
    Check ($Fake.Calls.Count -eq 0 -and $Fake.Keys.Count -eq 0) 'hands used every step'
}

$Scenarios['wired-the-other-way'] = {
    # Turning the yoke moves pot Y on this unit. The identity must follow the
    # measurement: roll's numbers land in slot 1.
    Reset-Fake
    $Fake.Keys.Enqueue('Enter'); $Fake.Keys.Enqueue('Enter'); $Fake.Keys.Enqueue('Enter')
    $Fake.Calls.Add((Rest 480 530))
    $Fake.Calls.Add((Sweep Y 10 1000 480 530))                 # roll sweep moves Y
    $Fake.Calls.Add((Sweep X 25 1015 480 530))                 # pitch sweep moves X
    $Fake.Calls.Add((Rest 478 528)); $Fake.Calls.Add((Rest 482 532))
    $rc = Invoke-Recalibration -Device $null
    Check ($rc -eq 0) "rc 0 (was $rc)"
    Check (((Slot 1) -join ',') -eq '10,530,1000') "slot 1 (Y) holds roll's numbers 10/530/1000, is $((Slot 1) -join '/')"
    Check (((Slot 0) -join ',') -eq '25,480,1015') "slot 0 (X) holds pitch's numbers 25/480/1015, is $((Slot 0) -join '/')"
    $axes = Get-Content -LiteralPath $script:AlphaAxesFile -Raw | ConvertFrom-Json
    Check ($axes.roll -eq 'Y' -and $axes.pitch -eq 'X') 'axes file says roll Y, pitch X'
    Check (Said 'roll is pot Y') 'says roll is pot Y'
}

$Scenarios['mistakes'] = {
    Reset-Fake
    foreach ($k in 1..5) { $Fake.Keys.Enqueue('Enter') }       # step 1 twice, step 4 twice, step 5
    $Fake.Calls.Add(@{ Samples = @(@(511, 500), @(560, 500), @(511, 470)); Key = 'Enter' })   # hands on: moving
    $Fake.Calls.Add((Rest 511 500))                            # then still
    $Fake.Calls.Add((Both 511 500))                            # roll sweep: both moved
    $Fake.Calls.Add((Sweep X 20 1010 511 500))                 # roll proper
    $Fake.Calls.Add((Sweep X 22 1008 511 500))                 # pitch sweep: same pot again
    $Fake.Calls.Add((Sweep Y 15 1005 511 500))                 # pitch proper
    $Fake.Calls.Add(@{ Samples = @(@(511, 500), @(511, 530), @(511, 500)); Key = 'Enter' })   # step 4 with a hand on it
    $Fake.Calls.Add((Rest 511 500)); $Fake.Calls.Add((Rest 511 500))
    $rc = Invoke-Recalibration -Device $null
    Check ($rc -eq 0) "rc 0 (was $rc)"
    Check ((SaidCount 'it was moving') -eq 2) 'hands-on rest reported at step 1 and step 4'
    Check ((SaidCount 'Exactly one should travel') -eq 1) 'both-moved sweep reported once'
    Check ((SaidCount 'moved the same pot') -eq 1) 'same-pot sweep reported once'
    Check (((Slot 0) -join ',') -eq '20,511,1010' -and ((Slot 1) -join ',') -eq '15,500,1005') 'stored the proper sweeps, not the mistaken ones'
    Check ($Fake.Calls.Count -eq 0 -and $Fake.Keys.Count -eq 0) 'hands used every step'
}

$Scenarios['rest-not-between-ends'] = {
    # Hands were on the yoke at step 1: the "rest" is beyond a sweep's end.
    Reset-Fake
    $Fake.Keys.Enqueue('Enter')
    $Fake.Calls.Add((Rest 990 500))
    $Fake.Calls.Add((Sweep X 20 1010 990 500))
    $rc = Invoke-Recalibration -Device $null
    Check ($rc -eq 1) "rc 1 (was $rc)"
    Check (Said 'not between the ends seen') 'says the rest is not between the ends'
    Check ($null -eq (Slot 0) -and $null -eq (Slot 1)) 'nothing written'
}

$Scenarios['quit'] = {
    Reset-Fake
    $Fake.Keys.Enqueue('Q')
    $rc = Invoke-Recalibration -Device $null
    Check ($rc -eq 1 -and (Said 'Stopped. Nothing was changed')) 'Q at step 1 stops with nothing changed'
    Reset-Fake
    $Fake.Keys.Enqueue('Enter')
    $Fake.Calls.Add((Rest 511 500))
    $Fake.Calls.Add((Sweep X 20 1010 511 500 'Q'))
    $rc = Invoke-Recalibration -Device $null
    Check ($rc -eq 1 -and (Said 'Stopped. Nothing was changed') -and $null -eq (Slot 0)) 'Q during a sweep stops with nothing written'
}

$Scenarios['restore'] = {
    Reset-Fake
    # Something stored beforehand, so the backup has bytes to put back.
    Write-SlotBytes -Slot 0 -Bytes (ConvertTo-CalibrationBytes -Min 1 -Centre 500 -Max 1020)
    $Fake.Keys.Enqueue('Enter'); $Fake.Keys.Enqueue('Enter'); $Fake.Keys.Enqueue('Enter')
    $Fake.Calls.Add((Rest 511 500)); $Fake.Calls.Add((Sweep X 20 1010 511 500)); $Fake.Calls.Add((Sweep Y 15 1005 511 500))
    $Fake.Calls.Add((Rest 511 500)); $Fake.Calls.Add((Rest 511 500))
    $rc = Invoke-Recalibration -Device $null
    Check ($rc -eq 0 -and ((Slot 0) -join ',') -eq '20,511,1010') 'recalibrated over the stored value'
    $bk = @(Get-ChildItem $work -Filter 'alpha-calibration-backup-*.json')
    $rc = Invoke-Restore -Path $bk[0].FullName
    Check ($rc -eq 0) "restore rc 0 (was $rc)"
    Check (((Slot 0) -join ',') -eq '1,500,1020') "slot 0 back to 1/500/1020, is $((Slot 0) -join '/')"
    Check ($null -eq (Slot 1)) 'slot 1, which had nothing before, has nothing again'
}

$Scenarios['entry-point'] = {
    # The tool as a real process, the way the launcher starts it, with no
    # keyboard: it must get as far as saying so (exit 2), not return quietly
    # from a library gate (exit 0 with nothing said - the 2026-09-07 fault,
    # which every dot-sourced test masked).
    $tool = Join-Path $here 'Set-AlphaCalibration.ps1'
    $outFile = Join-Path $work 'entry.txt'
    $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" < nul > "{1}" 2>&1' -f $tool, $outFile
    & cmd.exe /c $cmd
    $code = $LASTEXITCODE
    $text = if (Test-Path -LiteralPath $outFile) { Get-Content -LiteralPath $outFile -Raw } else { '' }
    Check ($code -eq 2) "exit code 2 without a keyboard (was $code)"
    Check ($text -match 'Log: ') 'says where its log is'
    Check ($text -match 'PowerShell window of its own') 'says it needs a window'
}

foreach ($n in $Scenarios.Keys) {
    Out-Line ('== ' + $n) Cyan
    $before = $script:Failures.Count
    try { & $Scenarios[$n] } catch { $script:Failures.Add("$n threw: $($_.Exception.Message)"); Out-Line ('   THREW: ' + $_.Exception.Message + ' | ' + (($_.ScriptStackTrace -split "`n" | Select-Object -First 2) -join ' | ')) Red }
    if ($script:Failures.Count -eq $before) { Out-Line '   ok' Green }
}
if (Test-Path 'HKCU:\Software\HoneycombAssignmentSelfTest') { Remove-Item -LiteralPath 'HKCU:\Software\HoneycombAssignmentSelfTest' -Recurse -Force }
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
if ($script:Failures.Count -eq 0) { Out-Line ("All {0} checks passed." -f $script:Checks) Green; exit 0 }
Out-Line ("{0} of {1} checks FAILED:" -f $script:Failures.Count, $script:Checks) Red
$script:Failures | ForEach-Object { Out-Line ('  - ' + $_) Red }
exit 1
