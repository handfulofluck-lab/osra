### Parent app — the Arabic screens read the way the native reviewer approved (#344, issue #159)
- Karim reviewed 14 Arabic screens at 320×568 RTL and left wording notes per screen. This PR applies
  every one of them to `app_ar.arb`: `serverLabel` ("الخادم (السيرفر)"), the screen-time value read
  used-then-limit ("45 من 120 دقيقة"), `socialMonitoringTitle` (now "وسائل التواصل"), the weekend-limit
  label spelled out in full, `totalAverage` punctuated as a sentence, `safeSearchForced` (now
  "تفعيل البحث الآمن على YouTube"), the pairing copy (`scanQr`, `expiresIn`), both appearance/language
  explanations, the consent status and active-detail sentences, the retention paragraph, the search-safety
  vault notice and empty state, and the three digest labels.
- `blockedTimes` and `daysShort` are ICU plurals with the full Arabic word, so the reports and usage
  screens no longer print "حُظر 12 مرة" or "7 ي". The minute counts are ICU plurals too —
  `minutesShort`, `screenTimeValue`, `liveActivityToday`, `dailyLimit`, `weekendLimit`,
  `totalAverage`, `totalOverDays` and `dayTooltip` — so a count of 3 or 10 reads "{n} دقائق" and 11
  or 100 reads "{n} دقيقة"; screen 09 no longer prints "10 دقيقة". `screenTimeValue`'s limit is an
  `int` (0 renders the "—" of an unset limit) so the noun can follow the number that governs it.
- **Alert titles are translated by type, never by matching the server's English text.** The mapping
  covers the whole enum `InternalAlertSchema` accepts (`services/api/src/routes/alerts.ts`): the 13
  categories have a title in both ARB files, listed once in `serverAlertCategories` (`l10n.dart`) and
  mapped by `alertTitleFor(category, serverTitle, isEnglish:)`. The invented `web_filter`/`screen_time`
  cases are gone (`alertTitleBlockedSite` now serves `web_threat` and `alertTitleDailyLimit` serves
  `screen_time_exceeded`, same approved wording); the test fixture uses the server's real names. A
  category the app does not know yet shows the server's own title in English and the translated
  generic in any other locale, so English never leaks onto an Arabic screen. Clause 06 uses "تمت
  محاولة زيارة موقع محظور" because OSRA blocks at DNS, before the page loads.
- Layout, per the review's points: 02 now shows the used/limit pair in that order; 04 splits the consent
  heading and detail into a two-column label/value row; 05 breaks the retention paragraph in two; 09's
  period selectors read "7 أيام / 14 يومًا / 30 يومًا" and its chart dates use the locale's own order;
  14 puts the send hour and the zone in separate, labelled fields.
- Second review round: 14's email field is a short label ("عناوين البريد الإلكتروني") with the
  maintainer's wording as `helperText` ("لتلقي الملخّص (افصل بينها بفواصل)"), so the label is no
  longer cut off at 320 px; 12's risk chips are localized (`searchRiskCategory`, raw tag only as the
  fallback) instead of showing `substance_use`; 05 reads "سيؤدي هذا إلى إيقاف مراقبة {childName}."
  instead of a hanging "لـ"; and 09's total carries the colon 08 has ("الإجمالي: …").
- `localization_test.dart` asserts the new strings and keeps its 320×568 no-overflow checks in both
  locales. It also fails if any of the 13 server categories renders the generic title, if the Dart
  category list drifts from `InternalAlertSchema`, or if the Arabic minute plurals for 3, 10, 11 and
  100 are wrong, and it renders the alerts feed with all 13 categories in Arabic for the maintainer's
  review image. Acceptance for roadmap 3.1 is Karim's sign-off on the re-rendered screens, not this
  suite.
- Known gap, not covered here: the alert tile's *subtitle* (`l10n.dart`'s `alertCategory`,
  `alerts_screen.dart:98`, `child_detail_screen.dart:806`) still maps the same two invented keys and
  shows the raw category (`web_threat`) for the other 11. The review asked for the titles; the short
  category labels need the maintainer's wording before they can be added.
- The lone "120" on the reports screen was the fl_chart left axis drawing bare minute numbers; it now
  renders `minutesShort`, so the tick is self-describing.
