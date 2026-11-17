import { beforeEach, describe, expect, it, vi } from "vitest";
import { meRoutes } from "../src/routes/me.js";
import { consentCopyFor } from "../src/lib/consentCopy.js";
import { authHeader, buildApp, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

/**
 * ADR-0043 D3/D5/D8 / #846 part A step 3: the parent's own consent state and writes.
 *
 * Mutants: drop the `requiresAcceptance` comparison and [an account with no row must re-accept] goes red;
 * accept a withdrawal of the terms and [withdrawing the terms is account deletion] goes red; offer a parked
 * purpose and [the parked purposes are refused while they are off] goes red.
 */
const SERVED = consentCopyFor("en");
const TERMS_HASH = SERVED.purposes[0].textHash;

const grantedRow = {
  purpose: "terms_privacy",
  action: "granted",
  textVersion: SERVED.textVersion,
  locale: "en",
  surface: "app_signup",
  createdAt: new Date("2026-11-17T06:00:00Z"),
};

describe("/v1/me/consents", () => {
  let app: Awaited<ReturnType<typeof buildApp>>;

  beforeEach(async () => {
    resetPrismaMock();
    prismaMock.parentConsentEvent.create.mockResolvedValue({ id: "pce-1" });
    prismaMock.parentConsentEvent.findMany.mockResolvedValue([]);
    app = await buildApp(meRoutes, "/v1/me");
  });

  it("an account with no consent row must accept before anything else", async () => {
    const res = await app.inject({ method: "GET", url: "/v1/me/consents", headers: authHeader(app) });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    // This is N2 (Ahmed, #878): accounts created before step 2 land here, and the app blocks on box 1.
    expect(body.requiresAcceptance).toBe(true);
    expect(body.purposes[0]).toMatchObject({ key: "terms_privacy", required: true, granted: false, at: null });
    expect(body.purposes[0].copy.textHash).toBe(TERMS_HASH);
  });

  it("serves the asked language, so the copy and the hash agree", async () => {
    // Ahmed's B1: serving English while a later write records Arabic would be a proof of text nobody saw.
    const res = await app.inject({ method: "GET", url: "/v1/me/consents?locale=ar", headers: authHeader(app) });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    const ar = consentCopyFor("ar");
    expect(body.purposes[0].copy.text).toBe(ar.purposes[0].text);
    expect(body.purposes[0].copy.textHash).toBe(ar.purposes[0].textHash);
    expect(body.purposes[0].copy.textHash).not.toBe(TERMS_HASH);
  });

  it("a granted row at the served version needs no re-accept", async () => {
    prismaMock.parentConsentEvent.findMany.mockResolvedValue([grantedRow]);
    const body = (await app.inject({ method: "GET", url: "/v1/me/consents", headers: authHeader(app) })).json();
    expect(body.requiresAcceptance).toBe(false);
    expect(body.purposes[0]).toMatchObject({ granted: true, textVersion: SERVED.textVersion });
  });

  it("a row at a retired version asks again, because the wording changed", async () => {
    prismaMock.parentConsentEvent.findMany.mockResolvedValue([{ ...grantedRow, textVersion: "signup-v0" }]);
    expect((await app.inject({ method: "GET", url: "/v1/me/consents", headers: authHeader(app) })).json().requiresAcceptance).toBe(true);
  });

  it("the history is the parent's own rows, without identity fields", async () => {
    prismaMock.parentConsentEvent.findMany.mockResolvedValue([grantedRow]);
    const body = (await app.inject({ method: "GET", url: "/v1/me/consents/history", headers: authHeader(app) })).json();
    expect(body.items).toHaveLength(1);
    expect(body.items[0]).toMatchObject({ purpose: "terms_privacy", action: "granted", textVersion: SERVED.textVersion });
    // ADR-0043 D7: no email and no name in the answer.
    expect(JSON.stringify(body)).not.toContain("@");
    expect(JSON.stringify(body)).not.toContain("parent-1");
  });

  it("the state is read for the signed-in parent", async () => {
    // Ahmed's c11 / Fable's Blocker 2: the id must come from the token, never from anything else in scope.
    await app.inject({ method: "GET", url: "/v1/me/consents", headers: authHeader(app) });
    const [call] = prismaMock.parentConsentEvent.findMany.mock.calls as Array<[{ where?: Record<string, unknown> }]>;
    expect(call[0].where).toEqual({ parentId: "parent-1" });
  });

  it("the row is written for the signed-in parent", async () => {
    // Ahmed's c10: recording under `user.familyId`, or any id but the token's, would file a consent against
    // the wrong person. `authHeader` signs as parent-1.
    prismaMock.parentConsentEvent.findFirst.mockResolvedValue(null);
    await app.inject({
      method: "PUT",
      url: "/v1/me/consents/terms_privacy",
      headers: authHeader(app),
      payload: { granted: true, textVersion: SERVED.textVersion, locale: "en" },
    });
    const [call] = prismaMock.parentConsentEvent.create.mock.calls as Array<[{ data: Record<string, unknown> }]>;
    expect(call[0].data.parentId).toBe("parent-1");
    // And the dedupe read is scoped the same way.
    const [first] = prismaMock.parentConsentEvent.findFirst.mock.calls as Array<[{ where?: Record<string, unknown> }]>;
    expect(first[0].where).toMatchObject({ parentId: "parent-1", purpose: "terms_privacy" });
  });

  it("an app write stores the locale the server served, not the one asked for", async () => {
    // Ahmed's c9: sign-up has this row (#878 N1); the app write did not.
    prismaMock.parentConsentEvent.findFirst.mockResolvedValue(null);
    await app.inject({
      method: "PUT",
      url: "/v1/me/consents/terms_privacy",
      headers: authHeader(app),
      payload: { granted: true, textVersion: SERVED.textVersion, locale: "fr" },
    });
    const [call] = prismaMock.parentConsentEvent.create.mock.calls as Array<[{ data: Record<string, unknown> }]>;
    expect(call[0].data).toMatchObject({ locale: "en", textHash: consentCopyFor("en").purposes[0].textHash });
  });

  it("the history is scoped to the signed-in parent", async () => {
    // Ahmed's B2: dropping `where: { parentId }` would let one parent read every family's consent history.
    prismaMock.parentConsentEvent.findMany.mockResolvedValue([grantedRow]);
    await app.inject({ method: "GET", url: "/v1/me/consents/history", headers: authHeader(app) });
    const [call] = prismaMock.parentConsentEvent.findMany.mock.calls as Array<[{ where?: Record<string, unknown> }]>;
    expect(call[0].where).toEqual({ parentId: "parent-1" });
  });

  it("a repeat of the newest state is not a second consent act", async () => {
    // Ahmed's N1: a loop would append one identical row per request.
    prismaMock.parentConsentEvent.findFirst.mockResolvedValue({
      action: "granted",
      textVersion: SERVED.textVersion,
      locale: "en",
    });
    const res = await app.inject({
      method: "PUT",
      url: "/v1/me/consents/terms_privacy",
      headers: authHeader(app),
      payload: { granted: true, textVersion: SERVED.textVersion, locale: "en" },
    });
    expect(res.statusCode).toBe(200);
    expect(res.json().recorded).toBe(false);
    expect(prismaMock.parentConsentEvent.create).not.toHaveBeenCalled();
  });

  it("ticking the terms writes one row with the served hash and the settings surface", async () => {
    prismaMock.parentConsentEvent.findFirst.mockResolvedValue(null);
    const res = await app.inject({
      method: "PUT",
      url: "/v1/me/consents/terms_privacy",
      headers: authHeader(app),
      payload: { granted: true, textVersion: SERVED.textVersion, locale: "en" },
    });
    expect(res.statusCode).toBe(201);
    const [call] = prismaMock.parentConsentEvent.create.mock.calls as Array<[{ data: Record<string, unknown> }]>;
    expect(call[0].data).toMatchObject({
      purpose: "terms_privacy",
      action: "granted",
      textVersion: SERVED.textVersion,
      textHash: TERMS_HASH,
      locale: "en",
      surface: "app_settings",
    });
  });

  it("withdrawing the terms is account deletion, not a write", async () => {
    const res = await app.inject({
      method: "PUT",
      url: "/v1/me/consents/terms_privacy",
      headers: authHeader(app),
      payload: { granted: false, textVersion: SERVED.textVersion, locale: "en" },
    });
    expect(res.statusCode).toBe(400);
    expect(res.json().error).toBe("terms_withdrawal_is_account_deletion");
    expect(prismaMock.parentConsentEvent.create).not.toHaveBeenCalled();
  });

  it("the parked purposes are refused while their switches are off", async () => {
    for (const purpose of ["ai_improvement", "marketing_email"]) {
      const res = await app.inject({
        method: "PUT",
        url: `/v1/me/consents/${purpose}`,
        headers: authHeader(app),
        payload: { granted: true, textVersion: SERVED.textVersion, locale: "en" },
      });
      expect(res.statusCode).toBe(400);
      expect(res.json().error).toBe("consent_purpose_not_offered");
    }
    expect(prismaMock.parentConsentEvent.create).not.toHaveBeenCalled();
  });

  it("an unknown purpose and a retired version are both refused by name", async () => {
    const unknown = await app.inject({
      method: "PUT",
      url: "/v1/me/consents/marketing_offers",
      headers: authHeader(app),
      payload: { granted: true, textVersion: SERVED.textVersion, locale: "en" },
    });
    expect(unknown.json().error).toBe("unknown_purpose");

    const stale = await app.inject({
      method: "PUT",
      url: "/v1/me/consents/terms_privacy",
      headers: authHeader(app),
      payload: { granted: true, textVersion: "signup-v0", locale: "en" },
    });
    expect(stale.json().error).toBe("consent_text_outdated");
    expect(prismaMock.parentConsentEvent.create).not.toHaveBeenCalled();
  });

  it("a parent token is required for every route", async () => {
    for (const [method, url] of [["GET", "/v1/me/consents"], ["GET", "/v1/me/consents/history"]]) {
      const res = await app.inject({ method: method as "GET", url });
      expect(res.statusCode).toBe(401);
    }
  });
});
