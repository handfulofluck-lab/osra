import argon2 from "argon2";
import { z } from "zod";
import { prisma } from "../db.js";
import { getRedis } from "../redis.js";
import { publishFamilyEvent } from "../realtime/gateway.js";
import { DEVICE_TOKEN_TTL_SECONDS } from "./deviceToken.js";
import { verifyTotpFresh } from "./mfaVerify.js";
import { invalidateSessionsBefore, tombstoneParentSessions } from "./sessions.js";
import { eraseChildData } from "./usageModel.js";

/**
 * Account deletion (#442 PR 1, the design in comment 6495864112): what Google Play requires of an app
 * that creates accounts. Two operations, chosen by the caller's role:
 *
 *  - the **owner** deletes the whole family (`DELETE /v1/family`): every child through the ADR-0013
 *    cascade, then the family-scoped rows, then every parent's rows, every `Parent`, the `Family`;
 *  - anyone else deletes **only themselves** (`DELETE /v1/me`): their `Parent` row and the rows that
 *    are theirs alone. The family and the children stay.
 *
 * There is no grace period. Re-authentication is the safeguard, and an "undo" would mean keeping a
 * child's data we told the parent we had deleted.
 *
 * Every table with a `familyId`, `parentId` or `childId` column must be named in
 * `CHILD_SCOPED_DELETE_ORDER` (usageModel.ts), in one of the lists below, or in [KEPT_ON_DELETION] with
 * its reason. `test/account-deletion.test.ts` reads `schema.prisma` and fails when a table is in none,
 * so a new table cannot escape the deletion by being forgotten.
 */

/** What both deletions take: the password, and the authenticator code when MFA is on. */
export const ReauthSchema = z.object({
  password: z.string().min(1).max(256),
  mfaCode: z.string().regex(/^\d{6}$/).optional(),
});

type ParentForReauth = { id: string; passwordHash: string; mfaEnabled: boolean; mfaSecret: string | null };

/**
 * Check the proof a deletion needs. Email possession alone is never enough (ADR-0031 made MFA hard to
 * bypass, and deletion must not become the easy way around it). Returns the refusal, or null.
 *
 * `mfa_reenroll_required` mirrors `/login` (#183): MFA is the account's policy but no factor is bound,
 * so there is nothing to ask a code from, and the password alone must not be enough here either.
 */
export async function checkReauth(parent: ParentForReauth, body: z.infer<typeof ReauthSchema>): Promise<"reauth_failed" | "mfa_reenroll_required" | null> {
  const passwordOk = await argon2.verify(parent.passwordHash, body.password).catch(() => false);
  if (!passwordOk) return "reauth_failed";
  if (!parent.mfaEnabled) return null;
  if (!parent.mfaSecret) return "mfa_reenroll_required";
  if (!body.mfaCode || !(await verifyTotpFresh(parent.id, parent.mfaSecret, body.mfaCode))) return "reauth_failed";
  return null;
}

type FamilyScope = { familyId: string; parentIds: string[] };
type DeleteMany = (args: { where: unknown }) => Promise<{ count: number }>;

/**
 * The family's own rows and every parent's rows, deleted in one transaction **after** the children.
 * The order respects the foreign keys: the parent-scoped rows before `parent`. `family` itself is
 * deleted last, outside this list, because it is `delete`, not `deleteMany`.
 *
 * `consentRecord` is not here: the child cascade removes every consent of this family's children, and
 * the routes refuse first when a parent holds one for a child elsewhere ([consentHeldElsewhere]).
 */
export const FAMILY_SCOPED_DELETES: Record<string, (s: FamilyScope) => unknown> = {
  familyInvite: (s) => ({ familyId: s.familyId }),
  digestRecipient: (s) => ({ familyId: s.familyId }),
  digestSend: (s) => ({ familyId: s.familyId }),
  digestPrefs: (s) => ({ familyId: s.familyId }),
  mfaResetRequest: (s) => ({ parentId: { in: s.parentIds } }),
  parentPushToken: (s) => ({ parentId: { in: s.parentIds } }),
  parentMfaRecoveryCode: (s) => ({ parentId: { in: s.parentIds } }),
  parent: (s) => ({ familyId: s.familyId }),
};

