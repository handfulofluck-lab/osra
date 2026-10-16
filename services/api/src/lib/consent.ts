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
 * ConsentRecord matching the family jurisdiction (spec §12.5).
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
