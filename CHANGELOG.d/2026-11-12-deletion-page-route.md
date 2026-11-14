### API — the web deletion page names the route the app actually has (#562 B, Play decision 9 A)
- **Before:** the page said *"open OSRA, go to Settings, then Delete account"*. The parent app has no Settings
  screen for this: the entry is the **⋮ menu on the dashboard**, then *Delete account*. A Google reviewer
  following the page would have failed to find it, which is the same class of problem as the dead link.
- **After:** both languages name the real route, with the menu glyph inline and *Delete account* in bold. The
  Arabic line is a **draft pending Karim**, as every new Arabic string is — and it says the menu is at the
  **top left**, because the Arabic UI runs right-to-left and Flutter mirrors the AppBar, so «أعلى اليمين» would
  have sent an Arabic user to the wrong corner.
- `account-deletion-web.test.ts` **W7** pinned the old wording — a check enforcing a bug. It now asserts the
  real route *and* the absence of "Settings, then Delete account", so a regression in either direction fails.
  It also pins the Arabic corner («أعلى اليسار»), which the English-only version of this check missed.
- API suite **809/809**.
