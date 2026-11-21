import { beforeEach, describe, expect, it, vi } from "vitest";
import Fastify, { type FastifyInstance } from "fastify";
import fastifyJwt from "@fastify/jwt";
import { controlsRoutes } from "../src/routes/controls.js";
import { deviceRoutes } from "../src/routes/devices.js";
import { rulesRoutes } from "../src/routes/rules.js";
import { getRedis } from "../src/redis.js";
import { MockRedis, authHeader, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

const CHILD = { id: "child-1", familyId: "fam-1" };
const DEVICES = [{ id: "dev-1" }, { id: "dev-2" }];
const INTERNET_PATH = "/v1/controls/children/child-1";
const PAUSED_KEY = "child:child-1:internet-paused";

/** In-memory Redis state so pause/status/resume round-trips behave like a real store. */
const store = new Map<string, string>();

function wireRedis(): MockRedis {
  const redis = getRedis() as unknown as MockRedis;
  redis.get.mockImplementation(async (key: string) => store.get(key) ?? null);
  redis.set.mockImplementation(async (key: string, value: unknown) => {
    store.set(key, String(value));
    return "OK";
  });
  redis.del.mockImplementation(async (...keys: string[]) =>
    keys.reduce((n, k) => n + (store.delete(k) ? 1 : 0), 0),
  );
  redis.publish.mockClear().mockResolvedValue(1);
  redis.lpush.mockResolvedValue(1);
  redis.ltrim.mockResolvedValue("OK");
  return redis;
}

/** Build one app with the device, rules and controls families mounted, mirroring server.ts. */
async function buildFullApp(): Promise<FastifyInstance> {
  const app = Fastify({ logger: false });
  await app.register(fastifyJwt, { secret: "test-secret" });
  await app.register(deviceRoutes, { prefix: "/v1/devices" });
  await app.register(rulesRoutes, { prefix: "/v1/rules" });
  await app.register(controlsRoutes, { prefix: "/v1/controls" });
  await app.ready();
  return app;
}

/** Flat Prisma RuleSet row as the upsert/findUnique mocks would return it. */
function flatRuleSet(bonusMinutesToday = 0) {
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
    alwaysAllowedApps: ["com.android.chrome"],
    bonusMinutesToday,
    updatedAt: "2026-09-16T00:00:00.000Z",
  };
}

/** Phase 2b: commands are durable rows — assert on the store, not on a Redis list. */
function queuedCommands(): Array<{ deviceId: string; type: string; payload: Record<string, unknown> }> {
  return prismaMock.deviceCommand.create.mock.calls.map(([arg]: [{ data: { deviceId: string; type: string; payload: Record<string, unknown> } }]) => arg.data);
}

/** Echo the transaction's persisted rows so the next GET sees the exact IDs created by POST. */
function wireInternetOperation() {
  const requestedAt = new Date("2026-11-21T03:00:00.000Z");
  let operation: Record<string, unknown> | null = null;
  const commands: Array<Record<string, unknown>> = [];
  prismaMock.child.findUnique.mockResolvedValue(CHILD);
  prismaMock.$queryRaw.mockResolvedValue([{ id: CHILD.id }]);
  prismaMock.device.findMany.mockResolvedValue(DEVICES);
  prismaMock.childInternetOperation.findUnique.mockImplementation(async () => operation);
  prismaMock.childInternetOperation.upsert.mockImplementation(async ({ create }: { create: Record<string, unknown> }) => {
    operation = { id: "op-1", generation: 1, requestedAt, ...create };
    return operation;
  });
  prismaMock.deviceCommand.createManyAndReturn.mockImplementation(async ({ data }: { data: Array<Record<string, unknown>> }) => {
    const rows = data.map((command, index) => ({
      id: `cmd-${index + 1}`,
      status: "pending",
      attempts: 0,
      createdAt: requestedAt,
      deliveredAt: null,
      ackedAt: null,
      result: null,
      ...command,
    }));
    commands.push(...rows);
    return rows;
  });
  prismaMock.deviceCommand.findMany.mockImplementation(async () => commands);
  return commands;
}

