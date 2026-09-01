<#
.SYNOPSIS
    Read-only health check of an FSUIPC7 installation and its relationship to
    MSFS 2024. Reports what it can determine and says so plainly when it cannot.

.DESCRIPTION
    First piece of the health-check engine described in docs/setup-spec.md.
    Setup discovers and records; the launcher re-verifies on every start. This
    script is the shared body of checks behind both.

    It makes NO changes. It reads files, the registry and the process list, and
    the only thing it ever writes is the report file named by -Json, if given.

    Nothing here may assume the machine it runs on resembles any particular
    developer's machine. Paths are discovered, never assumed:

      * FSUIPC7 is located from the running process, then the registry, then
        conventional install directories.
      * MSFS 2024 may be a Microsoft Store or a Steam install, and the two keep
        their configuration in different places. The Community folder is always
        read from InstalledPackagesPath in UserCfg.opt, never located by name -
        a machine can hold several plausible Community folders of which only one
        is live.

    No dependencies: Windows PowerShell 5.1, no modules, no admin rights.

    Execution policy: on a stock machine every scope is Undefined, which means
    Restricted, and this file will refuse to run when invoked normally. That is
    a property of Windows, not of the script. Launch it as

        powershell.exe -NoProfile -ExecutionPolicy Bypass -File Check-FSUIPCHealth.ps1

    and have the launcher do the same. Do not tell a user to change their
    machine-wide execution policy for this.

    Verified read-only: the FSUIPC7 directory is byte-identical before and
    after a run.

.PARAMETER FsuipcRoot
    Skip discovery and check this FSUIPC7 directory.

.PARAMETER Json
    Also write the full result set here as JSON, for the machine report.

.PARAMETER Quiet
    Suppress the table. Useful with -Json, or when only the exit code matters.

.OUTPUTS
    Result objects on the pipeline. Exit code 0 if nothing failed, 1 if any
    check failed, 2 if the check could not run at all.

.EXAMPLE
    .\Check-FSUIPCHealth.ps1

.EXAMPLE
    .\Check-FSUIPCHealth.ps1 -Json .\fsuipc-health.json -Quiet
#>
[CmdletBinding()]
param(
    [string] $FsuipcRoot,
    [string] $Json,
    [switch] $Quiet
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# States, worst first. PASS/FAIL/WARN mean what they say. TODO is the important
# one: not configured *yet*, which is the expected state of a fresh machine and
# must never be presented as a fault. SKIP means a precondition was absent so
# the check could not run - which is not the same as passing.
$script:Results = New-Object System.Collections.ArrayList

function Add-Result {
    param(
        [Parameter(Mandatory)] [string] $Check,
        [Parameter(Mandatory)] [ValidateSet('PASS','FAIL','WARN','TODO','INFO','SKIP')] [string] $State,
        [string] $Detail = ''
    )
    [void]$script:Results.Add([pscustomobject]@{
        Check  = $Check
        State  = $State
        Detail = ($Detail -replace '\s+', ' ').Trim()
    })
}

# Any single check that throws must degrade to a SKIP rather than taking the
# whole report down with it. A partial report is useful; a crash is not.
function Invoke-Check {
    param([string] $Name, [scriptblock] $Body)
    try { & $Body }
    catch { Add-Result $Name 'SKIP' ("Check could not complete: {0}" -f $_.Exception.Message) }
}

# Join-Path validates the drive qualifier and throws on an unknown drive, which
# under ErrorActionPreference=Stop takes the whole script down. Any path built
# from user input or from discovery goes through this instead.
function Join-PathSafe {
    param([string] $Parent, [string] $Child)
    return [System.IO.Path]::Combine($Parent, $Child)
}

function Test-PathSafe {
    param([string] $Path)
    try { return [bool](Test-Path -LiteralPath $Path -ErrorAction Stop) } catch { return $false }
}

function Get-FirstMatch {
    param([string[]] $Lines, [string] $Pattern)
    foreach ($l in $Lines) { if ($l -match $Pattern) { return $Matches } }
    return $null
}

# ---------------------------------------------------------------- discovery --

function Find-FsuipcRoot {
    # 1. A running instance is authoritative.
    try {
        $p = Get-Process -Name 'FSUIPC7' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($p -and $p.Path) { return (Split-Path $p.Path -Parent) }
    } catch { }

    # 2. Registry uninstall entries, both hives and both bitnesses.
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($k in $keys) {
        try {
            $hit = Get-ItemProperty $k -ErrorAction SilentlyContinue |
                   Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -match 'FSUIPC7' } |
                   Select-Object -First 1
            if ($hit -and $hit.PSObject.Properties['InstallLocation'] -and $hit.InstallLocation -and (Test-Path $hit.InstallLocation)) {
                return $hit.InstallLocation.TrimEnd('\')
            }
        } catch { }
    }

    # 3. Conventional locations, on every fixed drive rather than assuming C:.
    $candidates = New-Object System.Collections.ArrayList
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        [void]$candidates.Add((Join-Path $d.Root 'FSUIPC7'))
    }
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($base) { [void]$candidates.Add((Join-Path $base 'FSUIPC7')) }
    }
    foreach ($c in $candidates) {
        try { if (Test-Path (Join-Path $c 'FSUIPC7.exe')) { return $c } } catch { }
    }
    return $null
}

