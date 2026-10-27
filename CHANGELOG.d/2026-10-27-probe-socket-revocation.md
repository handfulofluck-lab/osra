### Probe — a socket opened before logout-all gets no further frame and is closed (plan 2.7, #414)
- New `Q2c` is the end-to-end row for #414 (the live socket re-checks the session on every frame). The co-parent
  opens `/v1/ws` and then runs `logout-all` with the same token. After the gateway's 5 s session cache has run out,
  an alert is raised for the family's child. The owner's socket must receive it: it's the control. The co-parent's
  socket must not, and must be closed with `4001`.
- Measured on a local stack, fresh database each run:
  - on `main` before #414 it fails as expected, 195/1 (`revokedSocketGotAlert=true close=null`);
  - on `main` with #414 it passes, 196/0, with Q6f still green;
  - with the gateway's per-frame session check skipped it goes red again, 195/1.
- `docs/QA/security/authz-matrix.md`: the `GET /v1/ws` line and the probe-section closure list cite Q2c.
