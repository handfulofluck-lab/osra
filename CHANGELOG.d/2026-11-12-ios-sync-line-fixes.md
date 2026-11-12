### OSRA Kids for iPhone — the last-synced line reads right in Arabic (Bureau row 5.7)
- **Before:** the stale line was "Not synced for 45 minutes", built with a duration formatter. In Arabic that put
  a nominative dual after the preposition at 2 hours and 2 days, which is a grammar fault. Right after a sync the
  line read "in 0 seconds", and a phone with a Saudi or Egyptian region showed Arabic-Indic digits, against R9.
- **After:** both lines use the same relative formatter ("Last synced 2 days ago. Check the internet connection,
  then tap "Sync now"."). The first minute reads "Last synced just now" (`status_last_synced_now`). Digits are
  pinned to 0-9 (`L10n.latinDigits`) for the formatter and for every `String(format:locale:)` line.
- The Arabic is the Bureau's, approved by Karim on 12 Nov at 16:09Z and copied byte for byte. The old Arabic stale
  line is withdrawn.
- Rows (`SyncStatusTests`): the first minute (0, 5 and 59 s, plus a phone clock behind the sync time), the new
  English and Arabic stale lines, Western digits on `ar_SA`, `ar_EG` and `ar_EG@numbers=arab`, and
  `latinDigits` keeping the language.
