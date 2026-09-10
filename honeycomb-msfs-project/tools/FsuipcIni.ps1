<#
    Shared by the writers: how this project changes files that are not its
    own. Dot-source it (". FsuipcIni.ps1"). It takes no parameters on
    purpose - a dot-sourced script's parameters land as variables in the
    caller's scope (learned 2026-09-07), and the writers have parameters of
    their own.

    Two files are involved, and the rule for both is the same: this program
    owns ONE part of the file and leaves every other byte alone.

      FSUIPC7.ini, global [Buttons]:  the program owns every line that acts on
          the quadrant's joystick. Lines for any other device are the user's
          and are kept, in their order, ahead of ours. (Audit 2026-09-05,
          finding 1: the writer used to replace the whole section.)

      myevents.txt:  the program owns one block between two marker lines.
          Everything outside it is the user's. (Finding 2: the file used to
          be copied over.)

    Both merges report what they kept and what they replaced, so the writer
    can say it out loud - a user's own line on our device is replaced, but
    never silently.
#>

# ---- FSUIPC button lines -------------------------------------------------------

function Get-FsuipcButtonJoystick {
    <#
        The joystick a [Buttons] line acts on, or $null when the line is not
        a button line this parser understands. Forms seen in real inis
        (2026-09-10): P<j>,<b>,C...  U<j>,<b>,C...  R<j>,<b>,C...
        CP(+<j>,<c>)<j>,<b>,C...  and the joystick may be a letter or a
        number. FSUIPC's own annotation (a tab and -{NAME}-) and our
        "; comment" may follow; neither matters here.
    #>
    param([string] $Line)
    if ($Line -match '^\s*\d+\s*=\s*(?:C[PUR]?\([^)]*\)\s*)?[PURH]*\s*([A-Za-z]|\d{1,2})\s*,\s*\d+\s*,') { return $Matches[1].ToUpper() }
    return $null
}

