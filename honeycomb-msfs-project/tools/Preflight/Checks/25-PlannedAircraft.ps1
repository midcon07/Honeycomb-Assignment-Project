<#
    Phase 2b. Is the aircraft about to be flown actually set up on this machine?

    This is the check that closes a gap the rest of the gate cannot see. The
    global [Axes] section in FSUIPC7.ini is kept EMPTY by design, so an aircraft
    with no profile gets no working levers at all - the honest failure, chosen
    over inheriting some other aircraft's layout. But it means every green
    check above can pass and the quadrant still be dead for the flight ahead.
    Nothing else here relates "the machine is set up" to "this flight will
    work"; this does.

    The aircraft comes from the SimBrief plan when one can be fetched, and from
    the last aircraft chosen in the app otherwise. It is identified by ICAO type
    (B350, DA62 ...), which SimBrief provides and the app already records.

    Two things must both be true:
      1. the type is in the curated aircraft table (data/lever-layouts.json) -
         that is where the lever layout is decided, and it cannot be read from
         the sim's packages, which are opaque archives on MSFS 2024;
      2. FSUIPC7.ini carries [Profile.<match>] and a non-empty [Axes.<match>]
         for that entry - the lever settings have actually been written.

    Either missing is blocking: continuing would mean a flight with no working
    throttle, discovered on the runway.

    Runs after FSUIPC (10) and Internet (20), and uses the SimBrief fetch only
    as a source of the aircraft type - the plan step itself may never block.
    Read-only.
#>

