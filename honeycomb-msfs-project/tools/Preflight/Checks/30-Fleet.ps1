<#
    Phase 5. Has the installed fleet changed since it was last classified.

    Never blocking. A newly installed aircraft is not a reason to stop someone
    flying the one they already have set up.

    This deliberately does NOT scan the aircraft. Reading the configuration of
    every aircraft in a large install is seconds of work, and seconds spent on
    every launch for a thing that changes a few times a year is a poor trade.
    Instead it takes a cheap fingerprint of the package folders - how many there
    are and when they last changed - and compares it against the one recorded
    when the fleet was last classified.

    The scan itself belongs after the gate has passed, because it writes, and
    nothing in the gate is allowed to write.
#>

@{
    Name        = 'Fleet'
    Description = 'Whether newly installed aircraft need classifying'

    Run = {

        $c = Get-AppConfig
        if ($c.State -ne 'Ok') {
            Add-Result 'Aircraft list' 'SKIP' `
                'Not checked - there is no configuration recording what was last seen.'
            return
        }
        $cfg = $c.Config

        $installs = @(Find-Msfs2024)
        if ($installs.Count -eq 0) {
            Add-Result 'Aircraft list' 'SKIP' 'Not checked - no simulator installation found, which is already reported above.'
            return
        }

        $ipp = $null
        try { $ipp = Get-InstalledPackagesPath -UserCfgPath $installs[0].UserCfg } catch { }
        if (-not $ipp) {
            Add-Result 'Aircraft list' 'SKIP' 'Not checked - the package folder could not be determined.'
            return
        }

        # Fingerprint: the top-level package folders and when each last changed.
        # Enough to notice something installed, removed or updated, without
        # opening any of them.
        # StreamedPackages is where MSFS 2024 keeps the bulk of its content -
        # 1314 folders on this machine against 72 in Community. A fingerprint
        # that watched only Community would miss almost every aircraft the user
        # has. Enumerating all of it costs about 45 ms, so there is no reason to
        # leave it out.
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $parts = New-Object System.Collections.ArrayList
        $total = 0
        foreach ($sub in @('Community', 'StreamedPackages', 'Official2024', 'Official')) {
            $dir = Join-PathSafe $ipp $sub
            if (-not (Test-PathSafe $dir)) { continue }
            $kids = @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue)
            $total += $kids.Count
            $newest = ($kids | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
            $stamp = if ($newest) { $newest.LastWriteTimeUtc.ToString('yyyyMMddHHmm') } else { '0' }
            [void]$parts.Add($sub + ':' + $kids.Count + ':' + $stamp)
        }
        $sw.Stop()

        if ($parts.Count -eq 0) {
            Add-Result 'Aircraft list' 'SKIP' ('No package folders found under ' + $ipp)
            return
        }

        $joined = $parts -join '|'
        $md5 = [System.Security.Cryptography.MD5]::Create()
        $hash = ([BitConverter]::ToString(
                    $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($joined))) -replace '-', '').Substring(0, 12)
        $md5.Dispose()

        $recorded = $null
        try { if ($cfg.PSObject.Properties['fleet'] -and $cfg.fleet.PSObject.Properties['fingerprint']) {
                  $recorded = $cfg.fleet.fingerprint } } catch { }

        # Format strings, not concatenation. PowerShell resolves + by the type of
        # the LEFT operand, so a number followed by a string tries to parse the
        # string as a number and throws. It cost this check a run: the per-check
        # guard caught it and reported SKIP, which is the safety net working, but
        # the result was a check that silently stopped doing its job.
        if (-not $recorded) {
            Add-Result 'Aircraft list' 'TODO' `
                ('{0} packages installed, none of them classified yet.' -f $total) `
                'The setup step will work out which lever layout each aircraft needs.'
        } elseif ($recorded -ne $hash) {
            Add-Result 'Aircraft list' 'WARN' `
                ('Your installed add-ons have changed since the aircraft were last sorted ({0} packages now).' -f $total) `
                'Some aircraft may not have lever settings yet. Re-run the aircraft scan when convenient - nothing stops you flying.'
        } else {
            Add-Result 'Aircraft list' 'PASS' ('{0} packages, unchanged since last scan' -f $total)
        }

        Add-Result 'Fleet fingerprint cost' 'INFO' ('{0} ms for {1} folders' -f $sw.ElapsedMilliseconds, $total)
    }
}
