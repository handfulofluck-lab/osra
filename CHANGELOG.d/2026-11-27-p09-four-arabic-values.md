### Parent app — the four P-09 Apps lines the Arabic Bureau decided (#604)

- **`appsFilterAllowed`** — "Allowed ({count})" / «مسموح ({count})».
- **`appsLimitSheetTitle`** — "Daily limit for {app}" / «الحد اليومي لتطبيق {app}».
- **`appsNoLimit`** — "No limit" / «بلا حد».
- **`appsIphoneNoAppList`** — "The iPhone doesn't send its app list yet." / «لا يرسل هاتف آيفون قائمة التطبيقات بعد.» — the shorter English the Bureau asked for.

Arabic is the Arabic Language Bureau's text verbatim (14:09 UAE, comment 7215542085); English is the same table.

**What this PR does not do, on purpose:** wire the four keys to the screen. The surfaces the Bureau described are not on `main` — the Apps filter row is All / Blocked / Limited with no Allowed chip, the limit sheet's title is the app's own name, there is no clearing action and no iPhone app-list reason. Adding them is a UI change that UI/UX owns, not a values edit, so it waits for a scope decision on #604.
