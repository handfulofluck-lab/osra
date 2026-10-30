import { createHash, randomBytes } from "node:crypto";
import { prisma } from "../db.js";

/**
 * #442 PR 3: the single-use link behind the public deletion page (Play requires that an account can be
 * deleted from a web link, not only in the app). Same pattern as the digest-confirm link (#363,
 * `lib/digestRecipients.ts`): a random token mailed once, only its SHA-256 at rest, an expiry, and a
 * spend that cannot happen twice.
 *
 * The link is not the credential that deletes. The page it opens asks for the password, and the
 * authenticator code when MFA is on (`checkReauth`), exactly as `DELETE /v1/family` and `DELETE /v1/me`
 * do: email possession alone is never enough (design §2, ADR-0031).
 */

/** How long a mailed link works. */
export const ACCOUNT_DELETION_TTL_MS = 30 * 60 * 1000;

/**
 * One mail per account per minute. The request route is public and answers the same for every address,
 * so without this anyone could have the sending domain mail one account 20 times a minute per IP
 * (`AUTH_RATE_LIMIT`). A request inside the minute mails nothing and keeps the link already sent.
 */
export const ACCOUNT_DELETION_MAIL_COOLDOWN_MS = 60 * 1000;

/** 32 random bytes as hex: the only shape the routes accept, so a malformed token never reaches the DB. */
export const DELETION_TOKEN_PATTERN = /^[a-f0-9]{64}$/;

export function hashDeletionToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

export interface IssuedDeletionLink {
  email: string;
  /** The plaintext. It exists to be mailed and nowhere else: never logged, never stored. */
  token: string;
}

/**
 * Issue a link for the account that uses this (already normalised) address, or nothing. A new link
 * deletes the parent's earlier rows in the same transaction, so an older link stops working the moment
 * a newer one exists and a parent never has more than one row.
 *
 * `null` for an unknown address, and for a known one inside the mail cooldown. The caller answers before
 * this runs, so neither the result nor the time it takes is visible to whoever asked.
 */
export async function issueDeletionLink(email: string, now = new Date()): Promise<IssuedDeletionLink | null> {
  const parent = await prisma.parent.findUnique({ where: { email }, select: { id: true, email: true } });
  if (!parent) return null;
  const recent = await prisma.accountDeletionToken.findFirst({
    where: { parentId: parent.id, createdAt: { gt: new Date(now.getTime() - ACCOUNT_DELETION_MAIL_COOLDOWN_MS) } },
    select: { id: true },
  });
  if (recent) return null;
  const token = randomBytes(32).toString("hex");
  await prisma.$transaction([
    prisma.accountDeletionToken.deleteMany({ where: { parentId: parent.id } }),
    prisma.accountDeletionToken.create({
      data: {
        parentId: parent.id,
        tokenHash: hashDeletionToken(token),
        expiresAt: new Date(now.getTime() + ACCOUNT_DELETION_TTL_MS),
        createdAt: now,
      },
    }),
  ]);
  return { email: parent.email, token };
}

/** Forget a link whose mail never left, so the parent can ask again at once instead of after the cooldown. */
export async function dropDeletionLink(token: string): Promise<void> {
  await prisma.accountDeletionToken.deleteMany({ where: { tokenHash: hashDeletionToken(token) } });
}

export interface LiveDeletionLink {
  id: string;
  parentId: string;
}

/**
 * The link's row if it is live: well formed, known, unused and unexpired. Spends nothing, so opening the
 * page (or a mail scanner following the link) leaves it usable. Unknown, used and expired are one answer.
 */
export async function findLiveDeletionLink(token: string, now = new Date()): Promise<LiveDeletionLink | null> {
  if (!DELETION_TOKEN_PATTERN.test(token)) return null;
  const row = await prisma.accountDeletionToken.findUnique({ where: { tokenHash: hashDeletionToken(token) } });
  if (!row || row.usedAt || new Date(row.expiresAt).getTime() <= now.getTime()) return null;
  return { id: row.id, parentId: row.parentId };
}

/**
 * Spend the link: one conditional update, so of two submits racing on the same link exactly one sees
 * `count === 1` and goes on to delete. Called only after the password (and code) checked out, so a
 * wrong password leaves the link usable.
 */
export async function consumeDeletionLink(id: string, now = new Date()): Promise<boolean> {
  const result = await prisma.accountDeletionToken.updateMany({
    where: { id, usedAt: null, expiresAt: { gt: now } },
    data: { usedAt: now },
  });
  return result.count === 1;
}