function Merge-FsuipcButtons {
    <#
        Puts this program's lines into a [Buttons] section of an ini, keeping
        the user's. Returns the whole ini as lines, plus what happened.

        -IniLines       the ini as read
        -Section        'Buttons', or 'Buttons.<profile>'
        -OwnedLines     our lines WITHOUT the leading "n=" (numbered here)
        -OwnedJoystick  the letter (or number) whose lines are ours
        -PollInterval   forced into the section when given (the trim wheel
                        needs 10 ms; FSUIPC's default 25 drops pulses)
        -ButtonRepeat   written only when the section has none

        Ordering: header, timing keys, any other non-button lines as they
        were, the user's button lines renumbered from 0 in their order, then
        ours. Numbers carry no meaning to FSUIPC beyond being consecutive
        from 0, which is why renumbering is safe (the previous writer already
        numbered from 0 and FSUIPC accepted it).
    #>
    param(
        [string[]] $IniLines,
        [string]   $Section = 'Buttons',
        [string[]] $OwnedLines,
        [string]   $OwnedJoystick,
        [int]      $PollInterval = 0,
        [string]   $ButtonRepeat = ''
    )
    $ownedJoy = $OwnedJoystick.ToUpper()
    $headerRx = '^\s*\[' + [regex]::Escape($Section) + '\]\s*$'

    # Find the section.
    $start = -1; $end = $IniLines.Count
    for ($i = 0; $i -lt $IniLines.Count; $i++) {
        if ($start -lt 0) { if ($IniLines[$i] -match $headerRx) { $start = $i }; continue }
        if ($IniLines[$i] -match '^\s*\[') { $end = $i; break }
    }
    $body = @()
    if ($start -ge 0 -and ($end - $start) -gt 1) { $body = @($IniLines[($start + 1)..($end - 1)]) }

    $timing = New-Object System.Collections.ArrayList
    $other  = New-Object System.Collections.ArrayList
    $kept   = New-Object System.Collections.ArrayList
    $replaced = New-Object System.Collections.ArrayList
    foreach ($line in $body) {
        if ($line -match '^\s*$') { continue }
        if ($line -match '^\s*(PollInterval|ButtonRepeat)\s*=') { [void]$timing.Add($line.Trim()); continue }
        if ($line -match '^\s*\d+\s*=') {
            $lineJoy = Get-FsuipcButtonJoystick $line
            if ($null -ne $lineJoy -and $lineJoy -eq $ownedJoy) { [void]$replaced.Add($line) } else { [void]$kept.Add($line) }
            continue
        }
        [void]$other.Add($line)
    }
    if ($PollInterval -gt 0) {
        # Built by hand: a one-element pipeline result collapses to a string
        # and the ArrayList cast then yields a string (PowerShell 5.1).
        $t2 = New-Object System.Collections.ArrayList
        foreach ($t in $timing) { if ($t -notmatch '^PollInterval') { [void]$t2.Add($t) } }
        $timing = $t2
        [void]$timing.Insert(0, 'PollInterval=' + $PollInterval)
    }
    if ($ButtonRepeat -and @($timing | Where-Object { $_ -match '^ButtonRepeat' }).Count -eq 0) { [void]$timing.Add('ButtonRepeat=' + $ButtonRepeat) }

    $secLines = New-Object System.Collections.ArrayList
    [void]$secLines.Add('[' + $Section + ']')
    foreach ($t in $timing) { [void]$secLines.Add($t) }
    foreach ($o in $other)  { [void]$secLines.Add($o) }
    $n = 0
    foreach ($k in $kept) { [void]$secLines.Add(($k -replace '^\s*\d+\s*=', ('{0}=' -f $n))); $n++ }
    foreach ($o in $OwnedLines) { [void]$secLines.Add(('{0}={1}' -f $n, $o)); $n++ }

    $out = New-Object System.Collections.ArrayList
    if ($start -lt 0) {
        [void]$out.AddRange([string[]]$IniLines)
        if ($out.Count -gt 0 -and $out[$out.Count - 1] -notmatch '^\s*$') { [void]$out.Add('') }
        [void]$out.AddRange([string[]]$secLines)
        [void]$out.Add('')
    } else {
        if ($start -gt 0) { [void]$out.AddRange([string[]]$IniLines[0..($start - 1)]) }
        [void]$out.AddRange([string[]]$secLines)
        [void]$out.Add('')
        if ($end -lt $IniLines.Count) { [void]$out.AddRange([string[]]$IniLines[$end..($IniLines.Count - 1)]) }
    }
    return [pscustomobject]@{
        Lines    = [string[]]$out
        Section  = [string[]]$secLines
        Kept     = [string[]]$kept
        Replaced = [string[]]$replaced
        Other    = [string[]]$other
        Created  = ($start -lt 0)
    }
}

# ---- the presets file ------------------------------------------------------------

$script:PresetBlockBegin = '// ---- Honeycomb Assignment Project: managed block. Its tools rewrite everything between this line and the end marker; keep your own presets OUTSIDE it. ----'
$script:PresetBlockEnd   = '// ---- end of the Honeycomb Assignment Project managed block ----'

function Get-PresetNames {
    # Preset names in a run of myevents.txt lines: "<name>#<calculator code>",
    # comments are // lines.
    param([string[]] $Lines)
    $names = New-Object System.Collections.ArrayList
    foreach ($l in $Lines) {
        if ($l -match '^\s*//' -or $l -match '^\s*$') { continue }
        if ($l -match '^\s*([^#]+?)\s*#') { [void]$names.Add($Matches[1]) }
    }
    return ,@($names)
}

function Merge-PresetBlock {
    <#
        Installs our presets as the managed block of a myevents.txt, leaving
        the user's own presets alone. Does not write when a user preset
        outside the block has the same name as one of ours (FSUIPC would not
        say which one won), or when only one of the two markers is present.

        Returns Action: created | appended | replaced | unchanged | refused,
        with Reason and Conflicts when refused.
    #>
    param([string] $Path, [string] $Block)
    $blockLines = @($Block -split "`r?`n")
    while ($blockLines.Count -gt 0 -and $blockLines[-1] -match '^\s*$') { $blockLines = @($blockLines[0..($blockLines.Count - 2)]) }
    $ours = @($script:PresetBlockBegin) + $blockLines + @($script:PresetBlockEnd)
    $enc = New-Object System.Text.UTF8Encoding($false)

    if (-not (Test-Path -LiteralPath $Path)) {
        [System.IO.File]::WriteAllText($Path, (($ours -join "`r`n") + "`r`n"), $enc)
        return [pscustomobject]@{ Action = 'created'; Reason = ''; Conflicts = @() }
    }
    $lines = @((Get-Content -LiteralPath $Path -Raw) -split "`r?`n")
    $b = [array]::IndexOf($lines, $script:PresetBlockBegin); $e = [array]::IndexOf($lines, $script:PresetBlockEnd)
    if (($b -ge 0) -ne ($e -ge 0) -or ($b -ge 0 -and $e -lt $b)) {
        return [pscustomobject]@{ Action = 'refused'; Reason = 'the managed block markers are damaged (one is missing, or they are out of order) - fix the file by hand, or delete both marker lines and everything between them'; Conflicts = @() }
    }
    $outside = @($lines)
    if ($b -ge 0) {
        $outside = @()
        if ($b -gt 0) { $outside += $lines[0..($b - 1)] }
        if ($e + 1 -le $lines.Count - 1) { $outside += $lines[($e + 1)..($lines.Count - 1)] }
    }
    # Before 2026-09-10 the writers copied our file over this one, so a
    # machine set up then holds our presets with no markers. That copy is
    # ours to absorb, not the user's to keep: a line outside the block that
    # is identical to one of ours is dropped, and a file that IS our old copy
    # is simply fenced. Only a same-named preset with DIFFERENT code is
    # somebody else's, and that refuses.
    $norm = { param($L) @($L | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ -ne '' }) }
    if ($b -lt 0 -and ((& $norm $lines) -join "`n") -eq ((& $norm $blockLines) -join "`n")) {
        [System.IO.File]::WriteAllText($Path, (($ours -join "`r`n") + "`r`n"), $enc)
        return [pscustomobject]@{ Action = 'converted'; Reason = ''; Conflicts = @() }
    }
    $mineLines = @{}
    foreach ($l in $blockLines) { if ($l -match '^\s*([^#]+?)\s*#' -and $l -notmatch '^\s*//') { $mineLines[$Matches[1]] = $l.TrimEnd() } }
    $absorbed = New-Object System.Collections.ArrayList
    $keptOutside = New-Object System.Collections.ArrayList
    foreach ($l in $outside) {
        if ($l -notmatch '^\s*//' -and $l -match '^\s*([^#]+?)\s*#' -and $mineLines.ContainsKey($Matches[1]) -and $mineLines[$Matches[1]] -eq $l.TrimEnd()) { [void]$absorbed.Add($Matches[1]); continue }
        [void]$keptOutside.Add($l)
    }
    if ($absorbed.Count -gt 0) {
        $outside = @($keptOutside)
        if ($b -ge 0) {
            # Rebuild the picture the splice below works on: what the user keeps, then an empty block to replace.
            $lines = @($keptOutside) + @($script:PresetBlockBegin) + @($script:PresetBlockEnd)
            $b = [array]::IndexOf($lines, $script:PresetBlockBegin); $e = [array]::IndexOf($lines, $script:PresetBlockEnd)
        } else {
            $lines = @($keptOutside)
        }
    }
    $theirs = Get-PresetNames -Lines $outside
    $mine   = Get-PresetNames -Lines $blockLines
    $clash  = @($theirs | Where-Object { $mine -contains $_ })
    if ($clash.Count -gt 0) {
        return [pscustomobject]@{ Action = 'refused'; Reason = ('the file already has preset(s) outside the managed block with the same name as ours but different code: ' + ($clash -join ', ') + '. Rename or remove them; FSUIPC would not say which one wins.'); Conflicts = $clash }
    }
    if ($b -ge 0) {
        $current = @($lines[$b..$e])
        if (($current -join "`n") -eq ($ours -join "`n")) { return [pscustomobject]@{ Action = 'unchanged'; Reason = ''; Conflicts = @() } }
        $new = @(); if ($b -gt 0) { $new += $lines[0..($b - 1)] }; $new += $ours; if ($e + 1 -le $lines.Count - 1) { $new += $lines[($e + 1)..($lines.Count - 1)] }
        [System.IO.File]::WriteAllText($Path, (($new -join "`r`n").TrimEnd("`r", "`n") + "`r`n"), $enc)
        return [pscustomobject]@{ Action = 'replaced'; Reason = ''; Conflicts = @() }
    }
    $new = @($lines); while ($new.Count -gt 0 -and $new[-1] -match '^\s*$') { $new = @($new[0..($new.Count - 2)]) }
    $new += ''; $new += $ours
    [System.IO.File]::WriteAllText($Path, (($new -join "`r`n") + "`r`n"), $enc)
    return [pscustomobject]@{ Action = 'appended'; Reason = ''; Conflicts = @() }
}
