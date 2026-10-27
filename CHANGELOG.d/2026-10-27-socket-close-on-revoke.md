### Security — every session revocation closes the parent's sockets at once
- `revokeAllRefreshTokens` now publishes a `session_revoked` signal naming the parent after it invalidates sessions.
  That one place covers **every** revocation path: `logout-all`, MFA enable and `/mfa/verify`, `/mfa/recover`, the
  MFA-reset helper, `/mfa/reset/complete`, `/reset/confirm`, and the **refresh-token reuse response** — our actual theft
  detector.
- The gateway closes that parent's sockets with `4001` on receipt and **forwards nothing**: the frame is a control
  message carrying a parent id, not family data, so it never reaches a client.
- The publish is **best effort**: wrapped in try/catch and logged, because a Redis failure after the sessions are revoked
  must not turn a completed revocation into a `500`. If the signal is lost, the per-frame check from #414 still closes the
  socket within five seconds.
- Tests: a second parent in the same family keeps their socket, never sees the frame, and still receives the next alert;
  `logout-all` publishes exactly one signal naming the parent; the refresh-token replay publishes it too; and a rejecting
  `publish` leaves `logout-all` answering `200` with the token dead.