type ParentScope = { parentId: string; familyId: string; email: string };

/**
 * What `DELETE /v1/me` removes for one non-owner: the rows that are theirs alone, and the invite that
 * carried their address into the family (it is the only other row holding their email).
 */
export const PARENT_SCOPED_DELETES: Record<string, (s: ParentScope) => unknown> = {
  mfaResetRequest: (s) => ({ parentId: s.parentId }),
  parentPushToken: (s) => ({ parentId: s.parentId }),
  parentMfaRecoveryCode: (s) => ({ parentId: s.parentId }),
  familyInvite: (s) => ({ familyId: s.familyId, email: s.email }),
  parent: (s) => ({ id: s.parentId }),
};

/** Tables a deletion deliberately leaves, each with the reason the listing and privacy policy state. */
export const KEPT_ON_DELETION: Record<string, string> = {
  revokedToken:
    "the record that a logged-out token is dead; holds only the token id and the parent id, and the nightly prune deletes it when the token would have expired (at most 8 days)",
};

/**
 * How many consent records these parents hold for children **outside** this family. A parent who was an
 * owner, then joined another family by invite, still holds the first family's consents, and
 * `ConsentRecord` has a foreign key to the parent. Deleting the account would have to delete them,
 * which would switch off monitoring of children in a family this person no longer manages, so both
 * routes answer `409 consent_records_held` instead.
 */
export async function consentHeldElsewhere(parentIds: string[], familyId: string): Promise<number> {
  return prisma.consentRecord.count({ where: { parentId: { in: parentIds }, child: { familyId: { not: familyId } } } });
}

/**
 * Tables with a `parentId` that `DELETE /v1/me` leaves, because the row belongs to the family, not to
 * the person leaving it. The id left behind no longer resolves to anyone.
 */
export const KEPT_ON_PARENT_DELETION: Record<string, string> = {
  revokedToken: KEPT_ON_DELETION.revokedToken,
  pairingDecision: "the child's record of who allowed or refused a phone; it is child data and goes with the child",
  consentRecord: "the child's consent record; a non-owner holds none in their own family, and one held elsewhere refuses the deletion (consentHeldElsewhere)",
};

const deleteManyOf = (model: string): DeleteMany =>
  (prisma as unknown as Record<string, { deleteMany: DeleteMany }>)[model].deleteMany.bind(
    (prisma as unknown as Record<string, unknown>)[model],
  );

export interface FamilyDeletionResult {
  deleted: "family";
  familyId: string;
  children: number;
  parents: number;
  rows: Record<string, number>;
}

export interface ParentDeletionResult {
  deleted: "parent";
  parentId: string;
  rows: Record<string, number>;
}

/**
 * Delete the whole family: the owner's operation.
 *
 * 1. Every parent's sessions are revoked first (`invalidateSessionsBefore`, the logout-all bump). It is
 *    not best-effort: if it fails, nothing has been deleted yet and the request answers 5xx.
 * 2. Every child goes through `eraseChildData`, the same cascade as `DELETE /v1/family/children/:id`,
 *    which also revokes each device's token (#56). The child's phone then gets `401 device_revoked`.
 * 3. The family-scoped and parent-scoped rows, every `Parent`, and the `Family`, in one transaction.
 * 4. The Redis state: the session tombstone for each parent (so a token minted before step 1 can never
 *    come back, even after a Redis flush), then the refresh records and per-parent keys, best effort.
 *
 * A failure after step 2 leaves a family with some children erased and its parents logged out. The
 * owner can sign in again (their row still exists) and repeat the deletion, which finishes the job:
 * every step is idempotent.
 */
