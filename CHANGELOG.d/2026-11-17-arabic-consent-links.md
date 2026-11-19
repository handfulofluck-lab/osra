### API — the Arabic consent copy links to pages we actually publish (#846, Arabic Bureau)
- `ar.links` and the two URLs inside the Arabic box-1 markdown pointed at `osratech.com/ar/terms` and
  `/ar/privacy`, **and neither page exists** (`site/ar/` ships only `index`, `download`, `guide`). An Arabic
  parent tapping «شروط استخدام تطبيق أسرة» while being asked to accept would have landed on nothing.
- They now point at the published English pages, which is what the Bureau's box-1 file has said since 16 Nov;
  the Bureau's Arabic wording itself is unchanged, only the two URLs inside it.
- New row: every link in the served copy (both locales, links object and markdown) must resolve to a
  `site/<path>/index.html` we ship. Mutant: putting `/ar/terms` back fails it — measured, 2 rows red.
- **The hash moves** — the text served to Arabic parents changed — so `textHash` differs from what earlier
  rows recorded. `textVersion` stays `signup-v1`: a link target is not a change of meaning (ADR-0043 D4), and
  a bump would force every existing account through the re-accept screen.
