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

- Lever 4 = `V` is by elimination from FSUIPC's six-axis list, not directly
  pushed. One throttle test closes it; not urgent.
- **The page's `FLEET`/`LAYOUTS` are a hand copy of `data/lever-layouts.json`
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
