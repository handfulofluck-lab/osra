### Push — a malformed FCM request no longer counts as a dead token (#385, roadmap 5.8)
- `fcm.ts` read every `400 INVALID_ARGUMENT` from FCM v1 as "this token is dead". FCM answers that
  status for **any** malformed request — a wrong field, a data value that is not a string, a bad TTL — so
  one payload bug made every send look dead. On the child side that cleared `Device.pushToken` for every
  Android phone (each dropped to the 60 s poll, and with #384 each re-sent its token into the same
  failure); on the parent side it deleted the `ParentPushToken` rows, so alert pushes stopped until each
  app registered again.
- A `400` is now a dead token only when FCM names it: a `google.rpc.BadRequest` detail with a
  `fieldViolations[].field` of `message.token`. That is also where an APNs token sent to FCM lands (#382).
  Every other `400` keeps the token and reports the status and message faithfully.
- **The failure direction is the point.** Getting the field name wrong now means a token is *kept* and
  tried again; the rule it replaces failed the other way, where one bad payload erased the wake target of
  every family at once. The `reason` still carries the HTTP status and FCM's status, so the log shows a
  payload bug rather than a dead token.
- Tests: `message.token` → `invalidToken: true`; `message.data` → `false` with a reason naming
  `INVALID_ARGUMENT`; no `details` → `false`. Putting the old rule back turns the last two red.
- **Assumption, stated:** no live FCM 400 was captured for this change. The fixture follows Google's
  documented `BadRequest` error shape, and the failure direction above is why that is acceptable here.
