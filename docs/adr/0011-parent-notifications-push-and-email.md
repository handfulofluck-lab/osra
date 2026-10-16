# ADR-0011 — Parent notifications: push (FCM/APNs) and email, with one alert path

**Status:** Accepted · 2026-10-16 · Phase 2a of the KCL plan (`docs/QA/KCL-2026-10-16/`)

## Context

The 2026-10-16 assessment ranked "no push notifications to parents" as the single most important
product gap: `FcmApnsPush.sendToFamily` was a `console.log`, it was wired to one of the five places
that create alerts, and parents learned of an SOS only while the app was open on the WebSocket.
Email had the same shape — password-reset tokens were written to the server log (audit API-07),
invites returned their accept token inline, and the digest route pointed at a cron job that did not
exist.

## Decision

1. **One alert path.** `lib/alerts.ts#raiseAlert()` creates the row, publishes the family WebSocket
   event and fans out push. Every producer (`/alerts/internal`, social scan, search/YouTube content
   routes, geofence transitions) calls it; `prisma.alert.create` is no longer called from a route.
2. **Push without SDKs.** `lib/push/fcm.ts` speaks FCM HTTP v1 with a service-account key
   (RS256 JWT-bearer → OAuth token, cached). `lib/push/apns.ts` speaks APNs over HTTP/2 with a p8
   provider token (ES256). Both report `{ok} | {invalidToken} | {transient}` and nothing else;
   `lib/push/notify.ts` owns policy: severity floor (`PUSH_MIN_SEVERITY`, SOS/tamper always),
   the family's `DigestPrefs.pushEnabled`, routing by token platform (web and iOS-via-Firebase ride
   FCM), and pruning dead tokens.
3. **Parent tokens are first-class.** `ParentPushToken` (migration 0010) keyed by token, moved to
   whichever parent last registered it (`POST/DELETE /v1/me/push-token`), cascade-deleted with the
   parent. Device `pushToken` on the child side is untouched.
4. **Email without SDKs.** `lib/email` has a `ResendEmailSender` (HTTPS API, idempotency key) and a
   `ConsoleEmailSender` that logs the envelope in dev and only a warning in production. Templates are
   bilingual EN+AR until a parent locale exists. Password reset emails the link and never logs the
   token; invites email the accept link and echo the token only when no provider is configured and
   `NODE_ENV != production`; digests are sent by `jobs/digestScheduler.ts` on a 15-minute tick with a
   Redis `SET NX` claim per (family, kind, day), or by an external cron calling `runDigestsDue()`.

## Alternatives rejected

- **firebase-admin / @parse/node-apn / nodemailer.** Each pulls a large dependency tree into a
  service that otherwise has ten runtime deps; the protocols are small and the tests can exercise the
  exact wire shape without them. Revisit if FCM topics or APNs feedback service are needed.
- **Push from the WebSocket gateway.** It only knows connected clients; the point of push is the
  disconnected parent.
- **A separate notifications worker now.** The in-process fan-out is one HTTP call per token and the
  alert row is committed before it runs; a queue earns its place when delivery needs retries or
  per-parent schedules (quiet hours), which is the next step and is tracked on the board (#50).

## Consequences

- Alert write latency includes the push fan-out (awaited so tests can observe it). With zero
  tokens or no provider the cost is two indexed reads.
- New env: `FCM_SERVICE_ACCOUNT_JSON|FILE`, `APNS_KEY_P8|KEY_ID|TEAM_ID|BUNDLE_ID|ENV`,
  `RESEND_API_KEY`, `EMAIL_FROM`, `APP_PUBLIC_URL`, `PUSH_MIN_SEVERITY`, `DIGEST_HOUR_UTC`,
  `JOBS_ENABLED`. None are required to boot; unset means the feature logs and no-ops.
- The parent app must register its FCM token after login and remove it on logout (Phase 3 lane).
- Quiet hours, per-parent category preferences and delivery receipts are not in this ADR.
