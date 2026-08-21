# Geotag camera — design system

Design direction: **Field kit**. The app is an instrument, not a social camera. It reads
like a survey tool: legible in sunlight, data-forward, no decoration that isn't information.

Do not introduce new colors, radii, or fonts. If a component seems to need one, it means the
component is wrong.

---

## Tokens

### Color

| Token | Hex | Use |
|---|---|---|
| `sand` | `#F0EDE4` | App background |
| `sand-deep` | `#E2DDCE` | Inset areas, viewfinder placeholder, disabled fills |
| `rule` | `#C7C0AE` | Hairline borders, dividers |
| `ink` | `#1E2A22` | Primary text |
| `ink-soft` | `#5A6B5F` | Secondary text, all metadata |
| `forest` | `#2F5D45` | Primary actions, shutter, active state |
| `forest-deep` | `#1F3E2E` | Pressed state |
| `signal` | `#E07A2F` | Live/recording, GPS degraded, destructive confirm |
| `paper` | `#FFFFFF` | Cards that sit above sand |

`signal` is the only saturated color and it means *pay attention*. Never use it for
decoration, branding, or a happy state. If two things on a screen are orange, one is wrong.

No dark theme in v1. Field use is outdoors; a dark UI in sunlight is unreadable.

### Type

- Display / UI: **Space Grotesk** — weights 400 and 500 only
- Data: **JetBrains Mono** — weight 400 only

Every number a user might verify goes in mono: coordinates, accuracy, timestamps, frame
counts, altitude, bearing. Prose goes in Space Grotesk. This split is the core of the
direction — a coordinate in a proportional font instantly looks untrustworthy.

| Role | Size | Weight | Family | Tracking |
|---|---|---|---|---|
| Screen title | 22 | 500 | Grotesk | -0.01em |
| Section head | 13 | 500 | Grotesk | 0.06em, uppercase |
| Body | 15 | 400 | Grotesk | 0 |
| Label | 12 | 500 | Grotesk | 0.02em |
| Data | 12 | 400 | Mono | 0 |
| Data small | 10 | 400 | Mono | 0.06em, uppercase |

Uppercase is allowed here (unlike most systems) but only on section heads and status
readouts — it's the instrument-panel vernacular. Never uppercase body text or buttons.

### Geometry

- Radius: `6px` on cards, inputs, and buttons. `0` on full-bleed panels. Never above 8px.
- Borders: `1px solid rule`. On emphasis, `1px solid forest`.
- Accent bars: `border-left: 3px` in `forest` or `signal`, with `border-radius: 0`.
- Spacing scale: 4, 8, 12, 16, 24, 32. Nothing between.
- Touch targets: minimum 48dp. Field users wear gloves.

---

## Components

### Status readout
Top of the viewfinder. Mono uppercase, 10px. Format: `FIX ±4M`. When accuracy is worse
than 15 m or the fix is stale, the text turns `signal` and reads `FIX ±38M — WEAK`. Never
hide this element; a camera that silently loses GPS is worse than one that says so.

### Stamp card
Sits below the viewfinder. `border-left: 3px solid signal`, no other border, radius 0.
Line 1: site name, uppercase, 12px Grotesk 500.
Line 2: coordinates, mono 11px, `ink-soft`.
Line 3: date and time, mono 11px, `ink-soft`. Format `21AUG26 09:14`.

### Shutter
44dp square, radius 6, `forest` fill. Pressed state fills `forest-deep` and scales 0.96.
Disabled (no GPS fix, no project) fills `sand-deep` with `ink-soft` — and tapping it shows
an inline reason rather than doing nothing.

### Log row
Thumbnail 56dp radius 6, hairline border. Site name as the primary line, mono metadata
below. Grouped under uppercase mono date heads. Bordered rows, not floating cards.

---

## Screens

1. **Viewfinder** — status readout, camera feed, stamp card, control row. The stamp card
   shows live values and is tappable to edit before capture.
2. **Log** — reverse-chronological, grouped by day, bordered rows.
3. **Map** — muted basemap, square pins in `forest`, `signal` for degraded-accuracy shots.
4. **Project detail** — photo count, date range, export action.
5. **Onboarding** — welcome, camera prime, location prime, first project, stamp template.

---

## Stamp compositing rules

The stamp is burned into the image at capture. This is the part most implementations get
wrong, so treat it as a first-class subsystem, not a UI overlay.

- Render on a canvas sized to the **photo's native resolution**, not screen density. Scaling
  a screen-rendered overlay up produces soft, unusable text.
- Bundle JetBrains Mono as an asset and load it explicitly before compositing. Do not rely
  on a system fallback — the fallback will be proportional and the digits will not align.
- Stamp font size is a **percentage of image height** (start at 2.2%), never a fixed px.
- Draw a `rgba(240,237,228,0.92)` panel behind the text block. Text with a drop shadow
  alone fails on bright sky and on dark shed interiors; a panel survives both.
- Write GPS to EXIF as well as burning it in. The pixels are for humans, EXIF is for
  everything downstream.
- Store the original unstamped frame alongside the stamped one. Users will eventually want
  a different template on an old photo.

---

## Copy rules

- Sentence case on buttons and body. Uppercase only on mono status readouts and section heads.
- Verb-first buttons: "Allow location", "Export project". Never "OK" or "Submit".
- Errors state what happened and the fix, in one sentence, no apology:
  "No GPS fix yet. Move away from the shed wall."
- Empty states are invitations: "No frames in this project yet."
- Never use "successfully", "please", or exclamation marks.

---

## Non-goals for v1

- Dark theme
- Filters or beautification
- Accounts or sign-in before first capture
- Any mascot or illustration inside the viewfinder, log, or map
