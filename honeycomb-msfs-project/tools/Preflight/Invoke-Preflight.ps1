<#
.SYNOPSIS
    The preflight gate. Runs every registered check and decides whether the
    program may proceed to start the simulator.

.DESCRIPTION
    This runs on EVERY launch, not only during setup. Setup discovers and
    records; the launcher re-verifies against that record each time it starts.
    A check that is optional gets skipped, and a machine drifts quietly until
    something breaks on a day nobody is available to fix it.

    Checks are discovered from Checks\*.ps1. Adding an add-on to the gate means
    dropping a new file in that folder - see README.md in this directory for the
    contract. Nothing in this host knows anything about FSUIPC specifically.

    Read-only. Nothing here changes the machine. The only thing ever written is
    the report file named by -Json.

    Execution policy: on a stock Windows machine every scope is Undefined, which
    means Restricted, and .ps1 files will not run when invoked normally. Launch
    as:

        powershell.exe -NoProfile -ExecutionPolicy Bypass -File Invoke-Preflight.ps1

    Never ask a user to change their machine-wide execution policy for this.

.PARAMETER Only
    Run just the named checks (matched against provider Name). For diagnosis.

.PARAMETER Json
    Write the full result set here, for the machine report.

.PARAMETER Quiet
    Suppress the report table and emit result objects on the pipeline instead.

.OUTPUTS
    Exit code:
      0  GO             - nothing blocking
      1  NO-GO          - a blocking check failed; do not start the sim
      2  CANNOT RUN     - the gate itself could not run
      3  SETUP NEEDED   - nothing broken, but this machine has not been set up

.EXAMPLE
    .\Invoke-Preflight.ps1

.EXAMPLE
    .\Invoke-Preflight.ps1 -Json .\preflight.json -Quiet
