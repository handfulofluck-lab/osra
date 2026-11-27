### Parent app — the Apps tab states Allow / Time limit / Block in words on every row (#1179, P-09)
- Each app row now carries the three choices as words, with the current one filled in, instead of a bare
  switch that said nothing about a time limit. Tapping Limit opens the daily-minutes sheet directly, and
  the Undo snackbar is unchanged.
- After a change is saved, that row says "Sent to phone" until the saved rules come back, so the parent
  can see the change left the app.
- At 320 px width, or with large text, the three words move under the app name instead of being clipped.
- A child on an iPhone now sees "Not yet available on iPhone" on the Apps tab, where the app list cannot
  be read from the phone yet.
