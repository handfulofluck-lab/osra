### Child agent + parent app — payment apps stay blocked at bedtime, and the parent is told (#172)
- **Decision (ADR-0035): option 2** — an OS payment surface (Samsung Pay, Google Wallet, OEM banking
  shells) stays blocked during bedtime. Nothing is added to the essential set; bedtime is unchanged in
  behaviour, and the change is that the decision is now visible and cannot drift.
- **`PaymentSurfacePinTest`** pins it: `com.samsung.android.spay` and `com.google.android.walletnfcrel` are
  not essential, and the set has not grown any wallet-like name. Mutant: add either to
  `EssentialPackages.EXACT` and both rows go red.
- **Parent copy and the way out, in one place:** the always-allowed section of the Apps tab now says that
  bedtime blocks payment apps, and a **"Add a payment app"** shortcut opens the existing add dialog
  prefilled with the first suggestion — the parent confirms a name instead of looking one up.
- New strings (en + ar draft): `bedtimeBlocksPayments`, `addPaymentApp`. The Arabic is a draft for Karim.
- **Why not exempt them:** the set exists so protection cannot make the phone unsafe — the dialer, the
  emergency dialer and the launcher are in it for that reason. A payment app is a convenience at night,
  and exempting every payment surface by default widens the one rule most parents set on day one, to save
  a few families one tap. Role-based NFC detection (option 3) is the right shape for a later version and
  is recorded as such, not dismissed.
- **Two existing rows were adjusted, not weakened:** the Apps tab is genuinely taller now, so
  `widget_screens_test` and `installed_apps_picker_test` drag the list before tapping below-the-fold
  controls. Both still assert the same things.
- **Not in it:** the Flip4 row (bedtime active, open Samsung Pay, expect the block screen) — it goes to
  #484 with the other hardware rows.
