### Probe — a session revocation closes the parent's open socket at once (plan 2.7, #417)
- New `Q2d`, read on Q2c's sockets before Q2c raises its alert. After `logout-all`, the co-parent's socket must be
  closed with `4001` within 2 s, before any family frame, and the `session_revoked` control signal must reach no
  socket, the owner's included.
- Measured on a local stack, fresh database:
  - on `main` before #417 it fails as expected, 196/1 (`close=null`: the socket waits for the next frame);
  - with #417 (and its review commit) it passes, 197/0, closing about 11 ms after `logout-all`;
  - with the publish in `revokeAllRefreshTokens` removed it goes red, 196/1 (`close=null`);
  - with the gateway forwarding the signal instead of handling it it goes red, 196/1 (`ownerGotSignal=true`).
    #414's per-frame check still closes the revoked socket there, so only the signal half of the row sees it.
- `docs/QA/security/authz-matrix.md`: the `GET /v1/ws` line and the probe-section closure list cite Q2d.
