### API + Android — a push token the server cleared is sent again on the next poll (#383, roadmap 5.8)
- A wake answered "dead token" clears `Device.pushToken` (`notify.ts`, compare-and-clear), and neither
  agent could find out: `PushTokenUploadPolicy` uploads only when its own marker differs, so push to that
  phone stayed dead until Firebase happened to rotate the token — with no error anywhere. On Android it
  fell back silently to the 60 s poll; on iOS to nothing.
- The commands poll now says which it is: `X-Push-Token: on-file | none`, set beside `X-Poll-After` from
  the row it already loads. Two values rather than an absent header, so a client never has to guess from
  silence, and an older server that sends nothing is read as "marker decides" — the behaviour before this
  change.
- `PushTokenUploadPolicy.shouldUpload` takes `serverHasToken: Boolean?` (`null` = header absent). `false`
  overrides the marker and the phone re-uploads the token it still holds; a blank stored token is still
  never uploaded.
- `CommandPoller` reads the cadence call's headers before deciding (the poll was already the retry path
  for a token minted before pairing, #319), so the guard added in #353 — the poller must not call the
  header-less `getCommands` — keeps holding.
- Tests: three server cases (`on-file`, `none` for a cleared row, `none` for one that never registered),
  red with the header removed; four policy cases, red when the `serverHasToken == false` branch is
  dropped.
- Not in this PR: the iOS side (`PushTokenRegistrar` has the same rule) is Ahmed's, per #383.
