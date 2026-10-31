import { beforeEach, describe, expect, it, vi } from "vitest";
import argon2 from "argon2";
import { authRoutes } from "../src/routes/auth.js";
import { familyRoutes } from "../src/routes/family.js";
import { utcOffsetMinutes } from "../src/lib/digestSchedule.js";
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
 * ADR-0020, the three named tests from the amended ADR plus the explicit-choice endpoint:
 * a device zone fills a family that has never set one, never overwrites a parent's choice,
 * and an invalid or absent zone changes nothing.
 */
describe("family timezone source (ADR-0020)", () => {
  beforeEach(() => resetPrismaMock());

  it("register stores the device zone with source=device when it is valid", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    let familyCreate: ReturnType<typeof vi.fn> | undefined;

    const mockTransaction = () => {
      familyCreate = vi.fn(async ({ data }: { data: Record<string, unknown> }) => ({ id: "fam-1", ...data }));
      prismaMock.$transaction.mockImplementation(async (fn: (tx: unknown) => unknown) =>
        fn({
          family: { create: familyCreate },
          parent: { create: vi.fn(async () => ({ id: "parent-1", email: "parent@example.com" })) },
        }),
      );
    };

    mockTransaction();
    prismaMock.parent.findUnique.mockResolvedValue(null);
    const ok = await app.inject({
      method: "POST",
      url: "/v1/auth/register",
      payload: { email: "parent@example.com", password: "correct-horse-battery", displayName: "A", familyName: "F", region: "OTHER", timezone: "Asia/Dubai" },
    });
    expect(ok.statusCode).toBe(201);
    expect(familyCreate).toHaveBeenCalledWith({
      data: expect.objectContaining({ timezone: "Asia/Dubai", timezoneSource: "device" }),
    });

    mockTransaction();
    prismaMock.parent.findUnique.mockResolvedValue(null);
    const bad = await app.inject({
      method: "POST",
      url: "/v1/auth/register",
      payload: { email: "second@example.com", password: "correct-horse-battery", displayName: "C", familyName: "G", region: "OTHER", timezone: "Mars/Olympus_Mons" },
    });
    expect(bad.statusCode).toBe(201);
    const createData = (familyCreate as unknown as { mock: { calls: Array<[{ data: Record<string, unknown> }]> } }).mock.calls.at(-1)?.[0]?.data ?? {};
    expect(createData.timezone).toBeUndefined();
    expect(createData.timezoneSource).toBeUndefined();
    await app.close();
  });

  it("login fills only while source is default; a device-filled or parent-chosen zone never moves", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    const hash = await argon2.hash("correct-horse-battery");
    prismaMock.parent.findUnique.mockResolvedValue({
      id: "parent-1",
      familyId: "fam-1",
      email: "parent@example.com",
      passwordHash: hash,
      mfaEnabled: false,
      mfaSecret: null,
    });
    prismaMock.family.updateMany.mockResolvedValue({ count: 1 });

    const ok = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: "parent@example.com", password: "correct-horse-battery", timezone: "Asia/Dubai" } });
    expect(ok.statusCode).toBe(200);
    expect(prismaMock.family.updateMany).toHaveBeenCalledWith({
      where: { id: "fam-1", timezoneSource: "default" },
      data: { timezone: "Asia/Dubai", timezoneSource: "device" },
    });
    // count 0 is what BOTH later cases look like: a zone filled by an earlier login (`device`) and one
    // the parent chose (`parent`) are outside the filter, so a travelling parent cannot move the digest.
    // The filter, not a read-then-write check, is the guarantee.
    prismaMock.family.updateMany.mockResolvedValue({ count: 0 });
    const again = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: "parent@example.com", password: "correct-horse-battery", timezone: "Europe/London" } });
    expect(again.statusCode).toBe(200);
    await app.close();
  });

  it("an invalid or absent timezone leaves the family unchanged at login", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    const hash = await argon2.hash("correct-horse-battery");
    prismaMock.parent.findUnique.mockResolvedValue({
      id: "parent-1", familyId: "fam-1", email: "parent@example.com", passwordHash: hash, mfaEnabled: false, mfaSecret: null,
    });
    await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: "parent@example.com", password: "correct-horse-battery", timezone: "Mars/Olympus_Mons" } });
    await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: "parent@example.com", password: "correct-horse-battery" } });
    expect(prismaMock.family.updateMany).not.toHaveBeenCalled();
    await app.close();
  });

  it("PATCH /family/me sets the parent's choice and source=parent; an invalid zone is refused", async () => {
    const app = await buildApp(familyRoutes, "/v1/family");
    prismaMock.family.update.mockResolvedValue({ id: "fam-1", timezone: "Asia/Dubai", timezoneSource: "parent" });

    const ok = await app.inject({ method: "PATCH", url: "/v1/family/me", headers: authHeader(app), payload: { timezone: "Asia/Dubai" } });
    expect(ok.statusCode).toBe(200);
    expect(ok.json()).toMatchObject({ family: { timezone: "Asia/Dubai", timezoneSource: "parent" } });
    expect(prismaMock.family.update).toHaveBeenCalledWith({
      where: { id: "fam-1" },
      data: { timezone: "Asia/Dubai", timezoneSource: "parent" },
    });

    const bad = await app.inject({ method: "PATCH", url: "/v1/family/me", headers: authHeader(app), payload: { timezone: "Mars/Olympus_Mons" } });
    expect(bad.statusCode).toBe(400);
    expect(bad.json()).toEqual({ error: "invalid_timezone" });
    await app.close();
  });

  /**
   * #476: the parent app reads a routine window on the child's clock. `/me` gives it the family
   * zone's offset at the moment of the request, and nothing while no zone has been set.
   * Mutant: drop the `utcOffsetMinutes` spread from `/me` → the Dubai row goes red.
   */
  describe("/me carries the family zone's UTC offset (#476)", () => {
    const familyRow = (timezone: string, timezoneSource: string) => ({
      id: "fam-1",
      name: "F",
      region: "OTHER",
      timezone,
      timezoneSource,
      parents: [{ id: "parent-1", email: "parent@example.com", passwordHash: "x", mfaSecret: null }],
      children: [],
    });

    it("a family in Asia/Dubai gets 240", async () => {
      const app = await buildApp(familyRoutes, "/v1/family");
      prismaMock.family.findUnique.mockResolvedValue(familyRow("Asia/Dubai", "parent"));
      const res = await app.inject({ method: "GET", url: "/v1/family/me", headers: authHeader(app) });
      expect(res.statusCode).toBe(200);
      expect(res.json().family.utcOffsetMinutes).toBe(240);
      await app.close();
    });

    it("a family with no zone set gets no field", async () => {
      const app = await buildApp(familyRoutes, "/v1/family");
      prismaMock.family.findUnique.mockResolvedValue(familyRow("UTC", "default"));
      const res = await app.inject({ method: "GET", url: "/v1/family/me", headers: authHeader(app) });
      expect(res.statusCode).toBe(200);
      expect(res.json().family).not.toHaveProperty("utcOffsetMinutes");
      await app.close();
    });

    it("the offset follows daylight saving and keeps its sign west of UTC", () => {
      expect(utcOffsetMinutes(new Date("2026-01-15T12:00:00Z"), "America/New_York")).toBe(-300);
      expect(utcOffsetMinutes(new Date("2026-07-15T12:00:00Z"), "America/New_York")).toBe(-240);
      expect(utcOffsetMinutes(new Date("2026-07-15T12:00:00.750Z"), "Asia/Kolkata")).toBe(330);
      expect(utcOffsetMinutes(new Date("2026-07-15T12:00:00Z"), "UTC")).toBe(0);
    });
  });
});
