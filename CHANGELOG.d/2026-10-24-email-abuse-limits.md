### API — digests go only to confirmed addresses, and outbound text is bounded (roadmap 2.7)
- A family's digest recipient list took any number of arbitrary addresses and `POST /v1/digests/send-now`
  mailed them on demand, so the sending domain could be used as a relay. `PUT /v1/digests/prefs` now
  answers **200** with each address marked `confirmed` or `pending`: a **current parent of that family**
  is confirmed as it is (registration verified the address), and **any other address** gets a single-use
  confirmation link valid **24 hours** and receives nothing until it is used. The list is bounded at
  **5** addresses, and both `PUT /v1/digests/prefs` and `POST /v1/digests/send-now` are **owner-only** —
  co-parents can still read the prefs. `send-now` and the scheduled digest deliver to the confirmed set
  only.
- The confirmation ledger is a new table, `DigestRecipient` (migration `0024_digest_recipient`), one row
  per family and address. It stores the SHA-256 of the link token, never the token; confirming clears it,
  which is what makes the link single-use. `GET /v1/digests/confirm?token=…` spends it.
- Per-family limits, keyed by `familyId`: **20 invites a day** (429 `invite_limit_reached` after that) and
  **one `send-now` an hour** (429 `digest_send_limit_reached`), the latter on top of the existing
  once-a-day provider idempotency key.
- Outbound text is bounded at **80 characters** on write — `familyName` at register, child `displayName` on
  create and update, parent `displayName` at register — and the email templates clip every stored name to
  80 as well, so a row written before the bound cannot stretch a subject or a body.
- The parent app's digest screen marks a pending address with **"Confirmation sent"** in English and
  Arabic, so an address that will receive nothing no longer looks like one that will.
- Verified locally: `pnpm --filter @familyshield/api test` **545 passed**, `tsc --noEmit` clean,
  `flutter analyze` clean, `flutter test` **376 passed**. `qa-probe.mjs` and `e2e.mjs` were **not run** —
  another process holds the shared stack on this host — so the adversarial and happy-path gates on a live
  API are still owed for this change.
