### iOS child agent — a push token the server cleared is sent again, and the wake answers in time (#383, roadmap 5.8)
- The iOS side of #383 (server and Android in #384). `CommandClient.poll` now returns `CommandPoll`: the commands
  and `serverHasPushToken`, which is false only on an explicit `X-Push-Token: none`.
- On `none`, `CommandDrainer` calls `PushTokenRegistrar.resendAfterServerCleared()`. It sends the token uploaded
  for this pairing again, past the "already uploaded" check. Without this, a token the server cleared as dead
  stayed cleared, and the iPhone could never be woken again.
  - Nothing is sent when nothing was uploaded for this pairing (`nothingToResend`).
  - An older server that sends no header changes nothing.
- The wake path answers within `CommandDrainer.wakeDeadlineSeconds` (25 s), under the roughly 30 s iOS gives a
  woken app. Past the deadline the drain is cancelled and the wake answers `.failed`; the next wake or launch
  drains again. This was Claude's note 2 on #382.
- Tests:
  - `DeviceCommandsTests`: `none` sends the stored token exactly once; `on-file` and no header send nothing;
    nothing to resend after a re-pair; the deadline holds even for work that ignores cancellation.
  - Live case 8 now also checks `on-file` after case 7 stored a token.
