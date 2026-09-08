# Honeycomb Assignment Project — working notes for Claude

Read this first. It exists so a session does not re-derive what is already known.

## What this is

A launcher for **midcon07** — 84, flies MSFS 2024 alone midweek, cannot get help
until Saturday. Mark (Midcon113) builds it; they fly together on Saturdays.

**The deliverable is not profiles. It is a system that is never *silently* wrong.**
Being broken and saying so plainly beats being subtly wrong. Everything else
follows from that.

Repo `midcon07/Honeycomb-Assignment-Project`, working branch `add-device-prober`,
PR #1. Code lives under `honeycomb-msfs-project/`.

## The launch flow

1. Preflight gate — `tools/Preflight/`. **May block.** Runs on app launch and on
   USB device change. Two checks tie "the machine is set up" to "*this* flight
   will work": **Planned aircraft** (25) takes the ICAO type from the SimBrief
   plan, else the last aircraft chosen, and **blocks** unless it is in the
   curated table *and* has a written `[Profile.*]`/`[Axes.*]` — because the
   global `[Axes]` is empty, an unprofiled aircraft has a dead quadrant.
   **Bravo profile in MSFS** (35) cannot be verified (WGS blob) so it is a
   one-time TODO cleared by `tools/Confirm-SimBravoProfile.ps1`, which records
   who looked and when. The Fleet "none classified" TODO is retired — it would
   have been amber forever.
2. Flight plan — `tools/Get-SimBriefPlan.ps1`. **May never block.**
3. Aircraft chosen, cap layout shown, physical setup confirmed.
4. Add-ons started.
5. MSFS started, **last**.

**FSUIPC7 starts with the app** (top of `StartAsync`), not at the Start button:
it waits harmlessly in the tray, and its `[JoyNames]` scan is done before the
gate reads the ini. **On midcon07's machine MSFS also auto-starts it** (an
`FSUIPC7` entry in his `EXE.xml`); on Mark's, nothing does. FSUIPC7 is
single-instance and `Runner.LaunchFsuipc` checks first, so both are safe. The
Start button's launch is a no-op safety net (`Runner.LaunchFsuipc` returns
"already running"). **Consequence:** any future in-app assignment write must
stop FSUIPC first; the tool refuses, loudly, if it doesn't. The gate's "Talks
to the simulator" line is gone — the gate runs before the sim, so it could only
ever say "untested".

## Settled — do not re-litigate

- **FSUIPC owns the Alpha/Bravo bindings**, not MSFS. Not a preference — the
  only workable option. **MSFS 2024 does not store controller profiles as XML.**
  They live in the Xbox-style WGS container at
  `…\Microsoft.Limitless_8wekyb3d8bbwe\SystemAppData\wgs\…` as GUID-named
  binary blobs that are cloud-synced. Verified: one 1.1 MB blob contains 529
  occurrences of `inputprofile` and 8 of `Bravo`, and does not begin with XML.
  There is no profile file to write. That was the MSFS 2020 model.

  Consequence: **MSFS and FSUIPC must not both bind the same axis.** They fight,
  and the symptom is a lever that appears to ignore whatever you just changed.
  To let FSUIPC drive, MSFS must have the Bravo on the profile named
  **"Claude Empty"** — created for this program, no throttle bindings — **for
  every aircraft**. Mark's working profile is kept alongside, one click away.
  The gate names "Claude Empty" in its remedy text; the confirmation is recorded
  by `tools/Confirm-SimBravoProfile.ps1`.
- **Layout follows capability, not engine type.** Prop control *and* mixture →
  constant-speed; mixture alone → fixed-pitch; neither → FADEC. **Turboprops
  are a special case for controls, not handles**: same black/blue/red, but the
  red levers take `AXIS_CONDITION_LEVER_n_SET` (67372/67379), not mixture.
  Measured on the King Air 350 — levers 5–6 on `AXIS_MIXTURE` did nothing while
  1–4 worked. Layouts `turboprop_1`/`turboprop_2`, fact `conditionLever`.
  **And `AXIS_CONDITION_LEVER_n_SET` did nothing either.** The Asobo King Air
  350i consumes no axis for its condition levers: the community presets in
  `C:\FSUIPC7\events.txt` (`//Asobo/King Air 350i/Fuel`) show it wants a
  3-position enum `TURB ENG CONDITION LEVER POSITION:n` (0 cut-off, 1 low idle,
  2 high idle) plus `SET_FUEL_VALVE_ENGn` and `L:Condition_Lever_CutOff_n`. So
  the red levers are driven by a **preset** (`data/myevents.txt`, installed to
  `C:\FSUIPC7\myevents.txt`) that maps the axis into thirds. **Verified 2026-09-04:
  the preset path moves the King Air's condition lever** — the first thing that
  ever has. Ini form, copied from FSUIPC: `BZ,32,F,PKA350_Condition1_Axis,0,0,0,*-1`
  with comment `Preset Control`. The table's `leverPresets` (lever → preset
  name) drives it. **`myevents.txt` must be installed on the target machine** —
  FSUIPC reads it at start — so it is part of setup, not of a profile write. **Before guessing a
  control for any aircraft, read its section of `events.txt`** — it is what the
  aircraft actually responds to, and it is on disk.
- **Classification cannot be read from disk on MSFS 2024.** Verified 2026-09-03:
  every package under `StreamedPackages` and `Official2024` is opaque
  `.fsarchive` blobs — **zero readable `aircraft.cfg`** across both. The
  "classify the fleet from config files" plan is dead; do not rebuild it. The
  replacement is the curated `aircraft` table in `data/lever-layouts.json`,
  grown one aircraft at a time by asking the user the two capability questions.
