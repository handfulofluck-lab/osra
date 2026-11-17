import type { Prisma } from "@prisma/client";
import { prisma } from "../db.js";
import { CONSENT_TEXT_VERSION, consentCopyFor } from "./consentCopy.js";

/**
 * ADR-0043 D2 / #846 part A step 2: the adult's consent, recorded at sign-up.
 *
 * One rule for the whole module: **the server decides what the copy was, the client only says which version
 * it showed**. The hash and the document version are read from the copy table `GET /v1/consent-copy` serves
 * (#875), never from the request, so a client cannot mint a proof of text nobody was shown.
 */
export const TERMS_PURPOSE = "terms_privacy";
export const SIGNUP_SURFACE = "app_signup";

export interface SignupConsents {
  termsPrivacy: boolean;
  textVersion: string;
  locale: string;
  /** Parked by counsel's amendment (A2/A8): refused if `true`, because no build offers the text. */
  aiImprovement?: boolean;
  marketingEmail?: boolean;
}

export type ConsentRefusal =
  | "terms_not_accepted"
  | "consent_text_outdated"
  | "consent_purpose_not_offered";

export interface ConsentEventFields {
  textVersion: string;
  textHash: string;
  locale: string;
  documentVersion: string | null;
}

/**
 * Resolve what a sign-up claims to have accepted against the copy the server serves *now*.
 *
 * - `termsPrivacy` not exactly `true` → `terms_not_accepted`: the box is the account's legal basis.
 * - a `textVersion` that is not the one served → `consent_text_outdated`: the app refetches the copy and
 *   asks again. A retired version fails here too, which is the point of versioning the text.
 * - either parked purpose sent as `true` → `consent_purpose_not_offered`: nobody was shown that wording.
 */
export function consentEventFor(
  input: SignupConsents,
): { ok: true; fields: ConsentEventFields } | { ok: false; reason: ConsentRefusal } {
  if (input.termsPrivacy !== true) return { ok: false, reason: "terms_not_accepted" };
  if (input.aiImprovement === true || input.marketingEmail === true) {
    return { ok: false, reason: "consent_purpose_not_offered" };
  }
  const copy = consentCopyFor(input.locale);
  if (input.textVersion !== CONSENT_TEXT_VERSION || copy.textVersion !== CONSENT_TEXT_VERSION) {
    return { ok: false, reason: "consent_text_outdated" };
  }
  const purpose = copy.purposes.find((entry) => entry.key === TERMS_PURPOSE);
  if (!purpose) return { ok: false, reason: "consent_text_outdated" };
  return {
    ok: true,
    fields: {
      textVersion: copy.textVersion,
      // The hash of the text this locale was served, not of anything the request carried.
      textHash: purpose.textHash,
      locale: copy.locale,
      // The ADR allows null until the published page versions are frozen; the copy table carries it the
      // moment it exists, and this line needs no change then.
      documentVersion: (copy as { documentVersion?: string | null }).documentVersion ?? null,
    },
  };
}

/**
 * Write the sign-up row. Takes a transaction client so the account and its acceptance row commit together:
 * an account that exists without its row is exactly the state ADR-0043 forbids.
 */
export async function recordSignupConsent(
  tx: Prisma.TransactionClient,
  parentId: string,
  fields: ConsentEventFields,
  clientVersion: string | null,
): Promise<void> {
  await tx.parentConsentEvent.create({
    data: {
      parentId,
      purpose: TERMS_PURPOSE,
      action: "granted",
      textVersion: fields.textVersion,
      documentVersion: fields.documentVersion,
      locale: fields.locale,
      textHash: fields.textHash,
      surface: SIGNUP_SURFACE,
      clientVersion,
    },
  });
}

export interface CurrentConsent {
  granted: boolean;
  at: Date;
  textVersion: string;
}

/**
 * D2's **only** reader: what this parent currently holds, per purpose.
 *
 * Newest row wins, because a later act supersedes an earlier one; nothing else in the codebase may read the
 * table directly, so a second interpretation of "held" cannot drift.
 */
export async function currentConsents(parentId: string): Promise<Record<string, CurrentConsent>> {
  const rows = await prisma.parentConsentEvent.findMany({
    where: { parentId },
    orderBy: { createdAt: "desc" },
    select: { purpose: true, action: true, textVersion: true, createdAt: true },
  });
  const out: Record<string, CurrentConsent> = {};
  for (const row of rows) {
    if (out[row.purpose]) continue;
    out[row.purpose] = { granted: row.action === "granted", at: row.createdAt, textVersion: row.textVersion };
  }
  return out;
}

