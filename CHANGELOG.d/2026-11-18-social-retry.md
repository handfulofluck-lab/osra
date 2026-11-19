### Parent app — the activity sections offer the retry their sentence promises (polish item 1)
- The UI/UX Bureau's follow-up on #841, routed by Claude on #50: Reports and Activity said "… Check your
  connection and try again." with nothing on screen to press. Reports was already answered by #871's
  `ErrorRetryView`; the four sections of the Activity screen were not.
- Monitoring, Concerns, Calls & SMS and Trusted contacts now render `ErrorRetryView` with their own retry —
  `rulesProvider`, `socialEventsProvider`, `activityProvider`, `rulesProvider` respectively — so the sentence
  and the action are in one place and re-request the section that failed rather than the whole screen.
- No new string: `ErrorRetryView` uses the existing `retry` label and `friendlyErrorText` the existing
  sentences, so this is a control, not copy.
- Verified: a row fails `/v1/rules/:id` with a 500 on the Activity screen, asserts the view is there, taps
  Retry and asserts the request is made again. `flutter test` in `apps/parent-app` is the number on the PR.
