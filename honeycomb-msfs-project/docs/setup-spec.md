# Setup and environment discovery

What the launcher must find out about a machine before it can be trusted to
configure anything, and how it should behave when it cannot.

## Principle

**Detect everything detectable. Ask only what genuinely cannot be observed.**

Every question put to the user is an opportunity to receive a confidently wrong
answer that then gets baked into the configuration. By this spec's count there
is exactly one thing that must be asked — which lever handles the user
physically owns — and even that should default to the standard set and merely
invite correction.

**Setup and the launcher run the same checks.** Setup discovers and records; the
launcher re-verifies against that record on every start. One engine, two modes.
That is what turns "correct when it was installed" into "correct every time",
and it means the failure path is built before it is needed.

Three entry points:

- **First-run wizard** — sequential, driven in person, does the mapping.
- **Setup menu** — re-openable, each item individually re-runnable.
- **Status view** — the same checks, read-only.

## Phase 1 — find the simulator

Distribution first: MSFS 2024 ships as a Microsoft Store/Xbox package
(`Microsoft.Limitless_8wekyb3d8bbwe`) or via Steam, and the two keep their
configuration in different places. A machine may carry the directory structure
of both, and may also have MSFS 2020 (`Microsoft.FlightSimulator_8wekyb3d8bbwe`)
installed alongside — so the presence of a folder is not proof of the active
install.

**The Community folder must be read from `UserCfg.opt`, never inferred.** The key
is `InstalledPackagesPath`; the Community folder is that path plus `\Community`.

This is not a theoretical concern. On the development machine:

| Path | Packages | Live |
|---|---|---|
| `G:\2024C\Community` | 72 | **yes** — matches `InstalledPackagesPath` |
| `G:\2024C\Community2024` | — | no |
| `G:\MSFS2024\Packages\Community` | 66 | **no**, despite being full of real add-ons |

None of these are junctions. Sixty-six packages sit in a folder the simulator
never reads. Any routine that locates the Community folder by looking for a
directory named `Community` has a coin-flip chance of being wrong, and would
fail silently.

Setup must therefore also **report plausible-but-inactive Community folders** as
a finding. That is a real misconfiguration worth telling someone about.

Also required: the sim must not be running while setup makes changes.

## Phase 2 — find the add-ons

**Two `exe.xml` files exist and add-ons are split across both:**

- `%APPDATA%\Microsoft Flight Simulator 2024\EXE.xml`
- `<Store package>\LocalCache\exe.xml`

On the development machine the first holds FS2Crew, and the second holds AFC
Bridge, GSX/Couatl, ChasePlane, Fenix and Maddog. Backup files left in place
(names ending `before-add.bak`, plus `exe_backup_fsdt.xml`) show several
installers have been rewriting these independently. Anything reasoning about
"what launches with the sim" must know both locations.

Other checks:

- **FSUIPC7 present** — and **registered**. `FSUIPC7.key` must exist; axis
  assignment is a paid feature, and an unregistered copy fails at exactly the
  thing this project depends on. Record the version.
- **FSUIPC7 WASM module** in Community, if used.
- **PMDG 737 / 777** installed, which variants, and whether `PMDG737offsets` and
  `PMDG777offsets` are set to `Auto`.
- **vJoy present.** It occupies an FSUIPC joystick id and shifts every other
  device's numbering.
- **Competing controller software running** — SPAD.neXt, MobiFlight, Axis and
  Ohs, HangarControl. All of them want the Bravo, and if one holds it we lose
  without any obvious symptom.
- **Registry of required add-ons** — a place to declare, once, which programs
  must be running before a flight is considered ready.

## Phase 3 — find and map the hardware

- **Alpha / Bravo present** — HID enumeration on `VID_294B`, `PID_1900` and
  `PID_1901`. Already solved by `tools/Probe-HoneycombDevices.ps1`.
- **Lever mapping** — a guided in-app sweep, one lever at a time, not a manual
  `-Watch` session. The person running it may be alone. Verify the
  report-descriptor-order shortcut rather than assuming it holds.