# Returns every MSFS 2024 install we can evidence, each with the UserCfg.opt
# that actually exists. Presence of a directory is not proof of an install.
function Find-Msfs2024 {
    $found = New-Object System.Collections.ArrayList

    $storePkg = 'Microsoft.Limitless_8wekyb3d8bbwe'
    $storeCfg = Join-Path $env:LOCALAPPDATA "Packages\$storePkg\LocalCache\UserCfg.opt"
    if (Test-Path $storeCfg) {
        [void]$found.Add([pscustomobject]@{
            Distribution = 'MS Store'
            UserCfg      = $storeCfg
            LocalCache   = (Split-Path $storeCfg -Parent)
        })
    }

    $steamCfg = Join-Path $env:APPDATA 'Microsoft Flight Simulator 2024\UserCfg.opt'
    if (Test-Path $steamCfg) {
        [void]$found.Add([pscustomobject]@{
            Distribution = 'Steam'
            UserCfg      = $steamCfg
            LocalCache   = (Split-Path $steamCfg -Parent)
        })
    }
    return $found
}

function Get-InstalledPackagesPath {
    param([string] $UserCfgPath)
    foreach ($line in (Get-Content -LiteralPath $UserCfgPath -ErrorAction Stop)) {
        if ($line -match '^\s*InstalledPackagesPath\s+"(.+)"\s*$') { return $Matches[1] }
    }
    return $null
}

# -------------------------------------------------------------- run checks --

if (-not $FsuipcRoot) {
    try { $FsuipcRoot = Find-FsuipcRoot } catch { $FsuipcRoot = $null }
}

$exePath = if ($FsuipcRoot) { Join-PathSafe $FsuipcRoot 'FSUIPC7.exe' } else { $null }

if (-not $exePath -or -not (Test-PathSafe $exePath)) {
    $where = if ($FsuipcRoot) { "Looked in '$FsuipcRoot'." }
             else { 'Looked at the running process, the registry, and conventional install directories on every fixed drive.' }
    Add-Result 'FSUIPC7 installed' 'FAIL' ("FSUIPC7.exe not found. {0} Pass -FsuipcRoot if it is installed somewhere unusual." -f $where)
    if (-not $Quiet) {
        ''
        'FSUIPC7 health check'
        ('=' * 110)
        $script:Results | Format-Table @{ n = ''; e = { '[FAIL]' } }, Check, Detail -AutoSize -Wrap | Out-String -Width 170
        '1 failed - the check could not run.'
    }
    if ($Json) {
        [pscustomobject]@{
            generatedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            machine      = $env:COMPUTERNAME
            fsuipcRoot   = $FsuipcRoot
            summary      = @{ FAIL = 1; WARN = 0; TODO = 0; SKIP = 0; PASS = 0; INFO = 0 }
            results      = @($script:Results)
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Json -Encoding UTF8
    }
    exit 2
}

Invoke-Check 'FSUIPC7 installed' {
    $v = (Get-Item $exePath).VersionInfo.FileVersion
    Add-Result 'FSUIPC7 installed' 'PASS' ("{0} (version {1})" -f $exePath, $v)
}

Invoke-Check 'Licence key' {
    $key = Join-PathSafe $FsuipcRoot 'FSUIPC7.key'
    if (Test-Path $key) {
        Add-Result 'Licence key' 'PASS' ("FSUIPC7.key present, {0} bytes" -f (Get-Item $key).Length)
    } else {
        Add-Result 'Licence key' 'FAIL' 'No FSUIPC7.key. Axis assignment is a paid feature of FSUIPC7 and will not be available without a registered copy.'
    }
}

Invoke-Check 'FSUIPC7 running' {
    $p = Get-Process -Name 'FSUIPC7' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p) {
        $started = try { $p.StartTime.ToString('HH:mm:ss') } catch { 'start time unavailable' }
        Add-Result 'FSUIPC7 running' 'INFO' ("pid {0}, started {1}" -f $p.Id, $started)
    } else {
        Add-Result 'FSUIPC7 running' 'INFO' 'Not running'
    }
}

