# Two future modes: lever calibration, and deep configuration

Deferred deliberately. Neither is needed for the basic path, and the basic
path is the promise: pick the aircraft, get the right layout, go and fly.
Everything here is opt-in and sits behind that.

## Why these exist

An evening of getting two levers working on one aircraft turned up four
separate faults, none of which announced itself:

- Raw mode, which scaled a 10-bit device as if it were 8-bit
- a control family whose reverse zone swallowed half the lever travel
- a delta large enough to read as lag
- and a lever whose pot appears to sit saturated across the bottom of its
  own range, which no configuration file can fix

Every one of them presented identically: the lever moves, and it is wrong.
FSUIPC does not report a bad assignment, it discards it. The sim does not
report an unreachable range, it just sits at idle. **The failure mode of this
whole subsystem is silence**, which is precisely what this project exists to
eliminate.

Doing that work by hand took hours and needed a second person reading numbers
off a probe. midcon07 cannot do that, and should never have to.

## 1. Lever calibration routine

**The thing it must not do is silently compensate.** A lever dead across a
fifth of its travel is a hardware fault, and the honest output is to say so
and point at Honeycomb's own configuration utility. Papering over it with
scale and offset would hide a broken pot behind a plausible-feeling throttle,
which is the exact failure this project is built to avoid.

Guided capture, one lever at a time, using `Probe-HoneycombDevices`:

1. Hold at full forward. Record.
2. Rest on the detent. Record, and note which detent button fires.
3. Push to the back stop. Record.
4. Sweep slowly through the whole travel so the response curve is sampled,
   not just its endpoints.

From that, per lever:

- true minimum and maximum, rather than the nominal `0`–`1023`
- where the detent sits in that range, which is where idle belongs
- **how much travel is saturated at either end**, reported in plain words
- whether the response is linear, since a compressed bottom end skews
  everything computed from the endpoints alone

Output is a per-lever scale and offset feeding `Set-LeverAssignments.ps1`,
which already takes `-AxisScale` and `-AxisOffset`. Today those are quadrant
defaults; calibration makes them per lever, because pots differ between
levers on the same device.

Store in the app config, keyed by device GUID from `[JoyNames]` - not by
letter, which is assigned per machine and will differ on midcon07's.

## 2. Deep configuration mode - the "FSUIPC dedication session"

Basic mode stays as designed: choose an aircraft, the layout is written, fly.

Deep mode is a dedicated session that does by itself what took an evening of
hand-editing here. The loop, per lever:

1. Close FSUIPC. The `-WaitForExit` machinery already does this, and the
   refusal to write underneath a running copy is already in place.
2. Write the assignment.
3. Start FSUIPC.
4. Ask for one specific movement, in plain words.
5. Read the truth from the prober rather than from what the file says.
6. Report agreement or disagreement, and correct.

Prerequisites already built:

- `Set-LeverAssignments.ps1` with `-WaitForExit`, backups, and a refusal to
  write while FSUIPC holds the file
- `Read-FsuipcConfig.ps1`, which waits for FSUIPC to exit before reading, so
  it never reports a stale file as current
- `Probe-HoneycombDevices.ps1` as the independent source of truth

Still needed:

- starting and stopping FSUIPC from the app
- per-lever verification prompts written to be read aloud
- somewhere to record what was verified, and when, so a later session does
  not re-ask

**No second monitor.** Settled constraint, and it shapes this: the session
either runs as an in-sim toolbar panel, or the sim runs windowed while it is
used. Anything assuming a second screen is not a design for this machine.

## What this is not

Not a replacement for FSUIPC's own dialogs. It is a way to reach a verified
configuration without a person who already knows FSUIPC sitting next to you -
which is the whole point, since on midweek days there is nobody there.