- **Per-aircraft assignments are FSUIPC profiles.** `[Profile.<name>]` lists a
  title substring (`1=Bonanza`); `[Axes.<name>]` carries that aircraft's lines.
  FSUIPC7 forces substring matching and switches on aircraft load — it logs the
  title it matched against (`Aircraft="DA62 Passengers"`). **The title substring
  must come from that log line, never from a package name.** The 350's package
  is `kingair350`; its title is `"Beechcraft King Air"`. Guessing `King Air 350`
  produced a flight with no working levers and a green gate. The table's
  `titleMatch` holds the logged title; `match` is only the profile name. The global `[Axes]`
  applies only to aircraft with no profile, so it is kept **empty**: an
  unprofiled aircraft gets no levers rather than the wrong layout.
- **Chart underlays: rejected.** SimBrief's own app does charts. See
  `notes/chart_underlays.md`.
- **Reverser check in preflight: rejected.** Live state, wrong moment.
- **`[Axes]` line format** (Advanced Users, *Axis Assignments*):
  `n=ja,(R)delta(/delay),ForD,ctl1..ctl4`. `F` = FS control, `D` = FSUIPC
  calibration (ctl is then a calibration index, not a control number).
- **Never write Raw mode.** An `R` before the delta selects it, and FSUIPC
  assumes a 7–8-bit device, scaling by 256 or 512. The Bravo is 10-bit
  (`0`–`1023`), so a Raw axis drives only part of its travel. Delta `256` is the
  documented default for calibrated input; `1` is Raw's. **Raw is per-joystick,
  not per-axis** — one hand-assigned Raw axis silently breaks every other lever
  on that device, and changing it means clearing all assignments on it first.
- `THROTTLEn_SET` is the family FSUIPC uses for **reverse zones on the same
  axis** — which is why it, not `AXIS_THROTTLEn_SET`, is right here.
- **The gate checks configuration that persists. Live state belongs in the sim.**
- **No constant may originate as an observation from Mark's machine.**

## Verified facts — measured, not assumed

