import { beforeEach, describe, expect, it, vi } from "vitest";
import { authHeader, buildApp, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => ({ prisma: (await import("./helpers.js")).prismaMock }));
vi.mock("ioredis", async () => ({ Redis: (await import("./helpers.js")).MockRedis }));

import { BY_NAME_MAX, cleanByName, withByName } from "../src/lib/actingAdult.js";
import { enqueueDeviceCommand } from "../src/lib/deviceCommands.js";
import { controlsRoutes } from "../src/routes/controls.js";
import { deviceRoutes } from "../src/routes/devices.js";
import { rulesRoutes } from "../src/routes/rules.js";

// Synthetic names only.
const CHILD = { id: "child-1", familyId: "fam-1" };
const DEVICE = { id: "dev-1", childId: "child-1", child: { familyId: "fam-1" } };

/** Flat Prisma RuleSet row, the same shape controls.test.ts uses. */
function rulesRow() {
  return {
    id: "rs-1",
    childId: "child-1",
    dailyLimitMinutes: 180,
    weekendLimitMinutes: 300,
    bedtimeStart: "21:00",
    bedtimeEnd: "07:00",
    schoolHoursStart: "08:00",
    schoolHoursEnd: "15:00",
    schoolDays: [1, 2, 3, 4, 5],
    blockedCategories: ["pornography"],
    allowedDomains: [],
    blockedDomains: [],
    safeSearchEnforced: true,
    appRules: [],
    routines: [],
    alwaysAllowedApps: [],
    bonusMinutesToday: 0,
    updatedAt: "2026-09-16T00:00:00.000Z",
  };
}

function queued(): Array<{ deviceId: string; type: string; payload: Record<string, unknown>; requestedBy?: string }> {
  return prismaMock.deviceCommand.create.mock.calls.map(([arg]: [{ data: never }]) => arg.data);
}

/** Keep the default owner row (role gates read it) and change only the display name. */
function setParentName(displayName: string) {
  prismaMock.parent.findUnique.mockResolvedValue({
    id: "parent-1", familyId: "fam-1", email: "parent-1@example.com", displayName,
    role: "owner", permissions: [], passwordHash: "argon2$stub", mfaEnabled: false, mfaSecret: null,
  });
}