# ---- log ----
$logPath = Join-PathSafe $FsuipcRoot 'FSUIPC7.log'
Invoke-Check 'Log' {
    if (-not (Test-Path $logPath)) {
        Add-Result 'Log' 'TODO' 'No FSUIPC7.log yet. Run FSUIPC7 once so it scans devices and records what it found.'
        return
    }
    $lines = @(Get-Content -LiteralPath $logPath -ErrorAction Stop)
    if ($lines.Count -eq 0) {
        Add-Result 'Log' 'TODO' 'FSUIPC7.log is empty. Run FSUIPC7 once to completion.'
        return
    }
    Add-Result 'Log' 'PASS' ("{0} lines, last written {1}" -f $lines.Count, (Get-Item $logPath).LastWriteTime)

    # Test positively for the key being accepted. Do NOT scan for the word
    # "unregistered": FSUIPC logs "Hot key unregistered" during a normal clean
    # shutdown, and treating that as a licence failure is a false alarm. A
    # health check that cries wolf gets ignored, which is worse than no check.
    $regLines = @($lines | Select-String -Pattern 'User Name=|User Addr=|Key is provided|Key NOT provided' |
                  ForEach-Object { $_.Line.Trim() })
    if ($lines -match '(?i)FSUIPC7 Key is provided') {
        Add-Result 'Registration' 'PASS' ($regLines -join ' | ')
    } elseif ($regLines) {
        Add-Result 'Registration' 'FAIL' ('Key not accepted: ' + ($regLines -join ' | '))
    } else {
        Add-Result 'Registration' 'SKIP' 'No registration lines in the log'
    }

    $sim = @($lines | Select-String -Pattern 'SimConnect_Open succeeded|MSFS version =|installation detected|Aircraft loaded' |
             ForEach-Object { $_.Line.Trim() })
    if ($sim) {
        Add-Result 'Reached a running sim' 'PASS' ($sim -join ' | ')

        $craft = @($lines | ForEach-Object { if ($_ -match 'Aircraft="([^"]+)"') { $Matches[1] } }) | Select-Object -Unique
        if ($craft) {
            Add-Result 'Per-aircraft detection' 'PASS' (($craft | Select-Object -First 8) -join ' | ')
        }
        $wapi = @($lines | Select-String -Pattern 'WASM Interface|Lvars/Hvars received' |
                  Select-Object -First 2 | ForEach-Object { $_.Line.Trim() })
        if ($wapi) { Add-Result 'WASM / L:var interface' 'PASS' ($wapi -join ' | ') }
    } else {
        Add-Result 'Reached a running sim' 'SKIP' 'This log records no sim connection, so driving the sim is untested. Only verifiable with MSFS running.'
    }

    # Whole words only, and deliberately NOT '***'. FSUIPC uses *** for its
    # banner, for shutdown lines and for non-fatal notices, so matching it
    # reports healthy installations as broken. Same failure as the "unregistered"
    # trap above: a check that cries wolf gets ignored, and an ignored check is
    # worse than no check at all.
    $err = @($lines | Select-String -Pattern '(?i)\berror\b|\bfailed\b|\bunable\b|\bcannot\b' |
             Select-Object -First 5 | ForEach-Object { $_.Line.Trim() })
    if ($err) { Add-Result 'Log errors' 'WARN' ($err -join ' | ') }
    else      { Add-Result 'Log errors' 'PASS' 'No error, failure, unable or cannot lines' }

    # FSUIPC silently drops presets whose name exceeds 63 characters once it has
    # prefixed the profile name. Not an error, but the dropped ones are simply
    # unavailable to bind by name - and on this machine some are PMDG 737.
    $dropped = @($lines | Select-String -Pattern 'Preset name .* (?:exceeds max allowed length|so ignoring)' |
                 ForEach-Object { if ($_.Line -match "Preset name '([^']+)'") { $Matches[1] } })
    if ($dropped.Count) {
        $pmdg = @($dropped | Where-Object { $_ -match '(?i)pmdg' })
        $note = "{0} preset(s) dropped for name length and cannot be bound by name" -f $dropped.Count
        if ($pmdg.Count) { $note += ("; {0} of them PMDG, e.g. {1}" -f $pmdg.Count, $pmdg[0]) }
        Add-Result 'Presets dropped by FSUIPC' 'INFO' $note
    }
}

