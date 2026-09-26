import { describe, expect, it } from "vitest";
import { requiredConsentAge } from "../src/index.js";
import { SmsPlusProvider } from "../src/sms-plus.js";
import type { MicroChargeProvider, SmsSender } from "../src/sms-plus.js";

describe("requiredConsentAge", () => {
  it("US is 13", () => expect(requiredConsentAge("US")).toBe(13));
  it("Germany is 16", () => expect(requiredConsentAge("EU", "DE")).toBe(16));
  it("Sweden is 13", () => expect(requiredConsentAge("EU", "SE")).toBe(13));
});

/** Captures SMS messages so tests can extract the 6-digit code. */
class FakeSmsSender implements SmsSender {
  messages: Array<{ to: string; body: string }> = [];

  async send(to: string, body: string): Promise<void> {
    this.messages.push({ to, body });
  }

  lastCode(): string {
    const body = this.messages.at(-1)?.body ?? "";
    const match = /\b(\d{6})\b/.exec(body);
    if (!match) throw new Error(`no 6-digit code captured in: ${body}`);
    return match[1];
  }
}

class FakeMicroCharger implements MicroChargeProvider {
  charged: string[] = [];

  async charge(token: string): Promise<{ last4: string; reference: string }> {
    this.charged.push(token);
    return { last4: token.slice(-4), reference: `fake-${this.charged.length}` };
  }
}

describe("SmsPlusProvider", () => {
  const secret = "test-consent-secret";

  it("challenge/verify round-trip succeeds via a fake SmsSender", async () => {
    const sender = new FakeSmsSender();
    const provider = new SmsPlusProvider({ secret, sender });

    const { challengeId, instructions } = await provider.initiate("parent-1", "child-1");

    expect(challengeId).toMatch(/^[0-9a-f]{64}$/);
    expect(instructions).toContain("6-digit");
    expect(sender.messages).toEqual([
      { to: "parent-1", body: expect.stringMatching(/\b\d{6}\b/) },
    ]);
    const code = sender.lastCode();
    expect(code).toMatch(/^\d{6}$/);

    const result = await provider.verify(challengeId, {
      code,
      signedConsentPdf: true,
    });
    expect(result.ok).toBe(true);
    expect(result.evidence.method).toBe("sms_plus");
    expect(result.evidence.codeVerified).toBe(true);
    expect(result.evidence.secondFactor).toMatchObject({ type: "signed_consent_pdf" });
    expect(result.evidence.initiatedAt).toBeTruthy();
    expect(result.evidence.verifiedAt).toBeTruthy();
  });

  it("wrong code fails", async () => {
    const sender = new FakeSmsSender();
    const provider = new SmsPlusProvider({ secret, sender });
    const { challengeId } = await provider.initiate("parent-1", "child-1");
    const realCode = sender.lastCode();
    const wrong = realCode === "000000" ? "000001" : "000000";

    const result = await provider.verify(challengeId, { code: wrong, ssnLast4: "1234" });
    expect(result.ok).toBe(false);
    expect(result.evidence.codeVerified).toBe(false);
  });

  it("right code without a second factor fails", async () => {
    const sender = new FakeSmsSender();
    const provider = new SmsPlusProvider({ secret, sender });
    const { challengeId } = await provider.initiate("parent-1", "child-1");
    const code = sender.lastCode();

    const result = await provider.verify(challengeId, { code });
    expect(result.ok).toBe(false);
    expect(result.evidence.codeVerified).toBe(true);
    expect(result.evidence.secondFactor).toBeUndefined();
  });

  it("right code + ssnLast4 succeeds and evidence is populated", async () => {
    const sender = new FakeSmsSender();
    const provider = new SmsPlusProvider({ secret, sender });
    const { challengeId } = await provider.initiate("parent-9", "child-9");
    const code = sender.lastCode();

    const result = await provider.verify(challengeId, { code, ssnLast4: "6789" });

    expect(result.ok).toBe(true);
    expect(result.evidence).toMatchObject({
      method: "sms_plus",
      codeVerified: true,
      parentId: "parent-9",
      childId: "child-9",
      secondFactor: { type: "ssn_last4", ssnLast4: "6789" },
    });
    expect(typeof result.evidence.challengeId).toBe("string");
    expect(result.evidence.initiatedAt).toEqual(expect.any(String));
    expect(result.evidence.verifiedAt).toEqual(expect.any(String));
  });

  it("credit-card micro-charge (stub) succeeds as second factor", async () => {
    const sender = new FakeSmsSender();
    const microCharger = new FakeMicroCharger();
    const provider = new SmsPlusProvider({ secret, sender, microCharger });
    const { challengeId } = await provider.initiate("parent-1", "child-1");
    const code = sender.lastCode();

    const result = await provider.verify(challengeId, { code, creditCardToken: "tok_visa_4242" });

    expect(result.ok).toBe(true);
    expect(microCharger.charged).toEqual(["tok_visa_4242"]);
    expect(result.evidence.secondFactor).toMatchObject({
      type: "credit_card_micro_charge",
      last4: "4242",
    });
  });

  it("unknown challengeId fails closed", async () => {
    const provider = new SmsPlusProvider({ secret, sender: new FakeSmsSender() });

    const result = await provider.verify("deadbeef".repeat(8), {
      code: "123456",
      ssnLast4: "1234",
    });

    expect(result.ok).toBe(false);
    expect(result.evidence.reason).toBe("unknown_challenge");
  });
});
