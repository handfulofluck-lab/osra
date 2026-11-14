### Child agent + API — a lock or a pause is polled every 10 s, and every wake push is logged (#673)
- Flip4, 12 Nov (scenario run 1 of #665, Play debug build from `main@d31fb71`): `resume_internet` round 1
  took **52.4 s** against a 5 s limit, `lock` round 2 7.8 s, and `pause_internet` round 1 arrived by the
  poll with no push at all. Round 2 of pause and resume landed in 1.9 s and 4.3 s, so a pause does not
  always stop the push. The API log held no line for any wake it had sent, so "never sent" and
  "delivered late" could not be told apart.
- API: every device wake writes one info line — `[push] device wake command=<row id> device=<id> sent
  provider=android priority=high messageId=<FCM name>` on success, `failed … reason=<error>` when the
  provider refuses, and `skipped skip=no_token|unsupported_platform` when nothing left. FCM's `name`
  (the provider's own message id) now travels back with the send result, so a push can be looked up in
  Google's log; a dead-token wake, which used to clear the token silently, is one of these lines.
- Child Android: while `lock`, `pause` or `pause_internet` is active the command poll runs every 10 s
  instead of the server interval capped at 60 s, and the loop's tick is 10 s while restricted — a 10 s
  rule read by the old 15 s tick would have been a 15 s poll. The idle budget is untouched: with no
  restriction the server's `X-Poll-After` (600 s) still governs, and an idle phone still costs ≤ 3
  requests per 10 minutes. The cost this accepts: a phone left locked or paused for an hour now sends up
  to 360 polls in it, which is the trade #673 asks for.
- FCM's connection during a pause was **already** outside the sinkhole: `TunnelBypassPolicy` excludes
  `com.google.android.gms` from the `sinkhole_all` tunnel (#458), so proposed fix 3 needed no code.
- Not verified where this was written: the numbers themselves. No handset was used, so the 10 s cadence,
  the wake log line and the push latency need a Flip4 row — lock/pause/resume with the API log beside
  the timings, which is what the hardware row in this PR runs.