# ---- ini ----
$iniPath = Join-PathSafe $FsuipcRoot 'FSUIPC7.ini'
Invoke-Check 'FSUIPC7.ini' {
    if (-not (Test-Path $iniPath)) {
        Add-Result 'FSUIPC7.ini' 'TODO' 'Not present. FSUIPC7 has never completed a run; start it once and it will write one.'
        return
    }
    $text = @(Get-Content -LiteralPath $iniPath -ErrorAction Stop)
    Add-Result 'FSUIPC7.ini' 'PASS' ("{0} bytes, last written {1}" -f (Get-Item $iniPath).Length, (Get-Item $iniPath).LastWriteTime)

    # Settings this project depends on. Absent is TODO, not a fault - a machine
    # that has never been set up is supposed to look like this.
    $want = [ordered]@{
        'UseProfiles'         = 'Yes'
        'ShortAircraftNameOk' = 'Substring'
        'AutoConnectToSim'    = 'Yes'
        'PMDG737offsets'      = 'Auto'
        'PMDG777offsets'      = 'Auto'
    }
    foreach ($k in $want.Keys) {
        $m = Get-FirstMatch -Lines $text -Pattern ("^{0}=(.*)$" -f [regex]::Escape($k))
        if (-not $m) {
            Add-Result "Setting: $k" 'TODO' ("not set; this project needs '{0}'" -f $want[$k])
        } elseif ($m[1].Trim() -eq $want[$k]) {
            Add-Result "Setting: $k" 'PASS' $m[1].Trim()
        } else {
            Add-Result "Setting: $k" 'WARN' ("is '{0}', this project needs '{1}'" -f $m[1].Trim(), $want[$k])
        }
    }

    # [JoyNames]
    $joy = New-Object System.Collections.ArrayList
    $inSection = $false
    foreach ($l in $text) {
        if ($l -match '^\[JoyNames\]')   { $inSection = $true;  continue }
        if ($l -match '^\[')             { $inSection = $false; continue }
        if ($inSection -and $l.Trim())   { [void]$joy.Add($l.Trim()) }
    }
    if ($joy.Count -eq 0) {
        Add-Result 'Joystick identity' 'TODO' 'No [JoyNames] yet. Run FSUIPC7 once with the hardware connected; it scans and records GUIDs at startup without needing the sim.'
    } else {
        $bravo = @($joy | Where-Object { $_ -match 'Bravo' -and $_ -notmatch '\.GUID' })
        $alpha = @($joy | Where-Object { $_ -match 'Alpha' -and $_ -notmatch '\.GUID' })
        if ($bravo) { Add-Result 'Bravo known to FSUIPC' 'PASS' ($bravo -join ' | ') }
        else        { Add-Result 'Bravo known to FSUIPC' 'WARN' 'FSUIPC has scanned but recorded no Bravo. Was it connected and powered at the time?' }
        if ($alpha) { Add-Result 'Alpha known to FSUIPC' 'PASS' ($alpha -join ' | ') }
        else        { Add-Result 'Alpha known to FSUIPC' 'INFO' 'No Alpha recorded' }

        # Anything else holding an id matters: ids shift when devices come and go.
        $others = @($joy | Where-Object { $_ -notmatch '\.GUID' -and $_ -notmatch 'Bravo|Alpha' })
        if ($others) {
            Add-Result 'Other devices holding ids' 'INFO' (($others -join ' | ') + '  - these occupy FSUIPC ids and shift the numbering of everything else')
        }
    }

    # Assignments. None is the expected state before we build anything.
    $axisLines = @($text | Select-String -Pattern '^\d+=.*(?i)axis')
    $profiles  = @($text | Select-String -Pattern '^\[Profile\.')
    Add-Result 'Axis assignments' $(if ($axisLines.Count) { 'INFO' } else { 'TODO' }) `
        ("{0} axis assignment line(s)" -f $axisLines.Count)
    Add-Result 'Aircraft profiles' $(if ($profiles.Count) { 'INFO' } else { 'TODO' }) `
        ("{0} [Profile.*] section(s)" -f $profiles.Count)
}

