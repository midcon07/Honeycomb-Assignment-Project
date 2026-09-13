> **Decision, 2026-09-01: not doing this.** SimBrief's own app already shows
> charts well, and carrying tile services would mean a licence question outside
> the US, coverage that stops at the American border, and one more thing to fail
> when the internet is down. The route map draws itself from the flight plan.
>
> Kept because the findings below cost real effort to establish and would have
> to be rediscovered if this is ever revisited. Nothing in the program depends
> on any of it.

# Chart underlays

Putting the route on top of real aeronautical charts, the way SkyVector does.

For the United States this is entirely reproducible from public domain data. For
the rest of the world it is not, and that is worth understanding before building
anything that assumes otherwise.

## The FAA services

Public domain, no API key, no registration. Standard Web Mercator XYZ, served as
**JPEG**.

```
https://tiles.arcgis.com/tiles/ssFJjBXIUyZDrSYZ/arcgis/rest/services/<SERVICE>/MapServer/tile/{z}/{y}/{x}
```

**The path order is z / ROW / COL, i.e. z/y/x** — not the z/x/y most tile servers
use. Getting this backwards produces tiles from the wrong place rather than an
error.

| Service | Chart |
|---|---|
| `VFR_Sectional` | VFR sectionals |
| `VFR_Terminal` | Terminal area charts |
| `IFR_AreaLow` | IFR enroute low |
| `IFR_High` | IFR enroute high |

## Cached zoom levels — measured, not read from metadata

The service metadata advertises 24 levels of detail. Only some are actually
built. These were found by probing:

| Service | Zooms that return tiles |
|---|---|
| `VFR_Sectional` | **8 – 12** |
| `VFR_Terminal` | 10 – 11 only |
| `IFR_AreaLow` | 8 – 12 (7 exists but is near-blank) |
| `IFR_High` | 5 – 9 |

**This matters more than it looks.** A view fitted to a 242 nm route lands at
zoom 7, which is below the sectional's minimum. Every tile 404s, the map falls
back, and it looks exactly like a network or policy problem. The failure is
silent and misattributed. Any layer definition must carry the zoom range it
actually serves and clamp into it.

Zoom 8 is the only level all three useful layers share, so it makes a sensible
default for a whole-route view.

`VFR_Terminal` is not worth offering for route display: it is cached only at
z10–11 and covers terminal areas alone, so it is blank over most of a leg and
cannot show a whole route at once.

## Coverage — measured

One tile probed per location per service:

| Region | Sectional | IFR Low | IFR High |
|---|---|---|---|
| Continental US | yes | yes | yes |
| Alaska | yes | yes | yes |
| Hawaii | yes | yes | yes |
| Guam | yes | — | yes |
| Toronto | yes | yes | — |
| Puerto Rico | — | — | — |
| Europe, Japan, Australia, Mexico | — | — | — |

**The FAA is United States only.** Toronto appears only because US sectionals
are drawn across the border; coverage stops shortly beyond it. Puerto Rico and
the Caribbean are a separate chart series not present in these caches.

## Outside the US

SkyVector's worldwide enroute charts are **SkyVector's own product**, not a
public domain source being re-served. That part of it cannot be reproduced.

The realistic options, none of them a drop-in equivalent:

- **open flightmaps** — genuinely good free VFR charts covering around 19
  European countries, produced by a nonprofit association. Distributed under
  the OFMA General Users' License: royalty-free, but with conditions that have
  to be read and honoured rather than assumed.
- **OpenAIP** — worldwide, free, and current, but it is aeronautical *data*
  (airspace, airports, navaids) rendered as a map, not scanned official charts.
  Needs an API key. A reasonable universal layer; it will not look like a
  sectional.
- **NGA / DoD legacy charts** (ONC, TPC) — public domain and worldwide, but
  many date from the 1980s and 90s and are not maintained. Fine as scenery,
  unsafe as reference.
- **A plain topographic base map** — universal, no aeronautical content. Better
  than an empty pane, and honest about being nothing more than terrain.

## Recommended shape

Treat the layer list as data, not code. The FAA layers work today and cost
nothing; everything else is a licence decision and an added dependency. Adding
a region later should be a configuration change.

Whatever is offered, a layer with no coverage at the current position must say
so plainly rather than showing an empty pane, and the route must remain drawn
and legible with no chart behind it at all.

## Two rendering notes

- Charts are bright paper. Knock them back (around 75% brightness) or the route
  and any panel styling disappear into a wall of tan.
- Give the route a dark casing and the labels a dark halo, or they vanish over
  terrain shading.

## Published pages cannot load these

A published artifact runs under a Content Security Policy that blocks every
external host, so no tile service will load in one. The same file opened from
disk works normally. Any prototype should detect the failure and fall back to a
drawn chart with an explanation, rather than presenting a broken map.
