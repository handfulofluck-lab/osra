### Android reporting — site names, gated off until the notice and the store forms are live (#830)
- **Why gated:** the DNS filter sees every name any app resolves, not only the browser. Karim's decision
  (16 Nov) is that a family sees none of it until the privacy notice (#649) names the collection and
  Play's Data safety form declares web browsing history.
- **Server flag, off by default:** `SITE_NAMES_ENABLED` is unset in every environment. While it is off,
  `POST /v1/devices/:id/activity` stores no visit for any name, **blocked included** (Claude's ruling on
  Fable's finding 5): the blocked attempt reaches the parent as a hostless count through its alert, and
  no address exists in the raw log, `WebVisit`, the summary or the digest.
- **The phone does not send while it is off:** the rule projection carries `siteNames`, the agent stores
  it with the rest of its rules, and `SiteVisitGate` keeps **every** name on the phone until the flag
  arrives as true.
- **The raw log is gated too:** the same rule runs before `ActivityEvent` stores a `url` event, so with
  the flag off no `url` event is stored at all (not only in `WebVisit`), a kept event carries
  the host and never the path or query, and excluded hosts are dropped. `url` rows leave the raw log at 90
  days too, and while the flag is off both reports return no address at all. A `web_threat` alert is
  redacted server-side to `{reason prefix, day}` with a server-owned title and body and the dedupe key
  `web:<day>`, and the phone counts it on a hostless key so the parent sees the day's total.
- **Exclusions, one list:** our API host and its subdomains, the search-enforcement hosts the filter
  forces, and the Android/OS connectivity and time checks are dropped on the server; the phone drops the
  same names before they reach the batch.
- **Host only, 90 days:** the row keeps the host (never path, query or fragment), and the cleanup job
  deletes site names at 90 days even when `RETENTION_DAYS` is raised.
- **Batched:** the filter queues names and posts one request per 20 names or per minute, not one per
  lookup.
- **Turning it on** is its own reviewed step after #649 and the Play forms are live; this change does not
  flip it.
- Tests: server rows for the off state (nothing is stored, blocked included), the exclusion
  list, the 90-day window and the flag in the rule projection; an Android unit test for the phone's
  decision function. The Android rows run in CI; this PC has no Android SDK, so they were not run locally.
