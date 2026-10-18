# ADR-0022 — WebSocket authentication is ticket-only; the legacy `?token=` handshake is removed

- **Status:** accepted
- **Date:** 2026-10-18
- **Deciders:** Kimi Code (development lead), applying the lead's default in issue #120 after the KCL
  lead (architecture) did not rule within the hour
- **Supersedes:** ADR-0004, the clause "The legacy `?token=` path is kept for old clients"

## Context

ADR-0004 introduced single-use WebSocket tickets but kept `?token=<jwt>` "for old clients". Issue #120
audited that branch (`services/api/src/realtime/gateway.ts:56-58` on `main@743626f`) and found it was
not a compatibility path so much as a second authentication system:

- It called `app.jwt.verify()` and used the `familyId` claim. It did **not** check the role, so a
  **device JWT** subscribed to the whole family's realtime stream.
- It did not read `revoked:device:<id>`, so a **revoked device** still subscribed.
- It did not consult the parent invalid-before epoch / `jti`, so a parent token killed by
  `/logout-all`, password reset, MFA enable or the refresh-reuse theft response still subscribed.
- The global hook in `services/api/src/server.ts:68-84` could not catch any of that: it verifies the
  `Authorization` header, and a query-string token never reaches it.
- The JWT travelled in the URL, which the request logger records, contradicting `README.md:152-153`.

No shipped caller used the path. `apps/parent-app/lib/providers/family_provider.dart:138,145` mints a
ticket and connects with `?ticket=`; `services/api/scripts/e2e.mjs:154,172` and
`services/api/scripts/qa-probe.mjs:713` do the same. The legacy branch existed only because a client
older than the ones in this repository might still use it.

## Decision

1. **One way in: a single-use ticket.** `POST /v1/ws-ticket` is unchanged (parent role required, device
   revocation checked, 60-second TTL, consumed on first presentment).
2. **The query-token path is removed, not repaired.** A route-level `preValidation` on `GET /v1/ws`
   answers any request that carries a `token` parameter — or carries no ticket at all — with
   **HTTP 401 `{"error":"ticket_required"}`** (`services/api/src/realtime/gateway.ts:54-63`). The same
   hook runs before the WebSocket upgrade, so a handshake never reaches a `ready` frame.
3. **The rejection is a JSON 401, not a 404.** `@fastify/websocket` answers a non-upgrade request to a
   websocket route with 404; a stale client would read that as "wrong URL" rather than "this handshake
   is no longer accepted". Naming the reason makes the failure actionable.
4. **Ticket failures are unchanged.** A missing, expired or already-consumed ticket still closes the
   socket with 4001 and sends no frame.

## Alternatives considered

- **Keep `?token=` and add the missing checks** (role, device revocation, parent epoch). Rejected: it
  keeps a bearer token in URLs and access logs, duplicates session validation in a second place, and
  leaves two paths to keep in sync — the defect was the path's existence, not one forgotten branch.
- **Keep it behind a deprecation window with logging.** Rejected: no caller was found to migrate, so
  the window would only preserve the leak; there is no evidence anyone needs it.
- **Delete the route entirely and let clients get 404.** Rejected: the issue asks for a loud, named
  failure; 404 is indistinguishable from a routing mistake.
- **Accept a ticket *and* a token when both are present.** Rejected: it makes the refused parameter
  silently inert and hides a stale client during a mixed rollout. If a request says `token`, it is a
  client that must be fixed.

## Consequences

- Good: one authentication path, one revocation model, and no JWT in request URLs.
- Good: device tokens and revoked/expired parent sessions can no longer subscribe.
- Good: a stale client fails with a named 401 instead of silently working or looking like a bad route.
- Cost: a third-party client that still presents `?token=` breaks at deploy time with no grace period.
  This is deliberate and, per the caller search above, affects no in-repo client.
- Cost: manual debugging can no longer open the stream with a copied JWT; it must mint a ticket first
  (`POST /v1/ws-ticket`), which is one extra request.
- Cost: the probe and unit suite grow four/five assertions that pin the refusal.

## Evidence

- `services/api/test/realtime.test.ts`: parent JWT, device JWT and missing-credential handshakes are
  401 `ticket_required`; these three fail on `origin/main` (`404 !== 401`) and pass here.
- `services/api/scripts/qa-probe.mjs` L6 (revoked parent), L7 (device), L7b (revoked device), L8 (no
  ticket) and L9 (fresh ticket still yields `ready`); `check-probe-integrity.mjs --base origin/main`
  reports 5 added, 0 removed.
- Live: probe **120 passed · 0 failed**, `e2e.mjs` **69 passed / 0 failed** on a branch instance
  (`127.0.0.1:3100`) sharing Postgres/Redis with the demo stack (issue #120, PR to follow).
