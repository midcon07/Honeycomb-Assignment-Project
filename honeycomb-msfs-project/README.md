# Honeycomb Alpha/Bravo Setup for MSFS 2024

Goal: aircraft-specific control profiles for the Honeycomb Alpha and Bravo, covering the default MSFS 2024 fleet plus the PMDG 737 and PMDG 777F, with automatic per-aircraft switching.

## What's done
- `docs/FSUIPC7_Honeycomb_Setup_Guide.docx` — full reference guide, organized by aircraft category (piston single/twin, turboprop, jet, helicopter, glider), with FSUIPC7 profile-switching explained.
- `docs/Honeycomb_Simple_Setup.docx` — simplified, plain-language walkthrough for the PMDG VNAV/HUD setup specifically, with exact numbers pre-calculated.
- `notes/PMDG_event_codes.md` — the exact PMDG custom control codes for VNAV and HUD, pulled from PMDG's own SDK files.

## What's in progress
- A complete lever-assignment table for the whole MSFS 2024 fleet (95+ aircraft in Standard/Deluxe/Premium, plus the Aviator tier's vintage/warbird aircraft), following this scheme:
  - SEP fixed-pitch: throttle, mixture
  - SEP constant-speed: throttle, prop, mixture
  - Piston twin (fixed-pitch analog): throttle x2, mixture x2
  - Piston twin (constant-speed): throttle x2, prop x2, mixture x2
  - FADEC single/twin: throttle only (x1 or x2)
  - Single jet: spoiler, (blank), throttle, (blank x2), flaps
  - Twin jet: spoiler, (blank), engine 1, engine 2, (blank), flaps
  - Tri-jet: spoiler, (blank), engine 1, engine 2, engine 3, flaps
  - Quad jet: spoiler, engine 1, engine 2, engine 3, engine 4, flaps
  - Turboprops weren't covered by the original rule set — needs a decision (see Issues)
- Aircraft that don't fit any of the above (helicopters, gliders, lighter-than-air, eVTOL/rotary, vintage multi-engine/tri-motor, amphibians, supersonic jets) — to be listed separately for manual review.
- Actual installable files (MSFS XML / FSUIPC7.ini) — blocked on knowing the exact Bravo axis/button identifiers as detected by this specific Windows installation. See Issues.

## Issues / open questions
1. **Turboprop lever scheme** — not covered by the original 6-lever rule set (King Air, TBM 930, Caravan, Saab 340B, ATR 42/72, etc.). Proposed default: power lever + condition/prop lever per engine, matching the constant-speed piston pattern. Needs confirmation.
2. **Bravo axis/button identifiers** — need either a Bravo-specific export (similar to `Jerry's Config.xml` for the Alpha) or manual confirmation of Honeycomb's fixed hardware GUID/axis order to generate ready-to-install files instead of instructions.
3. **Default 787 VNAV/HUD codes** — no SDK file exists for this aircraft; plan is to rely on FSUIPC7's automatic Input Events scan instead.

## How to use this repo
Everything here is reference material and instructions, not aircraft files (yet) — open the `docs/` files and follow them in order. As the project develops, installable configuration files will be added under a `profiles/` folder.
