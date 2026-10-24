import { createHash, randomBytes } from "node:crypto";
import { prisma } from "../db.js";

/**
 * Roadmap 2.7 (osra-security#2): who may receive a family's digest.
 *
 * A digest is delivered to a family's recipient list, and that list used to be free text: any number of
 * arbitrary addresses, mailed on demand. The recipient is therefore asked to prove the address wants the
 * digest before anything is sent to it, so the sending domain is not a relay.
 *
 * The rule, and nothing beyond it:
 * - an address of a **current parent of that family** is confirmed as it is — registration verified it;
 * - **any other address** gets a single-use link valid 24 hours and receives nothing until it is used;
 * - the list is bounded by `MAX_DIGEST_RECIPIENTS`.
 *
 * The ledger is `DigestRecipient` (one row per family and address, `confirmedAt` the proof). Requested
 * addresses stay in `DigestPrefs.emails`, which is the order the family chose; a requested address with
 * no proof is excluded at send time rather than refused at write time, because the proof arrives later
 * and out of band.
 */

export const MAX_DIGEST_RECIPIENTS = 5;
export const DIGEST_CONFIRM_TTL_MS = 24 * 60 * 60 * 1000;

export type RecipientStatus = "confirmed" | "pending";
export interface DigestRecipientStatus {
  email: string;
  status: RecipientStatus;
}

/** A freshly issued link. Only the hash is stored; this plaintext exists to be mailed and nowhere else. */
export interface IssuedConfirmation {
  email: string;
  token: string;
}

const normalize = (email: string) => email.trim().toLowerCase();

/** The ledger stores a hash, like the invite and MFA-reset tokens: a database read cannot replay a link. */
export function hashConfirmToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

/** Emails of the family's current parents. A parent who left the family stops counting. */
export async function parentEmailsOf(familyId: string): Promise<string[]> {
  const rows = (await prisma.parent.findMany({ where: { familyId }, select: { email: true } })) ?? [];
  return rows.map((row) => normalize(row.email)).filter(Boolean);
}

/**
 * The requested addresses that may actually receive a digest right now: the family's current parents,
 * plus the addresses that confirmed. Order follows the family's list, duplicates collapse.
 */
export async function confirmedRecipients(
  familyId: string,
  requested: string[],
  parentEmails: string[],
): Promise<string[]> {
  const parents = new Set(parentEmails.map(normalize));
  const emails = [...new Set(requested.map(normalize).filter(Boolean))];
  const others = emails.filter((email) => !parents.has(email));
  const rows = others.length
    ? ((await prisma.digestRecipient.findMany({ where: { familyId, email: { in: others } } })) ?? [])
    : [];
  const confirmed = new Set(rows.filter((row) => row.confirmedAt).map((row) => normalize(row.email)));
  return emails.filter((email) => parents.has(email) || confirmed.has(email));
}

/** Read-only status of each requested address, for the prefs screen: `confirmed` or `pending`. */
export async function recipientStatuses(
  familyId: string,
  emails: string[],
  parentEmails?: string[],
): Promise<DigestRecipientStatus[]> {
  const parents = new Set((parentEmails ?? (await parentEmailsOf(familyId))).map(normalize));
  const normalized = [...new Set(emails.map(normalize).filter(Boolean))];
  const others = normalized.filter((email) => !parents.has(email));
  const rows = others.length
    ? ((await prisma.digestRecipient.findMany({ where: { familyId, email: { in: others } } })) ?? [])
    : [];
  const confirmed = new Set(rows.filter((row) => row.confirmedAt).map((row) => normalize(row.email)));
  return normalized.map((email) => ({
    email,
    status: parents.has(email) || confirmed.has(email) ? "confirmed" : "pending",
  }));
}

/**
 * Reconcile the requested list with the ledger: drop the rows for addresses no longer listed, keep the
 * proofs of the ones that are, and issue a fresh 24-hour link for every address that still has none.
 *
 * A link is **not** reissued when a live one already exists, so opening the screen and saving again does
 * not mail an address a second time — that would be a cheaper relay than the one this prevents.
 */
export async function stageRecipients(
  familyId: string,
  emails: string[],
  parentEmails: string[],
  now = new Date(),
): Promise<{ statuses: DigestRecipientStatus[]; confirmations: IssuedConfirmation[] }> {
  const parents = new Set(parentEmails.map(normalize));
  const requested = [...new Set(emails.map(normalize).filter(Boolean))];

  // A removed address loses its proof with its place on the list: re-adding it asks again.
  if (requested.length) {
    await prisma.digestRecipient.deleteMany({ where: { familyId, email: { notIn: requested } } });
  } else {
    await prisma.digestRecipient.deleteMany({ where: { familyId } });
  }

  const others = requested.filter((email) => !parents.has(email));
  const existing = others.length
    ? ((await prisma.digestRecipient.findMany({ where: { familyId, email: { in: others } } })) ?? [])
    : [];
  const rows = new Map(existing.map((row) => [normalize(row.email), row]));

  const confirmations: IssuedConfirmation[] = [];
  const statuses: DigestRecipientStatus[] = [];
  for (const email of requested) {
    if (parents.has(email)) {
      statuses.push({ email, status: "confirmed" });
      continue;
    }
    const row = rows.get(email);
    if (row?.confirmedAt) {
      statuses.push({ email, status: "confirmed" });
      continue;
    }
    const liveToken =
      row?.tokenHash && row.tokenExpiresAt && new Date(row.tokenExpiresAt).getTime() > now.getTime();
    if (!liveToken) {
      const token = randomBytes(32).toString("hex");
      const tokenExpiresAt = new Date(now.getTime() + DIGEST_CONFIRM_TTL_MS);
      await prisma.digestRecipient.upsert({
        where: { familyId_email: { familyId, email } },
        update: { tokenHash: hashConfirmToken(token), tokenExpiresAt },
        create: { familyId, email, tokenHash: hashConfirmToken(token), tokenExpiresAt },
      });
      confirmations.push({ email, token });
    }
    statuses.push({ email, status: "pending" });
  }
  return { statuses, confirmations };
}

/**
 * Spend a confirmation link. Returns the address it was issued for, or null when the token is unknown,
 * expired or already used — the three cases are one answer on purpose: a caller has no business telling
 * them apart, and a used link that answered "already used" would confirm which addresses are on a list.
 */
export async function confirmRecipient(
  token: string,
  now = new Date(),
): Promise<{ email: string } | null> {
  const tokenHash = hashConfirmToken(token);
  const row = await prisma.digestRecipient.findUnique({ where: { tokenHash } });
  if (!row || row.confirmedAt || !row.tokenExpiresAt || new Date(row.tokenExpiresAt).getTime() <= now.getTime()) {
    return null;
  }
  await prisma.digestRecipient.update({
    where: { id: row.id },
    data: { confirmedAt: now, tokenHash: null, tokenExpiresAt: null },
  });
  return { email: row.email };
}
