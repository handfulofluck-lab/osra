import { beforeEach, describe, expect, it, vi } from "vitest";
import { createHmac } from "node:crypto";
import { alertsRoutes } from "../src/routes/alerts.js";
import { authenticateInternalRequest, signV2, signingStringV2 } from "../src/lib/internalAuth.js";
import { getRedis } from "../src/redis.js";
import { MockRedis, buildApp, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

const GLOBAL = "global-service-secret";
const DEV = { id: "dev-1", childId: "child-1", internalSecret: "device-secret-1", revokedAt: null };
const NOSECRET = { id: "dev-nosecret", childId: "child-1", internalSecret: null, revokedAt: null };
const env = { INTERNAL_HMAC_SECRET: GLOBAL } as NodeJS.ProcessEnv;
const NOW = 1_800_000_000;

/** Back the nonce claim with a Set so a second claim of the same key fails like Redis NX. */
function wireNonceStore() {
  const seen = new Set<string>();
  const redis = getRedis() as unknown as MockRedis;
  redis.set.mockImplementation(async (k: string, _v: unknown, ...rest: unknown[]) => {
    if (rest.includes("NX")) { if (seen.has(k)) return null; seen.add(k); }
    return "OK";
  });
  return seen;
}

describe("internal signing v2 — replay, skew, callers (ADR-0014, closes J2/J6)", () => {
  beforeEach(() => {
    resetPrismaMock();
    wireNonceStore();
    prismaMock.device.findUnique.mockImplementation(async ({ where }: { where: { id: string } }) => (where.id === DEV.id ? DEV : where.id === NOSECRET.id ? NOSECRET : null));
    prismaMock.device.findMany.mockResolvedValue([DEV, NOSECRET]);
  });

  const body = JSON.stringify({ childId: "child-1", deviceId: "dev-1", title: "x" });

  it("a v2 device signature is accepted once and rejected on replay (same nonce)", async () => {
    const h = signV2(DEV.internalSecret, body, { timestamp: NOW, nonce: "nonce-0123456789abcdef" });
    const first = await authenticateInternalRequest(body, h["x-familyshield-signature"], h, NOW, env);
    expect(first).toMatchObject({ valid: true, version: 2, device: { id: "dev-1" } });
    const replay = await authenticateInternalRequest(body, h["x-familyshield-signature"], h, NOW + 1, env);
    expect(replay).toEqual({ valid: false, reason: "replay" });
    // A different nonce over the same body is a new request.
    const h2 = signV2(DEV.internalSecret, body, { timestamp: NOW, nonce: "nonce-fedcba9876543210" });
    expect((await authenticateInternalRequest(body, h2["x-familyshield-signature"], h2, NOW, env)).valid).toBe(true);
  });

  it("the signing string binds timestamp, nonce and body — tampering with any of them fails", async () => {
    const h = signV2(DEV.internalSecret, body, { timestamp: NOW, nonce: "nonce-0123456789abcdef" });
    expect(signingStringV2("1", "n", "b").toString()).toBe("1.n.b");
    // Cross-platform reference vector — the SAME value is asserted by the Android interceptor test
    // (SignatureInterceptorTest) and the Windows agent test, so the four signers cannot drift apart.
    expect(h["x-familyshield-signature"]).toBe("ce725cf93f36fb43a586bcae590b3faab54afa4976347b859c9ca9259c220508");
    const tamperedBody = body.replace('"x"', '"y"');
    expect((await authenticateInternalRequest(tamperedBody, h["x-familyshield-signature"], h, NOW, env)).reason).toBe("invalid_signature");
    const tamperedTs = { ...h, "x-familyshield-timestamp": String(NOW + 10) };
    expect((await authenticateInternalRequest(body, h["x-familyshield-signature"], tamperedTs, NOW, env)).reason).toBe("invalid_signature");
    const tamperedNonce = { ...h, "x-familyshield-nonce": "nonce-zzzzzzzzzzzzzzzz" };
    expect((await authenticateInternalRequest(body, h["x-familyshield-signature"], tamperedNonce, NOW, env)).reason).toBe("invalid_signature");
  });

  it("rejects timestamps outside ±300 s and malformed nonces before touching the secret", async () => {
    const stale = signV2(DEV.internalSecret, body, { timestamp: NOW - 301, nonce: "nonce-0123456789abcdef" });
    expect((await authenticateInternalRequest(body, stale["x-familyshield-signature"], stale, NOW, env)).reason).toBe("stale_timestamp");
    const future = signV2(DEV.internalSecret, body, { timestamp: NOW + 301, nonce: "nonce-0123456789abcdef" });
    expect((await authenticateInternalRequest(body, future["x-familyshield-signature"], future, NOW, env)).reason).toBe("stale_timestamp");
    const edge = signV2(DEV.internalSecret, body, { timestamp: NOW - 300, nonce: "nonce-0123456789abcdef" });
    expect((await authenticateInternalRequest(body, edge["x-familyshield-signature"], edge, NOW, env)).valid).toBe(true);
    const shortNonce = signV2(DEV.internalSecret, body, { timestamp: NOW, nonce: "short" });
    expect((await authenticateInternalRequest(body, shortNonce["x-familyshield-signature"], shortNonce, NOW, env)).reason).toBe("missing_nonce");
    // Only the one valid (edge) request reached the database; the three rejections never did.
    expect(prismaMock.device.findUnique).toHaveBeenCalledTimes(1);
  });

  it("v1 (body-only) device signatures: refused by default, accepted only with INTERNAL_SIGNING_ALLOW_V1=1", async () => {
    const v1 = createHmac("sha256", DEV.internalSecret).update(body).digest("hex");
    expect((await authenticateInternalRequest(body, v1, {}, NOW, env))).toEqual({ valid: false, reason: "legacy_signature_disabled" });
    const zero = { ...env, INTERNAL_SIGNING_ALLOW_V1: "0" } as NodeJS.ProcessEnv;
    expect((await authenticateInternalRequest(body, v1, {}, NOW, zero))).toEqual({ valid: false, reason: "legacy_signature_disabled" });
    const optIn = { ...env, INTERNAL_SIGNING_ALLOW_V1: "1" } as NodeJS.ProcessEnv;
    expect((await authenticateInternalRequest(body, v1, {}, NOW, optIn))).toMatchObject({ valid: true, version: 1 });
    // No nonce window for v1: the same request is accepted again (this is exactly why v1 is opt-in only).
    expect((await authenticateInternalRequest(body, v1, {}, NOW, optIn)).valid).toBe(true);
  });

  it("the global secret authenticates only as a named service in v2 — never bare, never v1 (J5/J6)", async () => {
    const v1Global = createHmac("sha256", GLOBAL).update(body).digest("hex");
    expect((await authenticateInternalRequest(body, v1Global, {}, NOW, env)).reason).toBe("global_secret_requires_service_caller");
    const v2NoCaller = signV2(GLOBAL, body, { timestamp: NOW, nonce: "nonce-0123456789abcdef" });
    expect((await authenticateInternalRequest(body, v2NoCaller["x-familyshield-signature"], v2NoCaller, NOW, env)).reason).toBe("global_secret_requires_service_caller");
    const unknownCaller = signV2(GLOBAL, body, { timestamp: NOW, nonce: "nonce-0123456789abcdef", caller: "mystery" });
    expect((await authenticateInternalRequest(body, unknownCaller["x-familyshield-signature"], unknownCaller, NOW, env)).reason).toBe("global_secret_requires_service_caller");
    const service = signV2(GLOBAL, body, { timestamp: NOW, nonce: "nonce-0123456789abcdef", caller: "ai-engine" });
    expect(await authenticateInternalRequest(body, service["x-familyshield-signature"], service, NOW, env)).toEqual({ valid: true, version: 2, isGlobalSecret: true, caller: "ai-engine" });
    expect((await authenticateInternalRequest(body, service["x-familyshield-signature"], service, NOW, env)).reason).toBe("replay");
  });

  it("J6 closed: a secret-less device cannot be acted on by a body-only signature of any kind", async () => {
    const noSecretBody = JSON.stringify({ childId: "child-1", deviceId: NOSECRET.id, title: "x" });
    const v1Global = createHmac("sha256", GLOBAL).update(noSecretBody).digest("hex");
    expect((await authenticateInternalRequest(noSecretBody, v1Global, {}, NOW, env)).valid).toBe(false);
    const v1Sibling = createHmac("sha256", DEV.internalSecret).update(noSecretBody).digest("hex");
    expect((await authenticateInternalRequest(noSecretBody, v1Sibling, {}, NOW, env))).toEqual({ valid: false, reason: "device_has_no_secret" });
  });

  it("the route returns the reason code on 401 so a tester can tell replay from a bad key", async () => {
    const app = await buildApp(alertsRoutes, "/v1/alerts");
    process.env.INTERNAL_HMAC_SECRET = GLOBAL;
    prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-1" });
    prismaMock.alert.create.mockResolvedValue({ id: "a1", category: "sos" });
    const raw = JSON.stringify({ childId: "child-1", deviceId: "dev-1", severity: "info", category: "sos", title: "t", body: "b" });
    const h = signV2(DEV.internalSecret, raw, { nonce: "nonce-route-0123456789" });
    const ok = await app.inject({ method: "POST", url: "/v1/alerts/internal", headers: { "content-type": "application/json", ...h }, payload: raw });
    expect(ok.statusCode).toBe(201);
    const again = await app.inject({ method: "POST", url: "/v1/alerts/internal", headers: { "content-type": "application/json", ...h }, payload: raw });
    expect(again.statusCode).toBe(401);
    expect(again.json()).toEqual({ error: "invalid_signature", reason: "replay" });
    await app.close();
  });
});
