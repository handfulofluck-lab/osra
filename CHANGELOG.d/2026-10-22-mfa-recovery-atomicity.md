### API — an MFA recovery code is no longer spent when session revocation fails (#199, #183 finding 2)

`POST /v1/auth/mfa/recover` claimed the recovery code, deleted its siblings and cleared `mfaSecret` in a
transaction that committed, and only then called `revokeAllRefreshTokens`. That revocation bumps the
sessions version and is deliberately not best-effort (`services/api/src/lib/sessions.ts:112-116`), so a
Redis failure answered 5xx **after** the commit: the code was gone, the factor was cleared, and no
`recoveryToken` came back — the parent was locked out with nothing to show for it.

- **The revocation now runs before the code is consumed** (`services/api/src/routes/auth.ts:520`).
  If `revokeAllRefreshTokens` fails, it throws before the recovery transaction starts, so the code and
  the whole batch are untouched and the parent can retry the same code. If it succeeds and the
  transaction then fails or rolls back, every session is revoked and the code is still usable — the safe
  direction.
- **The candidate lookup now requires `usedAt: null`** (`services/api/src/routes/auth.ts:508`). Moving
  revocation ahead of the transaction would otherwise let a replay of an already-spent code — whose row
  still matches its hash — revoke every session before the claim answered 401; the filter keeps that
  path at 401 with no side effect.
- **The happy path is unchanged:** one transaction claims the code, deletes its siblings and clears
  `mfaSecret`; exactly one `recoveryToken` is minted and its Redis marker written after the commit; the
  sessions version is bumped once.
- **Verified:** two new tests in `services/api/test/mfa-recovery.test.ts`.
  `#199: a failed session revocation answers 5xx and leaves the recovery code unspent` makes `incrby`
  reject, asserts a 5xx with no `recoveryToken`, ten unused codes and the secret still bound, then
  retries the same code successfully; on the old ordering it failed at "batch intact" (one spent row
  remained). `#199: replaying a spent code does not revoke the parent's sessions again` asserts the
  sessions version is unchanged by a replay; without the `usedAt: null` filter it failed with the
  version at 3 where 2 was expected. `pnpm --filter @familyshield/api test` green, 456 tests;
  `npx tsc --noEmit -p services/api` clean after the CI's `prisma generate` step;
  `node scripts/check-changelog-fragment.mjs` green.
- **Not verified:** no live Redis/Postgres stack and no `qa-probe`/`e2e` run. The suite uses in-memory
  Prisma/Redis mocks, so "a failed revocation leaves the row unspent" rests on the ordering (the bump
  throws before the transaction is entered), not on a real rolled-back transaction. An ambiguous commit
  after a successful bump — the client sees an error but the commit lands — is out of scope and not
  exercised.
