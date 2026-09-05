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

### The preflight gate is not optional

**Every launch runs the gate before anything else happens, and a blocking
failure stops the launch.** Implemented in `tools/Preflight/`.

This is a hard requirement, not a feature. An add-on that was healthy in
September is not necessarily healthy in November — sim updates move files,
installers rewrite each other's configuration, hardware gets unplugged. The only
way the program can honestly claim to be working is to check, every time, and
refuse to proceed when something it depends on is broken.

Rules that follow, and none of them are negotiable:

- **A gate that verified nothing must never report GO.** Zero results is
  `CANNOT RUN`, not success.
- **`TODO` is not `FAIL`.** A machine that has never been set up has no
  assignments and no profiles. That is its expected state. Presenting it as a
  fault teaches the user the report is noise.
- **Prefer a missed warning to a false alarm.** The person reading it cannot
  distinguish a spurious alert from a real one, and a report that gets ignored
  is worse than no report.
- **Adding an add-on to the gate must not require editing the gate.** Checks are
  files in `Preflight/Checks/`; the host knows nothing about any of them.
- **One problem, one message.** A check reporting a consequence of an earlier
  failure defers to the root cause rather than adding a second instruction the
  user cannot act on yet.
- **A crash is not a verdict.** Any unexpected error is `CANNOT RUN`, never an
  exit code that could be mistaken for a real answer.
- **The gate checks configuration that persists. Live state belongs in the sim.**
  A thing is only worth checking here if it will still be true when the user is
  sitting at the runway. Anything that changes the moment they touch the
  hardware is being asked at the wrong time, and an always-green line that can
  never be acted on dilutes the ones that matter.

  Worked example, because this one nearly shipped: a reverser-position check
  was added to the checklist purely because the detent buttons had just been
  measured and there was somewhere to use them. It failed the test — lever
  position changes constantly once the sim is running, so verifying it before
  the sim has even started says nothing. The right home for that finding is the
  in-sim panel a few seconds before takeoff, where "reverser 2 is deployed and
  you are lined up on the runway" is worth saying.

  Having a capability is not a reason to build a feature.

### Hardware presence

**Both the Alpha and the Bravo missing are blocking.** Without the yoke or the
quadrant there is no flight, and continuing would only produce a session where
the controls do nothing and no message explains why.

Presence is checked **live, against Windows** — not read from FSUIPC's
`[JoyNames]`, which is a snapshot from its last run and will report hardware
that was unplugged yesterday. The check also separates *not plugged in* from
*plugged in but Windows reports a problem*, because those need different
remedies.

When hardware is missing the program prompts and **waits**, re-checking on a
timer, so the user can plug it in and have the program continue by itself. No
keypress: asking someone to press a key invites pressing it without doing the
thing, and is one more instruction to give somebody already stuck.

FSUIPC is checked after the hardware, because if the quadrant is not attached
then FSUIPC's opinion of it is beside the point. More add-ons follow the same
contract.

Three entry points:

- **First-run wizard** — sequential, driven in person, does the mapping.
- **Setup menu** — re-openable, each item individually re-runnable.
- **Status view** — the same checks, read-only.

## The startup sequence

Fail first. Check everything cheap and foundational before anything expensive,
and **change nothing until every check has passed**. When a check fails, nothing
has been modified yet — that is the whole value of failing early, and it is lost
the moment verification and work are interleaved.

| | Phase | Blocking |
|---|---|---|
| 0 | Simulator not already running; configuration present, readable, current schema | yes |
| 1 | **Alpha and Bravo connected and healthy** | yes |
| 2 | Simulator install still valid; Community folder read from `UserCfg.opt` | yes |
| 3 | FSUIPC installed, registered, knows both devices | yes |
| 4 | Internet and SimBrief reachable | **no** |
| 5 | Has the installed fleet changed since it was last classified | **no** |
| — | *everything above is read-only; the gate passes here* | |
| 6 | Snapshot, then scan and write assignments if the fleet changed | — |

**Why hardware sits above the configuration checks.** It is independent of them,
instant to test, and the thing most likely to be wrong on any given day. A USB
cable is what changes; an install path is not. Reporting it first means the user
is plugging the yoke in while the rest of the sequence runs.

**Why the aircraft scan is not in the sequence.** It is work, and it writes.
Phase 5 only takes a cheap fingerprint — package counts and modification times,
about 80 ms across 1387 folders — to decide whether a scan is *needed*. The scan
happens after the gate passes, after a snapshot.

### Three states of the configuration file, which are not the same thing

- **Missing** — this machine has not been set up. Expected, not a fault. Run
  setup.
- **Unreadable** — the file exists but will not parse. **Blocking, and never
  self-healing.** A file that will not parse may still hold a working setup, and
  quietly replacing it destroys the only copy of what used to work. Offer the
  backup.
- **Written by another version** — needs migrating, not guessing at. Blocking.

A configuration recorded on a *different computer* is also worth saying out
loud: every path and hardware identifier in it belongs to that other machine.

### Drift is not a question

When the configuration and the simulator disagree about where packages live, the
**simulator is right** — `InstalledPackagesPath` in `UserCfg.opt` is the
authority. So a moved Community folder is a fact to be read, reported and
written back, not a question to put to the user.

Only ask when the answer genuinely cannot be determined: the path the simulator
names does not exist, or there are two installations and no way to tell which is
meant. Never ask a question you already have the answer to.

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

## The launch flow, and what may block it

1. **Preflight gate** — `tools/Preflight/`. Hardware, then FSUIPC, then whatever
   else gets added. **May block.**
2. **Flight plan** — `tools/Get-SimBriefPlan.ps1`. **May never block.**
3. Cap layout shown, physical setup confirmed by the user.
4. Add-ons started.
5. MSFS started, last.

The distinction between 1 and 2 is load-bearing. The gate answers *is this
machine healthy* and can say NO-GO. SimBrief answers *what are we flying today*
and is advisory only. Mixing them would let a network hiccup present itself as a
broken installation, and would stop someone flying because a website was down.

### SimBrief

Fetching a user's own latest plan needs no API key; only generating plans does.

Store the **Pilot ID**, not the username — usernames change, ids do not. Ask for
the username once during setup because that is what the user knows, resolve it
to the id, store the id, and never ask again.

**SimBrief has no concept of a "current" plan.** The endpoint always returns the
most recent one, with a success status, however old it is. Recency has to be
judged from `params.time_generated`. This is not hypothetical: the first real
fetch during development returned a plan **9.3 days old**, which a naive
existence check would have presented as today's flight.

Rather than asking whether it is current, show the route and let the user
recognise it — *"KUDD to KVIS, Diamond DA62, made 9 days ago"*. Recognition
beats judgement.

**SimBrief identifies the aircraft, not the layout.** It returns an ICAO type
code; `aircraft.engines` is the engine model, not a count. Choosing a lever
layout still needs the four facts in `data/README.md`, which come from the
aircraft's own config files. Two lookups, not one.

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
| How the native `SimConnect.dll` gets found | On the dev machine a SimConnect client built against the SDK reaches the native layer with no local copy of the DLL, so something already on that machine is providing it — Lorby Axis and Ohs, FSCopilot, StreamFlight and Add-On Linker are all installed and all are SimConnect clients. A clean machine may resolve it differently or not at all. What has to ship alongside the program cannot be determined here. |
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
