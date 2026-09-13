<#
.SYNOPSIS
    Runs the button capture against a FAKE yoke with scripted hands, and
    checks what it saved and what it said.

.DESCRIPTION
    The capture in Probe-HoneycombDevices.ps1 could only ever be tried by a
    person with the unit plugged in, so its logic had been reviewed by
    reading, never by running. This drives it end to end with no hardware:

      - the unit is a fake Alpha (35 buttons, one hat) whose state is what
        the scripted hands have set, and which returns a BLANK reading every
        seventeenth time, as the real driver does (measured 2026-09-07);
      - the hands are a list of things a person does: move a switch, press a
        button, hold the hat, press a key, wait for a line to appear on the
        screen, or let some readings pass;
      - the screen is captured, so what the capture said can be checked too.

    Scenarios: perfect hands; hands that make every mistake the prompts are
    written for (two buttons at once, a switch where a button was asked for,
    the hat in the wrong direction or centred, a switch already in position at
    Step 1, two switches moved at Step 2, START not held, a stray keypress
    after a hat); no console; stop with Q and resume; skips.

    Exit code 0 when every check passes, 1 otherwise. -Show echoes the
    capture's screen as it runs.

.EXAMPLE
    .\Test-CaptureLogic.ps1
    .\Test-CaptureLogic.ps1 -Only mistakes -Show
