import { beforeEach, describe, expect, it, vi } from "vitest";
import argon2 from "argon2";
import { normalizeDigits } from "../src/lib/digits.js";
import { verifyTotpFresh } from "../src/lib/mfaVerify.js";
import { hashResetCode, resetCodeMatches } from "../src/lib/mfaReset.js";
import { generateTotpSecret, totpAtCounter } from "../src/lib/totp.js";
import { ReauthSchema } from "../src/lib/accountDeletion.js";
import { authRoutes } from "../src/routes/auth.js";
import { deviceRoutes } from "../src/routes/devices.js";
import { PAIR_SCRIPTS } from "../src/lib/pairApproval.js";
import { getRedis } from "../src/redis.js";
import { MockRedis, authHeader, buildApp, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

const store = new Map<string, string>();
const password = "test-only-password";

function arabicDigits(code: string): string {
  return code.replace(/\d/g, (digit) => "٠١٢٣٤٥٦٧٨٩"[Number(digit)]);
}

function persianDigits(code: string): string {
  return code.replace(/\d/g, (digit) => "۰۱۲۳۴۵۶۷۸۹"[Number(digit)]);
}

beforeEach(() => {
  resetPrismaMock();
  store.clear();
  const redis = getRedis() as unknown as MockRedis;
  redis.get.mockImplementation(async (key) => store.get(key) ?? null);
  redis.set.mockImplementation(async (key, value) => {
    store.set(key, String(value));
    return "OK";
  });
  redis.del.mockImplementation(async (...keys) => keys.reduce((count, key) => count + (store.delete(key) ? 1 : 0), 0));
  redis.eval.mockImplementation(async (script, _n, ...args) => {
    if (script === PAIR_SCRIPTS.reserve) {
      const [code, claim, claimId] = args;
      const value = store.get(code);
      if (value === undefined) return [0];
      if (store.has(claim)) return [2];
      store.set(claim, claimId);
      return [1, value, 600_000];
    }
    if (script === PAIR_SCRIPTS.compareAndSet) {
      const [key, expected, next] = args;
      if (store.get(key) !== expected) return 0;
      store.set(key, next);
      return 1;
    }
    if (script === PAIR_SCRIPTS.compareAndDelete) {
      const [key, expected] = args;
      if (store.get(key) !== expected) return 0;
      store.delete(key);
      return 1;
    }
    throw new Error(`unexpected script: ${script}`);
  });
  redis.incrby.mockImplementation(async (key, by) => {
    const next = Number(store.get(key) ?? 0) + by;
    store.set(key, String(next));
    return next;
  });
  redis.expire.mockResolvedValue(1);
  redis.publish.mockResolvedValue(1);
  redis.lpush.mockResolvedValue(1);
  redis.ltrim.mockResolvedValue("OK");
  redis.lrange.mockResolvedValue([]);
});

describe("digit normalization (#771)", () => {
  it("maps both approved digit sets and strips only approved marks and spaces", () => {
    expect(normalizeDigits("٠١٢٣٤٥٦")).toBe("0123456");
    expect(normalizeDigits("۱۲۳۴۵۶")).toBe("123456");
    expect(normalizeDigits("1٢3۴ 5\u200E6\u200F7\u061C8")).toBe("12345678");
    expect(normalizeDigits("٠1٢2۳3۴4۵5۶6")).toBe("012233445566");
  });

  it("refuses full-width digits, other scripts and every other character", () => {
    for (const value of ["１２３４５６", "\u09E7\u09E8\u09E9\u09EA\u09EB\u09EC", "\u0967\u0968\u0969\u096A\u096B\u096C", "12a456", "123\n456", "123\t456"]) {
      expect(normalizeDigits(value)).toBeNull();
    }
    expect(ReauthSchema.safeParse({ password, mfaCode: "１２３４５６" }).success).toBe(false);
    expect(ReauthSchema.parse({ password, mfaCode: "١٢٣٤٥٦" }).mfaCode).toBe("123456");
  });

  it("uses the normalized code for TOTP replay, not only for shape validation", async () => {
    const secret = generateTotpSecret();
    const counter = Math.floor(Date.now() / 1000 / 30);
    const code = totpAtCounter(secret, counter);

    expect(await verifyTotpFresh("parent-1", secret, arabicDigits(code))).toBe(true);
    expect(await verifyTotpFresh("parent-1", secret, code)).toBe(false);
    expect(await verifyTotpFresh("parent-2", secret, persianDigits(code))).toBe(true);
    expect(await verifyTotpFresh("parent-2", secret, code)).toBe(false);
    expect(await verifyTotpFresh("parent-3", secret, "１２３４５６")).toBe(false);
  });

  it("normalizes reset-code hashes before comparing them", () => {
    const stored = hashResetCode("01234567");
    expect(resetCodeMatches("٠١٢٣٤٥٦٧", stored)).toBe(true);
    expect(resetCodeMatches("۰۱۲۳۴۵۶۷", stored)).toBe(true);
    expect(resetCodeMatches("٠١٢٣٤٥٦٧", hashResetCode("۰۱۲۳۴۵۶۷"))).toBe(true);
    expect(resetCodeMatches("１２３４５６７８", stored)).toBe(false);
  });

  it("accepts a normalized login code and refuses its ASCII replay", async () => {
    const secret = generateTotpSecret();
    const counter = Math.floor(Date.now() / 1000 / 30);
    const code = totpAtCounter(secret, counter);
    const passwordHash = await argon2.hash(password);
    prismaMock.parent.findUnique.mockResolvedValue({
      id: "parent-1", familyId: "fam-1", email: "parent@example.com", passwordHash,
      mfaEnabled: true, mfaSecret: secret,
    });
    prismaMock.mfaResetRequest.findMany.mockResolvedValue([]);
    const app = await buildApp(authRoutes, "/v1/auth");

    const first = await app.inject({
      method: "POST", url: "/v1/auth/login",
      payload: { email: "parent@example.com", password, code: arabicDigits(code) },
    });
    expect(first.statusCode).toBe(200);
    const second = await app.inject({
      method: "POST", url: "/v1/auth/login",
      payload: { email: "parent@example.com", password, code },
    });
    expect(second.statusCode).toBe(401);
    await app.close();
  });

  it("accepts Arabic and Persian pairing codes, but not full-width or other scripts", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    for (const [code, ascii] of [["١٢٣٤٥٦", "123456"], ["۱۲۳۴۵۷", "123457"]]) {
      store.set(`pair:${ascii}`, JSON.stringify({ childId: "child-1", familyId: "fam-1" }));
      const res = await app.inject({
        method: "POST", url: "/v1/devices/pair/claim",
        payload: { code, platform: "android", model: "test-device", osVersion: "14" },
      });
      expect(res.statusCode).toBe(202);
      expect(store.has(`pair:${ascii}`)).toBe(true);
    }
    for (const code of ["１２３４５６", "\u09E7\u09E8\u09E9\u09EA\u09EB\u09EC"]) {
      const res = await app.inject({
        method: "POST", url: "/v1/devices/pair/claim",
        payload: { code, platform: "android", model: "test-device", osVersion: "14" },
      });
      expect(res.statusCode).toBe(400);
    }
    await app.close();
  });

  // Mutant (Codex's review finding): transform the refused value to `null` instead of `""` and the pipe reports
  // `Expected string, received null` — a user-visible message this PR promises not to change.
  it("keeps the previous field error for a refused character", async () => {
    const res = await buildApp(deviceRoutes, "/v1/devices").then((app) =>
      app.inject({
        method: "POST", url: "/v1/devices/pair/claim",
        payload: { code: "12345a", platform: "android", model: "test-device", osVersion: "14" },
      }),
    );
    expect(res.statusCode).toBe(400);
    expect(JSON.stringify(res.json())).toContain("Invalid");
    expect(JSON.stringify(res.json())).not.toContain("received null");
  });
});
