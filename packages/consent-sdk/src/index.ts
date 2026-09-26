export type ConsentMethod = "sms_plus" | "kba" | "face_match" | "credit_card";

export interface VerifiableParentalConsent {
  method: ConsentMethod;
  jurisdiction: "US" | "EU" | "UK" | "OTHER";
  parentId: string;
  childId: string;
  thirdPartySharing: boolean;
  evidence: Record<string, unknown>;
}

export interface ConsentProvider {
  name: ConsentMethod;
  initiate(parentId: string, childId: string):
    Promise<{ challengeId: string; instructions: string }>;
  verify(challengeId: string, response: Record<string, unknown>):
    Promise<{ ok: boolean; evidence: Record<string, unknown> }>;
}

export function requiredConsentAge(jurisdiction: string, countryCode?: string): number {
  if (jurisdiction === "US") return 13;
  if (jurisdiction === "EU") {
    const map: Record<string, number> = {
      DE: 16, FR: 15, ES: 14, IT: 14, NL: 16, SE: 13, DK: 13, PL: 16,
    };
    return countryCode ? (map[countryCode] ?? 16) : 16;
  }
  if (jurisdiction === "UK") return 13;
  return 13;
}
