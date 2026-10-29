### Parent app — a lapsed consent can be granted again, and the notice is now one widget (#437 part B)
- **The action that was missing.** The *Parental consent* screen could show that a child's consent had
  expired, been withdrawn, or did not match the family region, and could withdraw it — but it could not
  restore it, so an expired record stranded the family: monitoring stopped and every write answered
  `428`. The owner now gets a *Give consent again* card for every non-active state. It posts
  `POST /v1/family/children/:id/consent` and refreshes the screen to the new record, which the server
  also announces to the child's devices as `consent_granted`.
- **No region choice.** That route refuses any jurisdiction but the family's (`family.ts`,
  `428 consent_jurisdiction_mismatch`), so the action sends `family.region` and says which region the
  record will carry. A dropdown there would only offer a way to fail.
- **One notice.** `ConsentStep` (new, `apps/parent-app/lib/features/children/consent_step.dart`) holds
  the notice and the method picker, and nothing else. `AddChildDialog` and the new confirmation dialog
  both render it, so the wording a parent consents to cannot drift between the two places consent is
  given. `AddChildDialog` keeps its own region dropdown, unchanged.
- **A 56 px overflow found and fixed on the way.** `DropdownButtonFormField` defaults to
  `isExpanded: false`, which sizes the button to its widest item rather than the field, so the Arabic
  method labels overflowed the dialog at 320 px. The shared step now sets `isExpanded: true`, which
  protects the add-child dialog on a small phone too. The RTL row fails without it.
- **Who sees it.** The family owner only: the route is `requireOwner`, so a co-parent would get `403`.
  Every state but a healthy Active record gets the action, **including `expiring`**: a parent who can only
  renew after the record lapses is guaranteed a gap, because `requireConsent` starts answering `428` the
  moment the date passes. (`expiring` was excluded in the first push; the review of 2026-10-29 16:19Z
  corrected it, and the rows changed with it.)
- **Two wordings, because the truth differs.** A lapsed record means monitoring has stopped; an expiring
  one is still running, so that state gets *Renew consent* and "Renewing now keeps monitoring running
  without a gap" instead of the lapsed note. The dialog switches titles with it.
- **One notice, and the right one for each place.** `ConsentStep` (new,
  `apps/parent-app/lib/features/children/consent_step.dart`) holds the notice and the method picker, and
  nothing else. `AddChildDialog` renders it with the add-child wording; the re-grant dialog passes
  `consentRegrantNotice`, because "before you add a child" is false for a child who already has a record.
  The legal wording stays English (#159). `AddChildDialog` keeps its own region dropdown, unchanged.
- **A 56 px overflow found and fixed on the way.** `DropdownButtonFormField` defaults to
  `isExpanded: false`, which sizes the button to its widest item rather than the field, so the Arabic
  method labels overflowed the dialog at 320 px. The shared step now sets `isExpanded: true`, which
  protects the add-child dialog on a small phone too. The RTL row fails without it.
- Rows: `test/consent_test.dart` — owner + expired posts `{method, jurisdiction: "EU"}`, refreshes to
  Active **and refetches the family overview**; co-parent gets no action; Active gets none; owner +
  expiring renews with the renew wording and flips to Active; a withdrawn record is re-grantable; a `500`
  keeps the dialog open with a sentence and does not refetch; Arabic RTL at 320×568.
  `test/content_safety_test.dart` — the add-child dialog renders `ConsentStep` and posts the method chosen
  through it. Every row names the mutant that must turn it red, in a comment beside it.
- `regionLabel()` extracted in `api/permission_errors.dart`, so the region a grant dialog names and the
  region a refusal names are one mapping. Behaviour change, disclosed: `OTHER` now reads as the app's
  label instead of the raw code, which is what a sentence in Arabic needs.
