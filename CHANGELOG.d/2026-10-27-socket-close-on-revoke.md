### Security — `logout-all` closes the socket at once, not within five seconds
- `POST /v1/auth/logout-all` publishes a `session_revoked` signal naming the parent after the refresh tokens are gone.
- The gateway closes that parent's sockets with `4001` on receipt and **forwards nothing**: the frame is a control
  message, not family data, so it never reaches a client.
- This removes the five-second window the per-frame session check left open, which is the theft case it was written for.
- Tests: a row that opens a socket, publishes the signal, and expects `ready` only plus `close(4001)`; the mutant that
  forwards the signal instead of closing turns it red.
- Only `logout-all` publishes it today. A password reset, an MFA change and an invite move still rely on the per-frame
  check; adding them is the same one line each and is left as follow-up rather than claimed here.
