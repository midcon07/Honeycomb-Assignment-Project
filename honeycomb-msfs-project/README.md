# Honeycomb Alpha/Bravo Setup for MSFS 2024

Goal: aircraft-specific control profiles for the Honeycomb Alpha and Bravo, covering the default MSFS 2024 fleet plus the PMDG 737 and PMDG 777F, with automatic per-aircraft switching.

## What's done
- `docs/FSUIPC7_Honeycomb_Setup_Guide.docx` — full reference guide, organized by aircraft category (piston single/twin, turboprop, jet, helicopter, glider), with FSUIPC7 profile-switching explained.
- `docs/Honeycomb_Simple_Setup.docx` — simplified, plain-language walkthrough for the PMDG VNAV/HUD setup specifically, with exact numbers pre-calculated.
- `notes/PMDG_event_codes.md` — the exact PMDG custom control codes for VNAV and HUD, pulled from PMDG's own SDK files.
- `tools/Probe-HoneycombDevices.ps1` — reads the live axis and button state of the Alpha and Bravo straight from the HID input report, so profiles can be written against real identifiers. Dependency-free PowerShell (5.1, no modules, no admin); `-Watch` gives a live view for identifying one lever at a time, `-Json` writes a committable report. See Issue 2.
- `notes/reverse_thrust.md` — why reverse is the most confusing part of this hardware. The axis does not extend into the reverse range, so one button per lever is the entire signal, and each aircraft needs something different built from that single bit.
- `data/lever-layouts.json` — the eleven physical lever layouts, the handle inventory, and the rule for choosing between them. Source of truth: the pre-flight caps card, the in-sim panel and the per-aircraft profiles are all meant to be generated from this rather than duplicate it. See `data/README.md`.

## What's in progress
- Classifying the MSFS 2024 fleet (95+ aircraft in Standard/Deluxe/Premium, plus the Aviator tier's vintage/warbird aircraft) against the eleven layouts in `data/lever-layouts.json`.

  Rather than a hand-written per-aircraft table, each layout carries a `match` describing the aircraft it applies to, so a classifier needs only four facts — category, engine count, whether there is a prop control, whether there is a mixture control. Those should be readable from each aircraft's own config files, which would cover the installed fleet automatically and pick up new aircraft as they are added. The exact config keys still need verifying against a real MSFS 2024 install.

  An aircraft matching no layout must be reported as unclassified, not approximated. See `data/README.md` for the rule and the known gaps.
- Aircraft that don't fit any layout (helicopters, lighter-than-air, eVTOL/rotary, vintage multi-engine/tri-motor, amphibians, supersonic jets) — to be listed separately for manual review.
- Actual installable files (MSFS XML / FSUIPC7.ini) — the Bravo identifiers this was blocked on are now captured; see Issue 2.

## Issues / open questions
1. ~~**Turboprop lever scheme**~~ — **resolved.** Turboprops are not a special case. Layout is chosen by which controls an aircraft actually has, not by engine type: prop control *and* mixture control means the constant-speed arrangement (black, blue, red); mixture only means fixed-pitch (black, red); neither means FADEC (black only). A King Air's power/prop/condition levers satisfy the first test, so it takes the same layout as a Baron. Recorded in `data/lever-layouts.json`.

   Still open, and deliberately not guessed at: an aircraft with a prop control but *no* mixture control matches no layout, and propeller aircraft with three or more engines cannot fit a six-lever quadrant at all. Both go to manual review.
2. **Bravo axis/button identifiers** — partially answered by `tools/Probe-HoneycombDevices.ps1`. Verified against real hardware (levers driven to both stops and the readings confirmed to follow):

   | Property | Value |
   |---|---|
   | USB VID / PID | `VID_294B` / `PID_1901` (Alpha is `PID_1900`) |
   | DirectInput *product* GUID | `{1901294B-0000-0000-0000-504944564944}` |
   | Axes | 6 — HID usages `X, Y, Z, Rx, Ry, Rz` |
   | Axis range | `0`–`1023` (10-bit), full back = 0, full forward = 1023 |
   | Buttons | at least 47 |
   | Input report | 19 bytes, ~1 Hz idle heartbeat |

   Six axes is a clean 1:1 fit with the 6-lever scheme above.

   **Reverse detent:** pulling the levers back past the detent asserts six additional buttons (`24`–`28` and `33`), one per lever. That is the signal to bind for reverse thrust. See `notes/reverse_thrust.md` — the axis does *not* continue into the reverse range, so this button is the only signal the hardware gives.

   **Lever → axis map — resolved.** Captured with `-Watch` logging while the levers were swept one at a time, left to right, with a pause between each. The six movement windows were cleanly disjoint and every axis covered its full `0`–`1023` travel, so the ordering is unambiguous. Each detent button released on the exact frame its axis began to move, which pins the button to the lever independently of the axis.

   | Lever, left → right | HID axis usage | Reverse-detent button |
   |---|---|---|
   | 1 | `Y`  | 24 |
   | 2 | `X`  | 25 |
   | 3 | `Rz` | 26 |
   | 4 | `Ry` | 27 |
   | 5 | `Rx` | 28 |
   | 6 | `Z`  | 33 |

   The prober lists axes in report-descriptor order, and on this hardware that order *is* physical left-to-right. Convenient, but an observation — do not assume it holds for the Alpha.

   **FSUIPC7 `[JoyNames]` — captured.** `FSUIPC7.exe` completes a full joystick scan and writes `FSUIPC7.ini` plus `FSUIPC7.JoyScan.csv` at startup even with no sim running, so the GUIDs can be captured without launching MSFS. On this machine:

   | Device | Joystick id | Letter | Instance GUID |
   |---|---|---|---|
   | Bravo Throttle Quadrant | 3 | B | `{E3AAE090-7A90-11EE-8001-444553540000}` |
   | vJoy Device (`VID_1234`/`PID_BEAD`) | 0 | A | `{684B8680-1E6E-11EE-8002-444553540000}` |

   These are **per-machine and per-enumeration**. They are recorded here as a worked example, not as values to copy onto another installation — the capture has to be repeated on whatever machine the profiles will run on. Note also that a vJoy device is present and holds id `0`; if it is absent elsewhere the ids will differ.

   Still outstanding: the Alpha has not yet been seen enumerated, and FSUIPC7's own axis *letters* are unconfirmed. DirectInput ordering predicts `X→X, Y→Y, Z→Z, Rx→R, Ry→U, Rz→V`, but that must be checked in FSUIPC7's axis scanner before it is relied on.

   **Do not trust the axis letters shown by the legacy WinMM joystick API.** It enumerates the Bravo and returns success, but reports every axis pinned at 32767 regardless of lever position, and it cannot see past 32 buttons — which would hide buttons 33 and 47 entirely. The names above are HID usages read from the device's own report descriptor. FSUIPC7's axis letters are assigned separately by DirectInput and should be confirmed in FSUIPC7's own axis scanner rather than assumed to match.
3. **Default 787 VNAV/HUD codes** — no SDK file exists for this aircraft; plan is to rely on FSUIPC7's automatic Input Events scan instead.

## How to use this repo
Everything here is reference material and instructions, not aircraft files (yet) — open the `docs/` files and follow them in order. As the project develops, installable configuration files will be added under a `profiles/` folder.
