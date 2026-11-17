### Parent app — the lock rows compile, the site note is the settled one, and the summary counts sites (#841 review)
- The two lock-row getters (`activityLockRow`, `activityLockRowDetail`) are now in the committed
  `app_localizations*.dart`. They were in both ARB files and called by `social_screen.dart`, but missing
  from the generated files, so a checkout failed to compile without `gen-l10n` — the same class of hand
  edit as the escaped apostrophe on #862. The Arabic is the Bureau's issued line, copied byte for byte and
  checked against `app_ar.arb` by comparison, not by eye.
- `webSiteNamesOnlyNote`: the English draft that said OSRA Kids "does not see … anything typed" is
  replaced with the settled line — "Names of sites and online services this phone connected to, not the
  pages opened. Kept for 90 days." It matches the Arabic already in `app_ar.arb`.
- The Reports web summary counts **sites**, not addresses: `webSitesSummary` was issued for this card
  when site-name rows replace full URLs and had no caller until now.
- Verified: no Flutter SDK on the authoring host, so `flutter analyze`/`test` are CI evidence. The two
  tests that pinned the withdrawn English and the "42 URL visits" wording are updated.
- **#841 UI/UX condition 3:** `urlVisits` in the activity summary now counts **distinct sites (hosts)**, not
  URL events — ten visits to one site is one site — and a blocked attempt is not a visit, because it has its
  own counter (`blockedHits`, `topBlockedDomains`). The Reports card label already said "sites visited".
