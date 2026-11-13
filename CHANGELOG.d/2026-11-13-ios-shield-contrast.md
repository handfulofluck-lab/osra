### OSRA Kids for iPhone — the block screen's main button can be read (U14)
- **Before:** "Request access" was system-blue words on the system's default blue button, well under the 4.5:1
  contrast a child needs. "Close app" was faint system gray.
- **After:** the main button uses the brand `primary` background with `onPrimary` words (`#0B5D57` with white in
  light, `#7DB4FF` with `#0E1417` in dark, about 7.7:1 and 8.7:1), as one dynamic colour each that follows the
  phone. "Close app" uses `.label`. The title and subtitle are unchanged.
- Rows (`ShieldPaletteTests`): the WCAG contrast formula against known values, at least 4.5:1 for the main button in
  both themes, the palette equal to `docs/design/tokens.json`, and a source row that keeps the shield on the palette.