describe("controls routes (features #10/#11)", () => {
  beforeEach(() => {
    resetPrismaMock();
    store.clear();
    wireRedis();
  });

  it("returns the legacy paused-only shape when the child has no durable internet request", async () => {
    const app = await buildFullApp();
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.childInternetOperation.findUnique.mockResolvedValue(null);
    try {
      const getStatus = () => app.inject({ url: `${INTERNET_PATH}/status`, headers: authHeader(app) });
      const unset = await getStatus();
      expect(unset.statusCode).toBe(200);
      expect(unset.json()).toEqual({ paused: false });

      store.set(PAUSED_KEY, JSON.stringify({ pausedAt: "2026-09-16T10:00:00.000Z" }));
      const legacyPaused = await getStatus();
      expect(legacyPaused.statusCode).toBe(200);
      expect(legacyPaused.json()).toEqual({ paused: true });
      expect(prismaMock.deviceCommand.findMany).not.toHaveBeenCalled();
    } finally {
      await app.close();
    }
  });

  it.each([
    ["pause-internet", "pause", true],
    ["pause", "pause", true],
    ["resume-internet", "resume", false],
    ["resume", "resume", false],
  ] as const)("%s stores one request and its devices in a single transaction", async (path, action, paused) => {
    const app = await buildFullApp();
    const commands = wireInternetOperation();
    const redis = getRedis() as unknown as MockRedis;
    if (!paused) store.set(PAUSED_KEY, JSON.stringify({ pausedAt: "2026-09-16T10:00:00.000Z" }));
    prismaMock.$transaction.mockImplementationOnce(async (transaction: (tx: typeof prismaMock) => Promise<unknown>) => {
      expect(prismaMock.childInternetOperation.upsert).not.toHaveBeenCalled();
      expect(prismaMock.deviceCommand.createManyAndReturn).not.toHaveBeenCalled();
      const result = await transaction(prismaMock);
      expect(prismaMock.deviceCommand.createManyAndReturn).toHaveBeenCalledTimes(1);
      expect(prismaMock.childInternetOperation.upsert).toHaveBeenCalledTimes(1);
      expect(redis.publish).not.toHaveBeenCalled();
      return result;
    });
    try {
      const result = await app.inject({ method: "POST", url: `${INTERNET_PATH}/${path}`, headers: authHeader(app) });
      expect(result.statusCode).toBe(200);
      expect(result.json()).toEqual({ childId: CHILD.id, paused });
      expect(prismaMock.$transaction).toHaveBeenCalledTimes(1);
      expect(prismaMock.$queryRaw).toHaveBeenCalled();
      expect(commands).toHaveLength(2);
      expect(commands).toEqual(expect.arrayContaining(DEVICES.map(({ id }) =>
        expect.objectContaining({ deviceId: id, type: `${action}_internet` }),
      )));
      for (const { id } of DEVICES) {
        expect(redis.publish).toHaveBeenCalledWith(
          `device:${id}:commands`,
          expect.stringContaining(`"type":"${action}_internet"`),
        );
      }

      const status = await app.inject({ url: `${INTERNET_PATH}/status`, headers: authHeader(app) });
      expect(status.statusCode).toBe(200);
      expect(status.json()).toEqual({
        paused,
        internetRequest: {
          id: expect.any(String),
          generation: 1,
          action,
          requestedAt: expect.any(String),
          devices: expect.arrayContaining(commands.map(({ id, deviceId }) => ({ deviceId, commandId: id, status: "pending" }))),
        },
      });
      expect(status.json().internetRequest.devices).toHaveLength(2);
    } finally {
      await app.close();
    }
  });

  it("reports only the latest request's exact command receipts, with unknown for unmatched devices", async () => {
    const app = await buildFullApp();
    const requestedAt = new Date("2026-11-21T03:00:00.000Z");
    const expiresAt = new Date(Date.now() + 60_000);
    const targets = [
      { deviceId: "dev-1", commandId: "cmd-1" },
      { deviceId: "dev-2", commandId: "cmd-2" },
      { deviceId: "dev-3", commandId: "cmd-3" },
      { deviceId: "dev-4", commandId: "cmd-4" },
      { deviceId: "dev-5", commandId: "cmd-5" },
      { deviceId: "dev-removed", commandId: "cmd-removed" },
    ];
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.childInternetOperation.findUnique.mockResolvedValue({
      id: "op-resume",
      childId: CHILD.id,
      generation: 2,
      desiredPaused: false,
      requestedAt,
      targets,
    });
    prismaMock.device.findMany.mockResolvedValue([
      ...targets.filter(({ deviceId }) => deviceId !== "dev-removed").map(({ deviceId }) => ({ id: deviceId })),
      { id: "dev-added" },
    ]);
    prismaMock.deviceCommand.findMany.mockResolvedValue([
      { id: "cmd-1", deviceId: "dev-1", type: "resume_internet", status: "acked", expiresAt },
      { id: "cmd-2", deviceId: "dev-2", type: "resume_internet", status: "failed", expiresAt },
      { id: "cmd-3", deviceId: "dev-3", type: "resume_internet", status: "delivered", expiresAt },
      { id: "cmd-4", deviceId: "dev-4", type: "pause_internet", status: "acked", expiresAt },
      { id: "cmd-5", deviceId: "dev-added", type: "resume_internet", status: "acked", expiresAt },
      { id: "cmd-older", deviceId: "dev-4", type: "resume_internet", status: "acked", expiresAt },
    ]);
    store.set(PAUSED_KEY, JSON.stringify({ pausedAt: "2026-09-16T10:00:00.000Z" }));
    try {
      const status = await app.inject({ url: `${INTERNET_PATH}/status`, headers: authHeader(app) });
      expect(status.statusCode).toBe(200);
      expect(status.json()).toMatchObject({
        paused: false,
        internetRequest: {
          id: "op-resume",
          generation: 2,
          action: "resume",
          requestedAt: requestedAt.toISOString(),
          devices: expect.arrayContaining([
            { deviceId: "dev-1", commandId: "cmd-1", status: "acked" },
            { deviceId: "dev-2", commandId: "cmd-2", status: "failed" },
            { deviceId: "dev-3", commandId: "cmd-3", status: "delivered" },
            { deviceId: "dev-4", commandId: "cmd-4", status: "unknown" },
            { deviceId: "dev-5", commandId: "cmd-5", status: "unknown" },
            { deviceId: "dev-removed", commandId: "cmd-removed", status: "unknown" },
            { deviceId: "dev-added", commandId: null, status: "unknown" },
          ]),
        },
      });
      expect(status.json().internetRequest.devices).toHaveLength(7);
      expect(prismaMock.childInternetOperation.findUnique).toHaveBeenCalledWith(
        expect.objectContaining({ where: { childId: CHILD.id } }),
      );
      const [commandRead] = prismaMock.deviceCommand.findMany.mock.calls[0];
      expect(commandRead.where.id.in).toEqual(expect.arrayContaining(["cmd-1", "cmd-2", "cmd-3", "cmd-4", "cmd-5"]));
      expect(commandRead.where.id.in).not.toContain("cmd-older");
      expect(commandRead.where.device.is ?? commandRead.where.device).toMatchObject({ childId: CHILD.id });
    } finally {
      await app.close();
    }
  });

  it("records the requested state with no command receipts when there are no target devices", async () => {
    const app = await buildFullApp();
    const commands = wireInternetOperation();
    prismaMock.device.findMany.mockResolvedValue([]);
    try {
      const result = await app.inject({ method: "POST", url: `${INTERNET_PATH}/pause`, headers: authHeader(app) });
      expect(result.statusCode).toBe(200);
      expect(result.json()).toEqual({ childId: CHILD.id, paused: true });
      expect(commands).toEqual([]);
      expect((getRedis() as unknown as MockRedis).publish).not.toHaveBeenCalled();

      const status = await app.inject({ url: `${INTERNET_PATH}/status`, headers: authHeader(app) });
      expect(status.statusCode).toBe(200);
      expect(status.json()).toMatchObject({ paused: true, internetRequest: { action: "pause", devices: [] } });
    } finally {
      await app.close();
    }
  });

  it("does not wake a device or project a pause when the transaction fails after creating command rows", async () => {
    const app = await buildFullApp();
    wireInternetOperation();
    const redis = getRedis() as unknown as MockRedis;
    prismaMock.childInternetOperation.upsert.mockRejectedValueOnce(new Error("synthetic operation write failure"));
    try {
      const result = await app.inject({ method: "POST", url: `${INTERNET_PATH}/pause`, headers: authHeader(app) });
      expect(result.statusCode).toBeGreaterThanOrEqual(500);
      expect(prismaMock.$transaction).toHaveBeenCalledTimes(1);
      expect(prismaMock.deviceCommand.createManyAndReturn).toHaveBeenCalledTimes(1);
      expect(redis.publish).not.toHaveBeenCalled();

      const status = await app.inject({ url: `${INTERNET_PATH}/status`, headers: authHeader(app) });
      expect(status.statusCode).toBe(200);
      expect(status.json()).toEqual({ paused: false });
    } finally {
      await app.close();
    }
  });

  it("returns 404 when the child disappears before the operation can be locked", async () => {
    const app = await buildFullApp();
    wireInternetOperation();
    prismaMock.$queryRaw.mockResolvedValue([]);
    try {
      const result = await app.inject({ method: "POST", url: `${INTERNET_PATH}/resume`, headers: authHeader(app) });
      expect(result.statusCode).toBe(404);
      expect(prismaMock.deviceCommand.createManyAndReturn).not.toHaveBeenCalled();
      expect(prismaMock.childInternetOperation.upsert).not.toHaveBeenCalled();
      expect((getRedis() as unknown as MockRedis).publish).not.toHaveBeenCalled();
    } finally {
      await app.close();
    }
  });

  it("bonus increments bonusMinutesToday, notifies devices, and is visible via GET /v1/rules", async () => {
    const app = await buildFullApp();
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.device.findMany.mockResolvedValue(DEVICES);
    // The upsert returns the post-increment row (15 = 0 + 15); a later grant would return 30.
    prismaMock.ruleSet.upsert.mockResolvedValue(flatRuleSet(15));
    prismaMock.ruleSet.findUnique.mockResolvedValue(flatRuleSet(15));

    const res = await app.inject({
      method: "POST",
      url: "/v1/controls/children/child-1/bonus",
      headers: authHeader(app),
      payload: { minutes: 15 },
    });
    expect(res.statusCode).toBe(200);
    expect(res.json().bonusMinutesToday).toBe(15);
    expect(res.json().alwaysAllowedApps).toEqual(["com.android.chrome"]);
    // Issue #475 review: a bonus is a rule write, so it bumps the version in the same statement. Without
    // this, a parent granting time while the phone is offline would see no "hasn't picked this up" line.
    expect(prismaMock.ruleSet.upsert).toHaveBeenCalledWith(
      expect.objectContaining({
        where: { childId: "child-1" },
        update: { bonusMinutesToday: { increment: 15 }, rulesVersion: { increment: 1 } },
      }),
    );

    const redis = getRedis() as unknown as MockRedis;
    for (const deviceId of ["dev-1", "dev-2"]) {
      expect(queuedCommands()).toContainEqual(expect.objectContaining({ deviceId, type: "bonus_time", payload: { minutes: 15 } }));
    }
    expect(redis.publish).toHaveBeenCalledWith(
      "child:child-1:rules",
      expect.stringContaining('"bonusMinutesToday":15'),
    );

    const rules = await app.inject({
      method: "GET",
      url: "/v1/rules/child-1",
      headers: authHeader(app),
    });
    expect(rules.statusCode).toBe(200);
    expect(rules.json().bonusMinutesToday).toBe(15);
    await app.close();
  });

  it("rejects non-positive or non-integer bonus minutes with 400", async () => {
    const app = await buildFullApp();
    prismaMock.child.findUnique.mockResolvedValue(CHILD);

    for (const minutes of [0, -5, 1.5, "15"]) {
      const res = await app.inject({
        method: "POST",
        url: "/v1/controls/children/child-1/bonus",
        headers: authHeader(app),
        payload: { minutes },
      });
      expect(res.statusCode).toBe(400);
    }
    expect(prismaMock.ruleSet.upsert).not.toHaveBeenCalled();
    await app.close();
  });

  it("wind-down fans wind_down {minutes} out to every device (Feature #22)", async () => {
    const app = await buildFullApp();
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.device.findMany.mockResolvedValue(DEVICES);

    const res = await app.inject({
      method: "POST",
      url: "/v1/controls/children/child-1/wind-down",
      headers: authHeader(app),
      payload: { minutes: 30 },
    });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ childId: "child-1", minutes: 30 });

    const redis = getRedis() as unknown as MockRedis;
    for (const deviceId of ["dev-1", "dev-2"]) {
      expect(redis.publish).toHaveBeenCalledWith(
        `device:${deviceId}:commands`,
        expect.stringContaining('"type":"wind_down"'),
      );
      expect(queuedCommands()).toContainEqual(expect.objectContaining({ deviceId, type: "wind_down", payload: { minutes: 30 } }));
    }
    await app.close();
  });

  it("rejects invalid wind-down minutes with 400", async () => {
    const app = await buildFullApp();
    prismaMock.child.findUnique.mockResolvedValue(CHILD);

    for (const minutes of [0, -10, 2.5, "30"]) {
      const res = await app.inject({
        method: "POST",
        url: "/v1/controls/children/child-1/wind-down",
        headers: authHeader(app),
        payload: { minutes },
      });
      expect(res.statusCode).toBe(400);
    }
    expect(prismaMock.device.findMany).not.toHaveBeenCalled();
    await app.close();
  });

  it("device command enum accepts the new world-class command types", async () => {
    const app = await buildFullApp();
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-1", childId: "child-1", child: { familyId: "fam-1" } });

    for (const command of ["pause_internet", "resume_internet", "bonus_time", "wind_down", "locate_now", "stop_ring"]) {
      const res = await app.inject({
        method: "POST",
        url: "/v1/devices/dev-1/command",
        headers: authHeader(app),
        payload: { command, payload: { minutes: 15 } },
      });
      expect(res.statusCode).toBe(200);
      expect(res.json().type).toBe(command);
    }
    await app.close();
  });

  it("enforces family isolation (403) on every child-scoped control route", async () => {
    const app = await buildFullApp();
    prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-2" });

    const routes: Array<[string, string, unknown?]> = [
      ["POST", "/v1/controls/children/child-1/pause-internet"],
      ["POST", "/v1/controls/children/child-1/resume-internet"],
      ["POST", `${INTERNET_PATH}/pause`],
      ["POST", `${INTERNET_PATH}/resume`],
      ["POST", "/v1/controls/children/child-1/bonus", { minutes: 15 }],
      ["POST", "/v1/controls/children/child-1/wind-down", { minutes: 15 }],
      ["GET", "/v1/controls/children/child-1/status"],
    ];
    for (const [method, url, payload] of routes) {
      const res = await app.inject({ method: method as "POST" | "GET", url, headers: authHeader(app, "fam-1"), payload });
      expect(res.statusCode).toBe(403);
    }
    expect(prismaMock.device.findMany).not.toHaveBeenCalled();
    expect(prismaMock.childInternetOperation.findUnique).not.toHaveBeenCalled();
    expect(prismaMock.$transaction).not.toHaveBeenCalled();
    expect(prismaMock.ruleSet.upsert).not.toHaveBeenCalled();
    await app.close();
  });

  it("rejects unauthenticated calls with 401", async () => {
    const app = await buildFullApp();

    const unauth = await app.inject({
      method: "POST",
      url: "/v1/controls/children/child-1/pause-internet",
    });
    expect(unauth.statusCode).toBe(401);

    const status = await app.inject({ method: "GET", url: "/v1/controls/children/child-1/status" });
    expect(status.statusCode).toBe(401);

    const bonus = await app.inject({
      method: "POST",
      url: "/v1/controls/children/child-1/bonus",
      payload: { minutes: 15 },
    });
    expect(bonus.statusCode).toBe(401);
    expect(prismaMock.device.findMany).not.toHaveBeenCalled();
    await app.close();
  });
});
