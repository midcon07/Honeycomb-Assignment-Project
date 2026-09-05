<#
    Preflight check: are the flight controls plugged in, right now.

    Not Honeycomb-only - the rudder pedals are WinWing. The check is about the
    controls this cockpit needs, whoever made them.

    Deliberately asks Windows rather than reading FSUIPC's [JoyNames]. That
    section is a snapshot from whenever FSUIPC last ran and will happily report
    hardware that was unplugged yesterday. Presence is a live question and must
    be answered live.

    All three are blocking. Without the yoke, the quadrant or the pedals there
    is no proper flight, and continuing would only produce a confusing session
    in which some of the controls do nothing.

    Runs before the FSUIPC check: if the hardware is not there, FSUIPC's opinion
    of it is beside the point.

    Read-only. Win32_PnPEntity needs no admin rights.
#>

@{
    Name        = 'FlightControls'
    Description = 'Yoke, throttle quadrant and rudder pedals present and healthy'

    Run = {

        # VID/PID measured from the hardware, not taken from documentation.
        # Ranges differ between makers: the Bravo reports 0-1023, the WinWing
        # pedals 0-65535. Anything assuming one range would be wrong for the
        # other.
        # Verb and pronoun per device: one plural template produced "The yoke
        # are not plugged in", which reads badly to anyone, and worse to someone
        # who reads literally.
        $devices = @(
            [pscustomobject]@{ Label = 'Bravo throttle quadrant'; Vid = '294B'; Pid = '1901'
                               Plain = 'throttle quadrant'; Verb = 'is';  It = 'it' }
            [pscustomobject]@{ Label = 'Alpha yoke';              Vid = '294B'; Pid = '1900'
                               Plain = 'yoke';               Verb = 'is';  It = 'it' }
            [pscustomobject]@{ Label = 'Rudder pedals';           Vid = '4098'; Pid = 'BEF0'
                               Plain = 'rudder pedals';      Verb = 'are'; It = 'them' }
        )

        # One query for everything with a VID, then match locally. Cheaper than
        # a query per device.
        $found = $null
        try {
            $found = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop |
                       Where-Object { $_.PNPDeviceID -match 'VID_[0-9A-F]{4}&PID_[0-9A-F]{4}' })
        } catch {
            Add-Result 'Hardware detection' 'SKIP' `
                ('Windows could not be asked which devices are attached: {0}' -f $_.Exception.Message) `
                'This is a fault in the program, not your setup. Report it.'
            return
        }

        foreach ($d in $devices) {
            $pattern = 'VID_{0}&PID_{1}' -f $d.Vid, $d.Pid
            $hits = @($found | Where-Object { $_.PNPDeviceID -match $pattern })

            if ($hits.Count -eq 0) {
                Add-Result ('{0} connected' -f $d.Label) 'FAIL' -Blocking `
                    ('The {0} {1} not plugged in.' -f $d.Plain, $d.Verb) `
                    ('Plug the {0} into a USB socket and switch on if there is a switch. This screen will notice on its own - there is nothing to press.' -f $d.Plain)
                continue
            }

            # Present is not the same as working. A device with a driver problem
            # enumerates but will not report anything useful.
            $bad = @($hits | Where-Object { $_.Status -and $_.Status -ne 'OK' })
            if ($bad.Count -gt 0) {
                Add-Result ('{0} connected' -f $d.Label) 'FAIL' -Blocking `
                    ('The {0} {1} plugged in but Windows reports a problem: {2}' -f $d.Plain, $d.Verb, (($bad | ForEach-Object { $_.Status }) -join ', ')) `
                    ('Unplug the {0}, wait a few seconds, and plug {1} back in - ideally into a different USB socket.' -f $d.Plain, $d.It)
            } else {
                $names = ($hits | ForEach-Object { $_.Name } | Select-Object -Unique) -join ', '
                Add-Result ('{0} connected' -f $d.Label) 'PASS' ('{0} ({1})' -f $names, $hits[0].PNPDeviceID)
            }
        }

        # Anything else that presents as a game controller is worth naming: it
        # occupies a controller number and can shift the others.
        $known = @($devices | ForEach-Object { 'VID_{0}&PID_{1}' -f $_.Vid, $_.Pid })
        $extra = @($found | Where-Object {
            if ($_.Name -notmatch '(?i)game controller|joystick') { return $false }
            $id = $_.PNPDeviceID
            foreach ($k in $known) { if ($id -match $k) { return $false } }
            return $true
        })
        if ($extra.Count -gt 0) {
            Add-Result 'Other controllers attached' 'INFO' `
                ((($extra | ForEach-Object { $_.Name }) | Select-Object -Unique) -join ', ')
        }
    }
}
