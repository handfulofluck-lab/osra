import { createHash, createHmac, randomInt, timingSafeEqual } from "node:crypto";
import type { ConsentMethod, ConsentProvider } from "./index.js";

/** Abstraction over the SMS transport used to deliver consent codes. */
export interface SmsSender {
  send(to: string, body: string): Promise<void>;
}

// NOTE: real Twilio SDK wiring is a non-goal for this pass — this stub only logs.
/** Stub SmsSender that logs messages instead of calling the Twilio API. */
export class TwilioSmsSender implements SmsSender {
  async send(to: string, body: string): Promise<void> {
    console.log(`[TwilioSmsSender stub] to=${to} body=${body}`);
  }
}

// NOTE: real Stripe (or processor) micro-charge wiring is a non-goal — stub interface only.
/** Abstraction over the credit-card micro-charge second factor. */
export interface MicroChargeProvider {
  charge(token: string): Promise<{ last4: string; reference: string }>;
}

/** Stub MicroChargeProvider that pretends to run the micro-charge. */
export class StubMicroChargeProvider implements MicroChargeProvider {
  async charge(token: string): Promise<{ last4: string; reference: string }> {
    const last4 = /\d{4}$/.test(token) ? token.slice(-4) : "0000";
    return { last4, reference: `microcharge-stub-${Date.now()}` };
  }
}

/** Options for SmsPlusProvider (all injectable for testing). */
export interface SmsPlusProviderOptions {
  /** HMAC secret; defaults to env CONSENT_HMAC_SECRET, then a dev constant. */
  secret?: string;
  /** SMS transport; defaults to the Twilio stub. */
  sender?: SmsSender;
  /** Micro-charge provider; defaults to the stub. */
  microCharger?: MicroChargeProvider;
}

interface PendingChallenge {
  parentId: string;
  childId: string;
  code: string;
  createdAtMs: number;
}

/** SMS+ (text-plus) Verifiable Parental Consent provider per COPPA (spec §9.3). */
export class SmsPlusProvider implements ConsentProvider {
  readonly name: ConsentMethod = "sms_plus";
  private readonly secret: string;
  private readonly sender: SmsSender;
  private readonly microCharger: MicroChargeProvider;
  private readonly challenges = new Map<string, PendingChallenge>();

  constructor(options: SmsPlusProviderOptions = {}) {
    // NOTE: dev fallback constant is for local development only — set CONSENT_HMAC_SECRET in production.
    this.secret =
      options.secret ??
      process.env.CONSENT_HMAC_SECRET ??
      "familyshield-dev-consent-hmac-secret";
    this.sender = options.sender ?? new TwilioSmsSender();
    this.microCharger = options.microCharger ?? new StubMicroChargeProvider();
  }

  /** Send a 6-digit code to the parent and return the HMAC challengeId plus instructions. */
  async initiate(
    parentId: string,
    childId: string,
  ): Promise<{ challengeId: string; instructions: string }> {
    const code = randomInt(0, 1_000_000).toString().padStart(6, "0");
    const ts = Date.now();
    // NOTE: the SDK has no parent directory — the parentId is used as the SMS destination handle.
    await this.sender.send(
      parentId,
      `FamilyShield parental consent code: ${code}`,
    );
    const challengeId = createHmac("sha256", this.secret)
      .update(`${code}|${childId}|${ts}`)
      .digest("hex");
    this.challenges.set(challengeId, { parentId, childId, code, createdAtMs: ts });
    return {
      challengeId,
      instructions:
        "Enter the 6-digit code from the SMS plus one second factor: last 4 " +
        "digits of your SSN (ssnLast4), a signed consent PDF (signedConsentPdf), " +
        "or credit-card micro-charge (creditCardToken).",
    };
  }

  /** Verify the 6-digit code plus a second factor; fails closed on any mismatch or unknown challenge. */
  async verify(
    challengeId: string,
    response: Record<string, unknown>,
  ): Promise<{ ok: boolean; evidence: Record<string, unknown> }> {
    const base = { method: this.name, challengeId };
    const challenge = this.challenges.get(challengeId);
    if (!challenge) {
      return { ok: false, evidence: { ...base, reason: "unknown_challenge" } };
    }
    const submitted = typeof response.code === "string" ? response.code : "";
    if (!this.codesEqual(submitted, challenge.code)) {
      return {
        ok: false,
        evidence: { ...base, reason: "code_mismatch", codeVerified: false },
      };
    }
    const secondFactor = await this.resolveSecondFactor(response);
    if (!secondFactor) {
      return {
        ok: false,
        evidence: { ...base, reason: "missing_second_factor", codeVerified: true },
      };
    }
    return {
      ok: true,
      evidence: {
        ...base,
        codeVerified: true,
        secondFactor,
        parentId: challenge.parentId,
        childId: challenge.childId,
        initiatedAt: new Date(challenge.createdAtMs).toISOString(),
        verifiedAt: new Date().toISOString(),
      },
    };
  }

  /** Compare two codes in constant time via SHA-256 digests. */
  private codesEqual(a: string, b: string): boolean {
    const da = createHash("sha256").update(a).digest();
    const db = createHash("sha256").update(b).digest();
    return timingSafeEqual(da, db);
  }

  /** Resolve one accepted second factor from the verify response, or null if absent/invalid. */
  private async resolveSecondFactor(
    response: Record<string, unknown>,
  ): Promise<Record<string, unknown> | null> {
    const ssnLast4 = response.ssnLast4;
    if (typeof ssnLast4 === "string" && /^\d{4}$/.test(ssnLast4)) {
      return { type: "ssn_last4", ssnLast4 };
    }
    const pdf = response.signedConsentPdf;
    if (pdf === true || (typeof pdf === "string" && pdf.length > 0)) {
      return { type: "signed_consent_pdf" };
    }
    const token = response.creditCardToken;
    if (typeof token === "string" && token.length > 0) {
      try {
        const charge = await this.microCharger.charge(token);
        return {
          type: "credit_card_micro_charge",
          last4: charge.last4,
          reference: charge.reference,
        };
      } catch {
        return null;
      }
    }
    return null;
  }
}
