# Reverse thrust on the Honeycomb Bravo

Why reverse is the single most confusing part of configuring this hardware, and
what the device actually reports.

## The hardware gives one bit, not a range

Measured directly from the HID input report (`tools/Probe-HoneycombDevices.ps1`),
levers swept through their full travel and past the detent:

- The axis reads `0` **on both sides of the reverse detent**. Pulling a lever
  from the detent into the reverse range produces no axis change at all.
- The only thing that changes is a button: `24`, `25`, `26`, `27`, `28`, `33`
  for levers 1–6 respectively.

Confirmed a second way. A capture that ended with levers 1–3 at the detent and
levers 4–6 pulled past it showed all six axes reading `0`, with only buttons
`27`, `28` and `33` asserted. Axis value cannot distinguish idle from reverse;
the button is the entire signal.

This matches how the community describes the device — a user on the MSFS forums
puts it as the Bravo treating anything past the idle notch as a button event
rather than part of the axis.

## Why the correct setup appears to change per aircraft

Because it does. The hardware supplies one bit. Every aircraft models reverse
differently — a throttle-decrease loop, a held reverse state, a detent step, or
a turboprop beta range that is not reverse at all — so each one needs something
different built from that single bit. There is no one binding that is right
everywhere, which is exactly why guides appear to contradict each other.

Approaches reported working by various people, none of them clean:

- Detent button bound to **Throttle Decrease** with input repetition enabled.
- **Throttle Axis (0 to 100)** instead of plain **Throttle Axis**, so the axis
  never dips into the reverse region.
- **Hold Reverse Thrust**, with *set control on release* enabled.
- Cessna 208: **Previous Detent** reportedly behaves better than throttle decrease.
- MSFS will not register the detent button during a binding scan unless it is
  actuated **on and then off**.

Also widely reported in MSFS 2024: bindings failing to persist after saving.
Further reason not to depend on the sim's own binding store.

## Button numbering differs by layer — a major source of confusion

The same physical detent has three different numbers depending on who is asking:

| Layer | Numbering |
|---|---|
| Raw HID (this repo's prober) | `24`–`28`, `33` |
| MSFS controls UI | different offset |
| FSUIPC7 | different again |

A guide that says "bind button 26" may well mean a different physical lever than
the one in your hand. Always confirm against the prober rather than against a
number quoted in a forum post.

## Unresolved: are the piggyback reverser levers switches?

The commercial/jet throttle handles carry a small secondary lever that lifts for
reverse. Honeycomb's product copy states the commercial throttle levers include
thrust reverse commands, and several sources describe these as switches you
flick — which would make them electrical rather than purely mechanical. Treat
that as unconfirmed: it comes from marketing and retailer copy, and Honeycomb's
own product page says only "6 levers for flaps, spoilers and thrust reverser".

The detent buttons above were measured with the **bare** levers fitted, so the
detent itself is in the quadrant, not in the handle.

**Test to settle it** (jet handles fitted, `-Watch` running):

1. Lift each piggyback reverser *without moving the lever*. A new button number
   means they are independent switches and give a cleaner, earlier reverse
   signal; nothing means the detent button is all there is.
2. Pull each lever past the detent — confirm `24`–`28`/`33` still map the same
   way with the jet handles fitted.
3. Sweep the full travel — confirm the axis still pins at `0` below the detent.

## Where the detent buttons are actually useful

Not in the preflight gate. Lever position is live state that changes the moment
the throttles are touched, so checking it before the simulator has even started
tells you nothing about how the flight will begin.

The moment worth catching is **in the sim, shortly before takeoff**: lined up on
the runway with a reverser still deployed. That is the in-sim panel's job, and
it is the same measurement used at a point where it means something.

## Consequence for this project

Reverse is not a binding, it is a small per-aircraft state machine: detect the
bit, drive the aircraft to reverse idle, then modulate using the axis. Software
that reads both the axis and the button can do this correctly; the sim's binding
UI structurally cannot, which is why every published solution is a workaround.

Reverse must therefore be an explicitly tested part of each aircraft profile,
not assumed to work because it worked on another aircraft.

## Sources

- MSFS forums — [Bravo throttles and reversers FS2024](https://forums.flightsimulator.com/t/bravo-throttles-and-reversers-fs2024/667931)
- MSFS forums — [Bravo detent / reverse thrust engage-disengage](https://forums.flightsimulator.com/t/honeycomb-bravo-throttle-detent-reverse-thrust-engage-disengage/352794)
- [Honeycomb Bravo product page](https://flyhoneycomb.com/products/bravo-throttle-quadrant)
- [FenixSim — Bravo setup guide](https://support.fenixsim.com/hc/en-us/articles/12458977140367-How-to-setup-your-Honeycomb-Bravo-Throttle-Quadrant)
