### OSRA Kids for iPhone — the block screen's main button can be read (U14)
- **Before:** "Request access" was system-blue words on the system's default blue button, well under the 4.5:1
  contrast a child needs. "Close app" was faint system gray.
- **After:** the main button is the brand `primary` `#0B5D57` with white words in light **and** dark (7.73:1). A
  light/dark pair was tried first, but on a real iPhone 13 the shield drew the label white whatever dynamic colour
  it was given, so dark mode came out 2.13:1. The UI/UX Bureau chose one fixed pair for this system-drawn screen.
  "Close app" uses `.label`. The title and subtitle are unchanged.
- Rows (`ShieldPaletteTests`): the WCAG contrast formula against known values, at least 4.5:1 for the main button, the
  palette equal to the brand tokens, and a source row that keeps the shield on the fixed palette with no light/dark
  switch.
