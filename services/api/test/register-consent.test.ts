import { readFileSync } from "node:fs";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { authRoutes } from "../src/routes/auth.js";
import { consentCopyFor } from "../src/lib/consentCopy.js";
import { getRedis } from "../src/redis.js";
import { SIGNUP_CONSENTS, buildApp, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

/**
 * ADR-0043 D3 / #846 part A step 2: `POST /v1/auth/register` records the adult's acceptance of the terms,
 * in the same transaction as the account, with the hash of the text the server served.
 *
 * Mutants: drop `recordSignupConsent` and [a sign-up stores the served hash] goes red; move the consent
 * insert outside the transaction and [a failed insert leaves no account] goes red; read `textHash` from the
 * request and [the stored hash is the served one, not the client's] goes red.
 */
const PASSWORD = "CorrectHorseBatteryStaple!";

const body = (overrides: Record<string, unknown> = {}) => ({
  email: "new@osratech.com",
  password: PASSWORD,
  displayName: "New Parent",
  familyName: "New Family",
  region: "US",
  consents: { ...SIGNUP_CONSENTS },
  ...overrides,
});

describe("POST /v1/auth/register — the consent record", () => {
  let app: Awaited<ReturnType<typeof buildApp>>;

  beforeEach(async () => {
    resetPrismaMock();
    prismaMock.parent.findUnique.mockResolvedValue(null);
    prismaMock.family.create.mockResolvedValue({ id: "fam-1" });
    prismaMock.parent.create.mockResolvedValue({ id: "parent-1" });
    prismaMock.parentConsentEvent.create.mockResolvedValue({ id: "pce-1" });
    app = await buildApp(authRoutes, "/v1/auth");
  });

  it("refuses a sign-up with no consents block at all", async () => {
    const res = await app.inject({ method: "POST", url: "/v1/auth/register", payload: body({ consents: undefined }) });
    expect(res.statusCode).toBe(400);
    // The zod flatten names the missing field; the account is not created.
    expect(JSON.stringify(res.json())).toContain("consents");
    expect(prismaMock.parent.create).not.toHaveBeenCalled();
    expect(prismaMock.parentConsentEvent.create).not.toHaveBeenCalled();
  });

  it("refuses an unticked box with terms_not_accepted and writes nothing", async () => {
    const res = await app.inject({
      method: "POST",
      url: "/v1/auth/register",
      payload: body({ consents: { ...SIGNUP_CONSENTS, termsPrivacy: false } }),
    });
    expect(res.statusCode).toBe(400);
    expect(res.json().error).toBe("terms_not_accepted");
    expect(prismaMock.family.create).not.toHaveBeenCalled();
    expect(prismaMock.parent.create).not.toHaveBeenCalled();
  });

  it("refuses a text version the server no longer serves", async () => {
    const res = await app.inject({
      method: "POST",
      url: "/v1/auth/register",
      payload: body({ consents: { ...SIGNUP_CONSENTS, textVersion: "signup-v0" } }),
    });
    expect(res.statusCode).toBe(400);
    expect(res.json().error).toBe("consent_text_outdated");
    expect(prismaMock.parent.create).not.toHaveBeenCalled();
  });

  it("refuses a parked purpose sent as true, because nobody was shown that text", async () => {
    for (const parked of ["aiImprovement", "marketingEmail"]) {
      const res = await app.inject({
        method: "POST",
        url: "/v1/auth/register",
        payload: body({ consents: { ...SIGNUP_CONSENTS, [parked]: true } }),
      });
      expect(res.statusCode).toBe(400);
      expect(res.json().error).toBe("consent_purpose_not_offered");
    }
    expect(prismaMock.parent.create).not.toHaveBeenCalled();
  });

  it("stores the served hash, version and surface — never a hash from the request", async () => {
    const res = await app.inject({
      method: "POST",
      url: "/v1/auth/register",
      payload: body({ consents: { ...SIGNUP_CONSENTS, textHash: "0".repeat(64) } }),
    });
    expect(res.statusCode).toBe(201);

    const served = consentCopyFor("en").purposes[0];
    expect(prismaMock.parentConsentEvent.create).toHaveBeenCalledTimes(1);
    const [call] = prismaMock.parentConsentEvent.create.mock.calls as Array<[{ data: Record<string, unknown> }]>;
    expect(call[0].data).toMatchObject({
      parentId: "parent-1",
      purpose: "terms_privacy",
      action: "granted",
      textVersion: "signup-v1",
      locale: "en",
      textHash: served.textHash,
      surface: "app_signup",
    });
    // The client's 64 zeros are ignored; the stored hash is the one the copy endpoint serves.
    expect(call[0].data.textHash).not.toBe("0".repeat(64));
    expect(call[0].data.textHash).toBe(served.textHash);
  });

  it("stores the Arabic hash when the parent signed up in Arabic", async () => {
    const res = await app.inject({
      method: "POST",
      url: "/v1/auth/register",
      payload: body({ consents: { ...SIGNUP_CONSENTS, locale: "ar" } }),
    });
    expect(res.statusCode).toBe(201);
    const [call] = prismaMock.parentConsentEvent.create.mock.calls as Array<[{ data: Record<string, unknown> }]>;
    expect(call[0].data).toMatchObject({ locale: "ar", textHash: consentCopyFor("ar").purposes[0].textHash });
    // The two languages are different proofs of different text.
    expect(call[0].data.textHash).not.toBe(consentCopyFor("en").purposes[0].textHash);
  });

  it("writes the account and its consent row through the same transaction client", async () => {
    // A tagged transaction client: the row must go through `tx`, not through the global client. Mutant:
    // move `recordSignupConsent` after `$transaction` and this row catches it — which the mock cannot
    // otherwise show, because a mock has no rollback to observe.
    const parentCreate = vi.fn(async () => ({ id: "parent-1" }));
    const consentCreate = vi.fn(async () => ({ id: "pce-1" }));
    prismaMock.$transaction.mockImplementationOnce(async (fn: (tx: unknown) => unknown) =>
      fn({
        family: { create: vi.fn(async () => ({ id: "fam-1" })) },
        parent: { create: parentCreate },
        parentConsentEvent: { create: consentCreate },
      }),
    );
    prismaMock.parentConsentEvent.create.mockClear();

    const res = await app.inject({ method: "POST", url: "/v1/auth/register", payload: body() });
    expect(res.statusCode).toBe(201);
    expect(parentCreate).toHaveBeenCalledTimes(1);
    expect(consentCreate).toHaveBeenCalledTimes(1);
    // Nothing was written through the global client: the two writes share one transaction.
    expect(prismaMock.parentConsentEvent.create).not.toHaveBeenCalled();
  });

  it("a failed consent insert leaves no session", async () => {
    prismaMock.$transaction.mockImplementationOnce(async (fn: (tx: unknown) => unknown) =>
      fn({
        family: { create: vi.fn(async () => ({ id: "fam-1" })) },
        parent: { create: vi.fn(async () => ({ id: "parent-1" })) },
        parentConsentEvent: { create: vi.fn(async () => { throw new Error("insert exploded"); }) },
      }),
    );
    const redis = getRedis() as unknown as import("./helpers.js").MockRedis;
    redis.set.mockClear();

    const res = await app.inject({ method: "POST", url: "/v1/auth/register", payload: body() });
    expect(res.statusCode).toBeGreaterThanOrEqual(500);
    // The throw propagates out of the transaction, so no token is minted for an account that did not commit.
    expect(redis.set).not.toHaveBeenCalled();
    expect(res.json().token).toBeUndefined();
  });

  it("the model cannot record where the parent was", () => {
    const schema = readFileSync(new URL("../prisma/schema.prisma", import.meta.url), "utf8");
    const model = schema.slice(schema.indexOf("model ParentConsentEvent"), schema.indexOf("model ConsentRecord"));
    // ADR-0043 D2: no IP address and no device id. The row is the proof of the text, not a location record.
    expect(model).not.toMatch(/ip(Address)?/i);
    expect(model).not.toMatch(/device/i);
  });
});
