# Bravo test flight — Cessna 172 Skyhawk (G1000), KDPA → KSUE

About 200 nm, roughly 1 h 45 at 110 kt. Everything the ground test could not
prove gets flown here. Each item says what SHOULD happen before you try it.
Write next to it what actually happened: **OK**, **backwards**, **nothing**,
or a few words. Anything else on your mind goes in the notes at the bottom.

Aircraft facts the map assumes: fixed-pitch prop (throttle + mixture only,
levers 1 and 2, the red cap), fixed gear, flaps 0/10/20/30, GFC 700 autopilot in the
G1000 with HDG, NAV, APR, BC, ALT, VS, FLC and a TO/GA button.

---

## 0. In the launcher, before the sim

- [ ] Flight plan refreshed and shows **C172**, KDPA → KSUE.
- [ ] "MSFS is on the empty Bravo profile" confirmed.
- [ ] "Write and restart FSUIPC". Report should end with `[Axes.Skyhawk]`,
      two lines: throttle on lever 1, mixture on lever 2. No `<< ERROR`.
- [ ] Test rows that tick themselves: all green.

The title substring for the 172 is **reasoned, not measured** (from the 2020
title "Cessna Skyhawk G1000 Asobo"). If the levers do nothing at the ramp,
that is the first suspect, not the file. Nothing else in this flight depends
on it except the two levers.

## 1. Ramp, cold and dark

Levers and switches first, autopilot knobs second. Sit in the virtual
cockpit so you can watch the aircraft's own controls move.

**Levers**
- [ ] Lever 1 forward: cockpit throttle follows the whole travel, idle at the
      detent, full at the stop, no dead band at either end.
- [ ] Lever 1 pulled below the detent: **nothing** changes (no reverser on a piston).
- [ ] Lever 2, red cap (mixture): full forward = full rich, full back = idle cut-off.
- [ ] Levers 3–6: nothing (no cap fitted, nothing assigned).

**Switches** — flip one, watch the cockpit switch and its effect, flip back.
- [ ] Battery: the aircraft's BAT half of the master moves, panel lights.
- [ ] Alternator: ALT half of the master.
- [ ] Avionics: G1000 screens come up (may take a moment).
- [ ] Nav, beacon, strobe, taxi: the matching cockpit switch. Use an outside
      view for the lights themselves.
- [ ] Every switch: ON where you called it ON, and the cockpit switch
      **matches your position** after flipping both ways twice.

**Other**
- [ ] Trim wheel: trim indicator moves; forward = nose down. Four sim clicks per notch now (was one, and backwards): say if it is still too slow, too fast, or wrong way.
- [ ] Flap handle: down three times = 10, 20, 30; up three times back to 0.
- [ ] Gear lever: **nothing** (fixed gear).
- [ ] TO/GA on lever 1: flight director bars appear in TO/GA pitch, or
      nothing. Either is a valid result; write which.

**Autopilot knobs on the ground** (engine running or on battery is fine)
- [ ] Selector HDG, big knob: heading bug on the HSI moves, one degree per click.
- [ ] Selector CRS, knob: course pointer / CRS field moves.
- [ ] Selector ALT, knob: altitude preselect moves 100 ft per click. Set **5500**.
- [ ] Selector VS, knob: may show nothing until VS mode is active — note it.
- [ ] Selector IAS, knob: may show nothing until FLC is active — note it.

## 2. Take-off and climb

Hand-fly to about 1000 ft above the field. Heading bug on runway heading first.

- [ ] AUTOPILOT button: AP annunciates on the PFD, tone if you press it again.
- [ ] HDG button: HDG annunciates, aircraft turns to the bug.
- [ ] VS button: VS annunciates. Selector VS, knob: climb rate changes 100 fpm
      per click. Set +500.
- [ ] At 5500 the autopilot captures and shows ALT on its own.
- [ ] Knob with selector HDG while AP is flying: aircraft follows the bug.

## 3. Cruise

- [ ] Selector ALT, knob to **6500**. VS button, +500. Captures at 6500.
- [ ] IAS button: FLC annunciates. Selector IAS, knob: reference speed moves.
      Aircraft pitches to hold it. Then ALT button to hold altitude.
- [ ] NAV button: NAV or GPS annunciates. If the G1000 has a flight plan the
      aircraft tracks the magenta line; if not, write "no plan loaded".
- [ ] Selector ALT, knob back down to **3500**, VS −500. Descends and captures.
- [ ] REV button: BC annunciates (it will not have anything to follow — the
      annunciator is the test).

## 4. Descent and approach into KSUE

Pattern altitude about 1700 ft. Field elevation 725.

- [ ] APR button: APR annunciates (white/armed). Enough for the test.
- [ ] Selector ALT, knob to 1700, VS −500. Levels at 1700.
- [ ] AUTOPILOT button to disconnect: AP goes out, disconnect tone.
- [ ] Flaps 10 / 20 / 30 in turn, trim wheel as needed. Land.

## 5. After landing

- [ ] Lever 2 full back: engine stops (mixture reached cut-off).
- [ ] Switches off in reverse order; every cockpit switch ends OFF matching yours.

---

## What each result means

- **Backwards** (trim, flaps, a switch, the knob in one position): two
  numbers swapped in the map. Say which control.
- **Nothing** on a switch or button: the 172 ignores that standard event.
  Say which. The map is right; that aircraft needs a preset instead.
- **Nothing** on lever 1 and 2 both: the title substring is wrong. I read the
  real title from the FSUIPC log after the flight and fix the table.
- **Knob works in some selector positions, not others**: condition number
  for that position. Say which positions worked.
- **Switch does not match your position after a couple of flips**: press
  and release swapped for that switch.

## Notes

