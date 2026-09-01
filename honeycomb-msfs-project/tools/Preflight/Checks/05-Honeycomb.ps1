<#
    Preflight check: is the Honeycomb hardware actually plugged in, right now.

    Deliberately asks Windows rather than reading FSUIPC's [JoyNames]. That
    section is a snapshot from whenever FSUIPC last ran and will happily report
    a quadrant that was unplugged yesterday. Presence is a live question and
    must be answered live.

    Both devices are blocking. Without the yoke or the quadrant there is no
    flight, and continuing would only produce a confusing session in which the
    controls do nothing.

    Runs before the FSUIPC check: if the hardware is not there, FSUIPC's opinion
    of it is beside the point.

    Read-only. Win32_PnPEntity needs no admin rights.
#>

@{
    Name        = 'Honeycomb'
    Description = 'Honeycomb Alpha and Bravo present and healthy'

    Run = {

        # VID/PID measured from the hardware, not taken from documentation.
        $devices = @(
            [pscustomobject]@{ Label = 'Bravo throttle quadrant'; Vid = '294B'; Pid = '1901'; Plain = 'throttle quadrant' }
            [pscustomobject]@{ Label = 'Alpha yoke';              Vid = '294B'; Pid = '1900'; Plain = 'yoke' }
        )

        # One query for the vendor, then match locally. Cheaper than a query per
        # device, and it lets us report anything else from this vendor we find.
        $found = $null
        try {
            $found = @(Get-CimInstance -ClassName Win32_PnPEntity -Filter "PNPDeviceID LIKE '%VID_294B%'" -ErrorAction Stop)
        } catch {
            Add-Result 'Hardware detection' 'SKIP' `
                ("Windows could not be asked which devices are attached: {0}" -f $_.Exception.Message) `
                'This is a fault in the program, not your setup. Report it.'
            return
        }

        foreach ($d in $devices) {
            $matches = @($found | Where-Object { $_.PNPDeviceID -match ("VID_{0}&PID_{1}" -f $d.Vid, $d.Pid) })

            if ($matches.Count -eq 0) {
                Add-Result ("{0} connected" -f $d.Label) 'FAIL' -Blocking `
                    ("The {0} is not plugged in." -f $d.Label) `
                    ("Plug the {0} into a USB socket and switch it on. This screen will notice on its own - there is nothing to press." -f $d.Plain)
                continue
            }

            # Present is not the same as working. A device with a driver problem
            # enumerates but will not report anything useful.
            $bad = @($matches | Where-Object { $_.Status -and $_.Status -ne 'OK' })
            if ($bad.Count -gt 0) {
                Add-Result ("{0} connected" -f $d.Label) 'FAIL' -Blocking `
                    ("The {0} is plugged in but Windows reports a problem with it: {1}" -f $d.Label, (($bad | ForEach-Object { $_.Status }) -join ', ')) `
                    ("Unplug the {0}, wait a few seconds, and plug it back in - ideally into a different USB socket." -f $d.Plain)
            } else {
                $names = ($matches | ForEach-Object { $_.Name } | Select-Object -Unique) -join ', '
                Add-Result ("{0} connected" -f $d.Label) 'PASS' ("{0} ({1})" -f $names, ($matches[0].PNPDeviceID))
            }
        }

        # Anything else from Honeycomb is worth naming rather than ignoring - a
        # second quadrant or an unexpected device changes controller numbering.
        $known = $devices | ForEach-Object { "VID_{0}&PID_{1}" -f $_.Vid, $_.Pid }
        $extra = @($found | Where-Object {
            $id = $_.PNPDeviceID
            -not ($known | Where-Object { $id -match $_ })
        })
        if ($extra.Count -gt 0) {
            Add-Result 'Other Honeycomb devices' 'INFO' `
                ((($extra | ForEach-Object { $_.Name }) | Select-Object -Unique) -join ', ')
        }
    }
}
