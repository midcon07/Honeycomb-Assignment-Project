# Security audit — 2026-09-05

Question asked: if a stranger downloads this from GitHub and runs it, how safe
is it for their machine, their MSFS install, and against anything hostile
arriving from the internet? Done by reading the code paths that run
processes, touch the network, write files, and by checking what the public
repository itself contains. Nothing was changed as part of the audit.

Tick a box when the item is done, and say in the line how it was verified.

## What is already sound

- The app downloads nothing and updates nothing. No telemetry.
- Outbound connections, in full: SimBrief (`simbrief.com`, with the pilot ID),
  the FAA Aviation Weather Center (`aviationweather.gov`, with airport codes),
  Microsoft's connectivity test page (`msftconnecttest.com`), and - see item 4 -
  Google Fonts.
- Everything received from those sites is shown as plain text
  (`textContent`), never as HTML. No `innerHTML`, `eval` or equivalent in the
  page. A hostile response cannot run script.
- Scripts run as `powershell.exe -NoProfile -ExecutionPolicy Bypass -File
  <script>` with arguments passed as a list, never a string. Nothing from the
  network is built into a command line.
- The only URL ever opened in a browser is the fixed SimBrief dispatch page.
- No manifest requests elevation; runs as the invoking user.
- The public repository holds no logs, FSUIPC backups, licence keys,
  binaries or personal details (grep for the known names and addresses is
  clean; `git ls-files` shows no pdf/ini/log/bak/key/zip/exe/dll).
- The app never writes inside the MSFS installation. Preflight reads only.
  Starting the sim is `explorer.exe shell:AppsFolder\...`.

## Findings — most serious first

- [x] **1. Global button writer discards the user's own assignments.** DONE 2026-09-10: `tools/FsuipcIni.ps1` merges - lines on the quadrant's joystick are ours to replace, every other device's lines are kept and renumbered ahead of ours, and any replaced line the program did not write is named in the output. Proved by `tools/Test-FsuipcIniMerge.ps1`, including a real run against a scratch copy of the ini.
  `tools/Set-BravoButtons.ps1` keeps only `PollInterval`/`ButtonRepeat` from
  the existing global `[Buttons]` and replaces everything else. Correct for
  midcon07, destructive for anyone with an existing FSUIPC setup. A dated
  backup is taken every write, so it is recoverable, but nothing warns first.
  Fix: refuse (with the backup path named) when the section holds lines we
  did not write, or fence ours between marker comments and leave the rest.

- [x] **2. Presets file overwritten.** DONE 2026-09-10: our presets live between two marker lines in `myevents.txt`; the user's lines outside are untouched; an older plain copy of our file is fenced on the next write; a same-named preset with different code refuses the install and says so. `Set-LeverAssignments.ps1` copies
  `data/myevents.txt` over `<FSUIPC>\myevents.txt` whenever they differ. A
  user with their own presets loses them on the first lever write. Fix:
  append our block under a marker and update only that block.

- [ ] **3. Read-me tells users to click past SmartScreen.** Unavoidable for
  an unsigned exe, but it trains the habit malware relies on. Fix: code-sign
  the executable, or publish a SHA-256 with each release plus one line on how
  to check it, and distribute via GitHub Releases rather than desktop zips.

- [ ] **4. Page loads a font from Google on every start.**
  `ui/index.html` lines 2-4: preconnect + stylesheet from
  `fonts.googleapis.com`. A silent outbound connection with no business in a
  cockpit tool, and the only external resource in the page. Fix: bundle the
  font files in `ui/` or drop the face and rely on the fallback stack.

- [ ] **5. Embedded browser not fenced.** No `NavigationStarting` guard, no
  `NewWindowRequested` handler, developer tools left enabled. Nothing in the
  page does any of that today. Fix: cancel navigation to anything but the
  app's own file URL; on new-window requests, cancel, and open in the system
  browser only when the URL is the allowlisted SimBrief address; set
  `AreDevToolsEnabled = false` in release; `AreHostObjectsAllowed = false`.

- [ ] **6. Survey script collects more than its read-me says.**
  `tools/Survey/Survey-Machine.ps1` records computer name, user name, the
  full installed-software list from the Uninstall registry keys, device
  serial numbers, and the FSUIPC log - which carries the FSUIPC licence
  holder's name and email. It writes to the Desktop for the person to send,
  so it is opt-in and local. Fix: `READ-ME-FIRST.txt` lists exactly what the
  report contains before they run it.

- [ ] **7. Airport codes and pilot ID not validated before use in URLs.**
  `Get-AirportWeather.ps1` puts the ICAO into the query as given;
  `Get-SimBriefPlan.ps1` interpolates the pilot ID. Both values come from
  SimBrief data or the local settings file, so an attacker would have to
  control those already. Fix: letters and digits only, refuse otherwise.

- [ ] **8. Page values reach PowerShell parameters with no leading-dash
  check.** An aircraft id that starts with `-` could be read as a switch
  (`-ClearGlobal`, `-AllowUnverified` exist). Everything the page sends is
  built by our own code from a local file, so this is hardening. Fix:
  `MainForm` rejects any argument that starts with `-` before
  `Runner.PowerShellAsync`; the id regex `^[A-Za-z0-9][A-Za-z0-9 ._-]*$`.

- [ ] **9. FSUIPC is force-killed** after ten seconds if it will not close
  (`Runner.StopFsuipc`). Documented and intended; a downloader should be told
  in the read-me that the app closes and restarts FSUIPC to write its file.

- [ ] **10. Backups pile up.** Every write leaves
  `FSUIPC7.ini.<stamp>.bak`; Mark's machine had 49. Fix: keep the last ten.

## Order

Items 1, 2 and 4 can hurt someone (two lose data, one phones home). Items 3
and 5 are what a security-minded reader judges the project by. The rest is
polish. Do 1, 2, 4 before the repository is pointed at anyone outside the two
of you.

## On the PowerShell tools (asked at the same time)

Keep them for now. The by-hand diagnostic use (`-WhatIf`, the probe trick in
CLAUDE.md) is how every FSUIPC fact this week was found. Costs: a process
start per call (most of the old "checking" pause), Windows PowerShell 5.1
quirks (three hit today: JSON arrays, `.Count`, switch values under `-File`),
`-ExecutionPolicy Bypass` as an antivirus smell, two languages. Proper end
state, for a quiet week: the FSUIPC file writer and the preflight checks move
into the C# app; PowerShell stays for the tools a person runs by hand.
