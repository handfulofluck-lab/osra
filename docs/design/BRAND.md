# The OSRA logo

**Chosen by the maintainer on 2026-11-12:** option A, "Embrace", from four directions drawn that day. **Roadmap:**
3.20. **Design language:** ADR-0038; the colours below are tokens from `tokens.json`.

## 1. The mark

The O of OSRA drawn as a parent's arm around a child. The ring is the parent. The dot in the opening is the child.

In a 100 by 100 box: a ring of radius 26 and stroke 12 with round ends, running 270 degrees and open at the top
right; a dot of radius 7.5 centred in the opening at (68.4, 31.6). The mark stays inside the middle 66% of the box,
so the Android, iPhone, Windows and Mac icon masks all keep it whole.

The mark does not mirror in Arabic. It is the same on every surface.

## 2. One mark, three apps

| App | Ground | Ring | Dot (the child) |
|---|---|---|---|
| **OSRA** (parent) | `primary` light `#0B5D57` | `onPrimary` light `#FFFFFF` | `warn` dark `#FFB454` |
| **OSRA Kids** (child, every store and platform) | `tint` light `#EAF2F0` | `primary` light `#0B5D57` | `usageCategory.games` light `#C96A12` |
| **OSRA Kids Full** (Android, from osratech.com) | `ink` light `#12211F` | `ok` dark `#86D4BE` | `warn` dark `#FFB454` |

The parent app is solid teal. OSRA Kids is the same mark on the light tint. OSRA Kids Full is the same mark on dark,
so a parent can tell the two child apps apart on a home screen. The dot is always the warm colour.

On its own, without a ground: `brand/mark.svg` on light surfaces, `brand/mark-dark.svg` on dark ones.

## 3. The name beside the mark

"OSRA" in IBM Plex Sans 700 with «أسرة» in IBM Plex Sans Arabic 600 after it, in the secondary text colour. The
mark sits before the name, at the name's cap height times 1.6. Keep clear space of one dot diameter around the mark.

## 4. Do not

- Recolour the mark outside the three rows above, add a gradient or a shadow, or outline it.
- Rotate it, mirror it, or move the dot.
- Put text inside an app icon.
- Redraw it by hand. Change `scripts/brand/render.mjs` and render again.

## 5. Files

`scripts/brand/render.mjs` is the one source. It writes:

| Path under `docs/design/brand/` | What |
|---|---|
| `mark.svg`, `mark-dark.svg` | The mark alone |
| `icon-parent.svg`, `icon-kids.svg`, `icon-kids-full.svg` | Square app icons, full bleed |
| `export/<app>/icon-1024.png`, `store-512.png` | Store icons, no alpha channel |
| `export/<app>/ios/Icon-App-*.png` | The iPhone and iPad icon set, no alpha channel |
| `export/<app>/android/mipmap-*/ic_launcher.png`, `ic_launcher_round.png` | Android launchers before API 26 (newer ones use the adaptive icon in each app) |
| `export/<app>/windows/app.ico`, `icon-*.png` | Windows |
| `export/<app>/mac/icon-*.png` | Mac, with Apple's rounded square inset in the canvas |

```bash
NODE_PATH=$(npm root -g) node scripts/brand/render.mjs
```

## 6. Where it goes

| Surface | Icon | Status |
|---|---|---|
| Google Play listings | `docs/store/play/images/parent-icon-512.png`, `kids-icon-512.png` | in the 3.20 PR |
| Parent app, Android and iPhone | `parent` | its own PR |
| OSRA Kids, Android (Play and Full) | `kids`, `kids-full` | its own PR |
| osratech.com | `mark.svg` as the favicon and beside the name | with 3.19 |
| OSRA Kids, iPhone | `kids` | needs an asset catalog in `apps/child-ios` (Ahmed) |
| Windows and Mac child agents | `kids` | when each gets its window and installer |