/** What a write asks for: one purpose, granted or withdrawn, at a version the parent was shown. */
export interface ConsentWrite {
  purpose: string;
  granted: boolean;
  textVersion: string;
  locale: string;
}

export type ConsentWriteRefusal =
  | "unknown_purpose"
  | "consent_text_outdated"
  | "terms_withdrawal_is_account_deletion"
  | "consent_purpose_not_offered";

/** The purposes this build can record. The two parked ones stay listed so a write is refused by name. */
export const OFFERED_PURPOSES = [TERMS_PURPOSE] as const;
const PARKED_PURPOSES = ["ai_improvement", "marketing_email"] as const;

/**
 * ADR-0043 D3/D5/D8: whether a write may be recorded, and with what proof.
 *
 * - an unknown purpose is a caller bug, not a choice;
 * - `terms_privacy` is required to hold an account, so withdrawing it is account deletion (ADR-0043 D3),
 *   not a write this route can make;
 * - the two parked purposes are refused while their switches are off, because no build offers them.
 */
export function consentWriteFor(
  input: ConsentWrite,
): { ok: true; fields: ConsentEventFields; action: "granted" | "withdrawn" } | { ok: false; reason: ConsentWriteRefusal } {
  if ((PARKED_PURPOSES as readonly string[]).includes(input.purpose)) {
    return { ok: false, reason: "consent_purpose_not_offered" };
  }
  if (input.purpose !== TERMS_PURPOSE) return { ok: false, reason: "unknown_purpose" };
  if (!input.granted) return { ok: false, reason: "terms_withdrawal_is_account_deletion" };
  const copy = consentCopyFor(input.locale);
  if (input.textVersion !== CONSENT_TEXT_VERSION || copy.textVersion !== CONSENT_TEXT_VERSION) {
    return { ok: false, reason: "consent_text_outdated" };
  }
  const purpose = copy.purposes.find((entry) => entry.key === TERMS_PURPOSE);
  if (!purpose) return { ok: false, reason: "consent_text_outdated" };
  return {
    ok: true,
    action: "granted",
    fields: {
      textVersion: copy.textVersion,
      textHash: purpose.textHash,
      locale: copy.locale,
      documentVersion: (copy as { documentVersion?: string | null }).documentVersion ?? null,
    },
  };
}

/** One row of the parent's own consent history (a data-subject answer, ADR-0043 D3). */
export async function consentHistory(parentId: string) {
  const rows = await prisma.parentConsentEvent.findMany({
    where: { parentId },
    orderBy: { createdAt: "desc" },
    select: { purpose: true, action: true, textVersion: true, locale: true, surface: true, createdAt: true },
  });
  return rows.map((row) => ({
    purpose: row.purpose,
    action: row.action,
    textVersion: row.textVersion,
    locale: row.locale,
    surface: row.surface,
    at: row.createdAt,
  }));
}

/**
 * Append one row for a write that comes from the app rather than sign-up.
 *
 * It writes on its own (the module `prisma`), not inside a caller's transaction: an app tick is a single
 * append, and there is no account being created beside it that would have to roll back with it. Sign-up is
 * the case that needs a transaction, and it uses [recordSignupConsent] with the caller's client.
 * Same table and same proof either way; only `surface` differs, so a reader can tell where a tick happened.
 */
export async function recordConsent(
  parentId: string,
  input: ConsentWrite,
  fields: ConsentEventFields,
  action: "granted" | "withdrawn",
  surface: string,
  clientVersion: string | null,
): Promise<{ recorded: boolean }> {
  // Ahmed's N1 on #886: a loop on one account would otherwise append one identical row per request, up to
  // the global rate limit. A repeat of the newest state for that purpose is not a new consent act — the ADR
  // asks for one row per tick or untick, and repeating a tick is not another tick.
  const newest = await prisma.parentConsentEvent.findFirst({
    where: { parentId, purpose: input.purpose },
    orderBy: { createdAt: "desc" },
    select: { action: true, textVersion: true, locale: true },
  });
  if (newest && newest.action === action && newest.textVersion === fields.textVersion && newest.locale === fields.locale) {
    return { recorded: false };
  }
  await prisma.parentConsentEvent.create({
    data: {
      parentId,
      purpose: input.purpose,
      action,
      textVersion: fields.textVersion,
      documentVersion: fields.documentVersion,
      locale: fields.locale,
      textHash: fields.textHash,
      surface,
      clientVersion,
    },
  });
  return { recorded: true };
}
