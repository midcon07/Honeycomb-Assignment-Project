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
only Traffic Type changes between modes. The graphics densities
(UserCfg.opt) are the same in every mode: aircraft 2, everything else 3.

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

## Next

1. Flight-time confirmation (second stage of the strike-through): once a
   flight is loaded, count AI aircraft whose titles are not FSLTL/BATC
   models; Asobo traffic present while the mode says Off is a certain
   "wrong". Needs one measured flight to learn which titles belong to whom
   (FSUIPC TCAS tables or SimConnect). Proving "right" is weaker (an empty
   sky), so it confirms after a minute or two at a real airport.
2. Preflight rows per mode: the engine running or not, BATC up to date
   from its Player.log, densities sane.
3. Words for the graphics levels - low value.