@{
    Name        = 'PlannedAircraft'
    Description = 'The aircraft in the flight plan has a lever layout and an FSUIPC profile'

    Run = {

        $c = Get-AppConfig
        if ($c.State -ne 'Ok') {
            Add-Result 'Planned aircraft' 'SKIP' 'Not checked - no usable configuration, which is already reported above.'
            return
        }
        $cfg = $c.Config

        # --- which aircraft? --------------------------------------------------
        $icao   = ''
        $source = ''
        $planName = ''

        $pilotId = ''
        try { if ($cfg.PSObject.Properties['simBriefPilotId']) { $pilotId = [string]$cfg.simBriefPilotId } } catch { }

        if ($pilotId) {
            # $script:ProjectRoot is published by Invoke-Preflight; $PSScriptRoot
            # is not dependable inside a check's Run block.
            $fetcher = Join-PathSafe $script:ProjectRoot 'tools\Get-SimBriefPlan.ps1'
            if (Test-PathSafe $fetcher) {
                try {
                    $plan = & $fetcher -PilotId $pilotId -Quiet -ErrorAction Stop 2>$null
                    if ($plan -and $plan.PSObject.Properties['AircraftIcao'] -and $plan.AircraftIcao) {
                        $icao     = ([string]$plan.AircraftIcao).Trim()
                        $planName = [string]$plan.AircraftName
                        $source   = 'the SimBrief plan'
                    }
                } catch {
                    # SimBrief being unreachable is reported by the Internet check.
                    # Here it only means falling back to the last aircraft chosen.
                }
            }
        }

        if (-not $icao) {
            try { if ($cfg.PSObject.Properties['lastAircraftId']) { $icao = ([string]$cfg.lastAircraftId).Trim() } } catch { }
            if ($icao) { $source = 'the last aircraft chosen in this program' }
        }

        if (-not $icao) {
            # Not a fault. A fresh machine with no plan and no aircraft chosen
            # is supposed to look like this.
            Add-Result 'Planned aircraft' 'TODO' `
                'No flight plan could be read and no aircraft has been chosen yet.' `
                'Make a plan in SimBrief, or pick an aircraft in this program, and this will check it.'
            return
        }
        $icaoU = $icao.ToUpper()

        # --- is it in the aircraft table? --------------------------------------
        $dataFile = Join-PathSafe $script:ProjectRoot 'data\lever-layouts.json'
        if (-not (Test-PathSafe $dataFile)) {
            Add-Result 'Planned aircraft' 'FAIL' -Blocking `
                ('The aircraft table is missing: ' + $dataFile) `
                'The program files are incomplete. Reinstall the program.'
            return
        }

        $entries = @()
        try {
            $table = Get-Content -LiteralPath $dataFile -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($table.PSObject.Properties['aircraft']) { $entries = @($table.aircraft) }
        } catch {
            Add-Result 'Planned aircraft' 'FAIL' -Blocking `
                ('The aircraft table cannot be read: ' + $_.Exception.Message) `
                'The program files are damaged. Reinstall the program.'
            return
        }

        $entry = @($entries | Where-Object {
            $_.PSObject.Properties['icao'] -and ([string]$_.icao).ToUpper() -eq $icaoU
        })

        $shown = if ($planName) { '{0} ({1})' -f $planName, $icaoU } else { $icaoU }

        if ($entry.Count -eq 0) {
            $known = @($entries | ForEach-Object { if ($_.PSObject.Properties['icao']) { $_.icao } }) -join ', '
            Add-Result 'Planned aircraft' 'FAIL' -Blocking `
                ('{0} is not set up on this computer. It came from {1}.' -f $shown, $source) `
                ('The throttle levers will not work in it until it is set up. Setting it up needs two answers: does it have a propeller lever, and does it have a mixture or condition lever. Aircraft already set up: {0}.' -f $(if ($known) { $known } else { 'none' }))
            return
        }
        if ($entry.Count -gt 1) {
            Add-Result 'Planned aircraft' 'FAIL' -Blocking `
                ('The aircraft table lists {0} more than once.' -f $icaoU) `
                'The aircraft table needs correcting before this aircraft can be trusted.'
            return
        }
        $e     = $entry[0]
        $match = [string]$e.match
        $name  = [string]$e.name

        # --- has its profile been written to FSUIPC? -----------------------------
        $root = ''
        try { if ($cfg.PSObject.Properties['fsuipcRoot']) { $root = [string]$cfg.fsuipcRoot } } catch { }
        $iniPath = if ($root) { Join-PathSafe $root 'FSUIPC7.ini' } else { '' }

        if (-not $iniPath -or -not (Test-PathSafe $iniPath)) {
            Add-Result 'Planned aircraft' 'SKIP' `
                ('{0} is in the aircraft table, but FSUIPC7.ini could not be found to confirm its lever settings.' -f $name) `
                'The FSUIPC checks above say whether FSUIPC7 is installed and has run.'
            return
        }

        $text = @(Get-Content -LiteralPath $iniPath -ErrorAction SilentlyContinue)
        $profRx = '^\s*\[Profile\.' + [regex]::Escape($match) + '\]\s*$'
        $axesRx = '^\s*\[Axes\.'    + [regex]::Escape($match) + '\]\s*$'

        $hasProfile = [bool]($text | Where-Object { $_ -match $profRx } | Select-Object -First 1)

        $leverLines = 0
        $inAxes = $false
        foreach ($l in $text) {
            if ($l -match $axesRx) { $inAxes = $true; continue }
            if ($l -match '^\s*\[') { $inAxes = $false; continue }
            if ($inAxes -and $l -match '^\s*\d+\s*=\s*[A-Z][A-Z],') { $leverLines++ }
        }

        if (-not $hasProfile -or $leverLines -eq 0) {
            Add-Result 'Planned aircraft' 'FAIL' -Blocking `
                ('{0} is known, but its lever settings have not been written to FSUIPC ({1}).' -f $name,
                    $(if (-not $hasProfile) { 'no profile section' } else { 'profile has no lever lines' })) `
                ('Run the lever setup for the {0} before flying. Until then the throttle levers will do nothing in it.' -f $name)
            return
        }

        $verified = ''
        try { if ($e.PSObject.Properties['verified']) { $verified = [string]$e.verified } } catch { }

        Add-Result 'Planned aircraft' 'PASS' `
            ('{0} - layout {1}, {2} lever(s) assigned in FSUIPC, from {3}' -f $name, $e.layout, $leverLines, $source)

        if ($verified -and $verified -notmatch '^flown') {
            # Written from what the aircraft type implies rather than from seeing
            # the levers move. Worth knowing, not worth stopping for.
            Add-Result 'Planned aircraft verified in the sim' 'INFO' `
                ('{0}: {1}' -f $name, $verified)
        }

        # The global section is meant to be empty. If it is not, say what that
        # means rather than treating it as a fault - it is a choice.
        $globalLines = 0
        $inG = $false
        foreach ($l in $text) {
            if ($l -match '^\s*\[Axes\]\s*$') { $inG = $true; continue }
            if ($l -match '^\s*\[') { $inG = $false; continue }
            if ($inG -and $l -match '^\s*\d+\s*=\s*[A-Z][A-Z],') { $globalLines++ }
        }
        if ($globalLines -gt 0) {
            Add-Result 'Global lever assignments' 'INFO' `
                ('{0} line(s) in the global [Axes] section. These apply to any aircraft with no profile of its own.' -f $globalLines)
        }
    }
}
