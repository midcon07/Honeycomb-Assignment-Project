<#
    Phase 2. Is the simulator where the configuration says it is, and is the
    Community folder still the one the simulator actually reads.

    The important idea here: this is not a comparison of the configuration
    against itself. UserCfg.opt is the authority on where packages live, so when
    the configuration and the simulator disagree, the SIMULATOR is right and our
    record is stale.

    That means a moved Community folder is not a question to put to the user. It
    is a fact to be read, reported, and written back. Only ask when the answer
    genuinely cannot be determined - when the path the simulator names does not
    exist, or when there is more than one installation and no way to tell which
    is meant.

    Read-only. Where drift is found this check says what the new value should
    be; writing it back is setup's job, after the gate has passed.
#>

@{
    Name        = 'Simulator'
    Description = 'Simulator installation and Community folder, checked against the configuration'

    Run = {

        $c = Get-AppConfig
        if ($c.State -ne 'Ok') {
            Add-Result 'Simulator paths' 'SKIP' `
                'Not checked - there is no usable configuration to compare against, which is already reported above.'
            return
        }
        $cfg = $c.Config

        # --- which installation is live -------------------------------------
        $installs = @(Find-Msfs2024)
        if ($installs.Count -eq 0) {
            Add-Result 'Simulator installed' 'FAIL' -Blocking `
                'No Microsoft Flight Simulator 2024 installation could be found.' `
                'The simulator does not appear to be installed on this computer, or it has been moved. Run setup so the program can find it again.'
            return
        }

        $recorded = $null
        try { if ($cfg.PSObject.Properties['simulator']) { $recorded = $cfg.simulator } } catch { }

        # Prefer the installation the configuration already names; a machine can
        # carry the folders of both a Store and a Steam install and only one is
        # in use.
        $live = $installs[0]
        if ($recorded -and $recorded.PSObject.Properties['distribution']) {
            $m = @($installs | Where-Object { $_.Distribution -eq $recorded.distribution })
            if ($m.Count -eq 1) { $live = $m[0] }
        }

        if ($installs.Count -gt 1) {
            Add-Result 'Simulator installed' 'WARN' `
                ('More than one installation is present (' + (($installs | ForEach-Object { $_.Distribution }) -join ', ') +
                 '). Using ' + $live.Distribution + ', which is the one on record.') `
                'If that is the wrong one, run setup and choose the other.'
        } else {
            Add-Result 'Simulator installed' 'PASS' ($live.Distribution + ' - ' + $live.UserCfg)
        }

        if ($recorded -and $recorded.PSObject.Properties['distribution'] -and
            $recorded.distribution -ne $live.Distribution) {
            Add-Result 'Simulator edition changed' 'WARN' `
                ('The configuration records a ' + $recorded.distribution + ' installation, but a ' +
                 $live.Distribution + ' one is what is present.') `
                'Run setup so the program follows the installation you are actually using.'
        }

        # --- the Community folder, from the simulator itself ------------------
        $ipp = $null
        try { $ipp = Get-InstalledPackagesPath -UserCfgPath $live.UserCfg } catch { }
        if (-not $ipp) {
            Add-Result 'Community folder' 'FAIL' -Blocking `
                ('The simulator does not say where its packages are kept (no InstalledPackagesPath in ' + $live.UserCfg + ').') `
                'Start the simulator once and close it again, which rewrites that file, then try this again.'
            return
        }

        $community = Join-PathSafe $ipp 'Community'
        if (-not (Test-PathSafe $community)) {
            # This is the case that genuinely cannot be resolved on our own.
            Add-Result 'Community folder' 'FAIL' -Blocking `
                ('The simulator says its add-ons live in ' + $community + ', but that folder does not exist.') `
                'The add-on folder has been moved or a drive is not connected. Reconnect the drive, or run setup to point at the new location.'
            return
        }

        $count = @(Get-ChildItem -LiteralPath $community -Directory -ErrorAction SilentlyContinue).Count
        $known = $null
        try { if ($recorded -and $recorded.PSObject.Properties['communityPath']) { $known = $recorded.communityPath } } catch { }

        if ($known -and ($known.TrimEnd('\') -ne $community.TrimEnd('\'))) {
            # Drift, and it is resolvable: the simulator is the authority, so
            # this is reported and written back rather than put to the user as
            # a question they may not be able to answer.
            Add-Result 'Community folder moved' 'WARN' `
                ('The add-on folder has moved. Was ' + $known + ', is now ' + $community + ' (' + $count + ' packages).') `
                'Nothing is wrong. The program will update its own record to match the simulator.'
        } else {
            Add-Result 'Community folder' 'PASS' ($community + '  (' + $count + ' packages)')
        }

        # Folders that look like Community but are not the one being read. Real
        # add-ons sitting in one of these do nothing at all, silently.
        try {
            $decoys = New-Object System.Collections.ArrayList

            # Siblings of the real folder. This machine has a Community2024
            # holding ten packages right beside the live Community, which a
            # drive-root search would never have found.
            foreach ($sib in @(Get-ChildItem -LiteralPath $ipp -Directory -ErrorAction SilentlyContinue |
                               Where-Object { $_.Name -match '(?i)^community' })) {
                if ($sib.FullName.TrimEnd('\') -ne $community.TrimEnd('\')) {
                    $n = @(Get-ChildItem -LiteralPath $sib.FullName -Directory -ErrorAction SilentlyContinue).Count
                    # The extra parentheses matter. Inside a method call the
                    # comma is an argument separator, not an array constructor,
                    # so -f would receive one value for two placeholders and
                    # throw.
                    if ($n -gt 0) { [void]$decoys.Add(('{0} ({1})' -f $sib.FullName, $n)) }
                }
            }

            # And the conventional spots on every drive, for folders left behind
            # by an earlier install or a move.
            foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
                foreach ($guess in @('Community', 'Packages\Community', 'MSFS2024\Packages\Community')) {
                    $p = Join-PathSafe $d.Root $guess
                    if ((Test-PathSafe $p) -and ($p.TrimEnd('\') -ne $community.TrimEnd('\'))) {
                        $n = @(Get-ChildItem -LiteralPath $p -Directory -ErrorAction SilentlyContinue).Count
                        if ($n -gt 0) { [void]$decoys.Add(('{0} ({1})' -f $p, $n)) }
                    }
                }
            }
            $decoys = @($decoys | Select-Object -Unique)
            if ($decoys.Count) {
                Add-Result 'Inactive add-on folders' 'WARN' `
                    (($decoys -join ' | ') + ' - the simulator does not read these') `
                    'Anything installed into those folders has no effect. Worth knowing if an add-on seems to be missing.'
            }
        } catch {
            # Never swallow this. An empty catch here already hid a real defect
            # once: the search threw, silently stopped finding anything, and the
            # gate went on reporting that all was well. A check that quietly
            # stops working is worse than one that fails loudly.
            Add-Result 'Inactive add-on folders' 'SKIP' `
                ('The search for stray add-on folders could not run: ' + $_.Exception.Message) `
                'This is a fault in the program, not in your setup. Report it.'
        }
    }
}
