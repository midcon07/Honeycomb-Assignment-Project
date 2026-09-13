<#
.SYNOPSIS
    Proves the fenced writers: the [Buttons] merge and the presets block,
    then the real button writer against a scratch copy of this machine's ini.

.DESCRIPTION
    Audit 2026-09-05, findings 1 and 2: the button writer replaced the whole
    global [Buttons] section and the presets file was copied over. The fix is
    FsuipcIni.ps1, and this is how it is known to work:

      - unit scenarios on Merge-FsuipcButtons and Merge-PresetBlock, with
        line shapes taken from a real ini (press, release, repeat,
        conditional, presets, FSUIPC's -{NAME}- annotations, numeric
        joysticks, comments, gaps in numbering);
      - one end-to-end run of Set-BravoButtons.ps1 against a scratch folder
        holding a copy of C:\FSUIPC7\FSUIPC7.ini with a user's own lines
        added, and a myevents.txt with a user's own preset. The real
        FSUIPC7.ini is never touched.

    Exit 0 when every check passes, 1 otherwise.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'FsuipcIni.ps1')

$work = Join-Path $env:TEMP ('hc-ini-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Force -Path $work

$script:Failures = New-Object System.Collections.Generic.List[string]; $script:Checks = 0
function Out-Line { param([string] $Text, [string] $Color = 'Gray') Write-Host $Text -ForegroundColor $Color }
function Check { param([bool] $Ok, [string] $What) $script:Checks++; if (-not $Ok) { $script:Failures.Add($What); Out-Line ('   FAIL: ' + $What) Red } }

$ours = @(
    "PB,0,C65725,0`t; AP_HDG -> AP_HDG_HOLD",
    "UB,20,CPHC_ParkingBrake_Off,0`t; SWITCH_6 released -> parking brake off",
    "CP(+B,20)B,12,C65892,0`t; KNOB_INCR while MODE_ALT -> AP_ALT_VAR_INC"
)

$Scenarios = [ordered]@{}

$Scenarios['no section'] = {
    $ini = @('[General]', 'UpdatedByVersion=7500', '', '[JoyNames]', 'B=Bravo Throttle Quadrant')
    $m = Merge-FsuipcButtons -IniLines $ini -OwnedLines $ours -OwnedJoystick B -PollInterval 10 -ButtonRepeat '20,10'
    Check $m.Created 'section created'
    Check (($m.Lines[0..4] -join '|') -eq ($ini -join '|')) 'everything before it untouched'
    $s = $m.Section
    Check ($s[0] -eq '[Buttons]' -and $s[1] -eq 'PollInterval=10' -and $s[2] -eq 'ButtonRepeat=20,10') 'header and timing'
    Check ($s[3] -like '0=PB,0,*' -and $s[4] -like '1=UB,20,*' -and $s[5] -like '2=CP(+B,20)B,12,*') 'ours numbered from 0'
    Check ($m.Lines[-1] -eq '') 'file ends with a blank line'
}

$Scenarios['ours only, idempotent'] = {
    # The section as FSUIPC leaves it after a run: annotations appended.
    $ini = @('[Axes]', '', '[Buttons]', 'PollInterval=10', 'ButtonRepeat=20,10',
             "0=PB,0,C65725,0 ; AP_HDG -> AP_HDG_HOLD `t-{AP_HDG_HOLD}-",
             "1=UB,20,CPHC_ParkingBrake_Off,0 ; SWITCH_6 released `t-{Preset Control}-",
             "2=CP(+B,20)B,12,C65892,0 ; KNOB_INCR while MODE_ALT `t-{AP_ALT_VAR_INC}-",
             '', '[GPSout]', 'GPSoutEnabled=No')
    $m = Merge-FsuipcButtons -IniLines $ini -OwnedLines $ours -OwnedJoystick B -PollInterval 10 -ButtonRepeat '20,10'
    Check (-not $m.Created) 'section found'
    Check ($m.Replaced.Count -eq 3 -and $m.Kept.Count -eq 0) "three of ours replaced, nothing kept (replaced $($m.Replaced.Count), kept $($m.Kept.Count))"
    Check ($m.Lines[-2] -eq '[GPSout]' -and $m.Lines[-1] -eq 'GPSoutEnabled=No') 'following section intact'
    $m2 = Merge-FsuipcButtons -IniLines $m.Lines -OwnedLines $ours -OwnedJoystick B -PollInterval 10 -ButtonRepeat '20,10'
    Check (($m2.Lines -join "`n") -eq ($m.Lines -join "`n")) 'second merge changes nothing'
}

$Scenarios["user's devices kept"] = {
    $ini = @('[Buttons]', 'PollInterval=25', 'ButtonRepeat=30,15', '; my notes', 'InitialButtonDelay=5',
             '3=PA,3,C65561,0', '7=CP(+A,2)A,4,C65562,0', '9=P3,5,C65563,0', "12=UC,1,C65564,0`t-{X}-",
             "13=PB,45,C66079,0", "14=PB,0,C65725,0 ; AP_HDG -> AP_HDG_HOLD",
             '', '[Sounds]')
    $m = Merge-FsuipcButtons -IniLines $ini -OwnedLines $ours -OwnedJoystick B -PollInterval 10 -ButtonRepeat '20,10'
    Check ($m.Kept.Count -eq 4) "four user lines kept (was $($m.Kept.Count))"
    Check ($m.Replaced.Count -eq 2) "two lines on B replaced (was $($m.Replaced.Count))"
    Check (($m.Replaced -join '|') -like '*PB,45,*') "the user's own B line is among the replaced and reported"
    $s = $m.Section
    Check ($s[1] -eq 'PollInterval=10' -and $s[2] -eq 'ButtonRepeat=30,15') 'PollInterval forced, ButtonRepeat kept as the user had it'
    Check ($s[3] -eq '; my notes' -and $s[4] -eq 'InitialButtonDelay=5') 'other lines kept at the top'
    Check ($s[5] -eq '0=PA,3,C65561,0' -and $s[6] -eq '1=CP(+A,2)A,4,C65562,0' -and $s[7] -eq '2=P3,5,C65563,0' -and $s[8] -like "3=UC,1,*") 'user lines first, in order, renumbered from 0'
    Check ($s[9] -like '4=PB,0,*' -and $s[11] -like '6=CP(+B,20)B,12,*') 'ours after, numbered on'
    Check ($m.Lines[-1] -eq '[Sounds]') 'following section intact'
    Check ((Get-FsuipcButtonJoystick '5=CP(+A,2)A,4,C1,0') -eq 'A' -and (Get-FsuipcButtonJoystick '5=P3,5,C1,0') -eq '3' -and $null -eq (Get-FsuipcButtonJoystick 'PollInterval=10')) 'joystick parser'
}

$Scenarios['presets: create, append, replace, unchanged'] = {
    $p = Join-Path $work 'myevents.txt'
    $block = "// our presets`r`nHC_A#1 (>K:X)`r`nHC_B#0 (>K:X)`r`n"
    if (Test-Path $p) { Remove-Item $p }
    $r = Merge-PresetBlock -Path $p -Block $block
    Check ($r.Action -eq 'created') "created (was $($r.Action))"
    $t = Get-Content $p -Raw
    Check ($t -like "*managed block*HC_A#1 (>K:X)*HC_B#0 (>K:X)*end of the Honeycomb*") 'created file holds markers and block'
    # A user's file with their own preset and no markers.
    [System.IO.File]::WriteAllText($p, "// mine`r`nMY_Thing#1 (>K:Y)`r`n`r`n")
    $r = Merge-PresetBlock -Path $p -Block $block
    Check ($r.Action -eq 'appended') "appended (was $($r.Action))"
    $lines = Get-Content $p
    Check ($lines[0] -eq '// mine' -and $lines[1] -eq 'MY_Thing#1 (>K:Y)') "user's lines untouched at the top"
    Check (@($lines | Where-Object { $_ -eq 'HC_B#0 (>K:X)' }).Count -eq 1) 'our preset present once'
    # Our block changes: replaced, user's still there.
    $block2 = "// our presets v2`r`nHC_A#2 (>K:X)`r`nHC_C#0 (>K:X)`r`n"
    $r = Merge-PresetBlock -Path $p -Block $block2
    Check ($r.Action -eq 'replaced') "replaced (was $($r.Action))"
    $lines = Get-Content $p
    Check ($lines[1] -eq 'MY_Thing#1 (>K:Y)' -and ($lines -contains 'HC_C#0 (>K:X)') -and -not ($lines -contains 'HC_B#0 (>K:X)')) 'old block gone, new block in, user line kept'
    Check ((@($lines | Where-Object { $_ -eq $script:PresetBlockBegin }).Count) -eq 1) 'one begin marker'
    $r = Merge-PresetBlock -Path $p -Block $block2
    Check ($r.Action -eq 'unchanged') "unchanged on repeat (was $($r.Action))"
    # A user preset with one of our names: refused, file untouched.
    $before = Get-Content $p -Raw
    [System.IO.File]::WriteAllText($p, $before + "HC_C#5 (>K:Z)`r`n")
    $after = Get-Content $p -Raw
    $r = Merge-PresetBlock -Path $p -Block $block2
    Check ($r.Action -eq 'refused' -and $r.Conflicts -contains 'HC_C') "refused on a duplicate name (was $($r.Action): $($r.Reason))"
    Check ((Get-Content $p -Raw) -eq $after) 'refusal wrote nothing'
    # Damaged markers.
    [System.IO.File]::WriteAllText($p, "MY_Thing#1 (>K:Y)`r`n$script:PresetBlockBegin`r`nHC_A#1 (>K:X)`r`n")
    $r = Merge-PresetBlock -Path $p -Block $block2
    Check ($r.Action -eq 'refused' -and $r.Reason -like '*markers*') "refused on a lone marker (was $($r.Action))"
}

$Scenarios['presets: an older plain copy of ours is absorbed'] = {
    $p = Join-Path $work 'myevents2.txt'
    $block = "// our presets`r`nHC_A#1 (>K:X)`r`nHC_B#0 (>K:X)`r`n"
    # 1. The file IS our old copy (what every machine set up before 2026-09-10 has).
    [System.IO.File]::WriteAllText($p, $block)
    $r = Merge-PresetBlock -Path $p -Block $block
    Check ($r.Action -eq 'converted') "old copy converted (was $($r.Action): $($r.Reason))"
    $lines = Get-Content $p
    Check ($lines[0] -eq $script:PresetBlockBegin -and $lines[-1] -eq $script:PresetBlockEnd -and (@($lines | Where-Object { $_ -eq 'HC_A#1 (>K:X)' }).Count -eq 1)) 'now fenced, each preset once'
    $r = Merge-PresetBlock -Path $p -Block $block
    Check ($r.Action -eq 'unchanged') "then unchanged (was $($r.Action))"
    # 2. A user's file that also carries a stray identical line of ours: absorbed, the user's own kept.
    [System.IO.File]::WriteAllText($p, "MY_Thing#1 (>K:Y)`r`nHC_B#0 (>K:X)`r`n")
    $r = Merge-PresetBlock -Path $p -Block $block
    Check ($r.Action -eq 'appended') "stray identical line absorbed and block appended (was $($r.Action): $($r.Reason))"
    $lines = Get-Content $p
    Check ($lines[0] -eq 'MY_Thing#1 (>K:Y)' -and (@($lines | Where-Object { $_ -eq 'HC_B#0 (>K:X)' }).Count -eq 1)) "user's line kept, ours present once"
    # 3. Same name, different code, outside the block: still refused.
    [System.IO.File]::WriteAllText($p, "HC_B#7 (>K:OTHER)`r`n")
    $r = Merge-PresetBlock -Path $p -Block $block
    Check ($r.Action -eq 'refused' -and $r.Conflicts -contains 'HC_B') "different code under our name refuses (was $($r.Action))"
    # 4. Fenced file whose user part still has one stray identical line of ours: absorbed on replace.
    [System.IO.File]::WriteAllText($p, "MY_Thing#1 (>K:Y)`r`nHC_A#1 (>K:X)`r`n$script:PresetBlockBegin`r`nHC_A#1 (>K:X)`r`n$script:PresetBlockEnd`r`n")
    $r = Merge-PresetBlock -Path $p -Block $block
    Check ($r.Action -eq 'replaced') "fenced file with a stray line: replaced (was $($r.Action): $($r.Reason))"
    $lines = Get-Content $p
    Check ($lines[0] -eq 'MY_Thing#1 (>K:Y)' -and (@($lines | Where-Object { $_ -eq 'HC_A#1 (>K:X)' }).Count -eq 1) -and (@($lines | Where-Object { $_ -eq $script:PresetBlockBegin }).Count -eq 1)) 'stray line gone, one block, user line kept'
}

$Scenarios['end to end: Set-BravoButtons on a scratch copy of this machine'] = {
    $real = 'C:\FSUIPC7\FSUIPC7.ini'
    if (-not (Test-Path $real)) { Out-Line '   (no C:\FSUIPC7\FSUIPC7.ini here - skipped)' DarkGray; return }
    $root = Join-Path $work 'fsuipc'; $null = New-Item -ItemType Directory -Force -Path $root
    $lines = @(Get-Content $real)
    # A user's own lines: one on vJoy (A), one on the pedals (C), one on the Bravo (B) that is not ours.
    $out = New-Object System.Collections.ArrayList; $inB = $false
    foreach ($l in $lines) {
        if ($l -match '^\s*\[Buttons\]\s*$') { [void]$out.Add($l); [void]$out.Add('90=PA,3,C65561,0'); [void]$out.Add('91=UC,1,C65564,0'); [void]$out.Add('92=PB,45,C66079,0'); $inB = $true; continue }
        [void]$out.Add($l)
    }
    [System.IO.File]::WriteAllText((Join-Path $root 'FSUIPC7.ini'), (($out -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $root 'myevents.txt'), "// the user's own`r`nMY_Preset#1 (>K:PAUSE_ON)`r`n")
    $log = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'Set-BravoButtons.ps1') -FsuipcRoot $root 2>&1 | Out-String
    $code = $LASTEXITCODE
    Check ($code -eq 0) "writer exit 0 (was $code)"
    $ini = @(Get-Content (Join-Path $root 'FSUIPC7.ini'))
    $sec = @(); $in = $false
    foreach ($l in $ini) { if ($l -match '^\s*\[Buttons\]\s*$') { $in = $true; continue }; if ($in -and $l -match '^\s*\[') { break }; if ($in) { $sec += $l } }
    Check (@($sec | Where-Object { $_ -match '^\d+=PA,3,C65561,0$' }).Count -eq 1) 'vJoy line kept'
    Check (@($sec | Where-Object { $_ -match '^\d+=UC,1,C65564,0$' }).Count -eq 1) 'pedals line kept'
    Check (@($sec | Where-Object { $_ -match '^\d+=PB,45,' }).Count -eq 0) "user's Bravo line replaced"
    Check ($log -match '(?s)did not write.*PB,45') 'the replaced Bravo line is named in the output'
    Check (@($sec | Where-Object { $_ -match '^\d+=PB,0,C65725,0' }).Count -eq 1) 'AP_HDG written once'
    $nums = @($sec | Where-Object { $_ -match '^\d+=' } | ForEach-Object { [int]($_ -replace '=.*', '') })
    Check (($nums -join ',') -eq ((0..($nums.Count - 1)) -join ',')) 'numbered consecutively from 0'
    # Everything outside [Buttons] byte-identical to what we wrote in.
    function Outside { param($L) $o = @(); $in = $false; foreach ($x in $L) { if ($x -match '^\s*\[Buttons\]\s*$') { $in = $true; continue }; if ($in -and $x -match '^\s*\[') { $in = $false }; if (-not $in) { $o += $x } }; return ($o -join "`n").TrimEnd() }
    Check ((Outside $ini) -eq (Outside $out)) 'every other section untouched'
    Check (@(Get-ChildItem $root -Filter 'FSUIPC7.ini.*.bak').Count -eq 1) 'one backup taken'
    $ev = Get-Content (Join-Path $root 'myevents.txt')
    Check ($ev[1] -eq 'MY_Preset#1 (>K:PAUSE_ON)') "user's preset kept"
    Check (($ev -contains 'HC_ParkingBrake_On#1 (>K:PARKING_BRAKE_SET)')) 'our presets appended'
    Check ($log -match 'presets') 'output mentions the presets'
    if ($script:Failures.Count -gt 0) { Out-Line ('   writer output was:' + "`n" + $log) DarkGray }
}

foreach ($n in $Scenarios.Keys) {
    Out-Line ('== ' + $n) Cyan
    $before = $script:Failures.Count
    try { & $Scenarios[$n] } catch { $script:Failures.Add("$n threw: $($_.Exception.Message)"); Out-Line ('   THREW: ' + $_.Exception.Message + ' | ' + (($_.ScriptStackTrace -split "`n" | Select-Object -First 2) -join ' | ')) Red }
    if ($script:Failures.Count -eq $before) { Out-Line '   ok' Green }
}
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
if ($script:Failures.Count -eq 0) { Out-Line ("All {0} checks passed." -f $script:Checks) Green; exit 0 }
Out-Line ("{0} of {1} checks FAILED:" -f $script:Failures.Count, $script:Checks) Red
$script:Failures | ForEach-Object { Out-Line ('  - ' + $_) Red }
exit 1
