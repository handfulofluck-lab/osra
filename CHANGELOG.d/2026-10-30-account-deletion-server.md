### API — a parent can delete their account, and a deleted account's tokens never work again (#442 PR 1)
- **`DELETE /v1/family` (owner):** deletes the whole family. Every child goes through the existing
  ADR-0013 erasure (`eraseChildData`, which also revokes each phone's token), then the family's own
  rows (invites, digest prefs, recipients and sends), then every parent's rows (push tokens, MFA
  recovery codes, MFA-reset requests), every `Parent`, and the `Family`. A co-parent or guardian gets
  `403 owner_role_required`.
- **`DELETE /v1/me` (co-parent or guardian):** deletes only that person: their `Parent` row, their push
  tokens, recovery codes and reset requests, and the invite that carried their address. The family and
  the children stay. The owner gets `409 owner_must_delete_family` (ownership transfer is later).
- **Both need `{ password, mfaCode? }`.** The code is required when MFA is on. A wrong value is
  `401 reauth_failed`; MFA on with no factor bound is `401 mfa_reenroll_required`, as at `/login`. Both
  routes carry the auth routes' rate limit (`AUTH_RATE_LIMIT`, 20 a minute, fails closed). There is no
  grace period: the re-authentication is the safeguard.
- **`409 consent_records_held`:** a parent who joined this family by invite after owning another still
  holds that family's consent records. Deleting them would switch off another family's monitoring, so
  both routes refuse.
- **Fixed: a deleted parent's token stayed valid.** A missing `Parent` row read as session version 0,
  so a token minted at `sv=0` worked for its whole 7 days after the row was gone. Now every parent's
  sessions are revoked before anything is deleted, the Redis version key becomes the tombstone
  `"deleted"` (no TTL), and a cold read that finds no row writes the same tombstone. The guard answers
  `401 session_revoked`, with Redis intact and after a flush.
- **Coverage guard:** `test/account-deletion.test.ts` reads `schema.prisma`, and every model with a
  `familyId`, `parentId` or `childId` must be in the child erasure list, the family list, or
  `KEPT_ON_DELETION` with a reason. Today only `RevokedToken` is kept (token id and parent id, pruned when
  the token would have expired, at most 8 days). A new table without a decision turns CI red.
- `verifyTotpFresh` moved unchanged from `routes/auth.ts` to `lib/mfaVerify.ts`, so the deletion checks the
  code exactly as sign-in does, with the same replay protection.