# ---- MSFS 2024 and the Community folder ----
Invoke-Check 'MSFS 2024' {
    $installs = @(Find-Msfs2024)
    if ($installs.Count -eq 0) {
        Add-Result 'MSFS 2024' 'FAIL' 'No UserCfg.opt found for either a Microsoft Store or a Steam install. Note that the presence of a Flight Simulator folder is not proof of an install.'
        return
    }
    if ($installs.Count -gt 1) {
        Add-Result 'MSFS 2024' 'WARN' ('More than one install evidenced: ' + (($installs | ForEach-Object { $_.Distribution }) -join ', ') + '. Which one is in use must be confirmed rather than guessed.')
    }

    foreach ($i in $installs) {
        Add-Result ("MSFS 2024 ({0})" -f $i.Distribution) 'PASS' $i.UserCfg

        $ipp = Get-InstalledPackagesPath -UserCfgPath $i.UserCfg
        if (-not $ipp) {
            Add-Result 'Community folder' 'WARN' ("No InstalledPackagesPath in {0}" -f $i.UserCfg)
            continue
        }
        # $ipp is arbitrary text from a config file and may name a drive that is
        # not currently present - an external disk, or a path left behind by a
        # machine move. It must not be able to throw.
        $community = Join-PathSafe $ipp 'Community'
        if (Test-PathSafe $community) {
            $count = @(Get-ChildItem -LiteralPath $community -Directory -ErrorAction SilentlyContinue).Count
            Add-Result 'Community folder' 'PASS' ("{0}  ({1} packages)" -f $community, $count)

            $wasm = @(Get-ChildItem -LiteralPath $community -Directory -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -match '(?i)fsuipc' })
            if ($wasm) {
                Add-Result 'FSUIPC WASM module' 'PASS' (($wasm | ForEach-Object { $_.Name }) -join ', ')
            } else {
                Add-Result 'FSUIPC WASM module' 'INFO' 'Not installed. Only needed for L:var and H:var access on complex aircraft.'
            }
        } else {
            Add-Result 'Community folder' 'FAIL' ("InstalledPackagesPath points at {0}, but {1} does not exist" -f $ipp, $community)
        }

        # A machine can hold several plausible Community folders. Only the one
        # under InstalledPackagesPath is read by the sim; the rest are decoys
        # and are worth naming, because add-ons placed in them silently do
        # nothing.
        try {
            $decoys = New-Object System.Collections.ArrayList
            foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
                foreach ($guess in @('Community', 'Packages\Community', 'MSFS2024\Packages\Community')) {
                    $p = Join-Path $d.Root $guess
                    if ((Test-Path $p) -and ($p -ne $community)) {
                        $n = @(Get-ChildItem -LiteralPath $p -Directory -ErrorAction SilentlyContinue).Count
                        if ($n -gt 0) { [void]$decoys.Add(("{0} ({1} packages)" -f $p, $n)) }
                    }
                }
            }
            if ($decoys.Count) {
                Add-Result 'Inactive Community folders' 'WARN' (($decoys -join ' | ') + '  - the sim does not read these; anything installed there has no effect')
            }
        } catch { }
    }
}

