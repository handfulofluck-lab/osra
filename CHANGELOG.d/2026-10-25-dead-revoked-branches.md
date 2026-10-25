### API — five revocation checks that could never fire are gone, and the type stops promising them (#381, #351)
- `auth.device.revokedAt` was tested in five routes (`alerts.ts`, `content.ts` ×2, `location.ts`,
  `social.ts`), but `Device` has no `revokedAt` column and `authenticateInternalRequest` returns the
  Prisma row — so the branch was always `undefined` and the 401 it would have sent could never happen.
- The reason five call sites believed it existed was the type: `InternalAuthResult.device` declared
  `revokedAt?: Date | null`, which nothing ever set. That field is removed, so a future reader cannot
  be misled the same way.
- **No behaviour change.** Revocation is enforced on both paths, and each is now tested: the global
  `sessionGuard` answers `401 device_revoked` for JWTs (#349), and an unpaired phone's HMAC signature is
  refused as `device_has_no_secret` because its row is gone. That second case had no test until this PR:
  `internal-signing.test.ts:138` covers a row that **exists** with no secret, not a **deleted** row. The
  new case is `internal-signing.test.ts` "#351: an unpaired phone (its Device row is gone) is refused even
  when it signs with the secret it still holds", and it fails on the regression that lets an unpaired
  phone through (`internalAuth.ts` returning `valid: true` when `findUnique` answers null).
- Gates: `tsc --noEmit` clean, API `595 passed (46 files)`; the new test is red under that regression.
