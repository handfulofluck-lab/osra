### Parent app — a push wake becomes a notification, once (#360, #395)
- The pushed payload is data-only (`{ "w": "1" }`): it says an alert exists, never what it says, because an OS
  service sees the payload. So the wake reads `GET /v1/alerts?ack=false` and decides what the parent has not seen.
- `BackgroundAlertWake` holds the whole rule and takes every side effect as a seam: no `jwt` → nothing is fetched or
  shown; a `401` ends the wake and **never refreshes** (a background refresh could rotate a token under a live
  session — the next foreground launch refreshes, and the alert is still there); a failed fetch shows nothing and
  stores nothing, so the next wake retries.
- `planNotifications` (pure, 7 rows) drops acknowledged alerts, drops ids already shown, drops a duplicate inside one
  page, and shows the **newest** `max` when the backlog exceeds the cap — oldest-first, so the newest wins the shade.
  It remembers every fresh id, including the ones the cap dropped, so a backlog cannot dribble back out over later
  wakes (#395 review).
- The lock screen never carries the child's content (#360 decision 3, #395 review): the title is the app's own
  translated **category** title, chosen from the parent's stored locale, and the body is one generic sentence. The
  server's English titles and the alert body stay in the app.
- Notifications are posted with a stable id per alert, so a redelivered wake replaces the row instead of stacking,
  and with `NotificationVisibility.private` so the shade shows no content on a locked screen. The shown-id store is
  bounded at 50.
- The wake reads the **persisted** server URL (`server_url`, the same override the parent typed) before falling back
  to the `API_BASE` define; with neither set it fails without making a request.
- `main.dart` registers the FCM background handler only when Firebase can initialise, so a build with no
  `google-services.json` stays the three-shape case it was (#317) and skips this silently.
- **⚠️ not measured:** Android delivery needs a device with the app installed and a real FCM send; that is Claude's
  row. iOS delivery needs the APNs key in Firebase, which is Karim's queue — until then an iPhone `getToken()` returns
  nothing and this path is unexercised, not broken. The tests cover the decisions, not the delivery.
