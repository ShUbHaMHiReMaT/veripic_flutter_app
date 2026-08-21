# Geotag camera — design system

Design direction: **Bold paper**. Flat cream ground, heavy black outlines, hard offset
shadows, saturated colour used as identity. Every surface reads like a physical card sitting
on a desk: outlined, slightly raised, unambiguous. Nothing is subtle, nothing is glassy.

The app is still an instrument — it must stay legible in sunlight and honest about data —
but it states things loudly rather than quietly.

Do not introduce new fonts. Do not introduce a colour outside the palette below, and do not
invent a new radius. If a component seems to need one, the component is wrong.

---

## Tokens

### Color

| Token | Hex | Use |
|---|---|---|
| `canvas` | `#FCF9F0` | App background |
| `surface` | `#FFFFFF` | Cards, sheets, anything raised off the canvas |
| `surface-inset` | `#F1EDE1` | Inset wells, viewfinder placeholder, disabled fills |
| `outline` | `#000000` | Every border, every divider, every shadow |
| `text` | `#000000` | Primary text |
| `text-soft` | `#6B6B6B` | Secondary text and metadata |
| `accent` | `#FFD84D` | Primary action — the shutter, the confirm button |
| `accent-press` | `#E8C22F` | Pressed state for `accent` |
| `ok` | `#5EE9A0` | Verified, authentic, signature valid |
| `alert` | `#FF7BA0` | Tampered, denied, destructive, degraded GPS |
| `warn` | `#F5E3B0` | Caution, fallback key, unavailable service |
| `info` | `#A78BFA` | Neutral category identity |
| `cool` | `#C8E85A` | Neutral category identity |
| `null` | `#C4C4C4` | Unsorted, empty, nothing yet |

Colour here is **identity**, not decoration — it tells you *which thing this is* or *what
state it is in*. A card gets a colour because of what it holds, not to look lively. `ok`,
`alert`, and `warn` are reserved for state and may never be used as category identity.

No dark theme. Field use is outdoors; a dark UI in sunlight is unreadable.

### Type

Both faces are already bundled. **Space Grotesk** is variable (300–700); use the `wght`
axis, never a faux-bold.

- Display / UI: **Space Grotesk** — weights 400, 500, 700
- Data: **JetBrains Mono** — weight 400 only

Every number a user might verify goes in mono: coordinates, accuracy, timestamps, hashes,
counts, altitude. Prose goes in Space Grotesk. A coordinate in a proportional font instantly
looks untrustworthy.

| Role | Size | Weight | Family | Tracking |
|---|---|---|---|---|
| Display | 30 | 700 | Grotesk | -0.02em |
| Screen title | 22 | 700 | Grotesk | -0.01em |
| Card title | 15 | 700 | Grotesk | 0 |
| Body | 15 | 400 | Grotesk | 0 |
| Label | 12 | 500 | Grotesk | 0.02em |
| Data | 12 | 400 | Mono | 0 |
| Data small | 10 | 400 | Mono | 0.06em, uppercase |

Uppercase only on `data small` readouts and status badges. Never uppercase body or buttons.

### Geometry

- Radius: `16px` on cards and sheets. `12px` on buttons, inputs, and icon tiles. Full round
  on badges only. Never anything else.
- Borders: `2px solid outline` everywhere. `3px` only on the shutter.
- Shadow: `4px 4px 0 outline` — hard, zero blur, never coloured, never soft. This is the
  only depth cue in the system. Pressed elements drop the shadow and translate `2px, 2px`
  so the press feels physical.
- Spacing scale: 4, 8, 12, 16, 24, 32. Nothing between.
- Touch targets: minimum 48dp. Field users wear gloves.

---

## Components

### Icon tile
A rounded square, `12px` radius, `2px` outline, filled with the item's identity colour, with
a black glyph centred. 48dp. This is the visual anchor of every card.

### Tab card
The core unit. A `surface` card with a coloured tab protruding from its top-left edge, like a
file folder. Card is `16px` radius, `2px` outline, `4px 4px 0` shadow. The tab is the same
colour as the card's icon tile. Inside: icon tile top-left, count metadata top-right in mono,
title bottom-left in card title. Tapping presses the whole card.

### Status readout
Top of the viewfinder. Mono uppercase, 10px, inside a `12px` outlined pill. Format `FIX ±4M`.
When accuracy is worse than 15 m or the fix is stale it fills `alert` and reads
`FIX ±38M — WEAK`. Never hide it; a camera that silently loses GPS is worse than one that
says so.

### Stamp card
Sits below the viewfinder. `surface`, `2px` outline, `16px` radius, shadow, with a `12px`
wide `accent` bar down its left inside edge.
Line 1: site name, card title.
Line 2: coordinates, mono 11px, `text-soft`.
Line 3: date and time, mono 11px, `text-soft`. Format `21AUG26 09:14`.

### Shutter
64dp square, `12px` radius, `3px` outline, `accent` fill, `4px 4px 0` shadow. Pressed fills
`accent-press`, drops the shadow, translates `2px, 2px`. Disabled fills `surface-inset` —
and tapping it shows an inline reason rather than doing nothing.

### Badge
Full-round pill, `2px` outline, mono 10px uppercase, filled with a state colour. Used for
`NEW`, `SEALED`, verdicts.

---

## Screens

1. **Home** — display headline, primary action row, then a two-column grid of tab cards.
2. **Viewfinder** — status readout, camera feed, stamp card, control row.
3. **Check** — picked frame, verdict card, numbered check list, findings, metadata drawer.

---

## Stamp compositing rules

The stamp is burned into the image at capture. This is the part most implementations get
wrong, so treat it as a first-class subsystem, not a UI overlay.

- Render on a canvas sized to the **photo's native resolution**, not screen density. Scaling
  a screen-rendered overlay up produces soft, unusable text.
- Bundle JetBrains Mono as an asset and load it explicitly before compositing. Do not rely
  on a system fallback — the fallback will be proportional and the digits will not align.
- Stamp font size is a **percentage of image height** (start at 2.2%), never a fixed px.
- Draw a `rgba(252,249,240,0.94)` panel behind the text block, with a solid `accent` bar down
  its left edge. Text with a drop shadow alone fails on bright sky and on dark shed
  interiors; a panel survives both.
- Write GPS to EXIF as well as burning it in. The pixels are for humans, EXIF is for
  everything downstream.
- Store the original unstamped frame alongside the stamped one. Users will eventually want a
  different template on an old photo.

---

## Copy rules

- Sentence case on buttons and body. Uppercase only on mono readouts and badges.
- Verb-first buttons: "Allow location", "Export project". Never "OK" or "Submit".
- Errors state what happened and the fix, in one sentence, no apology:
  "No GPS fix yet. Move away from the shed wall."
- Empty states are invitations: "No frames in this project yet."
- Never use "successfully", "please", or exclamation marks.

---

## Non-goals

- Dark theme
- Gradients, blurs, glows, or soft shadows — depth is the hard offset shadow, nothing else
- Filters or beautification
- Accounts or sign-in before first capture
- Any mascot or illustration inside the viewfinder or the check report
