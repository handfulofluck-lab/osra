### API — the parent's own consent choices, and the re-accept signal (#846 part A step 3)
- `GET /v1/me/consents?locale=` answers the parent's current state per purpose with the copy to show **in the
  asked language**, so the text a parent reads and the hash a later write records are the same language, and
  **`requiresAcceptance`**: true whenever there is no granted `terms_privacy` row at the version the server
  serves today. That is what makes the re-accept screen (ADR-0043 D6.3) safe to build — the server decides
  it, so a phone holding an old copy cannot decide it has already agreed. Accounts created before step 2
  land here, which was Ahmed's N2.
- `GET /v1/me/consents/history` returns the parent's own rows (purpose, action, text version, locale,
  surface, time) — a data-subject answer with no email and no name.
- `PUT /v1/me/consents/{purpose}` writes one append-only row with the **served** hash and
  `surface: app_settings`. It refuses withdrawing the terms (`400 terms_withdrawal_is_account_deletion`,
  because withdrawal is account deletion), refuses both parked purposes while their switches are off
  (`consent_purpose_not_offered`), and refuses an unknown purpose or a retired version by name. Repeating the
  newest state is not a new act: it answers `200` with `recorded: false` and appends nothing.
- Verified locally: `consent-routes.test.ts` **9 passed**; full API suite result pasted on the PR.
- **Not in this PR:** the `ConsentProof` deletion table (ADR-0043 D7). Its own text flags it as an open
  lawyer question (L4 — whether to keep such a proof at all, and for how long), so the retention rule is
  asked rather than assumed.
