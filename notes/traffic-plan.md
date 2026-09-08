# AI traffic: who drives it, and what the program can check

Started 2026-09-07 with Mark in the sim. Parked at the end of that evening;
the "Tomorrow" list at the bottom is where to pick up.

## The four modes (Mark, 2026-09-07)

| Flight | Traffic comes from | MSFS Options > General > Traffic |
|---|---|---|
| VFR | FSLTL injector | the "FSLTL/BATC" settings |
| IFR without ATC (multiplayer sessions) | FSLTL injector | the "FSLTL/BATC" settings |
| IFR with ATC | BeyondATC, up to date, driving its own traffic | the "FSLTL/BATC" settings |
| None of the above | MSFS/Asobo online traffic | the "fully online" settings |

Mark's rule, verbatim in effect: **no FSLTL and no BATC = the settings as
set at 23:43 on 2026-09-07 (fully online); either FSLTL or BATC = the
settings as they were before that.** The words on the General > Traffic page
for either mode are NOT yet recorded - see Tomorrow.

## What is on disk, measured 2026-09-07

**UserCfg.opt** (`%LOCALAPPDATA%\Packages\Microsoft.Limitless_8wekyb3d8bbwe\LocalCache\UserCfg.opt`,
on this machine a link to G:\WpSystem\...). Plain text. **The sim rewrites it
within a second or two of every settings change**, not only at exit (watched
live: Windowed flips, then each traffic slider). It holds the GRAPHICS half
of traffic:

```
{Graphics ... {Traffic
    AircraftTrafficQuantity   2      <- was -1 until Mark touched it
    AircraftTrafficVariety    3
    AirportsServicesQuantity  3
    AirportsServicesVariety   3
    ParkedAircraftQuantity    3      <- was -1; went -1 -> 0 -> 3 as the control was moved
    ParkedAircraftVariety     3
    RoadQuality 3  SeaQuality 3
} }
{GraphicsVR ... {Traffic  AircraftTrafficQuantity -1  AircraftTrafficVariety 0  AirportsServicesQuantity -1 ... } }
```

- The quantities are **levels, not percentages**: values seen 0, 2, 3.
- **-1 = never set by a person** - the value the sim carries until the
  control is touched, after which it becomes a level. The VR block still has
  -1s.
- Which word each level is (Off/Low/Medium/High/Ultra?) is NOT measured. Mark
  saw the words on screen; the numbers 2 and 3 above correspond to whatever
  the page showed at 23:43 - to be read back once.
- Writable when the sim is closed, like FSUIPC7.ini (the sim rewrites the
  file, so a write under a running sim is undone).

**The Options > General > Traffic page (AI traffic type Off / AI offline /
Real-time online, ground aircraft, multiplayer, ...) is not in UserCfg.opt or
any readable file.** It is in the cloud-synced profile container under
`...\SystemAppData\wgs\<account>\<folder>\` - the index names it
`profile_00`; ~1.18 MB; **also rewritten within seconds of a settings change**
(23:43:30, right after the slider changes), as a NEW blob file each time
(container.253 -> container.254, new GUID-named blob). Not encrypted and not
compressed: `strings` shows the controller GUIDs, `inputprofile_<n>` names
and the profile name "Midcon General". Writing it is off the table (unknown
layout, cloud copy wins). READING it may be possible: a byte diff between
two saves with one setting changed between them shows where that setting
lives. Not done yet - see Tomorrow.

**Lead for a different problem:** that same container names which input
profile is assigned to which controller GUID. The "Empty Bravo profile set"
confirmation has so far been a person's word because the program could not
read that; a byte diff around a profile switch may make it readable.

## What is installed on Mark's machine

- **FSLTL**: `fsltl-traffic-base` and `fsltl-traffic-injector` (1.6.4) in
  `G:\2024C\Community`. Injector config:
  `%APPDATA%\fsltl-trafic-injector\fsltl-trafficinjector-config.json`
  (livefeed navigraph, `defaultsim: "2020"`, `fstraffic: Yes`, nogenerics,
  nofallback). A second copy of both packages sits in `F:\JMCommunity`,
  which is NOT linked into Community and does nothing.
- **Just Flight FS Traffic** (`justflight-fstraffic-controlcentre`,
  `-module`) is also in Community. Three traffic systems on one machine.
- **BeyondATC**: `G:\BeyondATC\BeyondATC.exe` (Unity 2022.3). Version and
  update state are in
  `%USERPROFILE%\AppData\LocalLow\Skirmish Mode Games, Inc\BeyondATC\Player.log`
  as `[Updater] Latest version: X, current: Y` on every start (seen: 1.10.2
  Experimental both). Its `config.json` there holds `sim_port` 49152; its
  simconnect bridge logs to `beyondATC.log` in the same folder. BATC's MOTD
  says the new in-sim toolbar can change BATC settings.
- On 2026-09-07 at 23:40, with the sim and FSUIPC up (737-600 loaded),
  neither BATC nor the FSLTL injector was running.

## What the program can do, given the above

- Verify the graphics traffic levels from UserCfg.opt (read any time; write
  only with the sim closed).
- Verify BATC is up to date from Player.log; verify BATC / FSLTL injector
  are running from the process list.
- The traffic TYPE is a person's setting: the program records which mode
  the person chose and, if the container diff works, reads back what the
  sim actually has. Otherwise the person's word, like the Bravo profile.

## Tomorrow

1. **Words for the levels.** Mark reads the Graphics > Traffic group once
   and lists the word next to each control (they are 2, 3, 3, 3, 3, 3 in the
   file now) and the full list of choices on one quantity control.
2. **Words for the General > Traffic page** in BOTH modes: fully online (as
   set now) and FSLTL/BATC (the previous settings). Read once each.
3. **Container diff.** With the sim running: snapshot the newest blob in the
   profile folder, switch General > Traffic to the other mode, snapshot the
   new blob, `cmp -l` the two. If a handful of bytes differ, that is where the
   traffic type lives; check it survives a restart. The watcher script from
   2026-09-07 is in this session's scratchpad and is three lines; rewrite it.
4. What the FSLTL injector and BATC each EXPECT the MSFS traffic type to be
   (their own docs/config), so the check can say "BATC is running but MSFS
   is still spawning its own traffic".
5. Then: a preflight row per mode, and the mode choice in the launcher
   (VFR / IFR no ATC / IFR with ATC / default), each with what must be
   running and what the person must have set.
