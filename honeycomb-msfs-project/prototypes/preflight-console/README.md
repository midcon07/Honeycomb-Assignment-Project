# Preflight console prototype

The launcher's main screen: what the user sees when they start the program.
Checklist on the left, flight plan on the right, aircraft picker across the top.

Open `index.html` in a browser. Nothing to build, no dependencies.

Also published as an artifact:
<https://claude.ai/code/artifact/67f1188d-cb9b-4af9-b280-347564959783>

## Visual language

Colours are taken from a 737-200 flight deck: Boeing cockpit grey `#565C60`,
annunciator amber `#F0A81E`, aged placard white `#E4E2DA`.

The *construction* is carried over from CommPanel and ClaudeSoundtrack, whose
theme source was read rather than guessed at — a metal chassis with a gradient,
recessed plates, visible screws, engraved labels sitting on a dark shadow, lamps
with bloom, and monospace readouts. Only the palette changed; CommPanel's lamp
colours survived almost unaltered.

Deliberately single-theme. A cockpit is one committed visual world, so every
colour is painted explicitly rather than switching with the host.

## What it demonstrates

**The checklist is a checklist.** Boeing normal-procedures format —
`CHALLENGE · · · · · RESPONSE` with leader dots. That formatting is what makes
it read as something you work through rather than a settings screen. Each line
carries a lamp, and anything needing attention gets a plain-language note
beneath it instead of an error code. The footer reads `— HOLD — YOKE NOT
CONNECTED —` in place of a checklist's usual "COMPLETE", and Start Simulator is
disabled. That is the preflight gate's NO-GO wearing cockpit clothes.

**Aircraft picker with frequency ordering.** Frequently flown aircraft rise into
their own group at the top, with a full alphabetical list below. They are *not*
sorted into one reordering list: that is disorienting once you have learned
where things are, so the lower list keeps a fixed order you can rely on. Counts
are shown so it is visible why something sits where it does.

A **native** `<select>`, on purpose. A hand-built dropdown would match the panel
better and be worse to use — the native one behaves like every other program on
the machine and works with the keyboard.

**Plan matching and the round trip.** Choosing an aircraft compares it against
the flight plan's ICAO type. Four states, all verified:

| Situation | Result |
|---|---|
| Aircraft matches, plan recent | green, no action offered |
| Aircraft matches, plan old | amber with the age and the route |
| Different aircraft | amber naming both, offering either way out |
| No plan at all | amber, prompts to make one |

The last three offer **Open SimBrief** and **I have made the plan — refresh**,
which is the case where the program is started before the plan exists.

**The lever caps row follows the aircraft** — `2 x BLACK on levers 1 and 2` for
a DA62, `SPEED BRAKE, 2 throttles, FLAP` for a 737 — from the layouts in
`data/lever-layouts.json`.

## What is real and what is not

Real: the preflight states are this machine's actual result, including the Alpha
genuinely being unplugged. The route is the live SimBrief plan for Pilot ID
24481, all thirteen fixes at their true coordinates, and it really is nine days
old. The mismatch logic is real and works with no network at all, because it
compares the selection against a plan already in hand.

Not real: the fleet list is a representative sample rather than the installed
aircraft, which is the config-scan job that does not exist yet. Usage counts sit
in browser storage; in the finished program they belong in its settings file.
The refresh button cycles the states rather than re-fetching, because a
published page cannot reach outside hosts — only the fetch needs the network.

## Rejected along the way

- **Chart underlays.** Real FAA VFR and IFR layers were built and working before
  being dropped: SimBrief's own app already does charts well. See
  `notes/chart_underlays.md`.
- **A reverser-position check.** Removed because lever position is live state
  and means nothing before the simulator has started. See `docs/setup-spec.md`.
