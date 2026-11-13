# Read-only missing-Arabic inventory (#614)

Source: `1ed24f83ce95e6713a3d9d38b273dd1cff9910d2` · Generated: 2026-11-13T15:32:26Z

- **180 new candidates** (143 app literals and 37 website terms rows).
- **135 already-tracked website rows**, marked rather than repeated as new work.
- **2 brand-label checks** for the Bureau, not automatic translation requests.
- **317 total rows** including both categories and the brand checks.

## Resource coverage

- Flutter `app_en.arb` / `app_ar.arb`: no missing keys.
- iOS `en.lproj` / `ar.lproj` and InfoPlist files: no missing keys.
- Android `values/strings.xml`: only `app_name` (OSRA) and `sos_tile_label` (OSRA SOS) lack a same-key Arabic value; see `brand-labels.md` for the brand review.
- API email templates and account-deletion pages already contain English and Arabic blocks, so they are not listed as missing.
- The site home, guide and download pages already have Arabic counterparts and are excluded. Privacy, terms and delete-account pages are listed.

## Method and exclusions

Read-only key comparison followed by a manual surface review of hard-coded strings. SQL, logs, protocol values, decoder internals, serialization, localized wrappers and developer-only stderr are excluded. Dynamic metadata is not presented as fixed English copy. The personal name/address in the privacy and terms pages is replaced with `[name and address in source]`; the source file retains the legal text for the Bureau to read in context.

No Arabic text or source file was written or changed. No CI check was added.

## Files

- `full-sweep.md`: every row and its status.
- `new.md`: the 180 new candidates, with file:line, English, surface, suggested key and status.
- `already-tracked.md`: the 135 rows already on #604 or sheet 2.
- `brand-labels.md`: the two brand-label checks.
- `full-sweep.csv`: all rows in spreadsheet form.
- `full-sweep.json`: the structured evidence.
- `ci-candidates.md`: possible future automated checks.

| File:line | English text | Where the user sees it | Suggested key | Bureau status |
|---|---|---|---|---|
| apps/child-android/app/src/main/res/values/strings.xml:3 | OSRA | Android child app | app_name | verify brand label |
| apps/child-android/app/src/main/res/values/strings.xml:5 | OSRA SOS | Android child app | sos_tile_label | verify brand label |
