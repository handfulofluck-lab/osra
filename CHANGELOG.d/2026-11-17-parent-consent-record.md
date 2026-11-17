### API — sign-up records the adult's acceptance in the same transaction as the account (#846 part A, step 2)
- New append-only `ParentConsentEvent` table (migration `0035`, additive only): parent id (cascade), purpose,
  action, `text_version`, `document_version`, `locale`, `text_hash`, `surface`, `client_version`, and the
  server's `created_at`. **No IP address and no device id** — the row is the proof of what wording was shown
  and agreed to, not a record of where the parent was. No update or delete path exists; the FK cascades when
  the account is deleted, and that is the documented end of the record.
- `POST /v1/auth/register` now **requires** `consents: { termsPrivacy, textVersion, locale }`. It refuses an
  unticked box with `400 terms_not_accepted`, a version the server no longer serves with
  `400 consent_text_outdated`, and either parked purpose (training, marketing) sent as `true` with
  `400 consent_purpose_not_offered` — nobody was shown that text, so a stored row would be a false proof.
- The hash and the document version come from the copy table `GET /v1/consent-copy` serves, never from the
  request; `currentConsents(parentId)` is the only reader of the table (ADR-0043 D2).
- **Old builds are refused at sign-up.** A client that sends no `consents` gets a 400. That is intended —
  no account may exist without its acceptance row — so the iPhone and Flip4 test builds have to be rebuilt
  from `main` before anyone new signs up on them.
- Verified locally: full API suite **1142 passed / 5 skipped**; three mutants measured (row dropped → 3 rows
  red; box check removed → 1 red; row written outside the transaction → 2 red).
