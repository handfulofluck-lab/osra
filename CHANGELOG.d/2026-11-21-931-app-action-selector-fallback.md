### Parent app — the app-rule action selector stops breaking Arabic labels (#931)
- At 320 px with 200 % text the three action labels cannot each hold one line, and a segmented label that
  does not fit breaks **mid-word** — which in Arabic cursive is unreadable. The selector now drops to the
  stacked buttons the appearance screen already uses, so every label stays whole. Labels, order and wording
  are unchanged; the Arabic Language Bureau's issued text is not touched.
- The choice is measured at build time from the three labels under the current font and text scale, not
  from a fixed breakpoint, so it follows the device rather than the spec.
- Six new rows: the fallback appears at the smallest supported width and 200 %, the stacked order is
  allow → block → time limit, a roomy width keeps the segmented row, a width-by-scale sweep asserts no
  label ever spans two lines, the fallback reports the chosen action, and English gets the same protection.
  Forcing the segmented row back kills the sweep row, which is how the fix was shown to be load-bearing.
