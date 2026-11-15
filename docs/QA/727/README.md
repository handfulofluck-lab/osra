# The four pictures the Bureaus asked for on #727

Both Bureaus asked for the two coaching cards in Arabic, once with numbers and once without, and for one of the
numbers to contain a space. These are the four files:

| Card | With numbers (device country AE) | Without numbers (unknown country) |
|---|---|---|
| Self-harm | [self_harm_ar_numbers.png](self_harm_ar_numbers.png) | [self_harm_ar_no_numbers.png](self_harm_ar_no_numbers.png) |
| Grooming | [grooming_ar_numbers.png](grooming_ar_numbers.png) | [grooming_ar_no_numbers.png](grooming_ar_no_numbers.png) |

## How they were made, exactly

**They are rendered from the widget, not photographed on a handset.** `CoachCardSection` was pumped inside the
parent app's real localisation delegates at **360 dp wide**, locale `ar-AE` (numbers) and `ar-ZZ` (no country row, so
the sentence fallback), captured through a `RepaintBoundary` at 2× and written to PNG.

Two things had to be worked around, and both are stated so a reviewer does not read more into the picture than is
there:

1. A Flutter widget test draws every glyph as a box with its test font. The render loads **Segoe UI** for text and
   Flutter's own **MaterialIcons** for the two icons, so what you see is real Arabic shaping.
2. The surface is 360 dp wide — the narrow case the UI/UX Bureau raised ("tip 5 will take three or four lines at
   320 wide"). It is not a 320-wide surface and does not stand in for one.

What they do show, and why the Arabic Bureau asked:

- The **isolate** around every number, in Arabic: `800 4673` keeps its groups in reading order, and `116111` and
  `999` are not reversed.
- The **hours bracket** after the number it belongs to, in the Arabic the Bureau worded, including the Ramadan case
  on the self-harm card's crisis line.
- The **sentence fallback** when a country has no row: "اتصل بخط الدعم النفسي في بلدك" and "فاتصل برقم الطوارئ في
  بلدك", never a placeholder.
- «فابقَ» without a comma on the self-harm tip, and «أما إذا … ف» on the grooming card's emergency sentence.

A handset or Simulator shot is still owed by whoever has one; these close the "we have no picture at all" gap that
held the sign-off.
