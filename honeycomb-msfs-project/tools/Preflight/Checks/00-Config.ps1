<#
    Phase 0. Can the program run at all, and does it know this machine.

    Runs before everything else because nothing later can be compared against
    anything without a configuration to compare it to, and because rewriting
    configuration underneath a running simulator is a good way to produce a
    mess that is hard to explain afterwards.

    Read-only, like every check. Setup writes the configuration; the gate only
    ever reads it.
#>

@{
    Name        = 'Config'
    Description = 'Simulator not already running, and a usable configuration file'

    Run = {

        # --- is the simulator already up? -------------------------------------
        # MSFS 2024 is the Store package Microsoft.Limitless; the process name
        # has not been observed on this machine because the simulator was not
        # running when this was written, so several plausible names are matched
        # rather than one being asserted.
        $sim = @(Get-Process -ErrorAction SilentlyContinue |
                 Where-Object { $_.ProcessName -match '(?i)FlightSimulator|Limitless' })
        # INFO, not WARN. The gate never writes anything, so a running simulator
        # is not a problem for it - and once the user has pressed Start, the
        # simulator running is the expected state. Warning about it then is
        # noise, and noise is what teaches people to ignore amber.
        #
        # The blocking version of this belongs to SETUP, which does write, and
        # must refuse while the simulator holds its configuration in memory.
        if ($sim.Count -gt 0) {
            Add-Result 'Simulator' 'INFO' `
                ('Running (' + (($sim | ForEach-Object { $_.ProcessName }) -join ', ') + ')')
        } else {
            Add-Result 'Simulator' 'INFO' 'Not running'
        }

        # --- the configuration file -------------------------------------------
        $c = Get-AppConfig

        if ($c.State -eq 'Missing') {
            # Not a fault. A machine nobody has set up is supposed to look
            # exactly like this, and saying otherwise teaches the user to
            # ignore the report.
            Add-Result 'Configuration' 'TODO' `
                ('No configuration file yet at ' + $c.Path) `
                'This computer has not been set up. The setup step will find your simulator and hardware and write this file.'
            return
        }

        if ($c.State -eq 'Unreadable') {
            # Deliberately blocking, and deliberately NOT self-healing. A file
            # that will not parse may still hold a working setup, and quietly
            # replacing it destroys the only copy of what used to work.
            Add-Result 'Configuration' 'FAIL' -Blocking `
                ('The settings file cannot be read: ' + $c.Why + ' (' + $c.Path + ')') `
                'The settings file is damaged. Restore the backup made before the last change rather than deleting it, so nothing already working is lost.'
            return
        }

        if ($c.State -eq 'WrongSchema') {
            Add-Result 'Configuration' 'FAIL' -Blocking `
                ('The settings file was written by a different version of this program (found version ' +
                 $c.Found + ', this program expects ' + $script:ConfigSchema + ').') `
                'The settings need bringing up to date before the program can trust them. Run setup, which will convert them.'
            return
        }

        $cfg = $c.Config
        $when = ''
        try { if ($cfg.PSObject.Properties['generatedUtc']) { $when = ', recorded ' + $cfg.generatedUtc } } catch { }
        Add-Result 'Configuration' 'PASS' ('Version ' + $script:ConfigSchema + $when)

        # A configuration written on a different computer is worth saying out
        # loud: every hardware id and path in it belongs to that other machine.
        try {
            if ($cfg.PSObject.Properties['machine'] -and $cfg.machine -and $cfg.machine -ne $env:COMPUTERNAME) {
                Add-Result 'Configuration belongs to this computer' 'WARN' `
                    ('These settings were recorded on a computer called ' + $cfg.machine +
                     ', this one is called ' + $env:COMPUTERNAME + '.') `
                    'Paths and hardware identifiers do not carry between computers. Run setup on this one.'
            }
        } catch { }
    }
}
