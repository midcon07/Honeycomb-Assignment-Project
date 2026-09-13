# AI traffic: who drives it, and what the program can check

Started 2026-09-07 with Mark in the sim. Parked at the end of that evening;
the "Tomorrow" list at the bottom is where to pick up.

## The three modes (Mark, 2026-09-11; replaces the four flight types)

The mode is the TRAFFIC ENGINE, not the kind of flight:

| Mode | MSFS Options > General > Online > Traffic Type | What must be running |
|---|---|---|
| BATC | **Off** | BeyondATC, up to date |
| FSLTL | **Off** | the FSLTL traffic injector |
| MSFS | **Real-Time Online** | neither |

BATC and FSLTL share the same MSFS settings; the difference is which engine
feeds traffic. "Real-Time Online" is Asobo's engine plus other users'
aircraft - right for multiplayer without an injector. The Online page as
Mark has it (2026-09-11): Photogrammetry on, Air Traffic in career on,
Live Weather on, Multiplayer on, servers Automatic [East USA], show
multiplayer aircraft in close proximity on, replication High Fidelity;
only Traffic Type changes between modes on the Online page. On the Graphics
page two levels change too (Mark, 2026-09-12): Aircraft Traffic and Parked
Aircraft are **Off** for BATC/FSLTL and **Ultra** for MSFS. Both are on disk
(below), so those two are READ, not taken on anyone's word.

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
- **-1 = Off** (measured 2026-09-12: Mark set Aircraft Traffic and Parked
  Aircraft to Off, the file went 2/3 -> -1/-1 within seconds; back to Ultra
  -> 3/3, and the overall `Preset` line flipped Custom -> Ultra). The earlier
  reading of -1 as "never set" was wrong. The VR block's -1s are Off too.
- **3 = Ultra** (same measurement). 2 is one below Ultra (High, presumably)
  but has not been read back against its word; 0 was seen once. The program
  names unmeasured levels "LEVEL n" rather than guessing.
- Writable when the sim is closed, like FSUIPC7.ini (the sim rewrites the
  file, so a write under a running sim is undone).

**Traffic Type is NOT on local disk at all - measured 2026-09-11 with the
sim running.** In MSFS 2024 it lives on Options > General > **Online**
(there is no Traffic page in the General list). Three saves of the
cloud-synced profile container (`SystemAppData\wgs\...\profile_00`, ~1.24
MB) were byte-compared: Online 21:05, Off 21:25 (after Save and back),
Online 21:30. Between Off and Online the only differing bytes are (a) a
16-bit save counter at offset ~813 that rises ~14 per second, (b) one
108 KB block at ~861409 that is a raw memory dump - 64-bit pointers
(`.. f7 7f 00 00`), repeating 242-byte structures, a different amount of
zero fill each save - and (c) the last 3 bytes, a checksum. Between the two
ONLINE saves the differences are exactly the same three things. No other
file under the package (LocalCache, LocalState, the other wgs containers)
or under Roaming/LocalLow was written during either save. So the setting
goes straight to Microsoft's cloud profile and nothing local records it.
**Do not chase this again.** The mode is recorded as a person's word, the
same way as "Empty Bravo profile set".

What the container DOES hold in readable form (1064 records, framing
`<8-byte hash> 00000002 00000000 <8-byte hash> <u32 len> <key> 00 <4 bytes>
2d 51 87 e6 <u32 len> <value> 00`): the aircraft/toolbar datastore - G1000
and EFB map settings per aircraft, in-game panel layouts, Navigraph state
and **the Navigraph and SimBrief sign-in tokens in clear**. Never copy this
file into the repo or a package; snapshots taken for the diff were deleted.
None of those records changed with Traffic Type.

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

## Built 2026-09-11: the mode choice and the tractor-feed reminder

