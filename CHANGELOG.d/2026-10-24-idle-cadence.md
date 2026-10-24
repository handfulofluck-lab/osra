### Android agent + API + parent app — an idle child phone stops calling the server every 20 seconds (#353, roadmap 5.8)
- **What was measured.** With #346's counter on the Flip4, an idle child phone sent **22 to 24 requests per 10 minutes**, screen
  off on power and in forced deep Doze alike, against 5.8's budget of 3. All three calls came from `LocationService`, a foreground
  service, which Doze neither stops nor cuts off: the commands poll every 60 s, the live-activity upload every 60 s (reporting
  "idle" sixty times an hour), and a location upload every 5 minutes.
- **The server says how often to poll.** `GET /v1/devices/:id/commands` answers with `X-Poll-After`: **600 s when the server can
  wake this device** (a push provider is configured and the device has a token on file, `canWakeDevice` in
  `lib/push/notify.ts`), 60 s otherwise (`lib/pollCadence.ts`). The body is the same array, so older agents are untouched.
- **The agent honours it, within limits** (`services/IdleCadence.kt`): clamped to 30 s–15 min, and **never more than 60 s apart
  while the screen is on**, so a child using the phone still gets a lock within a minute if a push is lost. No header (an older
  server) or a failed poll means 60 s, the old behaviour. A push still polls at once (#319).
- **One poller at a time.** The 60-second WorkManager poll (`CommandPollWorker`) skips its periodic run while `LocationService`
  is running, since the service already polls on the server's cadence; a run a push woke (`requestFetchNow`, flagged `KEY_WAKE`)
  always fetches, and with the service off the worker is the poll, as before (`IdleCadence.workerShouldPoll`).
- **Live activity only while the screen is on**, plus one last snapshot when it turns off, which now reports "idle" instead of
  the last app the accessibility stream saw.
- **Stationary location is batched**: buffered fixes go up when the oldest is 10 minutes old (two 5-minute fixes per request).
  Moving, `locate_now`, a consent pause (which discards) and a batch waiting after a failed upload still flush on the next tick.
- **"Online" stays true.** The poll now refreshes the device's `lastSeen` when it is 5 minutes old (one conditional write, so
  two racing polls are one write), and the parent app's online window is **15 minutes** instead of 3 (`kDeviceOnlineWindow`,
  used by the dashboard and the child page). The silent-device alert (30 minutes) is unchanged; a test pins that the slowest
  idle report still fits inside it.
- **Tests.** API: `poll-cadence.test.ts` (header 600 only with a provider and a token, 60 without either, body unchanged,
  `lastSeen` refresh, and the agent's constants read from `IdleCadence.kt`). Agent: `IdleCadenceTest` (parsing, clamping and the
  overflow case, the screen-on cap, the live-activity edge, the flush rule), `LocationServiceCadenceWiringTest` (the loops go
  through those rules, the 428 consent path stays), `CommandPollWorkerCadenceWiringTest` (the worker asks `workerShouldPoll` before fetching and
  `requestFetchNow` sets `KEY_WAKE`), and the ack-capability test now covers the new call. App:
  `device_online_test.dart`. The request count on a real idle phone is the hardware row in the PR.
