# Lever layout data

`lever-layouts.json` is the source of truth for how the Bravo is physically set
up per aircraft. It should generate, not duplicate:

- the pre-flight caps card in the launcher,
- the in-sim toolbar panel,
- the per-aircraft profiles.

Anything that needs to know which handle goes where reads this file. Nothing
hand-maintains a second copy.

## Handles

The Bravo ships two complete sets, and both fit their worst case exactly — a
twin with constant-speed props uses all six GA handles, a four-engine jet uses
all six jet handles. Nothing is ever short.

| Handle | Count | Role | Silhouette |
|---|---|---|---|
| Black | 2 | Throttle / power | flat block |
| Blue | 2 | Propeller | ribbed barrel |
| Red | 2 | Mixture / condition | domed |
| White throttle | 4 | Jet thrust lever | waisted |
| SPEED BRAKE | 1 | Spoilers | tall blade, function printed on it |
| FLAP | 1 | Flaps | squat block, function printed on it |

`SPEED BRAKE` and `FLAP` have their function moulded into the plastic. Where the
UI refers to them, use the printed word rather than the sim's term — "speed
brake", not "spoilers" — so the screen and the part in hand say the same thing.

## Classification rule

Which layout an aircraft gets is decided by what controls it actually has, not
by its engine type. This is what makes turboprops stop being a special case:
a King Air's power/prop/condition levers are a constant-speed arrangement by
this test, the same as a Baron's.

For propeller aircraft:

| Prop control | Mixture control | Layout |
|---|---|---|
| yes | yes | constant-speed — black, blue, red |
| no | yes | fixed-pitch — black, red |
| no | no | FADEC — black only |

Jets are classified by engine count alone. Gliders are their own case.

Each layout in the JSON carries a `match` object expressing exactly this, so a
classifier reads four facts about an aircraft — category, engine count, whether
it has a prop control, whether it has a mixture control — and selects the
layout. No hand-maintained per-aircraft list.

Those four facts should be derivable from the aircraft's own config files, which
would classify the whole installed fleet automatically and pick up new aircraft
as they are installed. **The exact config keys have not been verified against a
real MSFS 2024 installation yet** — do that before relying on it.

## Fixed anchors

On jets, lever 1 is always the speed brake and lever 6 is always the flaps.
Engines fill inward from lever 3, leaving lever 2 blank until a fourth engine
needs it. That keeps the outermost two levers meaning the same thing on every
jet, which is the point.

## Known gaps

These are not covered and must not be guessed at:

- **Prop control but no mixture control.** No layout matches. If such an
  aircraft exists in the fleet, it needs a decision.
- **Props with three or more engines.** A four-engine piston would want twelve
  levers on a six-lever quadrant. Tri-motors and vintage four-engine types go on
  the manual-review list rather than through this table.
- **Helicopters.** Deferred.
- Lighter-than-air, eVTOL, amphibians, supersonic — manual review.

A classifier that finds no match must say so plainly and refuse, rather than
falling back to a nearest guess. A wrong layout presented confidently is worse
than an honest "this one needs setting up by hand".
