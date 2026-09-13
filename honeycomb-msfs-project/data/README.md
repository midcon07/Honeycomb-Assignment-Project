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
| yes | **condition** lever (turboprop) | turboprop — black, blue, red; **same handles as constant-speed, different controls** |

The last row is the correction to "turboprops need no special case". For the
*handles* that was true. For the *controls* it was not: the King Air 350's
red levers did nothing on `AXIS_MIXTURE1/2_SET` while levers 1–4 worked, and
MSFS 2024 has a separate `AXIS_CONDITION_LEVER_n_SET` family for them. So a
turboprop is its own layout, distinguished by `conditionLever` rather than
`mixtureControl` in its facts.

Jets are classified by engine count alone. Gliders are their own case.

Each layout in the JSON carries a `match` object expressing exactly this, so a
classifier reads four facts about an aircraft — category, engine count, whether
it has a prop control, whether it has a mixture control — and selects the
layout. No hand-maintained per-aircraft list.

**Those four facts cannot be read from disk on MSFS 2024.** Verified
2026-09-03 on a real installation: every package under `StreamedPackages` and
`Official2024` is opaque `.fsarchive` blobs — the Bonanza G36 package is two
such files and nothing else — and there are **zero** readable `aircraft.cfg`
files across both trees. The 2020-era plan of classifying the fleet from
config files is dead on 2024 content, and nothing should be built on it.

What replaces it is the `aircraft` table in the JSON: a curated list of
aircraft, each carrying the four facts and the substring FSUIPC will match
its title on. It grows one aircraft at a time, at the moment that aircraft
is first chosen, by asking the user the two questions the config file would
have answered — *does it have a prop lever? a mixture lever?* — and writing
the answer down so it is never asked again. Slower than reading the fleet,
but every entry in it is true.

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
