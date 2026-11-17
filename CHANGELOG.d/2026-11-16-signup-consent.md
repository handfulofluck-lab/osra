### Parent app — sign-up page with one consent choice (#846, ADR-0043 D6)
- **Sign-up is its own page.** The registration form is no longer an expansion tile under the sign-in
  fields: one "Create account" line opens a page with the fields, the consent choice and one primary
  button (UI/UX Bureau, 16 Nov). Back returns to sign-in.
- **One required box, as counsel's 16 Nov advice left it.** The sentence comes from
  `GET /v1/consent-copy?locale=` — the app carries no legal text — rendered with the markdown stripped,
  and the two links are buttons **under** the row, so a tap meant for a link cannot tick the box. The
  marketing box and the training box (with its guardian line and Settings switch) are not built: removed
  and parked respectively, per counsel.
- **The error is a line under the box**, in the danger colour with an icon, announced as a live region;
  the button is never greyed out as the answer (WCAG 3.3.1 per the Bureau).
- **Registration carries the consent it showed:** `consents: { termsPrivacy: true, textVersion, locale }`
  on `POST /v1/auth/register`, with the version the copy served. An unservable copy is a plain line, never
  a half-filled form.
- Wording is the lawyer's draft (`signup-v1`); the Arabic box 1 and error line are the Arabic Language
  Bureau's bytes. Settings → Privacy choices and the re-accept screen wait for the server half (part A).
- Tests: the copy renders without markdown, the links sit outside the row, the box is required with a live
  region, the register payload carries the version, the register-form rules still fail before the request,
  the server's field error still names its field, and the Arabic error and box text are the Bureau's.
- **Two kinds of consent, deliberately named apart** (answers Kimi's question on #846): `ConsentRecord`
  is the per-child monitoring consent (ADR-0002) created when a child is added; `ParentConsentEvent`
  here is the account-level `terms_privacy` acceptance. They are not the same record and neither is
  derived from the other.
