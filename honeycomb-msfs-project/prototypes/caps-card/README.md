# Caps card prototype

Design study for the pre-flight lever card: the screen that tells the user which
handle goes on which lever for the aircraft they are about to fly.

Open `index.html` in a browser. Nothing to build, no dependencies.

Also published as an artifact:
<https://claude.ai/code/artifact/43c29061-8f32-4b82-9a7c-9fbdd095d185>

## What it demonstrates

- **The common case is a sentence, not a diagram.** Select an aircraft, confirm,
  then select another with the same layout - it stays green and says "no cap
  changes needed" rather than making the user re-read six levers to learn there
  is nothing to do. Both PMDG aircraft share the twin-jet layout, so switching
  between them requires no physical change at all.
- **Changes are a count and a diff.** Only affected levers are marked, with
  "change from Blue" on each.
- **Shape carries as much information as colour.** Each handle is drawn to its
  own silhouette, so the card still reads in poor light, and it still works for
  jets where every handle is white and colour says nothing.
- **The inventory check refuses impossible layouts.** If handles are missing,
  the card says which and disables confirmation rather than drawing a diagram
  that cannot be followed.
- **The reverser check.** Click "simulate a reverser left up" - the card refuses
  to go green and names the offending lever. In the real launcher this comes
  from the detent buttons, which are the only reverse signal the hardware gives.
- **Confirmation is deliberate**, and disabled when there is nothing to confirm,
  so it cannot become a reflex click. This is the one step no software can
  verify.

## Known duplication

The layout table is currently **copied** into the JavaScript in `index.html`.
`data/lever-layouts.json` is the source of truth, and this prototype should be
generated from it rather than holding its own copy. Until that is wired up,
any change to the layouts must be made in both places.

## Not real yet

Which aircraft maps to which layout is illustrative. That mapping is meant to be
derived from each aircraft's config files, not hand-written. See `data/README.md`.
