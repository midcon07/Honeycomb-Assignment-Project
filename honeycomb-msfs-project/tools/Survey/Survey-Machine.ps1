<#
.SYNOPSIS
    Read-only survey of a flight-sim PC, written to one report file on the
    Desktop for sending back.

.DESCRIPTION
    Built for midcon07's machine, which nobody on this project can reach. It
    answers, without changing anything, the questions that would otherwise be
    guessed at: where MSFS 2024 is and which build, which add-on folder is
    live, what aircraft are installed, whether FSUIPC7 is there and what it
    calls the controllers, which USB flight controls are plugged in, and
    whether the launcher's runtime pieces are present.

    Every probe is wrapped so that a missing thing is reported as missing,
    in words, rather than stopping the survey. Nothing here writes anywhere
    except the report files on the Desktop. No admin rights, no modules,
    plain PowerShell 5.1.

    Run it from Survey-Machine.cmd (a double-click), or:
        powershell -NoProfile -ExecutionPolicy Bypass -File Survey-Machine.ps1
#>
[CmdletBinding()]
param(
    [string] $OutDir = [Environment]::GetFolderPath('Desktop')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'

$report = New-Object System.Collections.ArrayList
$data   = [ordered]@{}

function Section { param([string]$Title) [void]$report.Add(''); [void]$report.Add('=== ' + $Title + ' ==='); }
function Line    { param([string]$Text)  [void]$report.Add($Text) }
function Probe {
    # Runs one probe. Whatever it throws becomes a line in the report, so the
    # survey never stops on a machine that differs from the one it was written on.
    param([string]$Label, [scriptblock]$Body)
    # A block run from inside this function cannot set a script-level variable
    # by plain assignment - not with "&" and not by dot-sourcing either; both
    # land it in a scope that vanishes on return. The first run printed the
    # packages path and, on the very next line, "no packages path", and the
    # aircraft list, JoyNames and logged titles were all missing with no error.
    # So probes that hand a value to later probes assign it as $script:name.
    try { & $Body } catch { Line ("{0}: could not be checked - {1}" -f $Label, $_.Exception.Message) }
}
function PathOrNo { param([string]$p) if ($p -and (Test-Path -LiteralPath $p)) { $p } else { '(not found)' } }
function IniSection {
    param([string[]]$Lines, [string]$Name)
    $out = New-Object System.Collections.ArrayList; $in = $false
    foreach ($l in $Lines) {
        if ($l -match ('^\s*\[' + [regex]::Escape($Name) + '\]\s*$')) { $in = $true; continue }
        if ($in -and $l -match '^\s*\[') { break }
        if ($in -and $l.Trim()) { [void]$out.Add($l.Trim()) }
    }
    ,@($out)
}

$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
Line ('Honeycomb flight-sim survey - ' + $env:COMPUTERNAME + ' - ' + $stamp)
Line 'Read-only. Nothing on this computer was changed.'
$data.machine = $env:COMPUTERNAME; $data.user = $env:USERNAME; $data.when = $stamp

# ---------------------------------------------------------------- Windows
Section 'Windows'
Probe 'Windows' {
    $os = Get-CimInstance Win32_OperatingSystem
    Line ("{0}, build {1}, {2} GB RAM" -f $os.Caption, $os.BuildNumber, [math]::Round($os.TotalVisibleMemorySize / 1MB))
    $data.windows = @{ caption = $os.Caption; build = $os.BuildNumber }
    Line ('PowerShell ' + $PSVersionTable.PSVersion)
}
Probe 'Drives' {
    foreach ($d in Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -ne $null }) {
        Line ("  {0}:  {1} GB free of {2} GB" -f $d.Name, [math]::Round($d.Free / 1GB), [math]::Round(($d.Used + $d.Free) / 1GB))
    }
}

