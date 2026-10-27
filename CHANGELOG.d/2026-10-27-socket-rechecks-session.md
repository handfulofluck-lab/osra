### Security — the live socket re-checks the session on every frame
- A websocket is authorised once, when the ticket is minted. After that it now re-reads two facts before **every**
  family frame, for every role: the parent session is still live (`jti`/`sv`), and the parent still belongs to the
  family the socket subscribed to. Failure closes the socket with `4001` and sends nothing.
- This is what makes a revocation reach a socket that is already open — `logout-all`, a password reset, an MFA change,
  and an invite move that re-homes the `Parent` row.
- The ticket carries `jti` and `sv` for it; the check is cached per socket for five seconds so the cost is bounded.
- **Behaviour tightened:** an unanswerable database now withdraws *all* frames, not only the gated types. Sending an
  ungated frame while the session is unconfirmed was the hole.
- Tests: a family-move row (no frame, `close(4001)`) and the tightened database-error row; the mutant that removes the
  check turns both red.
