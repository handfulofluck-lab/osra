### Parent app — screenshots the Bureaus review are drawn at full size in real faces (#1109)
- The frame harness rendered at half the intended surface: `physicalSize` is in device pixels, so 375 × 812 at dpr 2
  produced 187.5 × 406 pictures — the 188 × 406 frames in the ring review.
- A missing font face used to be skipped silently, so Arabic could render as solid blocks while the run stayed green.
  A family a frame needs now loads or throws, naming what is missing.
- Noto Naskh Arabic UI ships with the tests, with its licence: the parent app bundles no Arabic face and that is the
  face Android draws Arabic with, so 200 % line heights match a phone. One Arabic row now checks 320 logical px with
  200 % text.