# ---- what launches FSUIPC ----
Invoke-Check 'Auto-start' {
    $exeXmls = New-Object System.Collections.ArrayList
    [void]$exeXmls.Add((Join-Path $env:APPDATA 'Microsoft Flight Simulator 2024\EXE.xml'))
    foreach ($i in (Find-Msfs2024)) { [void]$exeXmls.Add((Join-Path $i.LocalCache 'exe.xml')) }

    $seen = $false; $present = New-Object System.Collections.ArrayList
    foreach ($x in ($exeXmls | Select-Object -Unique)) {
        if (Test-Path $x) {
            [void]$present.Add($x)
            if ((Get-Content -LiteralPath $x -Raw -ErrorAction SilentlyContinue) -match '(?i)FSUIPC') { $seen = $true }
        }
    }
    if ($present.Count) { Add-Result 'exe.xml files present' 'INFO' ($present -join ' | ') }
    if ($seen) {
        Add-Result 'FSUIPC auto-start' 'INFO' 'FSUIPC is listed in an exe.xml and will start with the sim'
    } else {
        Add-Result 'FSUIPC auto-start' 'INFO' 'FSUIPC is in no exe.xml, so something must launch it explicitly. That is fine when the launcher does it.'
    }
    $bat = Join-PathSafe $FsuipcRoot 'MSFS24.bat'
    if (Test-Path $bat) { Add-Result 'FSUIPC launcher batch' 'INFO' $bat }
}

# ---- software that will fight us for the hardware ----
Invoke-Check 'Competing controller software' {
    $names = @('SPAD','SPAD.neXt','MobiFlight','MobiFlightConnector','AxisAndOhs','HangarControl','FSUIPC6','FSUIPC5')
    $running = @(Get-Process -ErrorAction SilentlyContinue |
                 Where-Object { $names -contains $_.ProcessName } |
                 ForEach-Object { $_.ProcessName })
    if ($running) {
        Add-Result 'Competing controller software' 'WARN' (($running | Select-Object -Unique) -join ', ')
    } else {
        Add-Result 'Competing controller software' 'PASS' 'None of the known conflicting tools are running'
    }
}

# ------------------------------------------------------------------ report --

$order = @{ 'FAIL' = 0; 'WARN' = 1; 'TODO' = 2; 'SKIP' = 3; 'PASS' = 4; 'INFO' = 5 }
$counts = @{}
foreach ($s in @('FAIL','WARN','TODO','SKIP','PASS','INFO')) {
    $counts[$s] = @($script:Results | Where-Object { $_.State -eq $s }).Count
}

if (-not $Quiet) {
    ''
    'FSUIPC7 health check'
    ("FSUIPC7 root: {0}" -f $FsuipcRoot)
    ('=' * 110)
    $script:Results |
        Sort-Object @{ Expression = { $order[$_.State] } } |
        Format-Table @{ n = ''; e = { switch ($_.State) {
                            'PASS' { '[ ok ]' } 'FAIL' { '[FAIL]' } 'WARN' { '[warn]' }
                            'TODO' { '[todo]' } 'SKIP' { '[skip]' } default { '[ -- ]' } } } },
            Check, Detail -AutoSize -Wrap | Out-String -Width 170
    ("{0} failed, {1} warnings, {2} not yet configured, {3} not testable, {4} passed" -f
        $counts['FAIL'], $counts['WARN'], $counts['TODO'], $counts['SKIP'], $counts['PASS'])
    if ($counts['TODO']) { '"not yet configured" is the expected state of a machine this project has not been set up on.' }
}

if ($Json) {
    $report = [pscustomobject]@{
        generatedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        machine      = $env:COMPUTERNAME
        fsuipcRoot   = $FsuipcRoot
        summary      = $counts
        results      = @($script:Results)
    }
    $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Json -Encoding UTF8
    if (-not $Quiet) { "Report written to $Json" }
}

# Objects go to the pipeline only under -Quiet. Emitting them alongside the
# table would print the whole result set twice.
if ($Quiet) { $script:Results }

if ($counts['FAIL'] -gt 0) { exit 1 } else { exit 0 }