#>
[CmdletBinding()]
param(
    [string] $Only = '',
    [switch] $Show
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
. (Join-Path $here 'Probe-HoneycombDevices.ps1') -Library

$work = Join-Path $env:TEMP ('hc-capture-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Force -Path $work

function Out-Line { param([string] $Text, [string] $Color = 'Gray') Microsoft.PowerShell.Utility\Write-Host $Text -ForegroundColor $Color }

# ---------------------------------------------------------------------------
# The fake unit and the scripted hands
# ---------------------------------------------------------------------------
$Fake = @{
    Buttons     = @()
    Hat         = 'Center'
    SwitchCount = 1
    Queue       = New-Object System.Collections.Generic.List[object]
    Out         = New-Object System.Collections.Generic.List[string]
    OutCursor   = 0
    Flap        = $true
    Reads       = 0
    Console     = $true
}

function Reset-Fake {
    $Fake.Buttons = @(); $Fake.Hat = 'Center'; $Fake.SwitchCount = 1
    $Fake.Queue.Clear(); $Fake.Out.Clear(); $Fake.OutCursor = 0
    $Fake.Flap = $true; $Fake.Reads = 0; $Fake.Console = $true
}

# --- what the capture calls, replaced --------------------------------------
function Write-Host {
    param([Parameter(Position = 0)] $Object = '', $ForegroundColor = $null, $BackgroundColor = $null, [switch] $NoNewline)
    $Fake.Out.Add([string]$Object)
    if ($Show) { Microsoft.PowerShell.Utility\Write-Host ([string]$Object) }
}
function Start-Sleep {
    # Ten times faster than asked; the capture's settle windows are wall-clock
    # (Get-Date), so they still elapse, just polled more often.
    param([int] $Milliseconds = 0, [int] $Seconds = 0)
    Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds ([math]::Max(1, [int](($Milliseconds + 1000 * $Seconds) / 10)))
}
function Test-ConsoleInput { return $Fake.Console }
function Get-GamingControllers {
    return ,@([pscustomobject]@{
        DisplayName = 'fake Alpha'; HardwareVendorId = 0x294B; HardwareProductId = 0x1900
        ButtonCount = 35; SwitchCount = $Fake.SwitchCount; AxisCount = 2
    })
}

function Test-PromptSeen {
    param([string] $Pattern)
    for ($i = $Fake.OutCursor; $i -lt $Fake.Out.Count; $i++) {
        if ($Fake.Out[$i] -match $Pattern) { $Fake.OutCursor = $i + 1; return $true }
    }
    return $false
}

function Step-Hands {
    # Do what the hands do until they are waiting on something. Returns what
    # they wait on: 'key' (a keypress is offered), 'prompt' (a line on the
    # screen), 'after' (readings to pass), or 'empty'.
    param([switch] $Reading, [switch] $Blocking)
    while ($Fake.Queue.Count -gt 0) {
        $h = $Fake.Queue[0]
        if ($h.ContainsKey('set'))    { $Fake.Buttons = @($h.set); $Fake.Queue.RemoveAt(0); continue }
        if ($h.ContainsKey('hat'))    { $Fake.Hat = $h.hat; $Fake.Queue.RemoveAt(0); continue }
        if ($h.ContainsKey('prompt')) { if (Test-PromptSeen $h.prompt) { $Fake.Queue.RemoveAt(0); continue } else { return 'prompt' } }
        if ($h.ContainsKey('after')) {
            if ($Blocking) { $Fake.Queue.RemoveAt(0); continue }
            if ($Reading) { $h.after = $h.after - 1 }
            if ($h.after -le 0) { $Fake.Queue.RemoveAt(0); continue }
            return 'after'
        }
        if ($h.ContainsKey('key'))    { if ($Reading) { $h.seen = $h.seen + 1 }; return 'key' }
        throw 'unknown hands item'
    }
    return 'empty'
}

function Read-GamingController {
    param($Controller)
    $Fake.Reads++
    # The driver's blank reading. It takes the capture 20 ms to read past
    # one, which is no time at all to a person, so the hands do not move on it.
    if ($Fake.Flap -and ($Fake.Reads % 17) -eq 0) { return $null }
    $null = Step-Hands -Reading
    $hats = @(); if ($Controller.SwitchCount -gt 0) { $hats = @($Fake.Hat) }
    return [pscustomobject]@{ Buttons = @($Fake.Buttons); Hats = $hats; Axes = @(0.5, 0.5) }
}

function Read-ConsoleKey {
    param([switch] $IfAvailable)
    if (-not $Fake.Console) { return $null }
    $state = Step-Hands -Blocking:(-not $IfAvailable)
    if ($state -eq 'key') {
        # A person takes time to press a key after a prompt appears, and the
        # capture always reads the unit at least once in that time. So a key
        # tapped after a prompt is not there for the drain that runs the
        # instant the prompt is printed - only for a poll after a reading, or
        # for a blocking read.
        if ($IfAvailable -and $Fake.Queue[0].seen -lt 1) { return $null }
        $h = $Fake.Queue[0]; $Fake.Queue.RemoveAt(0)
        return [pscustomobject]@{ Key = [ConsoleKey]$h.key; KeyChar = ' ' }
    }
    if ($IfAvailable) { return $null }
    $tail = ($Fake.Out | Select-Object -Last 6) -join "`n"
    if ($state -eq 'prompt') { throw ("STUCK: the hands wait for a line matching /{0}/ but the capture waits for a key. Last lines:`n{1}" -f $Fake.Queue[0].prompt, $tail) }
    throw ("STUCK: the hands have nothing left to do but the capture waits for a key. Last lines:`n{0}" -f $tail)
}

# --- the physical model of the fake Alpha ----------------------------------
# Numbers are the fake's own; only the SHAPE matters (each toggle holds one
# of two buttons, the key holds one of five, everything else is momentary).
$Btn = @{
    PTT = 1; LEFT_WHITE_BUTTON = 2; RIGHT_WHITE_BUTTON = 3; RED_BUTTON = 4
    LH_LEFT_SWITCH_DOWN = 5; LH_LEFT_SWITCH_UP = 6; LH_RIGHT_SWITCH_DOWN = 7; LH_RIGHT_SWITCH_UP = 8
    RH_TOP_SWITCH_LEFT = 9; RH_TOP_SWITCH_RIGHT = 10; RH_BOTTOM_SWITCH_LEFT = 11; RH_BOTTOM_SWITCH_RIGHT = 12
}
$Tog = [ordered]@{ SW_ALT = @(13, 14); SW_BAT = @(15, 16); SW_AVIONICS_BUS1 = @(17, 18); SW_AVIONICS_BUS2 = @(19, 20); SW_BEACON = @(21, 22); SW_LAND = @(23, 24); SW_TAXI = @(25, 26); SW_NAV = @(27, 28); SW_STROBE = @(29, 30) }   # on, off
$KeyPos = [ordered]@{ MAG_OFF = 31; MAG_R = 32; MAG_L = 33; MAG_BOTH = 34; MAG_START = 35 }
$KeyOrder = @('MAG_OFF', 'MAG_R', 'MAG_L', 'MAG_BOTH', 'MAG_START')

function New-Unit {
    $t = @{}; foreach ($n in $Tog.Keys) { $t[$n] = 'off' }
    return @{ Toggles = $t; KeyAt = 'MAG_OFF'; Held = @() }
}
function Get-UnitState {
    param($U)
    $s = @()
    foreach ($n in $Tog.Keys) { $s += $(if ($U.Toggles[$n] -eq 'on') { $Tog[$n][0] } else { $Tog[$n][1] }) }
    $s += $KeyPos[$U.KeyAt]
    $s += @($U.Held)
    return ,@($s | Sort-Object -Unique)
}

# --- the hands' vocabulary ---------------------------------------------------
function Hands   { param($Item) $Fake.Queue.Add($Item) }
function Push-Unit { param($U) Hands @{ set = (Get-UnitState $U) } }
function Hold    { param($U, [int] $B) $U.Held = @($U.Held) + $B; Push-Unit $U }
function Release { param($U, [int] $B) $U.Held = @($U.Held | Where-Object { $_ -ne $B }); Push-Unit $U }
function Flip    { param($U, [string] $Name, [string] $To) $U.Toggles[$Name] = $To; Push-Unit $U }
function Turn    {
    # Turn the key to a position, passing through the ones between.
    param($U, [string] $To)
    $from = [array]::IndexOf($KeyOrder, $U.KeyAt); $dest = [array]::IndexOf($KeyOrder, $To)
    $step = if ($dest -ge $from) { 1 } else { -1 }
    for ($i = $from + $step; $i -ne $dest + $step; $i += $step) { $U.KeyAt = $KeyOrder[$i]; Push-Unit $U; Wait 1 }
}
function HatTo   { param([string] $Dir) Hands @{ hat = $Dir } }
function Wait    { param([int] $Reads) Hands @{ after = $Reads } }
function Tap     { param([string] $Key) Hands @{ key = $Key; seen = 0 } }
function Expect  { param([string] $Pattern) Hands @{ prompt = $Pattern } }

function Get-HatDir { param([string] $Name) (($Name -replace '^HAT_', '') -split '_' | ForEach-Object { $_.Substring(0, 1).ToUpper() + $_.Substring(1).ToLower() }) -join '' }

# Perfect hands for one control, by kind.
function Do-Control {
    param($U, [string] $Name, [string] $Kind)
    Expect ('^>> {0}:' -f [regex]::Escape($Name))
    switch ($Kind) {
        'momentary' { Wait 2; Hold $U $Btn[$Name]; Wait 4; Release $U $Btn[$Name] }
        'hat'       { HatTo (Get-HatDir $Name); Tap Enter; Wait 2; HatTo Center }
        'latching'  {
            Expect 'Step 1'
            if ($Name -like 'MAG_*') { if ($U.KeyAt -eq $Name) { Turn $U 'MAG_OFF' } }
            else { if ($U.Toggles[$Name] -eq 'on') { Flip $U $Name 'off' } }
            Tap Enter
            Expect 'Step 2'
            if ($Name -like 'MAG_*') { Turn $U $Name } else { Flip $U $Name 'on' }
            Tap Enter
        }
        'held'      { Turn $U 'MAG_START'; Tap Enter; Wait 3; Turn $U 'MAG_BOTH' }
        default     { throw "unknown kind $Kind" }
    }
}

# ---------------------------------------------------------------------------
# Table handling and checks
# ---------------------------------------------------------------------------
function New-FreshTable {
    param([string] $Name)
    $t = Get-Content -LiteralPath (Join-Path $root 'data\alpha-buttons.json') -Raw | ConvertFrom-Json
    foreach ($p in $t.controls.PSObject.Properties) {
        $c = $p.Value
        $c.prober = $null; $c.fsuipc = $null; $c.verified = $false
        foreach ($extra in @('hat', 'assumed', 'numbering')) { if ($c.PSObject.Properties[$extra]) { $c.PSObject.Properties.Remove($extra) } }
    }
    $path = Join-Path $work ($Name + '.json')
    [System.IO.File]::WriteAllText($path, (($t | ConvertTo-Json -Depth 10) + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    return $path
}
function Read-Table { param([string] $Path) Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
function Get-Kind { param($C) if ($C.PSObject.Properties['kind'] -and $C.kind) { [string]$C.kind } else { 'momentary' } }
function Expected-Fsuipc { param([string] $Name) $p = $null; if ($Btn.ContainsKey($Name)) { $p = $Btn[$Name] } elseif ($Tog.Contains($Name)) { $p = $Tog[$Name][0] } elseif ($KeyPos.Contains($Name)) { $p = $KeyPos[$Name] }; $f = $p - 1; if ($f -gt 31) { $f += 100 }; return @($p, $f) }

$script:Failures = New-Object System.Collections.Generic.List[string]
$script:Checks = 0
function Check { param([bool] $Ok, [string] $What) $script:Checks++; if (-not $Ok) { $script:Failures.Add($What); Out-Line ('   FAIL: ' + $What) Red } }
function Screen-Has { param([string] $Pattern) return [bool]($Fake.Out | Where-Object { $_ -match $Pattern } | Select-Object -First 1) }
function Screen-Count { param([string] $Pattern) return @($Fake.Out | Where-Object { $_ -match $Pattern }).Count }

function Assert-Captured {
    # Every control saved with the fake's numbers, except those named in $Except.
    param($Table, [string[]] $Except = @())
    foreach ($p in $Table.controls.PSObject.Properties) {
        $n = $p.Name; $c = $p.Value; $kind = Get-Kind $c
        if ($Except -contains $n) {
            if ($kind -eq 'hat') { Check (-not $c.PSObject.Properties['hat']) ("$n should have no hat saved") }
            else { Check (-not [bool]$c.verified -and $null -eq $c.prober) ("$n should be unverified") }
            continue
        }
        if ($kind -eq 'hat') {
            $dir = Get-HatDir $n
            Check ($c.PSObject.Properties['hat'] -and $c.hat -eq $dir) ("$n hat should be $dir")
            Check ($c.fsuipc -eq $HAT_FSUIPC[$dir]) ("$n fsuipc should be $($HAT_FSUIPC[$dir]), is $($c.fsuipc)")
            Check ($c.PSObject.Properties['assumed'] -and $c.assumed -eq $true -and $c.verified -eq $false) ("$n should be assumed, not verified")
        }
        else {
            $e = Expected-Fsuipc $n
            Check ($c.verified -eq $true) ("$n should be verified")
            Check ($c.prober -eq $e[0] -and $c.fsuipc -eq $e[1]) ("$n should be panel $($e[0]) / FSUIPC $($e[1]), is $($c.prober) / $($c.fsuipc)")
        }
    }
}

function Run-Capture {
    param([string] $Path, [string] $LogName)
    $log = Join-Path $work ($LogName + '.log')
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try { $rc = Start-CaptureSession -Path $Path -LogPath $log }
    catch { $rc = -1; Out-Line ('   EXCEPTION: ' + $_.Exception.Message) Red; if ($_.ScriptStackTrace) { Out-Line ('   ' + (($_.ScriptStackTrace -split "`n" | Select-Object -First 3) -join ' | ')) DarkGray } }
    $sw.Stop()
    return @{ Rc = $rc; Log = $log; Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
}

# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------
$Scenarios = [ordered]@{}

$Scenarios['perfect'] = {
    # Every control operated exactly as asked, once. Blank readings on.
    $path = New-FreshTable 'perfect'; $t = Read-Table $path
    Reset-Fake; $U = New-Unit; $Fake.Buttons = Get-UnitState $U
    Expect 'press ENTER'; Tap Enter
    foreach ($p in $t.controls.PSObject.Properties) { Do-Control $U $p.Name (Get-Kind $p.Value) }
    $r = Run-Capture $path 'perfect'
    Check ($r.Rc -eq 0) "rc 0 (was $($r.Rc))"
    Assert-Captured (Read-Table $path)
    Check (Screen-Has 'Finished: 34 control\(s\)') 'says Finished: 34'
    Check (-not (Screen-Has '(?i)skipped|nothing changed|more than one|still held|could not read|centred|asks for')) 'no complaint on a perfect run'
    $saved = Read-Table $path
    foreach ($n in $Tog.Keys) {
        $c = $saved.controls.$n
        Check ($c.PSObject.Properties['otherPosition'] -and $c.otherPosition.prober -eq $Tog[$n][1] -and $c.otherPosition.fsuipc -eq ($Tog[$n][1] - 1)) ("$n otherPosition should be panel $($Tog[$n][1])")
    }
    Check ($saved.controls.MAG_R.otherPosition.prober -eq $KeyPos.MAG_OFF) 'MAG_R records that it came from OFF'
    Check ($saved.controls.MAG_OFF.otherPosition.prober -eq $KeyPos.MAG_BOTH) 'MAG_OFF records that it came from BOTH'
    Check ($Fake.Queue.Count -eq 0) "hands used every step (left: $($Fake.Queue.Count))"
    Check (Test-Path $r.Log) 'log written'
    $logText = Get-Content -LiteralPath $r.Log -Raw
    Check ($logText -match 'read: blank \(driver timestamp 0\), read again') 'log records the blank readings'
    Check ($logText -match '\] >> PTT:' -and $logText -match 'key: Enter' -and $logText -match 'read: [0-9,]+  hat=') 'log has screen lines, keys and readings'
    Check ($Fake.Buttons.Count -gt 0) 'fake unit never ended blank'
    Out-Line ("   {0}s, {1} readings" -f $r.Seconds, $Fake.Reads) DarkGray
}

$Scenarios['mistakes'] = {
    # Every mistake the prompts are written for, each followed by the right move.
    $path = New-FreshTable 'mistakes'; $t = Read-Table $path
    Reset-Fake; $U = New-Unit; $Fake.Buttons = Get-UnitState $U
    Expect 'press ENTER'; Tap Enter; Tap Enter            # Enter tapped twice at the gate
    foreach ($p in $t.controls.PSObject.Properties) {
        $n = $p.Name; $kind = Get-Kind $p.Value
        switch ($n) {
            'PTT' {
                # two buttons at once, then just the one
                Expect '^>> PTT:'; Wait 2; Hold $U 1; Hold $U 2; Wait 3
                Expect 'more than one'
                Release $U 2; Release $U 1; Wait 3
                Hold $U 1; Wait 4; Release $U 1
            }
            'LEFT_WHITE_BUTTON' {
                # a base switch flipped where a button was asked for (8 s wall-clock)
                Expect '^>> LEFT_WHITE_BUTTON:'; Wait 2; Flip $U SW_LAND on
                Expect 'still held after 8 seconds'
                Flip $U SW_LAND off; Wait 3
                Hold $U 2; Wait 4; Release $U 2
            }
            'HAT_UP' {
                Expect '^>> HAT_UP:'; HatTo Right; Tap Enter
                Expect 'asks for Up'
                HatTo Up; Tap Enter; Wait 2; HatTo Center
            }
            'HAT_UP_RIGHT' {
                Expect '^>> HAT_UP_RIGHT:'; Tap Enter          # hat centred
                Expect 'centred'
                HatTo UpRight; Tap Enter; Wait 2; HatTo Center
            }
            'HAT_UP_LEFT' {
                # the last hat, with a stray extra keypress after Enter - the
                # next control is a momentary one and must NOT be skipped by it
                Expect '^>> HAT_UP_LEFT:'; HatTo UpLeft; Tap Enter; Tap S; Wait 2; HatTo Center
            }
            'SW_ALT' {
                # flipped ON at Step 1 (already in the asked position), so
                # Step 2 changes nothing; then done properly
                Expect '^>> SW_ALT:'; Expect 'Step 1'; Flip $U SW_ALT on; Tap Enter
                Expect 'Step 2'; Tap Enter
                Expect 'nothing changed'
                Expect 'Step 1'; Flip $U SW_ALT off; Tap Enter
                Expect 'Step 2'; Flip $U SW_ALT on; Tap Enter
            }
            'SW_BAT' {
                # two switches moved at Step 2
                Expect '^>> SW_BAT:'; Expect 'Step 1'; Tap Enter
                Expect 'Step 2'; Flip $U SW_BAT on; Flip $U SW_LAND on; Tap Enter
                Expect 'more than one new button'
                Expect 'Step 1'; Flip $U SW_LAND off; Flip $U SW_BAT off; Tap Enter
                Expect 'Step 2'; Flip $U SW_BAT on; Tap Enter
            }
            'MAG_START' {
                # Enter without holding it, then held
                Expect '^>> MAG_START:'; Tap Enter
                Expect 'nothing is held'
                Turn $U MAG_START; Tap Enter; Wait 3; Turn $U MAG_BOTH
            }
            default { Do-Control $U $n $kind }
        }
    }
    $r = Run-Capture $path 'mistakes'
    Check ($r.Rc -eq 0) "rc 0 (was $($r.Rc))"
    Assert-Captured (Read-Table $path)
    Check (Screen-Has 'Finished: 34 control\(s\)') 'says Finished: 34'
    Check ((Screen-Count 'more than one new button appeared') -eq 1) 'PTT: two buttons reported once'
    Check ((Screen-Count 'still held after 8 seconds') -eq 1) 'LEFT_WHITE: switch-as-button reported once'
    Check ((Screen-Count 'asks for Up') -eq 1) 'HAT_UP: wrong direction reported once'
    Check ((Screen-Count 'centred') -eq 1) 'HAT_UP_RIGHT: centred reported once'
    Check ((Screen-Count 'nothing changed') -eq 1) 'SW_ALT: already-in-position reported once'
    Check ((Screen-Count 'more than one new button \(') -eq 1) 'SW_BAT: two switches reported once'
    Check ((Screen-Count 'nothing is held') -eq 1) 'MAG_START: not held reported once'
    Check (-not (Screen-Has '(?i)skipped')) 'nothing was skipped (the stray S after the last hat was drained)'
    Check ($Fake.Queue.Count -eq 0) "hands used every step (left: $($Fake.Queue.Count))"
    Out-Line ("   {0}s, {1} readings" -f $r.Seconds, $Fake.Reads) DarkGray
}

$Scenarios['no-console'] = {
    $path = New-FreshTable 'no-console'
    Reset-Fake; $U = New-Unit; $Fake.Buttons = Get-UnitState $U; $Fake.Console = $false
    $r = Run-Capture $path 'no-console'
    Check ($r.Rc -eq 2) "rc 2 (was $($r.Rc))"
    Check (Screen-Has 'PowerShell window of its own') 'says a console is needed'
    Check (-not (Screen-Has '^>> ')) 'asked for nothing'
    Assert-Captured (Read-Table $path) -Except @((Read-Table $path).controls.PSObject.Properties.Name)
}

$Scenarios['stop-resume'] = {
    # Q on the second control; a second run asks only for what is left; Q at its gate.
    $path = New-FreshTable 'stop-resume'
    Reset-Fake; $U = New-Unit; $Fake.Buttons = Get-UnitState $U
    Expect 'press ENTER'; Tap Enter
    Do-Control $U PTT momentary
    Expect '^>> LEFT_WHITE_BUTTON:'; Tap Q
    $r = Run-Capture $path 'stop-resume-1'
    Check ($r.Rc -eq 0) "first run rc 0 (was $($r.Rc))"
    Check (Screen-Has 'Stopped\. 1 captured') 'says Stopped. 1 captured'
    Check (Screen-Has 'Capturing 34 control') 'first run asked for 34'
    $t = Read-Table $path
    Check ($t.controls.PTT.verified -eq $true -and $t.controls.PTT.prober -eq 1) 'PTT saved before the stop'
    Assert-Captured $t -Except @($t.controls.PSObject.Properties.Name | Where-Object { $_ -ne 'PTT' })

    Reset-Fake; $Fake.Buttons = Get-UnitState $U
    Expect 'press ENTER'; Tap Q
    $r = Run-Capture $path 'stop-resume-2'
    Check ($r.Rc -eq 0) "second run rc 0 (was $($r.Rc))"
    Check (Screen-Has 'Capturing 33 control') 'second run asked for the remaining 33'
    Check (Screen-Has 'Stopped before the first control') 'Q at the gate stops cleanly'
    $t2 = Read-Table $path
    Check (($t2 | ConvertTo-Json -Depth 10) -eq ($t | ConvertTo-Json -Depth 10)) 'table unchanged by the stopped second run'
}

$Scenarios['skips'] = {
    # S on a hat diagonal, on a momentary, and at a switch's Step 1; a later
    # run asks for exactly those three.
    $path = New-FreshTable 'skips'; $t = Read-Table $path
    Reset-Fake; $U = New-Unit; $Fake.Buttons = Get-UnitState $U
    Expect 'press ENTER'; Tap Enter
    $skip = @('HAT_UP_RIGHT', 'RED_BUTTON', 'SW_ALT')
    foreach ($p in $t.controls.PSObject.Properties) {
        $n = $p.Name; $kind = Get-Kind $p.Value
        if ($skip -contains $n) {
            Expect ('^>> {0}:' -f $n)
            if ($kind -eq 'latching') { Expect 'Step 1' }
            Tap S
        }
        else { Do-Control $U $n $kind }
    }
    $r = Run-Capture $path 'skips'
    Check ($r.Rc -eq 0) "rc 0 (was $($r.Rc))"
    Check (Screen-Has 'Finished: 31 control\(s\)') 'says Finished: 31'
    Check ((Screen-Count '^   skipped$') -eq 3) 'three skips reported'
    Assert-Captured (Read-Table $path) -Except $skip

    Reset-Fake; $Fake.Buttons = Get-UnitState $U
    Expect 'press ENTER'; Tap Q
    $r = Run-Capture $path 'skips-2'
    Check (Screen-Has 'Capturing 3 control') 'second run asks for the three skipped'
}

$Scenarios['no-hat-unit'] = {
    # Windows reports no hat switch: hat lines are skipped with a reason, the rest captured.
    $path = New-FreshTable 'no-hat'; $t = Read-Table $path
    Reset-Fake; $U = New-Unit; $Fake.Buttons = Get-UnitState $U; $Fake.SwitchCount = 0
    Expect 'press ENTER'; Tap Enter
    $hats = @($t.controls.PSObject.Properties | Where-Object { (Get-Kind $_.Value) -eq 'hat' } | ForEach-Object { $_.Name })
    foreach ($p in $t.controls.PSObject.Properties) {
        $n = $p.Name; $kind = Get-Kind $p.Value
        if ($kind -eq 'hat') { Expect ('^>> {0}:' -f $n) } else { Do-Control $U $n $kind }
    }
    $r = Run-Capture $path 'no-hat'
    Check ($r.Rc -eq 0) "rc 0 (was $($r.Rc))"
    Check ((Screen-Count 'reports no hat switch') -eq 8) 'eight hat lines say why'
    Check (Screen-Has 'Finished: 26 control\(s\)') 'says Finished: 26'
    Assert-Captured (Read-Table $path) -Except $hats
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
$names = @($Scenarios.Keys | Where-Object { -not $Only -or $_ -like $Only })
if ($names.Count -eq 0) { Out-Line "No scenario matches '$Only'. Known: $($Scenarios.Keys -join ', ')" Red; exit 1 }
$total = [Diagnostics.Stopwatch]::StartNew()
foreach ($n in $names) {
    Out-Line ('== ' + $n) Cyan
    $before = $script:Failures.Count
    try { & $Scenarios[$n] }
    catch { $script:Failures.Add("$n threw: $($_.Exception.Message)"); Out-Line ('   THREW: ' + $_.Exception.Message) Red }
    if ($script:Failures.Count -eq $before) { Out-Line '   ok' Green }
}
$total.Stop()
Out-Line ''
if ($script:Failures.Count -eq 0) {
    Out-Line ("All {0} checks passed in {1} scenario(s), {2}s. Work files: {3}" -f $script:Checks, $names.Count, [math]::Round($total.Elapsed.TotalSeconds), $work) Green
    exit 0
}
Out-Line ("{0} of {1} checks FAILED:" -f $script:Failures.Count, $script:Checks) Red
$script:Failures | ForEach-Object { Out-Line ('  - ' + $_) Red }
Out-Line ("Work files: {0}" -f $work) DarkGray
exit 1
