# Honeycomb Alpha — plan (goal set 2026-09-06)

Goal, in Mark's words: "set up the type of system for the Honeycomb Alpha"
that now works for the Bravo - measure once, map by data, write per machine,
test in the app.

## What carries over unchanged

- **Measure, never guess.** `tools/Probe-HoneycombDevices.ps1 -Capture
  data/alpha-buttons.json` walks the controls in that file and records the
  button number each one really is. The capture now reads the unit the
  table names (`"device": "alpha"`), so it cannot write Alpha numbers into
  the Bravo's file.
- **Same numbering** (prober − 1, above 31 add 100) and the same latching
  rule: a switch already in the asked-for position shows nothing - move it
  out first.
- **Per-machine writes.** FSUIPC gives the Alpha its own letter (Mark: D,
  BigBoy: B). Lines are written on each machine by name lookup, never copied.
- **The app** gets a "Set up Alpha" button, green from FSUIPC's own file,
  and test rows for the Alpha in the overlay.

## What is different about the Alpha - decisions for Mark

1. **The base switches duplicate the Bravo's.** The Alpha base has BAT, ALT,
   AVIONICS BUS 1/2 and the five light switches - the roles the Bravo's
   seven switches were given. Options:
   - **Alpha owns electrics and lights; the Bravo's switches are freed** for
     other things (switch 6 is already the parking brake). Cleanest: every
     switch has one meaning, and the labels on the Alpha base match.
   - **Both drive the same things.** Harmless while they agree; when they
     disagree the last one moved wins, and one handle then lies about the
     state. Not recommended.
   Recommendation: the first.
2. **Pitch and roll axes.** Two ways:
   - **Leave them to MSFS.** MSFS binds the Alpha's axes by default. But MSFS
     also binds its buttons, which would then fire twice (MSFS and FSUIPC), so
     MSFS needs an Alpha profile with ONLY the two axes bound - the Alpha's
     "Claude Axes Only", made by hand like "Claude Empty" was for the Bravo.
   - **FSUIPC drives them too.** Then the two yoke lines must be in EVERY
     aircraft's `[Axes.<name>]` section, because a profile's axes section
     replaces the global one wholesale (FSUIPC: buttons are additive, axes
     are not). `Set-LeverAssignments` would append a fixed yoke block to
     each write. MSFS then needs the Alpha on a fully empty profile.
   Recommendation: FSUIPC drives them. One place, one rule, and the empty
   MSFS profile is the pattern midcon07 already knows.
3. **The ignition key** is five latching positions plus a sprung START.
   Map: each position to its magneto event (`MAGNETO_OFF/RIGHT/LEFT/BOTH`),
   START to `MAGNETO_START` on press and `MAGNETO_BOTH` on release. Jets and
   turboprops ignore magnetos; leave it, or give those aircraft their own
   meaning later via the per-aircraft `buttons` block.
4. **Yoke buttons and hat.** Suggested defaults, all Mark's call:
   - Hat: pan the view (the sim's `PAN_*` events) - or trim, if he prefers.
   - Left rocker: elevator trim up/down (there is already a trim wheel on
     the Bravo - decide which is primary).
   - Right rocker: rudder trim? flaps? nothing?
   - Trigger: push-to-talk when online (vPilot/BeyondATC key), else nothing.
   - Four horn buttons: AP disconnect, TO/GA, view reset, brakes - to decide.
5. **Rudder pedals** (WINWING, 0-65535) are out of scope for this goal, but
   the same question - MSFS or FSUIPC - applies and should get the same
   answer as the yoke axes.

## Build order

- [x] Capture supports the Alpha (table names the device).
- [x] `data/alpha-buttons.json` with every control labelled, all unverified.
- [ ] Mark runs the capture with the Alpha plugged in; S skips any control
      the yoke does not have. Result: numbers for every control.
- [ ] Decisions 1-4 above, written into `alpha-buttons.json`'s `map`.
- [ ] Button writer generalised: takes a table and a device; writes each
      device's lines as a fenced block in the global `[Buttons]` so the
      Alpha's write does not erase the Bravo's and vice versa (this also
      settles security-audit item 1 - lines outside the fences are left
      alone).
- [ ] Yoke axes: fixed block appended to every `[Axes.<name>]` write
      (decision 2), or the MSFS axes-only profile.
- [ ] Preflight: the "Empty Bravo profile set" confirmation gains the Alpha,
      or a second confirmation.
- [ ] App: "Set up Alpha in FSUIPC" button, green from the file; test rows
      (switches, key, hat, rockers, buttons, pitch/roll direction).
- [ ] Fly it: 172 first (magnetos matter), then the 737 (they must not).
