<#
    Phase 3b. Has the simulator been told to leave the Bravo alone?

    FSUIPC drives the levers. If MSFS is ALSO binding the same axes, the two
    fight, and the symptom is a lever that seems to ignore whatever was just
    changed - with no error from either program. The cure is to select an
    EMPTY Bravo profile in MSFS's controls options.

    That setting cannot be read from disk. MSFS 2024 keeps controller profiles
    in a cloud-synced binary container, not in a file this program could open.
    So this check cannot verify it, and does not pretend to. What it can do is
    refuse to be silent about it: until a person has confirmed the setting once
    on this machine, it says so, and once they have, it records who and when.

    TODO rather than WARN, because it is a one-time setup step that clears when
    done - not something that would sit amber on every launch with nothing to
    do about it. Never blocking, because the program cannot know it is wrong.

    The confirmation is recorded by tools\Confirm-SimBravoProfile.ps1 (or by
    the app's setup step) as msfsBravoProfileConfirmedUtc in config.json.
    Read-only here, like every check.
#>

@{
    Name        = 'Simulator'
    Description = 'MSFS is using an empty Bravo profile, so it does not fight FSUIPC for the levers'

    Run = {

        $c = Get-AppConfig
        if ($c.State -ne 'Ok') {
            Add-Result 'Bravo profile in MSFS' 'SKIP' 'Not checked - no usable configuration, which is already reported above.'
            return
        }
        $cfg = $c.Config

        $when = ''
        $who  = ''
        try {
            if ($cfg.PSObject.Properties['msfsBravoProfileConfirmedUtc']) { $when = [string]$cfg.msfsBravoProfileConfirmedUtc }
            if ($cfg.PSObject.Properties['msfsBravoProfileConfirmedBy'])  { $who  = [string]$cfg.msfsBravoProfileConfirmedBy }
        } catch { }

        if (-not $when) {
            Add-Result 'Bravo profile in MSFS' 'TODO' `
                'Not yet confirmed on this computer. This program cannot read the setting, so someone has to look once.' `
                'In the simulator, open Options, then Controls, select the Bravo Throttle Quadrant, and make sure the profile chosen is the EMPTY one - not the one with throttle bindings. Then record it with the setup step, and this will stay green.'
            return
        }

        Add-Result 'Bravo profile in MSFS' 'PASS' `
            ('Confirmed empty{0} on {1}. Not re-checked - the simulator does not expose this setting.' -f
                $(if ($who) { ' by ' + $who } else { '' }), $when)
    }
}