describe("C-04 byName: the server stamps the acting adult on child-visible commands (#1179)", () => {
  beforeEach(() => {
    resetPrismaMock();
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.device.findMany.mockResolvedValue([{ id: "dev-1" }]);
    prismaMock.device.findUnique.mockResolvedValue(DEVICE);
    setParentName("  Mama\n Sara ");
    prismaMock.deviceCommand.create.mockImplementation(async ({ data }) => ({
      id: `cmd-${prismaMock.deviceCommand.create.mock.calls.length}`,
      status: "pending",
      attempts: 0,
      createdAt: new Date(),
      ...data,
    }));
  });

  it("cleans names: trims, folds whitespace and control characters, caps the length", () => {
    expect(cleanByName("  Mama\n Sara ")).toBe("Mama Sara");
    expect(cleanByName("أبو أحمد")).toBe("أبو أحمد");
    expect(cleanByName("   ")).toBeUndefined();
    // #1237 review: bidi embedding, override and isolate controls are stripped, not kept or turned into spaces.
    expect(cleanByName("Ma\u202Ema\u202C")).toBe("Mama");
    expect(cleanByName("\u202A\u202B\u202C\u202D\u202EDad\u2066\u2067\u2068\u2069")).toBe("Dad");
    expect(cleanByName("\u2067\u202E")).toBeUndefined();
    expect(cleanByName("أبو\u2068 أحمد\u2069")).toBe("أبو أحمد");
    expect(cleanByName(null)).toBeUndefined();
    expect(Array.from(cleanByName("x".repeat(200))!)).toHaveLength(BY_NAME_MAX);
    expect(withByName({ minutes: 5, byName: "Spoofed" }, undefined)).toEqual({ minutes: 5 });
    expect(withByName({ minutes: 5, byName: "Spoofed" }, "Real")).toEqual({ minutes: 5, byName: "Real" });
  });

  it("bonus time carries the parent's name and the parent id as requester", async () => {
    const app = await buildApp(controlsRoutes, "/v1/controls");
    prismaMock.ruleSet.upsert.mockResolvedValue({ ...rulesRow(), bonusMinutesToday: 15 });
    const res = await app.inject({
      method: "POST",
      url: "/v1/controls/children/child-1/bonus",
      headers: authHeader(app),
      payload: { minutes: 15 },
    });
    expect(res.statusCode, res.body).toBe(200);
    expect(queued()).toContainEqual(expect.objectContaining({
      type: "bonus_time",
      payload: { minutes: 15, byName: "Mama Sara" },
      requestedBy: "parent-1",
    }));
    expect(prismaMock.parent.findUnique).toHaveBeenCalledWith({ where: { id: "parent-1" }, select: { displayName: true } });
    await app.close();
  });

  it("pause internet stamps byName on every target command", async () => {
    const app = await buildApp(controlsRoutes, "/v1/controls");
    prismaMock.$queryRaw.mockResolvedValue([{ id: "child-1" }]);
    prismaMock.childInternetOperation.findUnique.mockResolvedValue(null);
    prismaMock.childInternetOperation.upsert.mockResolvedValue({});
    prismaMock.deviceCommand.createManyAndReturn.mockImplementation(async ({ data }) =>
      data.map((d: Record<string, unknown>, i: number) => ({ id: `c${i}`, status: "pending", attempts: 0, ...d })));
    const res = await app.inject({ method: "POST", url: "/v1/controls/children/child-1/pause", headers: authHeader(app) });
    expect(res.statusCode, res.body).toBe(200);
    const rows = prismaMock.deviceCommand.createManyAndReturn.mock.calls[0][0].data;
    expect(rows).toEqual([expect.objectContaining({ type: "pause_internet", payload: { byName: "Mama Sara" } })]);
    await app.close();
  });

  it("lock uses the server's name and ignores a client-sent byName; non-attributed commands carry none", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    const lock = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/command",
      headers: authHeader(app),
      payload: { command: "lock", payload: { byName: "Someone else" } },
    });
    expect(lock.statusCode, lock.body).toBe(200);
    const ring = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/command",
      headers: authHeader(app),
      payload: { command: "ring", payload: { byName: "Someone else" } },
    });
    expect(ring.statusCode).toBe(200);
    const [lockRow, ringRow] = queued();
    expect(lockRow).toMatchObject({ type: "lock", payload: { byName: "Mama Sara" } });
    expect(ringRow.type).toBe("ring");
    expect(ringRow.payload).toEqual({});
    await app.close();
  });

  it("a rules change sends rules_updated with byName", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.ruleSet.findUnique.mockResolvedValue(rulesRow());
    prismaMock.ruleSet.upsert.mockResolvedValue(rulesRow());
    const res = await app.inject({
      method: "PATCH",
      url: "/v1/rules/child-1",
      headers: authHeader(app),
      payload: { screenTime: { dailyLimitMinutes: 90 } },
    });
    expect(res.statusCode, res.body).toBe(200);
    expect(queued()).toContainEqual(expect.objectContaining({
      type: "rules_updated",
      payload: { reason: "rules_changed", byName: "Mama Sara" },
    }));
    await app.close();
  });

  it("without a usable name nothing is stamped, so the phone shows its fallback", async () => {
    setParentName("   ");
    const app = await buildApp(controlsRoutes, "/v1/controls");
    const res = await app.inject({
      method: "POST",
      url: "/v1/controls/children/child-1/wind-down",
      headers: authHeader(app),
      payload: { minutes: 10 },
    });
    expect(res.statusCode, res.body).toBe(200);
    expect(queued()).toContainEqual(expect.objectContaining({ type: "wind_down", payload: { minutes: 10 } }));
    await app.close();
  });

  it("a coalesced pending rules_updated takes the latest actor, and is left alone when it is the same", async () => {
    const existing = {
      id: "c-old", deviceId: "dev-1", type: "rules_updated", payload: { reason: "rules_changed", byName: "Baba" },
      status: "pending", createdAt: new Date(), expiresAt: new Date(Date.now() + 60_000), attempts: 0,
    };
    prismaMock.deviceCommand.findFirst.mockResolvedValue(existing);
    prismaMock.deviceCommand.updateMany.mockResolvedValue({ count: 1 });
    const msg = await enqueueDeviceCommand("dev-1", "rules_updated", { reason: "rules_changed", byName: "Mama Sara" });
    expect(prismaMock.deviceCommand.updateMany).toHaveBeenCalledWith({
      where: { id: "c-old", status: "pending" },
      data: { payload: { reason: "rules_changed", byName: "Mama Sara" } },
    });
    expect(msg).toMatchObject({ id: "c-old", payload: { byName: "Mama Sara" } });
    expect(prismaMock.deviceCommand.create).not.toHaveBeenCalled();

    prismaMock.deviceCommand.updateMany.mockClear();
    await enqueueDeviceCommand("dev-1", "rules_updated", { reason: "rules_changed", byName: "Mama Sara" });
    expect(prismaMock.deviceCommand.updateMany).not.toHaveBeenCalled();
  });

  // Codex (#1237 [Sat] 1): overlapping edits by two adults, in both arrival orders.
  const pendingRules = (byName: string, rulesVersion: number) => ({
    id: "c-old", deviceId: "dev-1", type: "rules_updated", payload: { reason: "rules_changed", rulesVersion, byName },
    status: "pending", createdAt: new Date(), expiresAt: new Date(Date.now() + 60_000), attempts: 0,
  });

  it("newer version arrives second: the pending row takes the newer adult", async () => {
    prismaMock.deviceCommand.findFirst.mockResolvedValue(pendingRules("Baba", 5));
    prismaMock.deviceCommand.updateMany.mockResolvedValue({ count: 1 });
    const msg = await enqueueDeviceCommand("dev-1", "rules_updated", { reason: "rules_changed", rulesVersion: 6, byName: "Mama Sara" });
    expect(prismaMock.deviceCommand.updateMany).toHaveBeenCalledWith({
      where: { id: "c-old", status: "pending" },
      data: { payload: { reason: "rules_changed", rulesVersion: 6, byName: "Mama Sara" } },
    });
    expect(msg).toMatchObject({ id: "c-old", payload: { rulesVersion: 6, byName: "Mama Sara" } });
    expect(prismaMock.deviceCommand.create).not.toHaveBeenCalled();
  });

  it("older version arrives second: the pending row keeps the newer adult", async () => {
    prismaMock.deviceCommand.findFirst.mockResolvedValue(pendingRules("Mama Sara", 6));
    const msg = await enqueueDeviceCommand("dev-1", "rules_updated", { reason: "rules_changed", rulesVersion: 5, byName: "Baba" });
    expect(prismaMock.deviceCommand.updateMany).not.toHaveBeenCalled();
    expect(prismaMock.deviceCommand.create).not.toHaveBeenCalled();
    expect(msg).toMatchObject({ id: "c-old", payload: { rulesVersion: 6, byName: "Mama Sara" } });
  });

  it("the phone claimed the older row first: the newer change is queued as its own row", async () => {
    prismaMock.deviceCommand.findFirst.mockResolvedValue(pendingRules("Baba", 5));
    prismaMock.deviceCommand.updateMany.mockResolvedValue({ count: 0 });
    const msg = await enqueueDeviceCommand("dev-1", "rules_updated", { reason: "rules_changed", rulesVersion: 6, byName: "Mama Sara" });
    expect(queued()).toEqual([expect.objectContaining({
      type: "rules_updated", payload: { reason: "rules_changed", rulesVersion: 6, byName: "Mama Sara" },
    })]);
    expect(msg.id).not.toBe("c-old");
  });

  it("a rules write sends its committed version with the adult", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.ruleSet.findUnique.mockResolvedValue(rulesRow());
    prismaMock.ruleSet.upsert.mockResolvedValue({ ...rulesRow(), rulesVersion: 7 });
    const res = await app.inject({
      method: "PATCH",
      url: "/v1/rules/child-1",
      headers: authHeader(app),
      payload: { screenTime: { dailyLimitMinutes: 90 } },
    });
    expect(res.statusCode, res.body).toBe(200);
    expect(queued()).toContainEqual(expect.objectContaining({
      type: "rules_updated",
      payload: { reason: "rules_changed", rulesVersion: 7, byName: "Mama Sara" },
    }));
    await app.close();
  });
});