| | |
|---|---|
| Bravo | `VID_294B`/`PID_1901`, Alpha `PID_1900` |
| Rudder pedals | **WINWING Orion Combat Rudder Pedals (Metal)**, `VID_4098`/`PID_BEF0`. 3 axes, no buttons: `Rz` rudder (centres at 32768), `Rx` and `Ry` toe brakes. **Range 0-65535, not the Bravo's 0-1023.** |
| Levers 1–6 → HID axis | `Y X Rz Ry Rx Z` |
| Levers 1–6 → FSUIPC letter | **`Y X R V U Z` — all six measured.** FSUIPC's log lists the Bravo as exactly six axes `R U V X Y Z`; five were tied to levers by wiring letters to throttles 1/2 and pushing, lever 4 is the remainder. Two theories ("follow HID usage", "descriptor order") each got lever 5 wrong. **There is no rule; the table is the fact.** |
| FSUIPC joystick letters | **On Mark's machine only:** Bravo `B`, pedals `C`, Alpha `D` — `B` because vJoy took `A`. Letters are per machine. `Set-LeverAssignments` looks the Bravo up by name in `[JoyNames]` on every run and **refuses to write** if it is absent or listed twice. Never assume a letter. |
| Reverse detent buttons | `24 25 26 27 28 33` |
| Axis range | `0`–`1023`; **saturates at 0 at the detent**, so the button is the only reverse signal. Re-confirmed by sweep: full forward `1023`, resting on the detent `0` with no button, past the detent `0` with button `24`. Idle therefore lands on the detent for free. |
| FSUIPC input direction | **Inverted from HID**: `+16383` at the detent, `-16384` full forward. Hence the `*-0.5` scale. Measured, not explained. |
| Lever 1 detent button | `24` |
| Axis is clean | **Verified by symmetry.** Sweeping detent↔full-forward, the reversal plateaus are 13/9/5/5/3/4 samples at `0` against 10/13/4/3/4/4 at `1023` — mean 6.5 vs 6.3. A pot dead at the bottom would make the zero plateaus much longer than their paired maxima. No dead band. |
| First sim response | at `Y=7` of 1023. Alone this proves nothing — a pot pinned across the first fifth of travel gives the same `7` on release. It only counts alongside the symmetry above. |
| MSFS's own binding | the user's working Bravo profile responds only after **50%** — the plain "Throttle Axis" (bottom half reverse) instead of "Throttle Axis (0 to 100%)". **It is not a clean baseline for A/B tests.** |
| Bravo switch rest state | buttons `19 32 35 37 39 41 43 44 47` are switch *positions*, always down |
| Handles | 2 black, 2 blue, 2 red, 4 white jet throttles, 1 SPEED BRAKE, 1 FLAP |
| MSFS 2024 | Store `Microsoft.Limitless_8wekyb3d8bbwe`; `UserCfg.opt` in its `LocalCache` |
| Live Community | from `InstalledPackagesPath` — **never** by folder name |
| Launch the sim | `shell:AppsFolder\Microsoft.Limitless_8wekyb3d8bbwe!App -FastLaunch` |
| SDK | `C:\MSFS 2024 SDK\` 1.7.3, `MSFS2024_SDK` set. **.NET 8 works** with the managed wrapper. |
| WebView2 runtime | present (151.x) |
| SimBrief Pilot ID | 24481. Fetching a user's own plan needs **no API key**. |

## Hard-won lessons — these cost real time

**My error handling defaults to optimism.** Five separate times a check reported
a confident answer it had not earned. On this project a false alarm is as
damaging as a missed fault, because the user cannot tell them apart. Test
*positively* for the thing you want.

**Read the manual before designing an experiment.** The full FSUIPC docs are at
`C:\Users\markl\OneDrive\Documents\FSUIPC7\*.pdf` — *FSUIPC7 for Advanced Users*
specifies the whole ini. This project guessed the `[Axes]` format, then built a
measure-and-read-back procedure to recover it, while the specification sat on
disk. "Don't guess" and "don't look it up" are not the same rule.

No poppler here, so convert with Word: open the PDF, read `$doc.Content.Text`.
`SaveAs2` fails on the two big guides with a bare "Command failed".

**When FSUIPC syntax is genuinely undocumented, make FSUIPC write it.** Assign
by hand, close FSUIPC, run `tools/Read-FsuipcConfig.ps1`. A wrong format is
*silently discarded*, so it looks exactly like a lever that does nothing.

**A wrong post-mortem outlasts the bug it describes.** This one bug got written
up wrongly *twice* before the manual settled it — first as "invented syntax"
(it was the real `D` form, misfielded), then as "`F` does no scaling, use `D`"
(`F` was always fine; Raw was the fault). Both were inference recorded as fact,
in the file every session loads and believes. Say which parts of a write-up were
measured and which were reasoned, or a later session inherits the guess as
settled knowledge.

**Build files with the Write tool; use the shell only to run them.** Inline
PowerShell through bash mangles backticks, apostrophes and heredocs. This cost
several round trips in one session.

**PowerShell traps that have already bitten:**

- `-f` inside a method call — the comma is an argument separator, so the format
  string gets one value for two placeholders. Wrap it: `.Add(('{0}' -f $x))`.
- `+` resolves by the **left** operand's type. Number + string throws.
- A function returning `@()` with one element returns the element; `.Count` then
  throws under StrictMode. Return `,@()`.
- Negative numbers as *positional* arguments parse as parameter names. Use named
  parameters.
- `-Only A,B` through `-File` arrives as one string, not an array.
- `$PSScriptRoot` is **not dependable inside a check's `Run` block** — it came out
  empty, and a relative path then resolved against the working directory, which
  worked by accident once. Use `$script:ProjectRoot`, published by the host.
- `Invoke-WebRequest` on 5.1 needs `-UseBasicParsing` or it fails on HTML.
- Exceptions from .NET method calls are wrapped; the `WebException` carrying the
  HTTP response is at `.InnerException`.
- `Join-Path` throws on an unknown drive. Use `[System.IO.Path]::Combine`.
- **Never wrap a block of work in an empty `catch`.** One already hid a real
  defect: a search threw, stopped finding anything, and the gate reported all
  was well.

## Conventions

- Dependency-free PowerShell 5.1 for tools; no modules, no admin.
- Execution policy is Undefined on a stock machine — always invoke with
  `-NoProfile -ExecutionPolicy Bypass -File`.
- Checks are **read-only**. Setup writes. Nothing mutates during verification.
- User-facing text: plain words, one action, written to be read aloud down a
  telephone. Name what he can see and touch.
- Commit messages explain *why*, including what was rejected and what a test
  actually proved.

## midcon07's machine — surveyed 2026-09-04, `BIGBOY`

First real data from the target machine. Everything here came from the survey,
not from assumption.

| | |
|---|---|
| Windows | 11 Home, build 26200, 32 GB. PowerShell 5.1. Two drives, `C:` and `E:`, both ~390 GB free |
| MSFS 2024 | **Store**, same as Mark. `InstalledPackagesPath` is the **default in-package location** (`…\Microsoft.Limitless_8wekyb3d8bbwe\LocalCache\Packages`), *not* a separate drive — reading `UserCfg.opt` rather than assuming a path is what makes this work |
| Packages | Community 36, StreamedPackages 1243, Official2024 1. **188 aircraft** |
| Our four aircraft | **all present**: `fs24-asobo-aircraft-da62`, `…-bonanza-g36`, `…-kingair350`, `fs24-microsoft-aircraft-c90-gtx` |
| Community add-ons | **PMDG 737-800 (`pmdg-aircraft-738`) and 777F (`pmdg-aircraft-77f`, plus `77f_CVT_`)**, and `fsltl-traffic-base`. The PMDG aircraft were in the *package* list but not the *titles* list, because **PMDG encrypt `aircraft.cfg`** — the survey now says so out loud. Their sim titles must come from FSUIPC's log, never from disk |
| FSUIPC7 | `C:\FSUIPC7`, **7.5.0.6** (Mark: 7.5.0.7). Licence **present**. `myevents.txt` absent — ours to install |
| **`[JoyNames]` — his Bravo is `C`** | **`A` = WINWING SKYWALKER Metal Rudder Pedals, `B` = Alpha Flight Controls, `C` = Bravo Throttle Quadrant.** On Mark's machine the Bravo is `B`. **Had the letter stayed hardcoded, every assignment would have gone to his Alpha yoke, silently.** Verified 2026-09-04 by running `Set-LeverAssignments` against a replica of his ini: it resolves `C` and emits `CY`/`CX`. His pedals also report a different product string than Mark's (SKYWALKER vs WINCTRL Orion) on the same `VID_4098`/`PID_BEF0` |
| His known sim titles | **`DA62 Passengers`** (identical to Mark's, so the `DA62` substring carries) and **`777F`** (the PMDG 777F). No King Air or 737 title yet — he did not load them |
| "Claude Empty" MSFS profile | **exists — Mark created it on his machine.** But the gate reads the confirmation from `config.json`, which BigBoy does not have, so check 35 shows amber until `tools/Confirm-SimBravoProfile.ps1` is run **there**. Existing and being *selected* for the Bravo are different things; only selected stops MSFS fighting FSUIPC |
| MSFS auto-starts FSUIPC | yes — `FSUIPC7` is in his `EXE.xml`, alongside `Couatl` and `AFCBridge`. So launching MSFS once is enough to create the ini |
| Flight controls | Bravo, Alpha and WINWING pedals **all connected** |
| Launcher prerequisites | **met** — .NET 8 Desktop `8.0.30`, WebView2 `151.0.4129.107`, SimBrief reachable |

**The PMDG pair are `jet_2`** — spoiler on lever 1, throttles on 3 and 4, flaps
on 6, all six white handles. They were named in the original project goal, and
FSUIPC's `PMDG737offsets`/`PMDG777offsets` settings (already checked by the
gate) exist for them. Their titles are the open question, per above.

**Still unknown for his machine:** his **axis** letters — we hardcode
`Y X R V U Z`, measured on Mark's Bravo. His FSUIPC scan reports the same six
(`R U V X Y Z`) on the same device model, so they are expected to match, but
this is the last Mark's-machine constant and it is unverified. It fails
*loudly* (a lever drives the wrong thing) and `-AxisLetters` corrects it.
Also unknown: titles for his King Air 350, C90 and PMDG 737 — he has all three
but has not loaded them with FSUIPC running.

## Open

- **TOMORROW (parked 2026-09-07 23:50, Mark: "Save this for tomorrow"):**
  1. **Alpha recalibration, second run** with the five-step tool (rests from each end of travel). Mark's first run stored pitch centre 495, an edge of the yoke's settling band; the midpoint is nearer 500. Press "Recalibrate the Alpha"; expected: two "settles between" lines, a centre near 500, an after reading inside the band, exit 0.
  2. **AI traffic** - everything is in `notes/traffic-plan.md`, "Tomorrow" list: the words for the graphics levels and for the General > Traffic page in both modes, the profile-container byte diff (sim running, one setting switched between two saves), what FSLTL and BATC expect MSFS's traffic type to be, then the mode choice and preflight rows.
  3. **Alpha axis letters in FSUIPC** (`DX`/`DY` unmeasured) - needs the sim AND the Alpha connected: FSUIPC's axis assignment window, turn, read the letter, push, read the letter. Then decision 2 in `notes/alpha-plan.md` can be written.
  4. **Lead: the MSFS profile container is readable** (`strings` shows controller GUIDs and input profile names such as "Midcon General") - the "Empty Bravo profile set" check might become a read instead of a person's word. Same byte-diff method as item 2.
- **GOAL (Mark, 2026-09-06): the same system for the Honeycomb Alpha.** Plan and decisions in `notes/alpha-plan.md`. **`data/alpha-buttons.json` is fully measured (Mark, 2026-09-07, two runs; log `capture-alpha-20260907-180936.log`): all 35 buttons named** - panel 1-12 yoke (PTT 1, left white 2, right white 3, red 4, LH left rocker down 5/up 6, LH right rocker down 7/up 8, RH top rocker left 9/right 10, RH bottom rocker left 11/right 12), 13-30 the nine base switches (odd ON, next even OFF in `otherPosition`), 31-35 key OFF/R/L/BOTH/START; hat = one switch, eight directions saved as assumed 32-39. Next: decisions 1-4 in the plan; then the writer is generalised with fenced per-device blocks.
- **Security audit 2026-09-05 → `notes/security-audit-2026-09-05.md`**, ten items as a checklist. Do 1 (global `[Buttons]` writer discards the user's own lines), 2 (`myevents.txt` overwritten), 4 (Google Fonts fetched on every start) before anyone outside Mark and midcon07 runs it.
- **VERIFY LATER (Mark, 2026-09-05): the IAS button reportedly does nothing on midcon07's machine.** Not yet tested by Mark; he will report. Candidates when it comes back: the 172/G1000 wants FLC via a different event than `AP_AIRSPEED_HOLD` (65898 family; check `events.txt` for the aircraft), or BigBoy's button map was written before the map was complete. Do not fix blind - wait for the report.

- Lever 4 = `V` is by elimination from FSUIPC's six-axis list, not directly
  pushed. One throttle test closes it; not urgent.
- **Retired 2026-09-05: `FLEET` now comes from the host. `LAYOUTS` is still a hand copy of `data/lever-layouts.json`
  and drifted** (King Air 350 wrong layout, C90 absent, turboprop layouts
  missing — fixed 2026-09-04, but the copy remains). The page should read the
  JSON; until it does, every table change must be made twice.
- **Bravo button map — MEASURED 2026-09-04 by `Probe-HoneycombDevices.ps1
  -Capture`, stored in `data/bravo-buttons.json`.** Prober numbers (FSUIPC =
  n−1, and +100 above 31 — confirmed at scale, e.g. 34 → 133): AP panel
  HDG…AUTOPILOT = `1–8`; knob INCR/DECR = `13/14`; mode selector HDG/VS/ALT =
  `19/20/21` (IAS and CRS pending a settle-then-read recapture — the first
  pass read a pass-through position); trim wheel = `22/23`; gear UP/DOWN =
  `31/32`, **two buttons**; **each switch is two buttons, one per position**
  (`34/35`, `36/37`, `38/39`, `40/41`, `42/43`, `44/45`, `46/47`); flap handle
  pending. At rest the Bravo holds ~9 buttons (selector position, gear
  position, seven switch positions) — any capture must diff against the
  current set, never look for "a button". The **choice** of sim events lives
  in the same file's `map` and is reviewable; `Set-BravoButtons.ps1` writes
  the global `[Buttons]` and refuses unmeasured controls.
- **Two layers, and only one knows about aircraft.** The physical map (which
  button is which number, `data/bravo-buttons.json`) is measured once per Bravo
  and is aircraft-free; 29 of its 35 controls also have aircraft-free *actions*
  (global `[Buttons]`). The six detent buttons are the sole exception, forced by
  the sim: the same button is feather on a prop lever, reverse on a throttle,
  cut-off on a condition lever, nothing on a mixture — MSFS has no "lever N
  went below its detent" event for the aircraft to interpret. **Documented
  (User Guide, Buttons page): `[Buttons.<name>]` is *additive* — "anything
  programmed without that checkbox selected will also be available, unless
  overridden by an aircraft-specific assignment."** So the global 38 stay, and
  an aircraft's six detent lines sit on top. Turboprop prop levers → feather
  (`TOGGLE_FEATHER_SWITCH_n`, toggle on press and on release — MSFS offers no
  explicit on/off).
- **Never pass `-Confirm:$false` (or any `-Switch:value`) to a script the app runs.** The app starts scripts with `powershell -File`, and in that mode every argument is a plain string, so a switch cannot take a value: FSUIPC-writing tools refused with "Cannot convert System.String to SwitchParameter". The scripts have no High-impact ShouldProcess, so they need no Confirm argument at all.
- **Measured 2026-09-04: the MSFS 2024 Cessna 172 title is `C172SP G1000 Passengers`.** No "Skyhawk", no "172 " with a space. Guessing "Skyhawk" from the 2020 title cost a flight. `Set-LeverAssignments` now prints a WARNING when no title in FSUIPC7.log contains the substring, listing the titles it has logged - the tell-tale before the flight, not after.
- **Trim wheel (measured on the 172, 2026-09-05): forward must send `ELEV_TRIM_DN`**, the opposite of the first guess. One MSFS trim click per wheel notch is uselessly slow, so the map carries `repeat: 4` and the writer emits the press line four times (FSUIPC fires every line naming a button). `[Buttons] PollInterval` is forced to 10 ms so fast wheel pulses are not dropped. Tune `repeat` in `data/bravo-buttons.json` if 4 is wrong; nothing else changes.
- The red mixture cap sits on **lever 2** in the fixed-pitch layout (letter X). Say "lever 2", never "lever 6", when talking about it.
- **Measured 2026-09-05 on BigBoy: the DC-3 title is `Douglas DC-3 METAL LEFT`** - the livery is part of the title, so the substring is `Douglas DC-3`. Layout `prop_2_cs`, not yet flown.
- **`myevents.txt` is installed by `Set-LeverAssignments` after every real write** (copied from `data/` into the FSUIPC folder when missing or different). BigBoy's log showed it had never been installed, which would have left the King Air condition levers dead there.
- **Launcher UI, settled 2026-09-05 (Mark):** every action button lives in the top bar in the order done - caps, levers, buttons, empty profile, Start Simulator - and is **amber until done, green after**; "done" is read from FSUIPC7.ini by the app (`ReadFsuipcState`), not from a note. Setup shows a **meter** while running and a **pop-up** at the end; failures are appended to `%LOCALAPPDATA%HoneycombAssignmentsetup-errors.log` and the pop-up names the file. One refresh button only. "Test the Bravo" is in a bottom bar. Trim wheel `repeat` is **3**.
- **Weather buttons (2026-09-05):** `tools/Get-AirportWeather.ps1` asks aviationweather.gov (`/api/data/metar?ids=X&format=json&taf=true`); a field with no METAR falls back to the nearest reporting station within 100 NM via a bbox query and the answer *names that station and the distance*. **Windows PowerShell 5.1 traps, both measured:** `Invoke-RestMethod` returns a JSON array as ONE object with array-valued properties, and `ConvertFrom-Json` emits an array as a single Object[] item - so fetch with `Invoke-WebRequest`, parse, and pipe the variable to enumerate. Also a lone PSCustomObject has no `.Count`; wrap in `@()`.
- **A family shares ONE FSUIPC profile** (2026-09-05): the four 737s have `match: "PMDG 737"` and their own `titleMatch`; a write for any member lists EVERY member's fragment in `[Profile.PMDG 737]` (`$MatchList`), and the app counts an aircraft as written only when its own fragment is in that list - an `[Axes]` section alone showed green for the 800 while FSUIPC matched nothing for it. The old 600-only sections were removed from Mark's ini by hand.
- **737-800 verified on BigBoy 2026-09-06 (midcon07): levers work, so the "737-800" fragment is measured-by-flight and the shared profile works under joystick C.** 700 and 900 still reasoned.
- **737-700/800/900 (B737/B738/B739) are copies of the flown 737-600 entry** (2026-09-05, Mark: "all four 737s should share the same configuration"). Their `titleMatch` (`737-700` etc.) is REASONED from the 600's measured title, not read from a log - the writer's no-logged-title WARNING is the tell-tale on first use, and the Add-aircraft window would list an unmatched real title.
- **Measured 2026-09-05 on Mark's machine: the PMDG 737-600 title is `737-600 PAX SC`** (variant/livery suffix); substring `737-600`, layout `jet_2`, ICAO B736, not yet flown. The "no template" window answers from the table the host reads (`templateIcao` in the config push), because the page's fleet list listed a 737-800 the table never had.
- **Settled 2026-09-05 (Mark: "this can't continue"): adding an aircraft never needs a build.** The aircraft table is two files merged: the shipped `data/lever-layouts.json` plus `%LOCALAPPDATA%HoneycombAssignmentircraft.json`, written by the app (`AircraftTable.cs`; local entry with the same ICAO or profile name replaces the shipped one). Every reader merges: `Set-LeverAssignments`, preflight check 25, and the app (`ReadFsuipcState`, config push). **The page's `FLEET` is no longer typed by hand** - it arrives in the config push as `fleet`; only `LAYOUTS` stays a hand copy. The "Add aircraft" button (and the refresh warning) opens a window that lists titles from FSUIPC7.log not yet covered by a template, asks kind/engines/prop/mixture, and writes the entry. Title substring = title minus trailing all-caps or variant words (`TitleMatchFor`, checked against every measured title). ICAO optional: an aircraft added without one is keyed by its profile name.
- **Lever direction (measured on the PMDG 737-600, 2026-09-05):** the family scale `*-1` is right for levers whose FORWARD is "most" (throttle, prop, mixture, power, condition). **Speed brake and flap levers are the other way round** (forward = retracted) and take the opposite sign; with the throttle's sign both ran backwards. `Set-LeverAssignments` flips by role (`Spoiler`, `Flaps`). Not a PMDG quirk.
- **Per-aircraft button actions:** an aircraft entry's `buttons` maps a Bravo control name to a preset, written into `[Buttons.<name>]`, which FSUIPC applies OVER the global line for that button. First use: on jets the flap axis is lever 6, so the Bravo flap switch drives the **PMDG 737 HGS combiner** via `PMDG_B737-7_HGS_HUD_UP_DOWN_SWITCH` (a toggle - PMDG offers no separate up/down, so both switch directions toggle). Unflown as of writing.
- **Reverse thrust has two drive methods** (aircraft entry `reverse`): `event` (default) sends `SET_THROTTLEn_REVERSE_THRUST_ON/OFF`; `throttleSet` sends `THROTTLEn_SET` with `reverseAmount` (default -12288, -16383 = full) on press and 0 on release - for add-ons that ignore the events but read the throttle's negative range. Neither is measured on the PMDG 737 yet (2026-09-05); Mark's test decides.
- **Jets: reverse thrust is the reverser lever on the throttle handle, not the detent** (Mark, 2026-09-05: "the separate, bespoke reverser levers"). Buttons `REVERSER_LEVER_n` in `bravo-buttons.json` (**measured 2026-09-05 on Mark's Bravo: lever 3 = FSUIPC 9, lever 4 = FSUIPC 10; confirmed working on midcon07's Bravo 2026-09-06 without recapture - same numbers on both units**), per lever POSITION (the handle sits on a different lever per jet layout); lifted = reverse, down = idle. Unmeasured = skipped and said. Turboprops keep the detent. **PMDG 737: `SET_THROTTLEn_REVERSE_THRUST_ON` did nothing (measured 2026-09-05)** - PMDG entries use `reverse: throttleSet`.
- **VERIFIED 2026-09-05 (Mark: "perfect"): PMDG 737 reverse works** with unlock SET -12288 + `R` repeat of THROTTLEn_DECR + release SET 0 and CUT. Bounce on drop nets to stowed.
- **PMDG reverse needs a repeating THROTTLEn_DECR while the reverser lever is up** (measured 2026-09-05: `THROTTLEn_SET -12288` alone gives reverse idle, ~5%). **FSUIPC does not repeat a preset** (an `RP` line with `CP<name>` unlocked and stopped) - only its own controls. Numbers **measured by probe** (candidate numbers written into the global `[Buttons]`, FSUIPC annotates each with `-{NAME}-` at startup; a `[Buttons.X]` profile section is annotated only when that aircraft loads): THROTTLE_DECR 65602, THROTTLE1..4_DECR 65966/65971/65976/65981, THROTTLE_CUT 65604, THROTTLE1..4_CUT 65967/65972/65977/65982, THROTTLE1..4_FULL 65963/65968/65973/65978. `reverse: throttleSet` writes three lines per reverser: press SET (unlock), `RP` repeat of `THROTTLEn_DECR`, release SET 0. **The probe trick is the way to get any control number from now on.**
- **FSUIPC button-line syntax, measured by probe 2026-09-05:** the repeat marker is `R` IN PLACE OF `P` (`n=R<joy>,<btn>,C<ctl>,<param>`), annotated `-{NAME}-` like any accepted line. **`RP` and `PR` are kept in the file, never flagged, never fired** - a silent miss; only a malformed compound (`RCP(...)`) drew `<< ERROR 19`. So "no `<< ERROR`" does not prove a line is understood: **look for the `-{NAME}-` annotation FSUIPC appends** (global `[Buttons]` at startup; a `[Buttons.X]` profile only once that aircraft loads). The button log (`LogButtonsKeys=Yes`) shows which line numbers fired - the way the dead `RP` line was found.
- **2026-09-05: a launcher (C:hcl, remote session) went black on selecting an aircraft.** The process stayed alive with NO WebView2 child process and, unexplained, no log line at all from that start. A fresh start from the same folder worked. Mitigations in place: WebView2 runs with `--disable-gpu-compositing` (embedded Chromium goes black under remote desktop/GPU loss), and `ProcessFailed` for browser/renderer death now rebuilds the control (`RecreateWebAsync`) and logs it. Cause not proven - watch for "page process lost" in the log.
- **Switch 6 = PARKING BRAKE on every aircraft** (Mark, 2026-09-06; was the strobe). Position, never toggle: press → preset `HC_ParkingBrake_On` (`1 (>K:PARKING_BRAKE_SET)`), release → `HC_ParkingBrake_Off`. FSUIPC's list has only the toggle `PARKING_BRAKES` (65752), so this is calculator code in `data/myevents.txt`; `Set-BravoButtons` now writes `CP<name>` for any non-numeric control and installs `myevents.txt` itself. Preset count in the log: 22718. Unverified in the cockpit as of writing; PMDG may ignore `K:PARKING_BRAKE_SET`.
- **Measured 2026-09-07, the Alpha, after an evening lost to a hand-rolled USB reader: read controllers through `Windows.Gaming.Input.RawGameController` (in-box WinRT, works from Windows PowerShell 5.1, works with FSUIPC running, no sim needed).** The Alpha is 35 buttons + **1 HAT SWITCH (not buttons)** + 2 axes; at rest buttons 14,16..32 (panel numbering, 1-based) are held = the down positions of the base switches; the push-to-talk trigger is panel button 1 = FSUIPC 0. **Windows' 0-based index IS FSUIPC's number**; the tables keep the 1-based panel number as `prober` and `To-Fsuipc` (minus one, +100 above 31) stays the one rule. The raw-report path (HidP_GetUsages) returned usage 0 for every base switch and never saw the hat; do not go back to it for buttons. `Probe-HoneycombDevices.ps1 -WindowsView` prints Windows' view. Hat directions use kind `hat` (hold, Enter, read direction); FSUIPC POV numbering 32-39 N-clockwise is written into each hat entry as unconfirmed until a log line proves it. Never assign `$all` in that script - `$All` is a parameter.
- **Capture design, settled after three adversarial reviews (2026-09-07), `Start-CaptureSession`:** the resting set is read only after the person presses ENTER to say everything is at rest (reading it at once caught the tidying as the first control). `momentary`: the first new button is WATCHED until cleanly released before it is saved - a second button meanwhile, or a button still held after 8 s (a switch position), rejects it and re-asks. `latching`: two ENTER-gated steps - put it in a DIFFERENT position (fresh baseline), then move it to the asked position and read the settled set; exactly one new button. `held`: hold, ENTER, one reading (the ignition START, which springs back and would otherwise be read on the way through R/L/BOTH). `hat`: hold, ENTER, read the hat DIRECTION, which must equal the one derived from the entry name (HAT_UP_RIGHT -> UpRight); saved with `hat`, `assumed: true`, `numbering`, `verified: false`, and skipped on later runs. Every wait honours Q and says what is still held. Readers return `,@()` so empty is not "failed". The table path is resolved to absolute before the .NET save. Both `device` shapes (object with pid, or a word) are accepted.
- **Measured 2026-09-07 (later): `RawGameController.GetCurrentReading` returns a BLANK reading (every button up, hat Center) with driver timestamp 0 about one time in seventeen at rest** (8 of 250, in between real readings with ten held). `Read-GamingController` returns `$null` for timestamp 0 and the capture's `Read-Unit` reads past it (six tries, 20 ms apart). Before this, a single reading taken on ENTER (hat, START) failed that often for no reason, and a blank mid-press could end a "clean release" wait early.
- **What Mark's first Alpha run (2026-09-07 01:33) showed, read from the table afterwards:** 11 momentaries saved; the control right after the eight hat lines was skipped by a stray keypress because the momentary prompt was the one prompt without `Drain-Keys` (fixed: every prompt drains); nothing else was diagnosable because the capture kept no record. **Now every run writes `%LOCALAPPDATA%\HoneycombAssignment\logs\capture-<unit>-<stamp>.log`** (every line printed, every key, every change in the pressed set, every blank) and prints the path first thing; read the log, do not ask Mark to retell a run. The capture **refuses to start without a real console** (`[Console]::KeyAvailable` throws when input is redirected) instead of skipping every keyed prompt one by one.
- **`tools/Test-CaptureLogic.ps1` proves the capture by running it** (~3 min): dot-sources the probe with `-Library`, replaces `Get-GamingControllers`/`Read-GamingController`/`Read-ConsoleKey`/`Test-ConsoleInput`/`Write-Host`/`Start-Sleep` with a fake Alpha (35 buttons + hat, blank every 17th reading) driven by scripted hands (`Hold`/`Flip`/`Turn`/`HatTo`/`Tap`/`Expect`/`Wait`). Six scenarios, 390 checks: perfect hands; every mistake the prompts are written for; no console; Q then resume; S skips then a run that asks only for those; a unit with no hat. **Run it after any change to `Start-CaptureSession`; it must stay at 0 failures before the capture goes near Mark's hands again.** A latching capture also records the position it LEFT (`otherPosition`, the one button released when the asked one appeared), so a two-position switch's other side is measured in the same step. Keys come only from `Read-ConsoleKey` so the fake can stand in; keep it that way. A tapped key in the fake is invisible to a non-blocking poll until one unit reading has passed (a person is slower than the drain that runs the instant a prompt prints), and blank readings do not advance the hands.
- **Alpha yoke calibration, measured 2026-09-07 (Mark: "sometimes Alphas lose their calibration").** Windows keeps the calibration the simulator and FSUIPC use at `HKCU\System\CurrentControlSet\Control\MediaProperties\PrivateProperties\DirectInput\VID_294B&PID_1900\Calibration\0\Type\Axes\<slot>\Calibration`: 12 bytes = min, centre, max as little-endian int32 (seen: 0 / 511 / 1023). **Slot 1 is the pitch pot (Y), slot 0 the roll pot (X)** - proved by writing centre 499 into slot 1 and watching the pitch reading go to exactly 0.0% (700 gave -28.6%). Raw pots are 0-1023 (rest measured X 511, Y 499-500). The Windows joystick API (`winmm` `joyGetPosEx`, P/Invoked in `tools/Test-AlphaCalibration.ps1`) returns the CALIBRATED value, 0-65535, centre 32767; it returns exact centre as a placeholder until the yoke's first report (up to ~1 s at rest, the unit reports on change and ~1 Hz idle), and **loads the calibration when the device is opened, never again in that process** - so a read after a write must come from a fresh process, and FSUIPC/MSFS must be restarted to see a recalibration (the launcher restarts FSUIPC around it). `Windows.Gaming.Input` does NOT apply the calibration (it returned raw/1023). Mark's pitch pot rested -2.2% off centre as the sim saw it; limit for the WARN is 3%. **The Alpha does not settle to one value: measured 2026-09-07 19:40 the pitch pot rested at 491, 495 and ~510 within a minute depending on which way the yoke last moved (roll pot 511 every time)** - a centring-mechanism band of about +/-2%, not pot drift. So the recalibration takes the centre as the MIDPOINT of the rest reached from fully forward/left and the rest reached from fully back/right (steps 4 and 5), records the band as `settleSpreadPercent` in `alpha-axes.json`, judges its own after-reading against that band, and the gate's remedy says "that is the mechanism" when a WARN is inside it. One rest is an edge of the band, never the centre.
- **The calibration tools:** `tools/Test-AlphaCalibration.ps1` (read-only, `-Json`, `-Library`; verdict + stored slots) feeds the preflight row **"Alpha yoke centred"** in `05-FlightControls.ps1` (PASS/WARN, never blocking). `tools/Set-AlphaCalibration.ps1` is the guided recalibration in its own console window: hands off (3 s, steady within 6 counts) = centre; a roll-only sweep and a pitch-only sweep (exactly one pot must move >=600 counts, the other <=80) = min/max **and which pot is roll and which is pitch, measured, written to `%LOCALAPPDATA%\HoneycombAssignment\alpha-axes.json`**; backup of the old bytes to `alpha-calibration-backup-<stamp>.json` (`-Restore <file>` puts them back); write, read back, verify from a fresh process. The launcher's **"Recalibrate the Alpha"** button (amber when the gate warns, green when centred) closes FSUIPC, runs it visibly, restarts FSUIPC, re-runs the gate. `tools/Test-AlphaCalibrationLogic.ps1` proves the flow with scripted samples against a scratch registry key (34 checks, six scenarios) - run it after any change; never test against the real key. **PowerShell trap (2026-09-07): a dot-sourced script's PARAMETERS become variables in the caller's scope**, so `. probe -Library` set the recalibration tool's own `$Library` to true and it returned from its library gate with exit 0 and no output - the first press of the button. Any script that dot-sources another with a switch must save its own switches first (`$runAsLibrary = [bool]$Library`), and the self-test runs the tool as a real process (`entry-point`) because every dot-sourced test masked it.
- **MSFS 2024 settings on disk, measured 2026-09-07 with the sim running:** `UserCfg.opt` is rewritten within a second or two of EVERY settings change (not only at exit); its `{Graphics}{Traffic}` block holds the density/variety settings as LEVELS (seen 0, 2, 3), and **-1 means "never set by a person"** (Mark's aircraft and parked quantities were -1 until he moved the controls; the VR block still is). The Options > General > Traffic page (AI traffic type, ground aircraft, multiplayer) is NOT in any readable file: it is in the cloud-synced profile container under `SystemAppData\wgs` (`profile_00` in the index, ~1.18 MB, a new blob per save, also written seconds after a change, plain bytes with readable strings). Never write it; reading it by byte diff is the open experiment. Details and the four traffic modes: `notes/traffic-plan.md`.
- **Alpha axes in FSUIPC: not assigned yet (decision 2 in `notes/alpha-plan.md`), and the letters are NOT measured.** Nothing in Mark's ini binds joystick D; MSFS's own default Alpha profile drives roll and pitch today. When they move to FSUIPC the letters must be read from FSUIPC's axis assignment window with the sim running (X and Y held for the Bravo's first two axes, but the Bravo's rotation axes broke the "follow HID usage" rule, so nothing is derived). The physical identity (which pot is roll) is measured by the recalibration sweep, not by convention, once Mark has run it.

- **Capture rule for latching controls: the control must NOT already be in the
  asked-for position.** A diff against the baseline sees nothing, and the next
  thing moved is recorded under that name. It happened: lever 3 was already
  below its detent during a capture, `DETENT_3..5` shifted by one and 5/6 both
  read 132. Corrected from the 2026-09-03 measurement; the capture now prints
  what is held before each latching prompt; `Set-LeverAssignments` refuses two
  levers on one button. A recapture of the detents with every lever above its
  detent would re-verify.
- **Detent buttons are per-aircraft, in `[Buttons.<name>]`, written by
  `Set-LeverAssignments` from the layout:** throttle lever below detent →
  `SET_THROTTLEn_REVERSE_THRUST_ON` on press / `_OFF` on release (explicit
  state, no toggle drift); a lever with `detentPresets` in the aircraft table →
  those presets (King Air 350: `KA_Fuel_*_Condition_Lever_Cut_Off` / `Low_Idle`);
  anything else → nothing. **TOGA** (top of lever 1) is global, `AUTO_THROTTLE_TO_GA`
  65861. **Bug fixed 2026-09-04:** sections were named after the raw `-Aircraft`
  argument, and the app passes ICAO ids — `[Axes.b350]` beside `[Profile.King
  Air 350]` would have looked complete and done nothing. The profile name now
  comes from the table entry.
- **Bravo buttons — trim wheel, AP panel, gear, seven switches — were unassigned
  by design consequence:** "Claude Empty" is empty of *everything*, so choosing
  FSUIPC-owns-the-levers took MSFS's default button map away too. Cheapest
  fix, doable in MSFS's UI on any machine in minutes: a profile copied from
  MSFS's default Bravo map with **only the six lever axes (and any
  spoiler/flap axes) removed** — buttons stay MSFS's, levers are FSUIPC's. The
  real build (FSUIPC `[Buttons]` map from measured button numbers; PMDG via
  `events.txt` presets) is the deep-configuration item. Button syntax is
  documented; numbers follow the measured rule (prober − 1; > 31 → 132+).
- **King Air 350 condition levers — unresolved, and Mark's live ini holds a
  diagnostic.** State on 2026-09-04 ~22:50: `[Axes.King Air 350]` has lever 5
  on the custom axis preset and lever 6 as a main entry plus two *range* lines
  (`BZ,D,-16384,0,P…High_Idle` / `BZ,U,0,16383,P…Low_Idle`); `[Buttons.King
  Air 350]` has `0=PB,132,CP…Cut_Off,0` / `1=UB,132,CP…Low_Idle,0`. Mark
  reported it "didn't work"; the read-back of what FSUIPC re-emitted was never
  captured. **Measured:** a preset receives the signed range, `+16383` forward
  / `−16383` on the detent (via `L:HC_Cond2_Raw` + *Add-Ons → WASM → List
  Lvars*); Bravo button 33 as the prober counts = FSUIPC **132**, so lever 5's
  detent is 27 and levers 1–4 are 23–26. Both custom-axis-preset attempts moved
  the lever but not reliably to high idle — likely the per-delta re-firing.
  FSUIPC's own dialogs saved *nothing* twice for button/range presets. Next:
  read back the ini after one FSUIPC close to see which of those lines survived
  or gained `<< ERROR n`, then test; if the range lines were rejected, that
  syntax needs one more hand-written example. **Strip `LogExtras`, `LogAxes`,
  `LogButtonsKeys` and `[LvarsLogged]` from his ini when done.** The C90 is on
  `turboprop_2` axis controls, never flown, and has no `events.txt` section.
- Reverse zones: `THROTTLEn_SET` supports them, syntax not yet worked out.
- **Lever calibration routine** and **deep configuration mode** — both deferred,
  both specified in `notes/deep-configuration.md`. Basic path stays as designed;
  these are opt-in.
- Small dead patches at both extremes of lever travel remain. **Not ours**:
  `*-1` covers the control range to within one unit at each end; the axis is
  clean by symmetry; halving the scale was tried and is a regression (jumps to
  15%, stops at 85%). What's left is mechanical over-travel past the pot's
  electrical limit plus the aircraft's own idle/max detents. Do not tune it.
- Bonanza profile is written from *type*, not flown. First flight verifies it;
  then flip its `verified` in `data/lever-layouts.json` to `flown`.
- Piggyback reverser levers: switches of their own, or mechanical?
- Nothing has ever run on midcon07's machine.
- **Loaded ≠ planned is invisible to the gate.** Seen 2026-09-04: plan said B350,
  gate passed, user loaded a King Air C90 GTX — no profile matched, levers dead,
  nothing said so. The gate checks persistent config and *cannot* see the loaded
  aircraft; that belongs to the SimConnect monitor / in-sim panel, which should
  compare the loaded title against `[Profile.*]` and say plainly "no lever
  settings for this aircraft" the moment it loads.