# ---------------------------------------------------------------- MSFS 2024
Section 'Microsoft Flight Simulator 2024'
$userCfg = $null; $ipp = $null
Probe 'MSFS install' {
    $store = [System.IO.Path]::Combine($env:LOCALAPPDATA, 'Packages\Microsoft.Limitless_8wekyb3d8bbwe\LocalCache\UserCfg.opt')
    $steam = [System.IO.Path]::Combine($env:APPDATA,   'Microsoft Flight Simulator 2024\UserCfg.opt')
    if     (Test-Path -LiteralPath $store) { $script:userCfg = $store; Line 'Edition: Microsoft Store'; $data.msfsEdition = 'Store' }
    elseif (Test-Path -LiteralPath $steam) { $script:userCfg = $steam; Line 'Edition: Steam';           $data.msfsEdition = 'Steam' }
    else { Line 'MSFS 2024 UserCfg.opt NOT FOUND in the Store or Steam location - the simulator may not be installed for this user.'; $data.msfsEdition = 'not found' }
    if ($userCfg) {
        Line ('UserCfg.opt: ' + $userCfg)
        $m = (Get-Content -LiteralPath $userCfg -ErrorAction Stop) | Select-String -Pattern 'InstalledPackagesPath\s+"([^"]+)"' | Select-Object -First 1
        if ($m) { $script:ipp = $m.Matches[0].Groups[1].Value; Line ('InstalledPackagesPath: ' + $ipp); $data.installedPackagesPath = $ipp }
        else { Line 'InstalledPackagesPath: not present in UserCfg.opt' }
    }
}
Probe 'Package folders' {
    if (-not $ipp) { Line 'Skipped - no packages path.'; return }
    foreach ($sub in 'Community', 'StreamedPackages', 'Official2024', 'Official') {
        $p = [System.IO.Path]::Combine($ipp, $sub)
        if (Test-Path -LiteralPath $p) {
            $n = @(Get-ChildItem -LiteralPath $p -Directory -ErrorAction SilentlyContinue).Count
            Line ("  {0,-17} {1,5} packages   {2}" -f $sub, $n, $p)
        } else { Line ("  {0,-17} (absent)" -f $sub) }
    }
}
Probe 'Aircraft packages' {
    # Folder names only. On MSFS 2024 the streamed packages are opaque archives
    # with no readable aircraft.cfg, so the folder name is what there is.
    if (-not $ipp) { return }
    $ac = New-Object System.Collections.ArrayList
    foreach ($sub in 'Community', 'StreamedPackages', 'Official2024', 'Official') {
        $p = [System.IO.Path]::Combine($ipp, $sub)
        if (-not (Test-Path -LiteralPath $p)) { continue }
        Get-ChildItem -LiteralPath $p -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '(?i)aircraft|airplane|plane|-a[0-9]{3}|-b[0-9]{3}|c172|c208|tbm|kingair|bonanza|baron|da62|da40|cessna|piper|beech|-737|-747|-777|-787|a320|a350|-crj|-e1|-atr|glider|heli' } |
            Where-Object { $_.Name -notmatch '(?i)passiveaircraft|livery|liveries|-scenery|airport|landingchallenge|simattachment' } |
            ForEach-Object { [void]$ac.Add(('  ' + $sub + '\' + $_.Name)) }
    }
    Line ('Likely aircraft packages: ' + $ac.Count)
    $ac | Sort-Object | ForEach-Object { Line $_ }
    $data.aircraftPackages = @($ac | ForEach-Object { $_.Trim() })
}
Probe 'Readable aircraft titles (Community add-ons only)' {
    # Third-party aircraft in Community are usually plain folders; their
    # aircraft.cfg title= lines are the exact strings FSUIPC matches on.
    if (-not $ipp) { return }
    $c = [System.IO.Path]::Combine($ipp, 'Community')
    if (-not (Test-Path -LiteralPath $c)) { return }
    # On Mark's machine this found 4,479 titles - almost all liveries and AI
    # traffic packs, and no delimiter reliably separates aircraft from livery
    # ("Boeing 727-100 - Alaska", "FSLTL A20N AMC Air Malta"). What a person
    # needs is per PACKAGE: which add-on aircraft folders exist, how many
    # titles each holds, and one example title. Every unique title still goes
    # to the JSON, grouped by package, where it is useful for matching.
    $byPkg = @{}
    Get-ChildItem -LiteralPath $c -Recurse -Depth 5 -Filter 'aircraft.cfg' -ErrorAction SilentlyContinue | ForEach-Object {
        $rel = $_.FullName.Substring($c.Length).TrimStart('\')
        $pkg = ($rel -split '\\')[0]
        if (-not $byPkg.ContainsKey($pkg)) { $byPkg[$pkg] = New-Object System.Collections.ArrayList }
        Get-Content -LiteralPath $_.FullName -ErrorAction SilentlyContinue |
            Select-String -Pattern '^\s*title\s*=\s*"?([^"]+)"?' |
            ForEach-Object { [void]$byPkg[$pkg].Add($_.Matches[0].Groups[1].Value.Trim()) }
    }
    $total = 0; foreach ($k in $byPkg.Keys) { $total += $byPkg[$k].Count }
    Line ('Titles found: {0} across {1} Community packages (every title is in the .json)' -f $total, $byPkg.Count)
    # Loud, because this section is easy to mistake for "the aircraft he has".
    # PMDG and other protected add-ons encrypt aircraft.cfg, so they appear in
    # the package list above and NOT here. Reading absence here as absence of
    # the aircraft is a mistake that has already been made once.
    Line '  NOTE: only add-ons with readable aircraft.cfg appear here. Protected add-ons'
    Line '  (PMDG and others) encrypt theirs - see the package list above for those, and'
    Line '  get their sim titles from the FSUIPC log section instead.'
    foreach ($k in ($byPkg.Keys | Sort-Object)) {
        $u = @($byPkg[$k] | Sort-Object -Unique)
        Line ('  {0,-44} {1,5} titles   e.g. {2}' -f $k, $u.Count, $(if ($u.Count) { $u[0] } else { '' }))
    }
    $grouped = [ordered]@{}
    foreach ($k in ($byPkg.Keys | Sort-Object)) { $grouped[$k] = @($byPkg[$k] | Sort-Object -Unique) }
    $data.communityTitlesByPackage = $grouped
}
Probe 'Add-ons started with the simulator (EXE.xml)' {
    foreach ($x in @([System.IO.Path]::Combine($env:APPDATA, 'Microsoft Flight Simulator 2024\EXE.xml'),
                     [System.IO.Path]::Combine($env:LOCALAPPDATA, 'Packages\Microsoft.Limitless_8wekyb3d8bbwe\LocalCache\EXE.xml'))) {
        if (Test-Path -LiteralPath $x) {
            Line ('  ' + $x)
            Get-Content -LiteralPath $x -ErrorAction SilentlyContinue | Select-String -Pattern '<Name>([^<]+)</Name>' |
                ForEach-Object { Line ('    - ' + $_.Matches[0].Groups[1].Value) }
        }
    }
}

# ---------------------------------------------------------------- FSUIPC7
Section 'FSUIPC7'
$fsRoot = $null
Probe 'FSUIPC7 location' {
    $p = Get-Process -Name FSUIPC7 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p -and $p.Path) { $script:fsRoot = Split-Path $p.Path -Parent; Line 'FSUIPC7 is running now.' }
    if (-not $fsRoot) {
        foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                       'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                       'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*') {
            $h = Get-ItemProperty $k -ErrorAction SilentlyContinue |
                 Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -match 'FSUIPC7' } | Select-Object -First 1
            if ($h -and $h.PSObject.Properties['InstallLocation'] -and $h.InstallLocation -and (Test-Path -LiteralPath $h.InstallLocation)) { $script:fsRoot = $h.InstallLocation.TrimEnd('\'); break }
        }
    }
    if (-not $fsRoot) {
        foreach ($d in Get-PSDrive -PSProvider FileSystem) {
            $c = [System.IO.Path]::Combine($d.Root, 'FSUIPC7')
            if (Test-Path -LiteralPath ([System.IO.Path]::Combine($c, 'FSUIPC7.exe'))) { $script:fsRoot = $c; break }
        }
    }
    if ($fsRoot) {
        $exe = [System.IO.Path]::Combine($fsRoot, 'FSUIPC7.exe')
        Line ('Folder: ' + $fsRoot)
        Line ('Version: ' + (Get-Item -LiteralPath $exe).VersionInfo.FileVersion)
        $data.fsuipcRoot = $fsRoot
        Line ('FSUIPC7.key (licence): ' + $(if (Test-Path -LiteralPath ([System.IO.Path]::Combine($fsRoot, 'FSUIPC7.key'))) { 'present' } else { 'NOT PRESENT - unregistered' }))
        Line ('myevents.txt: ' + (PathOrNo ([System.IO.Path]::Combine($fsRoot, 'myevents.txt'))))
        Line ('events.txt:   ' + (PathOrNo ([System.IO.Path]::Combine($fsRoot, 'events.txt'))))
    } else { Line 'FSUIPC7 NOT FOUND on this computer.'; $data.fsuipcRoot = '' }
}
Probe 'FSUIPC7.ini' {
    if (-not $fsRoot) { return }
    $ini = [System.IO.Path]::Combine($fsRoot, 'FSUIPC7.ini')
    if (-not (Test-Path -LiteralPath $ini)) { Line 'FSUIPC7.ini not present - FSUIPC7 has never been run.'; return }
    $t = Get-Content -LiteralPath $ini -ErrorAction Stop
    Line 'Controllers FSUIPC knows ([JoyNames], letter = name):'
    $jn = @{}
    foreach ($l in (IniSection $t 'JoyNames')) { if ($l -match '^([A-Za-z])=(.+)$') { $jn[$Matches[1]] = $Matches[2]; Line ('  ' + $Matches[1] + ' = ' + $Matches[2]) } }
    if ($jn.Count -eq 0) { Line '  (none - FSUIPC has not scanned for controllers yet)' }
    $data.joyNames = $jn
    Line 'Settings:'
    foreach ($k in 'UseProfiles', 'AutoConnectToSim', 'ShortAircraftNameOk', 'LogExtras', 'LogAxes') {
        $m = $t | Select-String -Pattern ('^\s*' + $k + '\s*=\s*(.+)$') | Select-Object -First 1
        Line ('  ' + $k + ' = ' + $(if ($m) { $m.Matches[0].Groups[1].Value.Trim() } else { '(not set)' }))
    }
    $prof = @($t | Select-String -Pattern '^\[Profile\.(.+)\]' | ForEach-Object { $_.Matches[0].Groups[1].Value })
    Line ('Aircraft profiles present: ' + $(if ($prof.Count) { $prof -join ', ' } else { 'none' }))
    $data.fsuipcProfiles = $prof
    $axes = @($t | Where-Object { $_ -match '^\s*\d+\s*=\s*[A-Z][A-Z],' })
    Line ('Axis assignment lines (all sections): ' + $axes.Count)
}
Probe 'FSUIPC7.log - aircraft titles seen' {
    # The exact strings a profile must match. Only aircraft that have been
    # flown with FSUIPC running appear here.
    if (-not $fsRoot) { return }
    $log = [System.IO.Path]::Combine($fsRoot, 'FSUIPC7.log')
    if (-not (Test-Path -LiteralPath $log)) { Line 'No FSUIPC7.log yet.'; return }
    $fs = [System.IO.File]::Open($log, 'Open', 'Read', 'ReadWrite'); $sr = New-Object System.IO.StreamReader($fs)
    $txt = $sr.ReadToEnd(); $sr.Close()
    $titles = @([regex]::Matches($txt, 'Aircraft="([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    # FSUIPC rewrites its log every time it starts, so this shows only aircraft
    # loaded since the last start. Empty is normal after a restart; it is not
    # a fault. Best run right after a flight, with FSUIPC still open.
    Line ('Titles in the current log: ' + $(if ($titles.Count) { '' } else { 'none - FSUIPC starts a new log each time it runs, so nothing has been flown since it last started' }))
    $titles | ForEach-Object { Line ('  ' + $_) }
    $data.fsuipcLoggedTitles = $titles
    $scan = [regex]::Match($txt, 'Product= (.+?)\r?\n.*?Max=([^\r\n]+)', 'Singleline')
    $errs = @([regex]::Matches($txt, '(?m)^.*\*\*\*.*(?:error|fail|cannot).*$') | ForEach-Object { $_.Value.Trim() } | Select-Object -First 5)
    if ($errs.Count) { Line 'Log lines mentioning errors (first 5):'; $errs | ForEach-Object { Line ('  ' + $_) } }
    $bravo = [regex]::Match($txt, 'Product= Bravo[^\r\n]*[\s\S]*?Max=([^\r\n]+)')
    if ($bravo.Success) { Line ('Bravo axes as FSUIPC scanned them: ' + $bravo.Groups[1].Value) }
}

# ---------------------------------------------------------------- USB flight controls
Section 'Flight controls plugged in'
Probe 'USB devices' {
    $want = @(
        @{ Label = 'Honeycomb Bravo throttle quadrant'; Vid = '294B'; Pid = '1901' },
        @{ Label = 'Honeycomb Alpha yoke';              Vid = '294B'; Pid = '1900' },
        @{ Label = 'WINWING Orion rudder pedals';       Vid = '4098'; Pid = 'BEF0' }
    )
    $all = @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop | Where-Object { $_.PNPDeviceID -match '(?i)VID_[0-9A-F]{4}&PID_[0-9A-F]{4}' })
    $found = @{}
    foreach ($w in $want) {
        $hit = @($all | Where-Object { $_.PNPDeviceID -match ('(?i)VID_' + $w.Vid + '&PID_' + $w.Pid) })
        $present = $hit.Count -gt 0
        Line ("  {0,-34} {1}" -f $w.Label, $(if ($present) { 'CONNECTED' } else { 'not connected' }))
        $found[$w.Label] = $present
    }
    $data.controls = $found
    $others = @($all | Where-Object { $_.PNPDeviceID -match '(?i)VID_(294B|4098)' -or $_.Name -match '(?i)joystick|game controller|throttle|yoke|pedal|rudder' } |
                Select-Object -ExpandProperty Name -Unique | Sort-Object)
    if ($others.Count) { Line 'Other game-controller-looking devices:'; $others | ForEach-Object { Line ('  ' + $_) } }
}

# ---------------------------------------------------------------- launcher runtime
Section 'Launcher prerequisites'
Probe '.NET 8 desktop runtime' {
    $r = @()
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $base) { continue }
        $d = [System.IO.Path]::Combine($base, 'dotnet\shared\Microsoft.WindowsDesktop.App')
        if (Test-Path -LiteralPath $d) { $r += @(Get-ChildItem -LiteralPath $d -Directory | Where-Object { $_.Name -like '8.*' } | ForEach-Object { $_.Name }) }
    }
    Line ('.NET 8 Windows Desktop runtime: ' + $(if ($r.Count) { $r -join ', ' } else { 'NOT INSTALLED - the launcher needs it' }))
    $data.dotnet8Desktop = $r
}
Probe 'WebView2 runtime' {
    $v = $null
    foreach ($k in 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
                   'HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}') {
        $p = Get-ItemProperty $k -ErrorAction SilentlyContinue
        if ($p -and $p.PSObject.Properties['pv'] -and $p.pv) { $v = $p.pv; break }
    }
    Line ('WebView2 runtime: ' + $(if ($v) { $v } else { 'NOT FOUND - the launcher needs it' }))
    $data.webview2 = $v
}
Probe 'SimBrief reachable' {
    try {
        $r = Invoke-WebRequest -Uri 'https://www.simbrief.com/' -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
        Line ('SimBrief: reachable (HTTP ' + $r.StatusCode + ')')
    } catch { Line ('SimBrief: not reachable from here - ' + $_.Exception.Message) }
}

# ---------------------------------------------------------------- write it out
Section 'Done'
$base = [System.IO.Path]::Combine($OutDir, ('HoneycombSurvey-' + $env:COMPUTERNAME + '-' + (Get-Date -Format 'yyyyMMdd-HHmm')))
$txtPath = $base + '.txt'; $jsonPath = $base + '.json'
Line ('Report: ' + $txtPath)
[System.IO.File]::WriteAllText($txtPath,  (($report -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText($jsonPath, (($data | ConvertTo-Json -Depth 6) + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))

$report | ForEach-Object { Write-Host $_ }
Write-Host ''
Write-Host '======================================================================' -ForegroundColor Green
Write-Host ' FINISHED. Two files are on your Desktop. Please send BOTH to Mark:' -ForegroundColor Green
Write-Host ('   ' + [System.IO.Path]::GetFileName($txtPath)) -ForegroundColor Green
Write-Host ('   ' + [System.IO.Path]::GetFileName($jsonPath)) -ForegroundColor Green
Write-Host ' Nothing on this computer was changed.' -ForegroundColor Green
Write-Host '======================================================================' -ForegroundColor Green
