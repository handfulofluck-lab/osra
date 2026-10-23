### Parent app — the Arabic screens read the way the native reviewer approved (#344, issue #159)
- Karim reviewed 14 Arabic screens at 320×568 RTL and left wording notes per screen. This PR applies
  every one of them to `app_ar.arb`: `serverLabel` ("الخادم (السيرفر)"), the screen-time value read
  used-then-limit ("45 من 120 دقيقة"), `socialMonitoringTitle` (now "وسائل التواصل"), the weekend-limit
  label spelled out in full, `totalAverage` punctuated as a sentence, `safeSearchForced` (now
  "تفعيل البحث الآمن على YouTube"), the pairing copy (`scanQr`, `expiresIn`), both appearance/language
  explanations, the consent status and active-detail sentences, the retention paragraph, the search-safety
  vault notice and empty state, and the three digest labels.
- `blockedTimes` and `daysShort` are ICU plurals with the full Arabic word, so the reports and usage
  screens no longer print "حُظر 12 مرة" or "7 ي".
- **Alert titles are translated by type, never by matching the server's English text.** Four new keys
  (`alertTitleSos`, `alertTitleBlockedSite`, `alertTitleDailyLimit`, `alertTitleGeneric`) exist in both
  ARB files; `l10n.dart`'s `alertTitleFor(category, serverTitle)` picks the key from `category` and falls
  back to the translated generic — an unknown category can never leak English into an Arabic screen.
  Clause 06 uses "تمت محاولة زيارة موقع محظور" because OSRA blocks at DNS, before the page loads.
- Layout, per the review's points: 02 now shows the used/limit pair in that order; 04 splits the consent
  heading and detail into a two-column label/value row; 05 breaks the retention paragraph in two; 09's
  period selectors read "7 أيام / 14 يومًا / 30 يومًا" and its chart dates use the locale's own order;
  14 puts the send hour and the zone in separate, labelled fields.
- The lone "120" on the reports screen was the fl_chart left axis drawing bare minute numbers; it now
  renders `minutesShort`, so the tick is self-describing.
- `localization_test.dart` asserts the new strings and keeps its 320×568 no-overflow checks in both
  locales. Acceptance for roadmap 3.1 is Karim's sign-off on the re-rendered screens, not this suite.
