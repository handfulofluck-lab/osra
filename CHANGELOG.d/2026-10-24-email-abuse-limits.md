### API — digests go only to confirmed addresses, and outbound text is bounded (roadmap 2.7)
- A family's digest recipient list took any number of arbitrary addresses and `POST /v1/digests/send-now`
  mailed them on demand, so the sending domain could be used as a relay. `PUT /v1/digests/prefs` now
  answers **200** with each address marked `confirmed`, `pending` or `unsent`: a **current parent of that
  family** is confirmed as it is — that is the parent's own account address, **trusted as that account's
  address** (sign-up does not check the mailbox; a verification step is a separate, private follow-up) —
  and **any other address** gets a single-use confirmation link valid **24 hours** and receives nothing
  until it is used. The list is bounded at **5** addresses, and both `PUT /v1/digests/prefs` and
  `POST /v1/digests/send-now` are **owner-only** — co-parents can still read the prefs. `send-now` and the
  scheduled digest deliver to the confirmed set only.
- The confirmation ledger is a new table, `DigestRecipient` (migration `0025_digest_recipient`), one row
  per family and address. It stores the SHA-256 of the link token, never the token; confirming clears it,
  which is what makes the link single-use.
- **A person confirms, not a link scanner.** `GET /v1/digests/confirm?token=…` serves a page with one
  button and spends nothing; the button's `POST /v1/digests/confirm` spends the link. Unknown, expired and
  already-used tokens get the same 404, so the route says nothing about which addresses are on a list.
- **The confirmation mail carries no user-written text** — no family name, no child's name — because it
  goes to an address that has agreed to nothing yet.
- **Confirmation mail is capped per family**: at most **10 live links** at once (`MAX_PENDING_CONFIRMATIONS`).
  Past that, an address is `pending` with `limited: true` and no mail. An address removed from the list
  keeps its row while its link is live, so removing and re-adding it does not buy a second mail. When a
  send fails the link is cleared and the address answers `unsent`, so the next save retries it instead of
  the family waiting out a 24-hour link nobody received; the app says "Not sent. Save again to retry." in
  English and Arabic.
- Per-family limits, keyed by `familyId`: **20 invites a day** (429 `invite_limit_reached` after that) and
  **one `send-now` an hour** (429 `digest_send_limit_reached`), the latter on top of the existing
  once-a-day provider idempotency key. The invite count and create are two statements, so a parallel burst
  can pass 20 by the size of the burst; that is acceptable for a daily abuse limit. The `send-now` throttle
  fails **open** when Redis is unreachable: the provider's daily key still holds, and a digest that
  silently stops is the worse failure.
- Outbound text is bounded at **80 characters** on write — `familyName` at register, child `displayName` on
  create and update, parent `displayName` at register — and the email templates clip every stored name to
  80 as well, so a row written before the bound cannot stretch a subject or a body.
- **No family-rename endpoint was added** (agreed on review): the name is bounded where the family is
  created, and whoever adds a rename later bounds it there too.
- The parent app's digest screen marks a pending address with **"Confirmation sent"** in English and
  Arabic, so an address that will receive nothing no longer looks like one that will.
- **The confirmation button works in a browser** (#354 re-review). The page's `<form>` posts as
  `application/x-www-form-urlencoded` and Fastify had no parser for it, so every press answered **415**
  before the handler ran — no address could ever be confirmed, and `app.inject` with no content type could
  not see it. The type is now parsed inside this plugin only, the browser gets a page instead of raw JSON
  (confirmed, and expired/used), and both pages carry `cache-control: no-store` so a cache never keeps one
  holding a live token.
- **A `limited` address says nothing was sent.** When the family is at the confirmation cap the API sends
  no mail, and the app now reads `limited` and says so rather than repeating "Confirmation sent".
- Verified locally: `pnpm --filter @familyshield/api test` **573 passed**, `tsc --noEmit` clean,
  `flutter analyze` clean, `flutter test` **394 passed**. `qa-probe.mjs` and `e2e.mjs` were **not run** —
  another process holds the shared stack on this host — so the adversarial and happy-path gates on a live
  API are still owed for this change.
