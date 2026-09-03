<#
    Preflight check: FSUIPC7.

    FSUIPC owns the Alpha and Bravo bindings, so if it is missing, unregistered
    or has not scanned the hardware, the controls will not work and nothing else
    in the program can compensate. Those cases are blocking.

    Dot-sourced by Invoke-Preflight.ps1 and runs in its scope, so Add-Result,
    Join-PathSafe, Test-PathSafe, Get-FirstMatch and Find-Msfs2024 are available.

    Read-only.
#>

@{
    Name        = 'FSUIPC'
    Description = 'FSUIPC7 installation, licence, device scan and settings'

    Run = {

        # -- locate it. Never assume a path. ---------------------------------
        function Find-FsuipcRoot {
            try {
                $p = Get-Process -Name 'FSUIPC7' -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($p -and $p.Path) { return (Split-Path $p.Path -Parent) }
            } catch { }

            foreach ($k in @(
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
                try {
                    $hit = Get-ItemProperty $k -ErrorAction SilentlyContinue |
                           Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -match 'FSUIPC7' } |
                           Select-Object -First 1
                    if ($hit -and $hit.PSObject.Properties['InstallLocation'] -and
                        $hit.InstallLocation -and (Test-PathSafe $hit.InstallLocation)) {
                        return $hit.InstallLocation.TrimEnd('\')
                    }
                } catch { }
            }

            $candidates = New-Object System.Collections.ArrayList
            foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
                [void]$candidates.Add((Join-PathSafe $d.Root 'FSUIPC7'))
            }
            foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
                if ($base) { [void]$candidates.Add((Join-PathSafe $base 'FSUIPC7')) }
            }
            foreach ($c in $candidates) {
                if (Test-PathSafe (Join-PathSafe $c 'FSUIPC7.exe')) { return $c }
            }
            return $null
        }

        $root = Find-FsuipcRoot
        if (-not $root) {
            Add-Result 'FSUIPC7 installed' 'FAIL' -Blocking `
                'FSUIPC7 was not found on this computer.' `
                'FSUIPC7 is what makes the throttle levers work. It needs installing before the program can set up your controls.'
            return
        }

        $exe = Join-PathSafe $root 'FSUIPC7.exe'
        Add-Result 'FSUIPC7 installed' 'PASS' ("{0} (version {1})" -f $exe, (Get-Item $exe).VersionInfo.FileVersion)

        # -- licence ---------------------------------------------------------
        # Axis assignment is a paid feature. Without a key the whole approach
        # fails, and it fails quietly, so this blocks.
        if (Test-PathSafe (Join-PathSafe $root 'FSUIPC7.key')) {
            Add-Result 'FSUIPC7 registered' 'PASS' 'Licence key present'
        } else {
            Add-Result 'FSUIPC7 registered' 'FAIL' -Blocking `
                'FSUIPC7 is installed but has no licence key.' `
                'The paid version of FSUIPC7 is needed to assign the throttle levers. The free version cannot do it.'
        }

        # -- what the log tells us -------------------------------------------
        $logPath = Join-PathSafe $root 'FSUIPC7.log'
        if (-not (Test-PathSafe $logPath)) {
            Add-Result 'FSUIPC7 has run' 'TODO' 'No log file yet - FSUIPC7 has never been run on this computer.' `
                'Start FSUIPC7 once so it can find your throttle quadrant.'
        } else {
            $lines = @(Get-Content -LiteralPath $logPath -ErrorAction SilentlyContinue)
            if ($lines.Count -eq 0) {
                Add-Result 'FSUIPC7 has run' 'TODO' 'Log file is empty.' 'Start FSUIPC7 once and let it finish loading.'
            } else {
                Add-Result 'FSUIPC7 has run' 'PASS' ("Log has {0} lines, last written {1}" -f $lines.Count, (Get-Item $logPath).LastWriteTime)

                # Test POSITIVELY for the key being accepted. Do not scan for
                # "unregistered": FSUIPC writes "Hot key unregistered" during a
                # normal clean shutdown, and treating that as a licence failure
                # reports a healthy machine as broken. A gate that cries wolf
                # gets ignored, and an ignored gate is worse than none.
                if ($lines -match '(?i)FSUIPC7 Key is provided') {
                    $who = Get-FirstMatch -Lines $lines -Pattern 'User Name="([^"]+)"'
                    Add-Result 'Licence accepted' 'PASS' $(if ($who) { "Registered to $($who[1])" } else { 'Key accepted' })
                } elseif ($lines -match '(?i)Key NOT provided|not registered') {
                    Add-Result 'Licence accepted' 'FAIL' -Blocking `
                        'FSUIPC7 did not accept its licence key.' `
                        'The FSUIPC7 licence needs re-entering. Its own Help menu has the registration screen.'
                }

                # Whole words only, and deliberately NOT '***' - FSUIPC uses
                # that for its banner, its shutdown lines and harmless notices.
                $err = @($lines | Select-String -Pattern '(?i)\berror\b|\bfailed\b|\bunable\b|\bcannot\b' |
                         Select-Object -First 5 | ForEach-Object { $_.Line.Trim() })
                if ($err) { Add-Result 'FSUIPC7 log errors' 'WARN' ($err -join ' | ') 'Worth a look, but not necessarily stopping you flying.' }
                else      { Add-Result 'FSUIPC7 log errors' 'PASS' 'No errors in the log' }

                $sim = @($lines | Select-String -Pattern 'SimConnect_Open succeeded|MSFS version =' |
                         ForEach-Object { $_.Line.Trim() })
                if ($sim) { Add-Result 'Talks to the simulator' 'PASS' ($sim -join ' | ') }
                else      { Add-Result 'Talks to the simulator' 'SKIP' 'This log records no connection to the simulator, so it is untested.' }
            }
        }

        # -- settings and identity from the ini -------------------------------
        $iniPath = Join-PathSafe $root 'FSUIPC7.ini'
        if (-not (Test-PathSafe $iniPath)) {
            Add-Result 'FSUIPC7 settings' 'TODO' 'No FSUIPC7.ini yet.' 'Start FSUIPC7 once; it writes its settings file on the way up.'
            return
        }
        $text = @(Get-Content -LiteralPath $iniPath -ErrorAction SilentlyContinue)

        # Absent is TODO, not a fault. A machine nobody has set up is supposed
        # to look like this.
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
                Add-Result "Setting: $k" 'TODO' ("not set; needs '{0}'" -f $want[$k]) 'The setup step will set this for you.'
            } elseif ($m[1].Trim() -eq $want[$k]) {
                Add-Result "Setting: $k" 'PASS' $m[1].Trim()
            } else {
                Add-Result "Setting: $k" 'WARN' ("is '{0}', needs '{1}'" -f $m[1].Trim(), $want[$k]) 'The setup step can correct this.'
            }
        }

        # [JoyNames] - does FSUIPC know the hardware?
        $joy = New-Object System.Collections.ArrayList
        $inSection = $false
        foreach ($l in $text) {
            if ($l -match '^\[JoyNames\]') { $inSection = $true;  continue }
            if ($l -match '^\[')           { $inSection = $false; continue }
            if ($inSection -and $l.Trim()) { [void]$joy.Add($l.Trim()) }
        }
        if ($joy.Count -eq 0) {
            Add-Result 'Quadrant known to FSUIPC' 'TODO' 'FSUIPC has not scanned for controllers yet.' `
                'Plug in the throttle quadrant and start FSUIPC7 once.'
        } else {
            # Whether the hardware is physically attached is answered live by the
            # Honeycomb check, which runs first. This is the different question
            # of whether FSUIPC has a record of it - its [JoyNames] is a snapshot
            # from its last run, so it can be out of date even when everything is
            # plugged in. Different fault, different fix, different wording.
            # If the device is not physically attached, the Honeycomb check has
            # already said so and FSUIPC not knowing about it is a consequence,
            # not a second thing to fix. Step aside and let the root cause stand
            # alone - two instructions for one fault is worse than one.
            foreach ($dev in @(
                @{ Match = 'Bravo'; Label = 'quadrant'; Root = 'Bravo throttle quadrant connected'
                   Detail = 'FSUIPC has no record of the throttle quadrant, so it cannot control the levers.' },
                @{ Match = 'Alpha'; Label = 'yoke';     Root = 'Alpha yoke connected'
                   Detail = 'FSUIPC has no record of the yoke, so it cannot control it.' }
            )) {
                $entry = @($joy | Where-Object { $_ -match $dev.Match -and $_ -notmatch '\.GUID' })
                if ($entry) {
                    Add-Result ("FSUIPC knows the {0}" -f $dev.Label) 'PASS' ($entry -join ' | ')
                } elseif (Test-AlreadyFailed $dev.Root) {
                    Add-Result ("FSUIPC knows the {0}" -f $dev.Label) 'SKIP' `
                        ("Not checked - the {0} is not plugged in, which is already reported above." -f $dev.Label)
                } else {
                    Add-Result ("FSUIPC knows the {0}" -f $dev.Label) 'FAIL' -Blocking `
                        $dev.Detail `
                        ("Start FSUIPC7 once with the {0} plugged in. It looks for controllers as it starts up." -f $dev.Label)
                }
            }

            # Anything else holding an id shifts the numbering of everything
            # else, which silently breaks assignments written against old ids.
            $others = @($joy | Where-Object { $_ -notmatch '\.GUID' -and $_ -notmatch 'Bravo|Alpha' })
            if ($others) {
                Add-Result 'Other controllers present' 'INFO' `
                    (($others -join ' | ') + ' - these take up controller numbers and can shift the quadrant to a different one')
            }
        }

        # Count real assignment lines inside [Axes], which look like
        #   0=BY,256,D,66420,0,0,0
        # The previous test looked for the word "axis" in the line, which no
        # actual FSUIPC assignment contains - so freshly written assignments
        # were still reported as missing.
        $axisLines = New-Object System.Collections.ArrayList
        $inAxes = $false
        foreach ($l in $text) {
            if ($l -match '^\s*\[Axes')  { $inAxes = $true;  continue }
            if ($l -match '^\s*\[')      { $inAxes = $false; continue }
            if ($inAxes -and $l -match '^\s*\d+\s*=\s*[A-Z]{2},') { [void]$axisLines.Add($l) }
        }
        $profiles  = @($text | Select-String -Pattern '^\[Profile\.')
        if ($axisLines.Count) { Add-Result 'Lever assignments' 'PASS' ("{0} assignment line(s)" -f $axisLines.Count) }
        else { Add-Result 'Lever assignments' 'TODO' 'No lever assignments written yet.' `
                 'Nothing is wrong. This is the part that tells FSUIPC what each lever does, and it has not been built yet. Set the levers up in FSUIPC by hand in the meantime.' }
        if ($profiles.Count) { Add-Result 'Aircraft profiles' 'PASS' ("{0} profile(s)" -f $profiles.Count) }
        else { Add-Result 'Aircraft profiles' 'TODO' 'No per-aircraft profiles yet.' `
                 'Nothing is wrong. Per-aircraft switching has not been built yet, so FSUIPC uses one set of assignments for everything.' }
    }
}
