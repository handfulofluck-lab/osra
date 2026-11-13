### OSRA Kids for iPhone — a removed phone also goes back to pairing on resume (#690)
- **Before:** #697 checked for `device_revoked` on a cold launch and on a push wake. A phone the parent removed
  that stayed alive in the background kept its shields and old rules until iOS ended the app, which can take
  hours.
- **After:** coming back to the front runs the same drain and sync as an app open, so a removed phone shows
  pairing on resume. A resume within 30 seconds of the last refresh (for example the one that follows every launch)
  is skipped (`ResumeRefresh`).
- Rows (`ResumeRefreshTests`): when a resume refreshes, and a source row that fails if the resume handler stops
  calling the refresh, or the refresh stops syncing and leaving when unpaired.
