### Tests — the wake log is proved to say why, and never to say the token (#673, Antigravity's review)

- **No device token in any wake log line, across every outcome** (Claude `a4`, Fable `B1`): one row drives `sent`, a
  retained failure, a dead token cleared, an unsupported platform and a provider that throws, captures every
  `console.info/warn/error` line, and asserts none of them carries the token — with the positive control that each
  still names the device, or "no line" would go back to meaning two things.
- **The two lines that explain a non-send** (Fable `B2`): `skipped skip=unsupported_platform` (an iPhone token with no
  APNs provider — the one route that reports it, since every other platform falls back to FCM) and
  `failed … reason=… tokenCleared=true` when the provider reports the token dead.
- Mutants run, both red: adding `token=${device.pushToken}` to the sent line fails the first row; deleting the
  `skipped skip=unsupported_platform` line fails the second.
