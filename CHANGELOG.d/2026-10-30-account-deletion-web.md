### API — an account can be deleted from a web link, as Google Play requires (#442 PR 3)
- **`GET /v1/account/delete`** is the page the Play listing names. It gives the in-app steps, says what
  is deleted and what is kept, and asks for the account's email, in English and Arabic (right-to-left).
- **`POST /v1/account/deletion-request {email}`** (JSON or the page's form) always answers `202` with the
  same body for a well-formed address, and answers before the address is looked up, so it cannot be used
  to learn whether an account exists. A known address gets a link that works once, for 30 minutes: 32
  random bytes, only the SHA-256 stored (new table `AccountDeletionToken`, migration `0027`). A new request
  invalidates the older link, and a request within a minute of the last mail sends nothing, so the page
  cannot be used to flood someone's inbox.
- **The link's page asks for the password, and the authenticator code when MFA is on**, and then runs the
  same erase as the app (#464): the owner deletes the whole family, anyone else only their own account. A
  wrong password shows the form again and the link stays usable; the link is spent by one conditional
  update, so two submits cannot both delete. An expired, used or unknown link shows an "expired" page.
- Both POSTs carry the auth routes' rate limit (`AUTH_RATE_LIMIT`, 20 a minute, fails closed). The pages
  are `Cache-Control: no-store`, `Referrer-Policy: no-referrer`, never framed, and run no script.
- **The request log no longer carries link credentials.** Fastify logged each URL with its query string,
  so a mailed `?token=` (this link, and the digest-confirm link) or a realtime `?ticket=` reached the log.
  `lib/logRedaction.ts` now replaces those values with `[redacted]`.
- Verified here with the API suite (`test/account-deletion-web.test.ts`, mocked database) and planted
  faults. Not yet run against a live stack, and the Arabic copy has not been reviewed by Karim.
