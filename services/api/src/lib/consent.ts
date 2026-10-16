import type { FastifyReply } from "fastify";
import { prisma } from "../db.js";

export interface ActiveConsentResult {
  active: boolean;
  reason?: "parental_consent_required" | "consent_jurisdiction_mismatch";
  jurisdiction?: string;
  consent?: {
    id: string;
    childId: string;
    parentId: string;
    method: string;
    jurisdiction: string;
    grantedAt: Date;
    expiresAt: Date | null;
    revokedAt: Date | null;
    thirdPartySharing: boolean;
  };
}

/**
 * Check whether a child currently has an active (non-revoked, non-expired)
 * ConsentRecord matching the family jurisdiction (spec §12.5, ADR-0008).
 */
export async function checkActiveConsent(
  childId: string,
  familyRegion?: string,
): Promise<ActiveConsentResult> {
  const now = new Date();
  const consent = await prisma.consentRecord.findFirst({
    where: {
      childId,
      revokedAt: null,
      OR: [
        { expiresAt: null },
        { expiresAt: { gt: now } },
      ],
    },
    orderBy: { grantedAt: "desc" },
  });

  if (!consent) {
    return {
      active: false,
      reason: "parental_consent_required",
      jurisdiction: familyRegion,
    };
  }

  if (familyRegion && consent.jurisdiction !== familyRegion) {
    return {
      active: false,
      reason: "consent_jurisdiction_mismatch",
      jurisdiction: familyRegion,
      consent,
    };
  }

  return {
    active: true,
    jurisdiction: consent.jurisdiction,
    consent,
  };
}

/**
 * Processing gate for device-originated data and device reads (ADR-0008 §2b).
 *
 * Withdrawal of consent must stop *collection*, not only configuration: once a parent revokes,
 * location pings, social scans, telemetry, activity, content events and agent alerts are refused
 * with 428, and the device's rule/command reads return 428 so the agent knows to pause
 * monitoring. Device JWTs are deliberately left valid so re-granting consent resumes the same
 * pairing without re-enrolment.
 *
 * Returns `true` when processing may continue; otherwise the 428 has already been sent.
 */
export async function assertProcessingAllowed(childId: string, reply: FastifyReply): Promise<boolean> {
  const result = await checkActiveConsent(childId);
  if (result.active) return true;
  await reply.code(428).send({ error: result.reason ?? "parental_consent_required", childId });
  return false;
}