- **Detent buttons** — confirm per lever on this unit.
- **Piggyback reverser levers** — determine whether they are independent
  switches. See `notes/reverse_thrust.md`.
- **Axis travel** — confirm each lever actually reaches both `0` and `1023`. A
  worn lever that stops short never reaches full throttle, and nothing else
  would report it.
- **Handle inventory** — the one genuine question. Default to the standard sets
  and invite correction.
- **Current physical cap state** — so the first diff reads "change these two"
  rather than "set up all six".

## Phase 4 — identity and state

- Run FSUIPC7 once and read `[JoyNames]`. It completes a full joystick scan and
  writes its ini at startup with no sim running, so this needs no MSFS launch.
- Record joystick ids, letters and instance GUIDs as **captured data, never
  constants**. They are per-machine and per-enumeration.
- **Snapshot before changing anything**: `FSUIPC7.ini`, MSFS control profiles,
  both `exe.xml` files, the Community listing. One action to restore all of it.
  This is what makes the tool safe to run unattended.
- **Environment fingerprint** — MSFS build, FSUIPC version, PMDG versions, our
  own version, device GUIDs. With this recorded, "something changed" becomes a
  diff rather than a guess, and a broken Tuesday becomes explainable.

## Phase 5 — the machine report

Setup's primary output is not a configured machine. It is **a record of what was
found**: one JSON profile for the software, and one plain-language summary a
non-technical user can send to whoever supports them.

This exists because the person maintaining the configuration may have no remote
access to the machine running it. The report is the substitute for that access,
and should be treated as a deliverable rather than a log.

## Accessibility

Capture text size at setup rather than shipping a guess. The intended user is
84. Error messages should be short, specific, and written to be read aloud over
a telephone.

## What the development machine cannot tell us

Development happens on a heavily-modified rig; deployment is to a simpler one.
The simpler machine is **not a subset** — it is a different point in the space,
and in several respects an easier one that the development machine actively
masks:

| Untestable there | Why it matters |
|---|---|
| Steam distribution | Dev machine is Store, and carries both directory layouts, so the Store branch always matches first and the Steam path never executes until it runs on the target. |
| Absence of vJoy | Dev machine has vJoy at id `0`, pushing the Bravo to `3`. Without it the Bravo is likely `0`. The case is hidden, not merely untested. |
| Unregistered or absent FSUIPC7 | Dev machine has a key. Without one, axis assignment is unavailable and the whole approach fails — at the target, never at the source. |
| Slower hardware | Any launch timeout tuned on a fast machine is wrong on a slow one. |
| OneDrive-redirected folders, no admin rights, different display scaling | None of these are exercised by having fewer add-ons. |
| Worn hardware, USB hubs, different topology | Fewer add-ons does not mean healthier hardware. |
| **An operator who will not debug** | The variable that never reproduces. Every defect on the dev machine is found because someone notices and investigates. That condition is absent by definition on the target. |

**Mitigation:** run a read-only survey on the target machine *before* building
against assumptions. It touches nothing and reports what is there —
distribution, paths, FSUIPC presence and registration, devices, vJoy, drive
layout, handle inventory. Two minutes at the desk, and it converts the largest
remaining unknown into data before that unknown can shape the architecture.

**Design rule that follows:** every environment fact is captured data. No
constant in this project may originate as an observation from the development
machine.

## Failure behaviour

A check that cannot determine an answer must report that it could not, and say
what it would need. It must never fall back to a plausible default and continue.

The point of this tool is to be trustworthy when nobody is watching, and a
confident wrong answer is worse than an honest refusal.

## Status of the claims here

Facts about the development machine were read from disk directly. Claims about
how MSFS *behaves* — that `UserCfg.opt` is authoritative, that both `exe.xml`
locations are honoured — are inference from what is on disk, not tested
behaviour. Strong evidence, not proof. Verify before depending on them.
