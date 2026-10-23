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
- Third review round, the category label under the title: `alertCategory` (`l10n.dart`) now maps the
  same 13 names `InternalAlertSchema` accepts, in both ARB files, with the raw key still the fallback
  for a value newer than the app. The invented `web_filter`/`screen_time`/`social_concern`/`location`/
  `device`/`safety` keys are gone, so no screen can reach the old vocabulary again. The wording is the
  reviewer's short-label table (e.g. "موقع محظور", "تطبيق محظور", "الأماكن", "تنمّر", "الحماية",
  "جهة غير معروفة"), with `sos` and `install_request` keeping the labels they had; Karim has the final
  word on it. Both places that render it — the tile subtitle (`child_detail_screen.dart:819`, shared by
  the alerts feed and the child-detail list) and the alert dialog (`alerts_screen.dart:98`) — read the
  mapping.
- The drift test now covers the label too: for every category from `InternalAlertSchema`, in both
  locales, the label *and* the title must differ from the raw key, and an unknown category still falls
  back to the key. Dropping one case (`tamper`) fails the test in both locales. The all-13 Arabic feed
  render also asserts the label under each title, so the review's screenshot cannot regress silently.
- Third review round, review render 03: the child-detail app bar clipped "تعديل القواعد" at the left
  edge at 320 px. Below 360 px the rules action is now an `IconButton` with the label as its tooltip —
  the shape the other two actions already use — and at 360, 375 and 411 px it stays the labelled
  `TextButton.icon` with the same route. A 320×568 test taps it and lands on the rules editor; the
  wider-width tests do the same with the label visible.
- The lone "120" on the reports screen was the fl_chart left axis drawing bare minute numbers; it now
  renders `minutesShort`, so the tick is self-describing.
