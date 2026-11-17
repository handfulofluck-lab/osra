### API — the sign-up consent copy is served, with the version and hash it is recorded under (#846 part A)
- New public `GET /v1/consent-copy?locale=` (ADR-0043 D3): one purpose, `terms_privacy`, required, with the
  wording, its SHA-256 `textHash`, `textVersion: "signup-v1"` and the two link URLs. The app renders what
  this returns and carries no legal sentence of its own, which is what gives the hash meaning.
- English is counsel's final A1 text from ADR-0043; Arabic is the Arabic Language Bureau's line from
  #846 (comment 6923432616), byte for byte, with the two Arabic pages the Bureau's link labels point at.
  A locale the API does not serve answers in English and says `locale: "en"` rather than failing — a
  sign-up page that cannot read the terms is worse than one that shows them in the default language.
- Box 1 only: the marketing purpose is removed and the training one is parked by counsel's 16 Nov
  amendment, so the copy describes no choice the server refuses.
- Verified: `npx vitest run test/consent-copy.test.ts` — **6 passed**; two mutants red (forcing the
  English fallback, and a constant hash). `tsc --noEmit` reports the same 77 pre-existing errors as a
  clean checkout, none of them in the new files.
- Not yet: the register half (`consents` required in the same transaction), `/v1/me/consents`, the
  switch refusals and the deletion proof — steps 2 and 3 of the order on #846.