export async function eraseFamilyData(familyId: string): Promise<FamilyDeletionResult> {
  const parents = await prisma.parent.findMany({ where: { familyId }, select: { id: true } });
  const parentIds = parents.map((p) => p.id);
  for (const id of parentIds) await invalidateSessionsBefore(id);

  const children = await prisma.child.findMany({ where: { familyId }, select: { id: true } });
  const rows: Record<string, number> = {};
  for (const child of children) {
    const erased = await eraseChildData(child.id, DEVICE_TOKEN_TTL_SECONDS);
    for (const [name, count] of Object.entries(erased.rows)) rows[name] = (rows[name] ?? 0) + count;
  }

  const scope = { familyId, parentIds };
  const names = Object.keys(FAMILY_SCOPED_DELETES);
  const results = await prisma.$transaction([
    ...names.map((name) => deleteManyOf(name)({ where: FAMILY_SCOPED_DELETES[name](scope) })),
    prisma.family.delete({ where: { id: familyId } }),
  ] as never[]);
  names.forEach((name, i) => {
    const r = results[i] as { count?: number } | undefined;
    rows[name] = (rows[name] ?? 0) + (typeof r?.count === "number" ? r.count : 0);
  });
  rows.family = 1;

  for (const id of parentIds) await tombstoneParentSessions(id);
  for (const id of parentIds) await forgetParentKeys(id);
  // The parents' open sockets close now rather than at the gateway's next per-frame check.
  for (const id of parentIds) {
    await publishFamilyEvent(familyId, { type: "session_revoked", payload: { parentId: id } }).catch(() => {});
  }
  return { deleted: "family", familyId, children: children.length, parents: parentIds.length, rows };
}

/**
 * Delete one non-owner parent: `DELETE /v1/me`. The family, its children and every other parent stay.
 * Same order as the family deletion: revoke, delete the rows in one transaction, then tombstone.
 */
export async function eraseParentAccount(parent: { id: string; familyId: string; email: string }): Promise<ParentDeletionResult> {
  await invalidateSessionsBefore(parent.id);
  const scope = { parentId: parent.id, familyId: parent.familyId, email: parent.email };
  const names = Object.keys(PARENT_SCOPED_DELETES);
  const results = await prisma.$transaction(
    names.map((name) => deleteManyOf(name)({ where: PARENT_SCOPED_DELETES[name](scope) })) as never[],
  );
  const rows: Record<string, number> = {};
  names.forEach((name, i) => {
    const r = results[i] as { count?: number } | undefined;
    rows[name] = typeof r?.count === "number" ? r.count : 0;
  });
  await tombstoneParentSessions(parent.id);
  await forgetParentKeys(parent.id);
  await publishFamilyEvent(parent.familyId, { type: "session_revoked", payload: { parentId: parent.id } }).catch(() => {});
  return { deleted: "parent", parentId: parent.id, rows };
}

/**
 * The Redis state a deleted parent leaves, best effort: the tombstone already refuses every token, and
 * every key here expires on its own. The refresh-store key names are `routes/auth.ts`'s
 * (`refresh:<hash>`, `refresh:jwt:<hash>`, `refresh:owner:<hash>`, indexed by `refresh:index:<id>`).
 * No `refresh:used:` marker is written: presenting a deleted parent's refresh token must answer
 * `invalid_refresh_token`, not run the theft response against an account that no longer exists.
 */
async function forgetParentKeys(parentId: string): Promise<void> {
  const redis = getRedis();
  try {
    const hashes = await redis.smembers(`refresh:index:${parentId}`);
    for (const hash of hashes) await redis.del(`refresh:${hash}`, `refresh:jwt:${hash}`, `refresh:owner:${hash}`);
    // `auth:invalid-before:<id>` stays: it is what refuses a pre-#117 token (no `sv`) until it expires.
    await redis.del(`refresh:index:${parentId}`, `mfa:lastcounter:${parentId}`, `reset:latest:${parentId}`);
  } catch {
    /* expires on its own; the tombstone is what refuses the tokens */
  }
}
