<#
    Phase 3c. Are the simulator's two graphics traffic levels right for the
    chosen traffic engine?

    Three modes (Mark, 2026-09-11): BATC and FSLTL feed the traffic themselves,
    so the sim's own Aircraft Traffic and Parked Aircraft must be OFF or the
    two engines double up; MSFS uses Asobo's engine, and those two are ULTRA
    (Mark's choice, 2026-09-12).

    Unlike the Traffic Type on the Online page (cloud profile, a person's
    word), these two ARE on disk: Graphics > Traffic in UserCfg.opt, which the
    sim rewrites within a second or two of every change (measured 2026-09-07
    and 2026-09-12: Off writes -1, Ultra writes 3). So this check reads them
    and says what it read. Levels other than -1 and 3 have not been read back
    against their words, so they are reported as levels, not guessed at.

    WARN, not FAIL: a flight with doubled traffic is wrong, not broken, and the
    printout in the launcher walks the person through the fix and confirms it
    by itself. Read-only, like every check.
#>

@{
    Name        = 'Traffic'
    Description = 'The simulator''s Aircraft Traffic and Parked Aircraft levels match the chosen traffic engine'

    Run = {

        $c = Get-AppConfig
        if ($c.State -ne 'Ok') {
            Add-Result 'Traffic graphics levels' 'SKIP' 'Not checked - no usable configuration, which is already reported above.'
            return
        }
        $cfg = $c.Config

        $mode = ''
        try { if ($cfg.PSObject.Properties['trafficMode']) { $mode = [string]$cfg.trafficMode } } catch { }
        if (-not $mode) {
            Add-Result 'Traffic graphics levels' 'TODO' `
                'No traffic engine has been chosen yet, so there is nothing to compare the simulator against.' `
                'In the launcher, choose BATC, FSLTL or MSFS in the Traffic box at the top.'
            return
        }

        # What the mode needs: the same table as AppConfig.GraphicsRequiredFor.
        switch ($mode) {
            'BATC'  { $needA = -1; $needP = -1 }
            'FSLTL' { $needA = -1; $needP = -1 }
            'MSFS'  { $needA =  3; $needP =  3 }
            default {
                Add-Result 'Traffic graphics levels' 'WARN' ('The configuration names a traffic engine this check does not know: "' + $mode + '".') `
                    'In the launcher, choose BATC, FSLTL or MSFS in the Traffic box at the top.'
                return
            }
        }
        function Word([int] $level) { switch ($level) { -1 { 'Off' } 3 { 'Ultra' } default { 'level ' + $level } } }

        $installs = @(Find-Msfs2024)
        if ($installs.Count -eq 0) {
            Add-Result 'Traffic graphics levels' 'SKIP' 'Not checked - the simulator''s settings file was not found, which is already reported above.'
            return
        }
        $path = $installs[0].UserCfg
        $text = $null
        try { $text = Get-Content -LiteralPath $path -Raw -ErrorAction Stop } catch {
            Add-Result 'Traffic graphics levels' 'WARN' ('The simulator''s settings file could not be read: ' + $_.Exception.Message) `
                'Nothing to do at the controls - tell the person who set this up.'
            return
        }
        # The first {Traffic block is the one under {Graphics; {GraphicsVR has its own.
        $at = $text.IndexOf('{Traffic')
        if ($at -lt 0) {
            Add-Result 'Traffic graphics levels' 'WARN' ('No traffic block in ' + $path + '.') 'Nothing to do at the controls - tell the person who set this up.'
            return
        }
        $end = $text.IndexOf('}', $at); if ($end -lt 0) { $end = $text.Length }
        $block = $text.Substring($at, $end - $at)
        $ma = [regex]::Match($block, 'AircraftTrafficQuantity\s+(-?\d+)')
        $mp = [regex]::Match($block, 'ParkedAircraftQuantity\s+(-?\d+)')
        if (-not $ma.Success -or -not $mp.Success) {
            Add-Result 'Traffic graphics levels' 'WARN' ('The traffic block in ' + $path + ' does not hold both Aircraft Traffic and Parked Aircraft.') `
                'Nothing to do at the controls - tell the person who set this up.'
            return
        }
        $a = [int]$ma.Groups[1].Value
        $p = [int]$mp.Groups[1].Value
        $when = ''
        try { $when = (Get-Item -LiteralPath $path).LastWriteTime.ToString('yyyy-MM-dd HH:mm') } catch { }

        if ($a -eq $needA -and $p -eq $needP) {
            Add-Result 'Traffic graphics levels' 'PASS' `
                ('Aircraft Traffic ' + (Word $a) + ', Parked Aircraft ' + (Word $p) + ' - right for ' + $mode + '. Read from the simulator''s settings file' + $(if ($when) { ' (last saved ' + $when + ')' } else { '' }) + '.')
            return
        }
        Add-Result 'Traffic graphics levels' 'WARN' `
            ('The simulator has Aircraft Traffic ' + (Word $a) + ' and Parked Aircraft ' + (Word $p) + '; ' + $mode + ' needs ' + (Word $needA) + ' and ' + (Word $needP) + '. Read from the simulator''s settings file' + $(if ($when) { ' (last saved ' + $when + ')' } else { '' }) + '.') `
            ('In the simulator, open Options, General, Graphics, and set Aircraft Traffic to ' + (Word $needA) + ' and Parked Aircraft to ' + (Word $needP) + ', then Save and back. The launcher''s printout confirms it by itself.')
    }
}
