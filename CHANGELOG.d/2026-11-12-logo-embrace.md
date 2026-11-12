### Brand — the OSRA logo, "Embrace" (roadmap 3.20)
- The maintainer chose the logo on 2026-11-12: the O of OSRA as a parent's arm around a child, with the child as
  the dot. `docs/design/BRAND.md` is its specification.
- `scripts/brand/render.mjs` is the one source. It writes the SVG masters and 123 exported files to
  `docs/design/brand/`: store icons, the iPhone set, Android launchers, Windows `.ico` and Mac sizes, for the
  parent app (solid teal), OSRA Kids (light) and OSRA Kids Full (dark). Colours are read from
  `docs/design/tokens.json`.
- The two Google Play listing icons in `docs/store/play/images/` are replaced with the new ones. Nothing is
  uploaded to Play by this change.
- No app shows the logo yet: each app takes it in its own PR.
