### API — five revocation checks that could never fire are gone, and the type stops promising them (#381, #351)
- `auth.device.revokedAt` was tested in five routes (`alerts.ts`, `content.ts` ×2, `location.ts`,
  `social.ts`), but `Device` has no `revokedAt` column and `authenticateInternalRequest` returns the
  Prisma row — so the branch was always `undefined` and the 401 it would have sent could never happen.
- The reason five call sites believed it existed was the type: `InternalAuthResult.device` declared
  `revokedAt?: Date | null`, which nothing ever set. That field is removed, so a future reader cannot
  be misled the same way.
- **No behaviour change.** Revocation is enforced on both paths, and each is tested elsewhere: the
  global `sessionGuard` answers `401 device_revoked` for JWTs (#349), and an unpaired device's HMAC
  signature is refused as `device_has_no_secret` because its row is gone
  (`test/internal-signing.test.ts:138`).
- Gates: `tsc --noEmit` clean, API `594 passed (46 files)`.
