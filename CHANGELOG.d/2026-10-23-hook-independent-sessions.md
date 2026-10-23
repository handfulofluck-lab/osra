### API — a logged-out parent session is refused by the route itself, not only by the global hook (plan 2.7 F5)
- Four routes relied only on the global `server.ts` hook to refuse a revoked parent session:
  - `requireAuth` checked only a revoked `jti` (`GET /v1/blocklists`, `GET /v1/insights/apps`,
    `POST /v1/family/invites/:id/accept`);
  - `POST /v1/ws-ticket` never checked the session version.
- Probe Q2 with the hook's session branch removed measured `200` on all four, including a ticket to the
  family's live socket. This is defence in depth, not an exploit: the hook runs on every route today.
- Both guards now call `isParentSessionLive` and answer `401 session_revoked`. Device tokens are unchanged.
- Unit pins on `/v1/blocklists` and `/v1/ws-ticket` with a stale session-version token. Deleting either new
  check makes its test fail ("expected 200 to be 401").
