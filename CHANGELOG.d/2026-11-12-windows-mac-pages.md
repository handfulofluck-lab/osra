### Website — Windows and Mac pages, written and held back (roadmap 5.13, ADR-0041 D4)
- `build.mjs` now writes `/windows/`, `/mac/`, `/ar/windows/` and `/ar/mac/` in the marketing look: what OSRA Kids
  does on the computer, what it needs, how to install it, how to pair it from the parent app's "Add a computer"
  screen, and that it sells nothing. No download button until the installer host is chosen.
- `site-pages.yml` leaves all four out of what is published: ADR-0041 D4 puts no page online before its client's
  first working release.
- `scripts/check-site-no-payment.mjs` (ADR-0041 claim 8) fails CI if any of these pages holds a price, a buy,
  subscribe or checkout word in English or Arabic, or a link to a payment host; 12-case self-test.