#>
[CmdletBinding()]
param(
    [string[]] $Only,
    [string]   $Json,
    [switch]   $Quiet,
    # On NO-GO, print what is wrong and keep re-checking, so the user can put it
    # right and have the program notice by itself. No keypress: "press any key"
    # is one more thing to explain to someone who is already stuck.
    [switch]   $Retry,
    [int]      $RetryTimeoutSeconds = 300,
    [int]      $RetryIntervalSeconds = 3
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# An unexpected error means the gate verified nothing it can stand behind, and
# that must be reported as CANNOT RUN. Without this the script dies with exit
# code 1, which is indistinguishable from a legitimate NO-GO - a crash wearing
# the costume of a verdict.
trap {
    Write-Host ''
    Write-Host ("Preflight could not run: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host 'This is a fault in the program, not in your setup. Nothing was verified, so no verdict is possible.' -ForegroundColor Red
    exit 2
}

# ------------------------------------------------------------------ shared --
# Helpers live in the host scope. Check files are dot-sourced, so they run in
# this scope and can use everything defined here.

$script:Results = New-Object System.Collections.ArrayList
$script:CurrentProvider = 'preflight'

<#
    State meanings, and they are not interchangeable:

      PASS  verified good
      FAIL  broken. Blocking decides whether it stops the launch.
      WARN  works, but something is off and someone should look
      TODO  not configured YET. The expected state of a machine this project
            has not been set up on. Never present this as a fault - doing so
            teaches the user that the report is noise.
      SKIP  a precondition was absent so the check could not run. Not a pass.
      INFO  context, no judgement
#>
function Add-Result {
    param(
        [Parameter(Mandatory)] [string] $Check,
        [Parameter(Mandatory)] [ValidateSet('PASS','FAIL','WARN','TODO','INFO','SKIP')] [string] $State,
        [string] $Detail = '',
        # Remedy is written for the person sitting at the machine, who may be
        # alone and may read it aloud down a telephone. Plain words, one action.
        [string] $Remedy = '',
        # A blocking FAIL stops the launch. Use it only where continuing would
        # produce a broken or misleading flight.
        [switch] $Blocking
    )
    [void]$script:Results.Add([pscustomobject]@{
        Provider = $script:CurrentProvider
        Check    = $Check
        State    = $State
        Blocking = [bool]$Blocking
        Detail   = ($Detail -replace '\s+', ' ').Trim()
        Remedy   = ($Remedy -replace '\s+', ' ').Trim()
    })
}

# Join-Path validates the drive qualifier and throws on an unknown drive, which
# under ErrorActionPreference=Stop takes the whole run down. Anything built from
# user input or from a config file goes through these instead.
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

<#
    One problem, one message.

    Checks run in order, and a later check often fails only because an earlier
    one did - FSUIPC has no record of the yoke because the yoke is unplugged.
    Reporting both gives the user two things to do when there is one thing
    wrong, and the second instruction is impossible until the first is done.

    A check that would be reporting a consequence asks this first, and steps
    aside if the root cause is already on the list.
#>
function Test-AlreadyFailed {
    param([Parameter(Mandatory)] [string] $CheckPattern)
    return @($script:Results | Where-Object {
        $_.State -eq 'FAIL' -and $_.Check -match $CheckPattern
    }).Count -gt 0
}

# Every MSFS 2024 install we can evidence. A directory is not proof of an
# install; only a UserCfg.opt that actually exists is.
function Find-Msfs2024 {
    $found = New-Object System.Collections.ArrayList

    $storeCfg = Join-PathSafe $env:LOCALAPPDATA 'Packages\Microsoft.Limitless_8wekyb3d8bbwe\LocalCache\UserCfg.opt'
    if (Test-PathSafe $storeCfg) {
        [void]$found.Add([pscustomobject]@{
            Distribution = 'MS Store'; UserCfg = $storeCfg; LocalCache = (Split-Path $storeCfg -Parent) })
    }
    $steamCfg = Join-PathSafe $env:APPDATA 'Microsoft Flight Simulator 2024\UserCfg.opt'
    if (Test-PathSafe $steamCfg) {
        [void]$found.Add([pscustomobject]@{
            Distribution = 'Steam'; UserCfg = $steamCfg; LocalCache = (Split-Path $steamCfg -Parent) })
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

# ------------------------------------------------------------ run the gate --

$checksDir = Join-PathSafe $PSScriptRoot 'Checks'
if (-not (Test-PathSafe $checksDir)) {
    Write-Host "Preflight cannot run: no Checks directory at $checksDir" -ForegroundColor Red
    exit 2
}

$checkFiles = @(Get-ChildItem -LiteralPath $checksDir -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
                Sort-Object Name)
if ($checkFiles.Count -eq 0) {
    Write-Host "Preflight cannot run: no checks found in $checksDir" -ForegroundColor Red
    exit 2
}

function Invoke-AllChecks {
    $script:Results = New-Object System.Collections.ArrayList

    foreach ($file in $checkFiles) {
        $provider = $null
        try {
            # Dot-sourced so the check runs in this scope and sees the helpers above.
            $provider = . $file.FullName
        } catch {
            $script:CurrentProvider = $file.BaseName
            Add-Result 'Check failed to load' 'SKIP' $_.Exception.Message `
                       'This is a defect in the program, not in your setup. Report it.'
            continue
        }

        if (-not $provider -or -not $provider.Name -or -not $provider.Run) {
            $script:CurrentProvider = $file.BaseName
            Add-Result 'Malformed check' 'SKIP' "$($file.Name) did not return a valid provider" `
                       'This is a defect in the program, not in your setup. Report it.'
            continue
        }

        if ($Only -and ($Only -notcontains $provider.Name)) { continue }

        $script:CurrentProvider = $provider.Name
        try {
            & $provider.Run
        } catch {
            # A check that throws must not take the gate down with it. A partial
            # report is useful; a crash tells the user nothing.
            Add-Result 'Check did not complete' 'SKIP' $_.Exception.Message `
                       'This is a defect in the program, not in your setup. Report it.'
        }
    }
}

# The leading comma forces an array back even when there is exactly one match.
# Without it PowerShell unwraps a single-element result to the element itself,
# and under StrictMode the caller's .Count then throws - which killed the script
# with exit code 1, indistinguishable from a legitimate NO-GO.
function Get-Blockers {
    return ,@($script:Results | Where-Object { $_.State -eq 'FAIL' -and $_.Blocking })
}

Invoke-AllChecks

# Something the user can put right without leaving the screen - a device to
# plug in, a program to start - deserves the chance to be put right. Re-check
# on a timer rather than asking for a keypress: the program noticing by itself
# is one less instruction to give someone who is already stuck.
if ($Retry -and @(Get-Blockers).Count -gt 0) {
    $deadline = (Get-Date).AddSeconds($RetryTimeoutSeconds)
    $lastShown = ''

    while ((Get-Date) -lt $deadline) {
        $blockers = Get-Blockers
        if ($blockers.Count -eq 0) { break }

        $fingerprint = ($blockers | ForEach-Object { $_.Check }) -join '|'
        if ($fingerprint -ne $lastShown) {
            $lastShown = $fingerprint
            if (-not $Quiet) {
                ''
                Write-Host 'Before we can carry on:' -ForegroundColor Yellow
                foreach ($b in $blockers) {
                    Write-Host ("  * {0}" -f $b.Detail) -ForegroundColor Red
                    if ($b.Remedy) { Write-Host ("    {0}" -f $b.Remedy) -ForegroundColor Yellow }
                }
                ''
                Write-Host 'Waiting - this will continue by itself once that is done.' -ForegroundColor DarkGray
            }
        }

        Start-Sleep -Seconds $RetryIntervalSeconds
        Invoke-AllChecks
    }

    if (-not $Quiet -and @(Get-Blockers).Count -eq 0) {
        ''
        Write-Host 'That is sorted. Carrying on.' -ForegroundColor Green
    } elseif (-not $Quiet) {
        ''
        Write-Host ("Still not resolved after {0} seconds. Stopping here rather than starting the simulator in a state that will not work." -f $RetryTimeoutSeconds) -ForegroundColor Red
    }
}

# ------------------------------------------------------------- the verdict --

$counts = @{}
foreach ($s in @('FAIL','WARN','TODO','SKIP','PASS','INFO')) {
    $counts[$s] = @($script:Results | Where-Object { $_.State -eq $s }).Count
}
$blockers = @($script:Results | Where-Object { $_.State -eq 'FAIL' -and $_.Blocking })

# A gate that verified nothing must never report GO. Zero results means the run
# was vacuous - a bad -Only filter, checks that all failed to load, an empty
# Checks folder - and "everything is fine" would be a lie told confidently.
if ($script:Results.Count -eq 0) {
    $verdict = 'CANNOT RUN'; $code = 2
    $hint = if ($Only) {
        $available = @($checkFiles | ForEach-Object {
            try { $d = . $_.FullName; if ($d -and $d.Name) { $d.Name } } catch { } })
        "No check matched -Only '{0}'. Available: {1}" -f ($Only -join ', '), (($available | Sort-Object) -join ', ')
    } else {
        'No checks produced any result.'
    }
    if (-not $Quiet) {
        ''
        Write-Host ("CANNOT RUN - nothing was verified, so no verdict is possible. {0}" -f $hint) -ForegroundColor Red
        ''
    }
    if ($Json) {
        [pscustomobject]@{
            generatedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            machine      = $env:COMPUTERNAME
            verdict      = $verdict
            exitCode     = $code
            summary      = $counts
            blocking     = @()
            results      = @()
            note         = $hint
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Json -Encoding UTF8
    }
    exit $code
}

if ($blockers.Count -gt 0) {
    $verdict = 'NO-GO'; $code = 1
} elseif ($counts['TODO'] -gt 0) {
    $verdict = 'SETUP NEEDED'; $code = 3
} else {
    $verdict = 'GO'; $code = 0
}

if (-not $Quiet) {
    $order = @{ 'FAIL' = 0; 'WARN' = 1; 'TODO' = 2; 'SKIP' = 3; 'PASS' = 4; 'INFO' = 5 }
    ''
    'Preflight'
    ('=' * 110)
    $script:Results |
        Sort-Object @{ Expression = { $order[$_.State] } }, Provider |
        # switch rebinds $_ to its input, so the row has to be captured first -
        # otherwise $_.Blocking resolves against the state string and, under
        # StrictMode, silently renders an empty cell.
        Format-Table @{ n = ''; e = {
                        $row = $_
                        switch ($row.State) {
                            'PASS' { '[ ok ]' }
                            'FAIL' { if ($row.Blocking) { '[STOP]' } else { '[FAIL]' } }
                            'WARN' { '[warn]' }
                            'TODO' { '[todo]' }
                            'SKIP' { '[skip]' }
                            default { '[ -- ]' }
                        } } },
            Provider, Check, Detail -AutoSize -Wrap | Out-String -Width 170

    switch ($verdict) {
        'NO-GO' {
            Write-Host 'NO-GO - do not start the simulator until these are fixed:' -ForegroundColor Red
            foreach ($b in $blockers) {
                Write-Host ("  * {0}" -f $b.Detail) -ForegroundColor Red
                if ($b.Remedy) { Write-Host ("    {0}" -f $b.Remedy) -ForegroundColor Yellow }
            }
        }
        'SETUP NEEDED' {
            Write-Host 'SETUP NEEDED - nothing is broken, but this machine has not been set up yet.' -ForegroundColor Yellow
            foreach ($t in @($script:Results | Where-Object { $_.State -eq 'TODO' })) {
                Write-Host ("  * {0}: {1}" -f $t.Check, $t.Detail) -ForegroundColor Yellow
            }
        }
        default { Write-Host 'GO - everything the program depends on is in good shape.' -ForegroundColor Green }
    }
    ''
    ("{0} blocking, {1} failed, {2} warnings, {3} not yet configured, {4} not testable, {5} passed" -f
        $blockers.Count, $counts['FAIL'], $counts['WARN'], $counts['TODO'], $counts['SKIP'], $counts['PASS'])
}

if ($Json) {
    [pscustomobject]@{
        generatedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        machine      = $env:COMPUTERNAME
        verdict      = $verdict
        exitCode     = $code
        summary      = $counts
        blocking     = @($blockers)
        results      = @($script:Results)
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Json -Encoding UTF8
    if (-not $Quiet) { "Report written to $Json" }
}

if ($Quiet) { $script:Results }
exit $code
