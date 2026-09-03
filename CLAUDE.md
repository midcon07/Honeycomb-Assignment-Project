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

1. Preflight gate — `tools/Preflight/`. **May block.**
2. Flight plan — `tools/Get-SimBriefPlan.ps1`. **May never block.**
3. Aircraft chosen, cap layout shown, physical setup confirmed.
4. Add-ons started.
5. MSFS started, **last**.

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
  To let FSUIPC drive, select an *empty* Bravo profile in MSFS — create a new
  one rather than clearing the working one, so it stays one click away.
- **Layout follows capability, not engine type.** Prop control *and* mixture →
  constant-speed; mixture alone → fixed-pitch; neither → FADEC. Turboprops need
  no special case.
- **Chart underlays: rejected.** SimBrief's own app does charts. See
  `notes/chart_underlays.md`.
- **Reverser check in preflight: rejected.** Live state, wrong moment.
- **FSUIPC has two axis forms and they are not interchangeable.**
  `F` sends a sim control and does **no scaling** — a `0`–`1023` lever into a
  `0`–`16383` control gives 6.2% of travel. `D` sends to FSUIPC's calibration,
  which maps the ranges. Assigning is not calibrating; they are separate steps.
- **The gate checks configuration that persists. Live state belongs in the sim.**
- **No constant may originate as an observation from Mark's machine.**

## Verified facts — measured, not assumed

| | |
|---|---|
| Bravo | `VID_294B`/`PID_1901`, Alpha `PID_1900` |
| Rudder pedals | **WINWING Orion Combat Rudder Pedals (Metal)**, `VID_4098`/`PID_BEF0`. 3 axes, no buttons: `Rz` rudder (centres at 32768), `Rx` and `Ry` toe brakes. **Range 0-65535, not the Bravo's 0-1023.** |
| Levers 1–6 → HID axis | `Y X Rz Ry Rx Z` |
| Levers 1–6 → FSUIPC letter | `Y X R U V Z`. Levers 1 and 3 **measured**. Not the obvious convention: `Rz` is `R`, not `V`. Linear axes keep their usage letter; rotational ones are lettered in report-descriptor order. |
| FSUIPC joystick letters | Bravo `B`, pedals `C`, **Alpha `D`** |
| Reverse detent buttons | `24 25 26 27 28 33` |
| Axis range | `0`–`1023`; **saturates at 0 at the detent**, so the button is the only reverse signal |
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

**Never guess FSUIPC ini syntax — make FSUIPC write it.** Assign one thing by
hand, close FSUIPC, run `tools/Read-FsuipcConfig.ps1`, copy what it wrote. A
wrong format is *silently discarded*, so it looks exactly like a lever that does
nothing. Guessing has failed twice here; this technique has worked every time.

**When a mistake gets written down, write down the right thing.** The first bad
`[Axes]` line was recorded as "invented syntax". It was the real `D` form with a
control number in the wrong field — and `D` is the form actually needed. That
note would have steered the next reader away from the answer. A wrong
post-mortem outlasts the bug it describes.

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

## Open

- Bravo lever 5 letter unconfirmed. `R U V` fits both measurements; the naive
  reading says otherwise. One hand assignment settles it.
- Throttle scaling: `D` form + calibration, syntax to be read off FSUIPC.
- Piggyback reverser levers: switches of their own, or mechanical?
- Nothing has ever run on midcon07's machine.