- **Mode choice** in the launcher's top bar (`Traffic` select: BATC / FSLTL /
  MSFS) -> `config.json` `trafficMode`. The checklist row "Traffic: <mode>"
  is amber until the sim's Traffic Type has been recorded as what the mode
  needs, green after, and its note says whose word it is and when.
- **The reminder** (`TrafficReminderForm.cs`, `DotMatrix.cs`): a sheet of
  green-bar tractor-feed paper, always on top, that prints - one character
  at a time in a 5x7 dot font, with the printer's sounds synthesised in
  memory (print-head loop, line-feed ratchet, strike; written once to
  `%LOCALAPPDATA%\HoneycombAssignment\sounds\`) - what to set in the sim:
  Options > General > Online > Traffic Type, then Save and back. It appears
  when the chosen mode needs a different Traffic Type from the one last
  recorded: at program start, on a mode change, and when Start Simulator
  is pressed (on top of the sim). Two printed lines are clickable (Enter /
  Escape too): DONE prints an X, strikes the line through, prints
  "RECORDED hh:mm BY <user>" and writes `trafficTypeRecorded/By/Utc` to
  config.json - **a person's word, and the sheet says so in print**. NOT NOW
  holds until the next occasion. The sheet never claims to have verified
  anything.
- **One printout window per session** (Mark, 2026-09-11: "I have more plans
  for this window"). Opens pinned and open, and never collapses on its own.
  An anchor lamp top-left: green = on top of everything, red = an ordinary
  window; click to toggle, and dropping it after a drag anchors it. Window
  chrome top-right, printed on the paper: A- A+ (seven dot pitches, saved as
  `printoutPitch` in config.json; the window grows and shrinks with the
  text), minimise (winds up into a small square of paper, `PrintoutIconForm`,
  at the sheet's corner; one click winds the same sheet back down), maximise
  (the working area of its monitor), close (NOT NOW if undecided). Resizable
  by its edges - the text reflows to the width, wrapped at spaces, the print
  head keeps its place. Draggable by its paper to any monitor. The first
  version tore off and left a reprint stub; the second collapsed to an icon
  by itself; this is what Mark asked for.
- `HoneycombLauncher.exe --traffic-sheet [BATC|FSLTL|MSFS]` prints the
  sheet on its own with sample values and records nothing: for hearing and
  seeing it without a sim.

## Built 2026-09-12: the graphics levels, read from the sim

- `SimSettings.cs` reads Graphics > Traffic (`AircraftTrafficQuantity`,
  `ParkedAircraftQuantity`) from UserCfg.opt (Store, then Steam;
  `HONEYCOMB_USERCFG` overrides the path for tests). `AppConfig.GraphicsRequiredFor`
  holds the per-mode levels (-1/-1, 3/3).
- The launcher checks the file's write time every two seconds. A change goes
  to the sheet and to the checklist row "Traffic graphics" (green READ FROM
  SIM / red WRONG IN SIM / amber NOT READ with the reason).
- The sheet has two numbered parts: 1. Graphics - the two "MUST BE" lines,
  which are struck through and followed by "GRAPHICS CONFIRMED hh:mm - READ
  FROM THE SIM" when the file comes to agree, or by "!! GRAPHICS CHANGED"
  when it stops agreeing; 2. Online - Traffic Type, a person's word as before.
  The sheet prints whenever either part is wrong. `PrintLines()` is the
  append-only feed every later message will use.
- Preflight check `37-TrafficGraphics.ps1`: PASS/WARN with what was read and
  when the sim last saved.
- Rehearsed on the demo against a scratch copy of the file (Ultra -> Off ->
  level 2), then the real sheet printed from the live file: Ultra/Ultra, needs
  Off/Off for BATC. Then the real run (Mark, 12:22): the launcher saw each
  slider step land in the file (Ultra -> level 2 -> Off, then parked -> Off),
  the sheet struck its lines and printed GRAPHICS CONFIRMED; Mark: "looking
  good". Save-and-back rewrites the file again with the same values, which
  the sheet ignores.

## Built 2026-09-12 (evening): Mark's list from the session with midcon07

Mark's notes, verbatim in order: 0) Global Rendering Quality; 1) darker
font; 2) bidirectional; 3) mixed case; 4) faster print - each "make it a
settable option?"; 5) an early laser printer option with its sounds; 6) once
the graphics are right, prompt to start the AI traffic program; 7) the
button still said "Simulator Starting" after the sim closed; 8) the printout
did not pop when the sim came up again.

- **0** (read as: the Graphics page's Global Rendering Quality drops to
  Custom when the two traffic levels go Off, and someone might "fix" it):
  `SimSettings` now reads the `Preset` word from the `{Graphics` block; the
  sheet's part 1 says "Global Rendering Quality will say Custom - that is
  right; leave it" whenever the mode wants Off. **Assumption - confirm with
  Mark.**
- **1-4**: printer options on the sheet's right-click menu, kept in
  config.json (`printoutInk` 0-3, `printoutBidirectional`,
  `printoutMixedCase`, `printoutSpeed` 0-2), applied at once. Ink weight =
  a fresher ribbon and a fatter dot (`DotMatrix.DrawChar` weight). Both
  directions = alternate rows print right to left (the head's k-th step maps
  to a column per row direction; a reflow keeps the count). Mixed case =
  every source line is now sentence case and `Disp()` upper-cases it unless
  the option is on; 26 lowercase 5x7 glyphs added. Speed = 17 / 9 / 4 ms per
  character; the print-loop sound is rebuilt for the new rhythm.
  Demo: `HONEYCOMB_PRINTOUT=ink,bidi,mixed,speed` (e.g. `2,1,1,1`).
- **5 (laser)**: built later the same evening as **the LaserWriter** (Mark:
  "I'm reminiscing of the old Apple laser writers"; Canon CX/SX engine, 8
  ppm, PostScript). Menu: Printer = Dot matrix / LaserWriter; Face = the
  LaserWriter Plus resident faces with Windows stand-ins (Helvetica=Arial,
  Times=Times New Roman, Courier=Courier New, Palatino=Palatino Linotype,
  Bookman=Bookman Old Style, New Century Schoolbook=Century Schoolbook,
  Avant Garde=Century Gothic, Helvetica Narrow=Arial Narrow), listed only
  if installed; config `printoutPrinter`, `printoutFace`. Proportional
  text wrapped by measured width (`RelayoutLaser`), the header's date at
  the right edge (`Src.Right`), a white cut sheet with a hairline edge, ink
  = toner density. The page prints whole: `LaserPrint()` plays the
  sequence (fan throughout; the PostScript pause; relay click; motor
  whining up; pickup clunk; transport whirr with the rollers ticking; the
  page dropping; wind-down - `DotMatrix.LaserPage`, phases by speed 0.9/
  1.1/2.2/0.7 s, 0.4/0.6/1.2/0.4, 0.1/0.3/0.6/0.2) and reveals the rows
  top-down through the transport phase. **Every later line reprints the
  page**, as a laser must (PrintSourceThen / PrintLines / AskClose take a
  laser branch); the X in a box shows on the reprint. Demo:
  `HONEYCOMB_PRINTOUT=ink,bidi,mixed,speed,printer,face`. Mark tried every
  face on the demo within a minute of it existing and set the real one to
  LaserWriter, Helvetica, black, fast.
- **Standing direction (Mark, 2026-09-12): "80s - 90s vibe is our ultimate
  visual UI goal."** Period hardware, paper and real machine sounds.
- **The launcher's page, same evening: the ops terminal, 1989.** The
  `<style>` block of `ui/index.html` was replaced whole (the DOM and the
  JS untouched): the sixteen VGA colours and nothing else, IBM Plex Mono
  for everything (Barlow kept only for the caps diagram's function
  labels), a reverse-video menu bar with bracketed `[ A- ]` buttons, the
  annunciators as reverse-video blocks (red ones blink), buttons as
  bracketed words that reverse on hover, panels as double-line boxes with
  the title let into the top edge, a reverse-video status line at the
  foot with a blinking block cursor, scanlines and a corner vignette over
  the whole tube (`body::before/::after`, pointer-events none). The old
  variable names (`--placard`, `--amber`...) are mapped to VGA colours so
  nothing the JS sets goes unstyled. `.hidden` had lived in the old block:
  restored (the meter drew as an empty box without it).
- **The airport under the printer** (`Ambience.cs`, NAudio 2.2.1 for
  mixing, System.Speech 8.0.0 for the voice): nothing continuous (Mark:
  "the wind sound... drop it"). Every 30-90 s a faint jet at a distance
  (a low-passed roar shaped as a swell, easing down in pitch, no whine),
  three in ten a turboprop (a 95 Hz buzz with harmonics, beating, dropping
  a few percent through the pass); every 25-60 s a gate announcement -
  Windows' own voice (a woman's if installed), through a PA: two-tone
  chime, 300 Hz-2.5 kHz band, overdrive, two echoes. Twelve templates
  with the airlines and cities of the era (TWA, Pan Am, Eastern, Braniff,
  Piedmont...; the white zone line). Option "Airport ambience" on the
  sheet's menu, `printoutAmbience`, default on; lives with the sheet.
  The LaserWriter's fan and motor are gone from its page sound ("sounds
  like a jet engine"); what is left is the paper: drawn off the stack,
  rollers, the drop.
- **6**: `TrafficEngines.cs` - BeyondATC found via a running copy, the
  uninstall registry (Inno Setup), or `<drive>\BeyondATC\BeyondATC.exe`,
  then remembered as `batcPath`; the FSLTL injector at
  `<InstalledPackagesPath>\Community\fsltl-traffic-injector\fsltl-trafficinjector.exe`.
  Sheet part 3: running / not running; `[ ] Start <engine> now` once the
  graphics are right (printed later through the feed if they were wrong at
  print time); the launcher starts it; the process watcher confirms
  "<engine> running - confirmed hh:mm" and strikes the line, or prints
  "!! <engine> has stopped" with a fresh START line. MSFS mode: "nothing to
  start", and "!! <engine> is running - close it" for any injector up.
  Rehearsed with a renamed ping.exe standing in for BeyondATC.exe (same
  process name): up, confirmed, gone, offered again.
- **7**: a process watcher in the launcher (3 s) pushes `simState`
  (`simRunning`, `launchPending` = a Start press within the last 3 min);
  the page's button says "Simulator Running" (disabled) while the sim is
  up, "Simulator Starting" only while a launch is pending, else "Start
  Simulator".
- **8**: when the sim's process appears, a fresh sheet prints (or the one
  still wanting something is brought back), any mode chosen. Also when an
  engine the mode does not want comes up.
- Everything on the sheet after the first print goes through one queue
  (`Later`/`Flush`/`PrintLines`): nothing prints over the sheet's own print,
  an animation, or the close question. This is the feed for whatever comes
  next during a flight.

## Next

1. Flight-time confirmation (second stage of the strike-through): once a
   flight is loaded, count AI aircraft whose titles are not FSLTL/BATC
   models; Asobo traffic present while the mode says Off is a certain
   "wrong". Needs one measured flight to learn which titles belong to whom
   (FSUIPC TCAS tables or SimConnect). Proving "right" is weaker (an empty
   sky), so it confirms after a minute or two at a real airport.
2. Preflight rows per mode: the engine running or not, BATC up to date
   from its Player.log, densities sane.
3. Words for the graphics levels 0-2 - low value; -1 and 3 are measured.
4. Item 0 above is an assumption about what Mark meant - confirm.
5. The launcher's own page is the next thing to bring into the 80s/90s
   vibe (Mark, 2026-09-12: "our ultimate visual UI goal").
