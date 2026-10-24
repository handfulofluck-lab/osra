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
 * - an address of a **current parent of that family** is confirmed as it is: it is that account's own
 *   address, and the account is the one configuring the digest (sign-up does not check the mailbox, so
 *   this is trust in the account, not proof of the address);
 * - **any other address** gets a single-use link valid 24 hours and receives nothing until it is used;
 * - the list is bounded by `MAX_DIGEST_RECIPIENTS`, and the live links a family can have open at once by
 *   `MAX_PENDING_CONFIRMATIONS`.
 *
 * The ledger is `DigestRecipient` (one row per family and address, `confirmedAt` the proof). Requested
 * addresses stay in `DigestPrefs.emails`, which is the order the family chose; a requested address with
 * no proof is excluded at send time rather than refused at write time, because the proof arrives later
 * and out of band.
 */

export const MAX_DIGEST_RECIPIENTS = 5;
export const DIGEST_CONFIRM_TTL_MS = 24 * 60 * 60 * 1000;
/**
 * How many confirmation mails one family may have outstanding at once (review of #354). The recipient
 * list is bounded at 5, but a family could otherwise add and remove addresses in a loop and mail a new
 * stranger every time; the live links are the mail, so they are what is capped.
 */
export const MAX_PENDING_CONFIRMATIONS = 10;

export type RecipientStatus = "confirmed" | "pending" | "unsent";
export interface DigestRecipientStatus {
  email: string;
  status: RecipientStatus;
  /** `pending` because the family's live-link budget is spent: this save mailed nothing for it. */
  limited?: boolean;
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
 * Reconcile the requested list with the ledger: drop the rows that are neither listed nor holding a live
 * link, keep the proofs of the addresses that are listed, and issue a fresh 24-hour link for every
 * address that still has none — up to `MAX_PENDING_CONFIRMATIONS` live links per family.
 *
 * A link is **not** reissued when a live one already exists, so opening the screen and saving again does
 * not mail an address a second time — that would be a cheaper relay than the one this prevents. And an
 * address that is removed keeps its row while its link is live, so re-adding it inside the 24 hours does
 * not buy a second mail either.
 */
export async function stageRecipients(
  familyId: string,
  emails: string[],
  parentEmails: string[],
  now = new Date(),
): Promise<{ statuses: DigestRecipientStatus[]; confirmations: IssuedConfirmation[] }> {
  const parents = new Set(parentEmails.map(normalize));
  const requested = [...new Set(emails.map(normalize).filter(Boolean))];

  // A removed address loses its proof with its place on the list: re-adding it asks again. Its row is
  // kept only while a link it already received is live — deleting that row would let the family remove
  // and re-add the address to mint another mail, which is the loop this whole change closes. A confirmed
  // row has no link, so it is still dropped.
  const noLiveLink = { OR: [{ tokenExpiresAt: null }, { tokenExpiresAt: { lte: now } }] };
  await prisma.digestRecipient.deleteMany({
    where: requested.length
      ? { familyId, email: { notIn: requested }, ...noLiveLink }
      : { familyId, ...noLiveLink },
  });

  // The live links are the mails that left the building in the last 24 hours. Count them before issuing
  // any more, so a save cannot start more than the family is allowed to have open at once.
  let budget =
    MAX_PENDING_CONFIRMATIONS -
    (((await prisma.digestRecipient.count({
      where: { familyId, tokenExpiresAt: { gt: now } },
    })) as number | undefined) ?? 0);

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
    if (liveToken) {
      statuses.push({ email, status: "pending" });
      continue;
    }
    if (budget <= 0) {
      // Nothing is mailed for this address, and nothing is stored: the next save, once a live link has
      // expired and freed the budget, mails it then.
      statuses.push({ email, status: "pending", limited: true });
      continue;
    }
    budget -= 1;
    const token = randomBytes(32).toString("hex");
    const tokenExpiresAt = new Date(now.getTime() + DIGEST_CONFIRM_TTL_MS);
    await prisma.digestRecipient.upsert({
      where: { familyId_email: { familyId, email } },
      update: { tokenHash: hashConfirmToken(token), tokenExpiresAt },
      create: { familyId, email, tokenHash: hashConfirmToken(token), tokenExpiresAt },
    });
    confirmations.push({ email, token });
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
