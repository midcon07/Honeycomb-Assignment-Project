# PMDG Custom Event Codes (confirmed from installed SDK files)

Pulled directly from `PMDG_NG3_SDK.h` (737) and `PMDG_777X_SDK.h` (777F), both shipped inside the aircraft's own `Documentation/SDK` folder.

| Aircraft | Function | Event Code | Source constant |
|---|---|---|---|
| PMDG 737 | VNAV toggle | 70018 | `EVT_MCP_VNAV_SWITCH` (THIRD_PARTY_EVENT_ID_MIN + 386) |
| PMDG 737 | HUD raise/lower | 70611 | `EVT_HUD_STOW` (THIRD_PARTY_EVENT_ID_MIN + 979) |
| PMDG 777F | VNAV toggle | 69844 | `EVT_MCP_VNAV_SWITCH` (THIRD_PARTY_EVENT_ID_MIN + 212) |
| PMDG 777F | HUD | N/A — 777F has no HUD/HGS system | — |

These are used in FSUIPC7's button assignment screen as a custom/PMDG control event, with the number above as the parameter. See `docs/Honeycomb_Simple_Setup.docx` for the exact click-by-click steps.

## Still open / in progress
- Default 787-10 VNAV/HUD codes — not a PMDG aircraft, no SDK header file exists to pull from. Plan: FSUIPC7 should surface these via its Input Events scanner instead of needing a numeric code.
- Full aircraft-by-aircraft lever assignment table (per the 6-lever Bravo scheme) — in progress, large fleet (130+ aircraft in MSFS 2024 across all tiers).
- Native MSFS XML / FSUIPC7.ini file generation for the full fleet — blocked on knowing the exact Bravo axis/button identifiers as recognized by this specific installation.
