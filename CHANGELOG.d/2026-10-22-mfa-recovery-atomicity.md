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
- **The recovery-token record is registered before anything is spent too** (`services/api/src/routes/auth.ts:520-525`),
  because the same lockout existed one step later: if `mfa:recovery:<jti>` failed after the commit, the
  code was spent and no token came back. The token is now signed only after the commit (signing does no
  I/O), and the losing branch of the claim deletes the orphaned record, so a lost race leaves nothing
  presentable behind. Raised by Claude's review of this PR, folded in here rather than deferred: it is the
  same defect class and the same move.
- **Verified:** three new tests in `services/api/test/mfa-recovery.test.ts`.
  `#199: a failed session revocation answers 5xx and leaves the recovery code unspent` makes `incrby`
  reject, asserts a 5xx with no `recoveryToken`, ten unused codes and the secret still bound, then
  retries the same code successfully; on the old ordering it failed at "batch intact" (one spent row
  remained). `#199: a failed recovery-token write leaves the code unspent` rejects only writes to
  `mfa:recovery:` (a blanket `mockRejectedValueOnce` is consumed by an earlier best-effort `set`, which
  made the mutation return 200 and the test pass for the wrong reason — the first version of it did) and
  asserts the same, with no `mfa:recovery:` key left behind; on the old ordering it failed at "batch
  intact" (one spent row remained). `#199: replaying a spent code does not revoke the parent's sessions
  again` asserts the sessions version is unchanged by a replay; without the `usedAt: null` filter it
  failed with the version at 3 where 2 was expected. `pnpm --filter @familyshield/api test` green, 457
  tests; `npx tsc --noEmit -p services/api` clean after the CI's `prisma generate` step;
  `node scripts/check-changelog-fragment.mjs` green.
- **Documented in the same change:** `docs/adr/0023-mfa-recovery.md` gains a dated amendment for the
  order, with the rejected alternative (a marker inside the transaction) and the reason it loses: Redis
  cannot join a Postgres transaction, so an early bump inside the callback is the same "revoked early"
  case with more machinery. The endpoint table's original row is left as written, per §8.
- **Not verified:** no live Redis/Postgres stack and no `qa-probe`/`e2e` run. The suite uses in-memory
  Prisma/Redis mocks, so "a failed revocation leaves the row unspent" rests on the ordering (the bump
  throws before the transaction is entered), not on a real rolled-back transaction. An ambiguous commit
  after a successful bump — the client sees an error but the commit lands — is out of scope and not
  exercised.
