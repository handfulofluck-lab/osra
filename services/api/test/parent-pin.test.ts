import { readFileSync } from "node:fs";
import { Writable } from "node:stream";
import Fastify from "fastify";
import fastifyJwt from "@fastify/jwt";
import argon2 from "argon2";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { prismaMock, resetPrismaMock, buildApp, authHeader, deviceHeader } from "./helpers.js";

vi.mock("../src/db.js", () => ({ prisma: prismaMock }));
vi.mock("../src/redis.js", async () => {
  const { MockRedis } = await import("./helpers.js");
  const redis = new MockRedis();
  return {
    getRedis: () => redis,
    publishJson: vi.fn(async () => undefined),
    setJson: vi.fn(async () => undefined),
    getJson: vi.fn(async () => null),
    setJsonNx: vi.fn(async () => true),
  };
});
vi.mock("argon2", () => ({
  default: { verify: vi.fn(async () => true), hash: vi.fn(async () => "argon2$stub") },
}));
vi.mock("../src/lib/mfaVerify.js", () => ({ verifyTotpFresh: vi.fn(async () => false) }));
vi.mock("../src/lib/alerts.js", () => ({ raiseAlertOnce: vi.fn(async () => ({ alert: { id: "al-1" }, deduplicated: false })) }));

import { deviceRoutes } from "../src/routes/devices.js";
import { publishJson } from "../src/redis.js";
import { raiseAlertOnce } from "../src/lib/alerts.js";
import { verifyTotpFresh } from "../src/lib/mfaVerify.js";
import { ackDeviceCommand, listDeviceCommands, ttlFor, wakeForDeviceCommand } from "../src/lib/deviceCommands.js";
import { runMfaResetExpiry } from "../src/jobs/mfaResetExpiry.js";
import { registerErrorHandler } from "../src/lib/errorHandler.js";
import { LOGGER_REDACT, LOGGER_SERIALIZERS } from "../src/lib/logRedaction.js";
import {
  PARENT_PIN_KDF,
  hashParentPin,
  isPrehashedParentPin,
  normalizePinDigits,
  parentPinValidationError,
  verifyParentPinForTest,
} from "../src/lib/parentPin.js";

/**
 * #1108: "Change device PIN" — Ahmed's R3 ruling (7151514667), option A, conditions 1–7. Each describe below
 * names the condition it pins.
 */

const PIN = "4729";
const PASSWORD = "correct horse battery staple";
const DEVICE = {
  id: "dev-1",
  childId: "child-1",
  platform: "android",
  model: "Galaxy Z Flip4",
  pairedAt: new Date(),
  child: { id: "child-1", familyId: "fam-1", displayName: "Sara" },
};
const PARENT = { id: "parent-1", familyId: "fam-1", displayName: "Karim", role: "owner", passwordHash: "argon2$x", mfaEnabled: false, mfaSecret: null, permissions: [] };

function primeHappyPath() {
  prismaMock.device.findUnique.mockResolvedValue(DEVICE);
  prismaMock.parent.findUnique.mockResolvedValue(PARENT);
  prismaMock.consentRecord.findFirst.mockResolvedValue({ id: "c-1", childId: "child-1", grantedAt: new Date(), revokedAt: null });
  prismaMock.deviceCommand.count.mockResolvedValue(0);
  prismaMock.deviceCommand.updateMany.mockResolvedValue({ count: 0 });
  prismaMock.deviceCommand.create.mockImplementation(async ({ data }: { data: Record<string, unknown> }) => ({
    id: "cmd-pin-1",
    status: "pending",
    attempts: 0,
    createdAt: new Date(),
    ...data,
  }));
}

async function post(app: Awaited<ReturnType<typeof buildApp>>, payload: Record<string, unknown>, deviceId = "dev-1") {
  return app.inject({ method: "POST", url: `/v1/devices/${deviceId}/parent-pin`, headers: authHeader(app), payload });
}

beforeEach(() => {
  resetPrismaMock();
  vi.mocked(publishJson).mockClear();
  vi.mocked(raiseAlertOnce).mockClear();
  vi.mocked(argon2.verify).mockResolvedValue(true);
  vi.mocked(verifyTotpFresh).mockResolvedValue(false);
});

describe("the API's KDF is the phone's (shared vectors, condition 3)", () => {
  const rows = readFileSync(new URL("../../../docs/test-vectors/parent-pin.tsv", import.meta.url), "utf8")
    .split("\n")
    .filter((l) => l && !l.startsWith("#"))
    .map((l) => l.split("\t").map((c) => (c === "<empty>" ? "" : c)));

  it("refuses and accepts exactly the PINs the phone does", () => {
    const validate = rows.filter((r) => r[0] === "validate");
    expect(validate.length).toBeGreaterThan(10);
    for (const [, pin, want] of validate) expect(parentPinValidationError(pin)).toBe(want === "ok" ? null : want);
  });

  it("reads every stored hash in the vectors the way the phone does", async () => {
    const verify = rows.filter((r) => r[0] === "verify");
    expect(verify.length).toBeGreaterThan(4);
    for (const [, pin, stored, want] of verify) expect(await verifyParentPinForTest(pin, stored)).toBe(want === "true");
  });

  it("writes the phone's format with a fresh 16-byte salt and the shared iteration count", async () => {
    const a = await hashParentPin(PIN);
    const b = await hashParentPin(PIN);
    expect(a).not.toBe(b);
    for (const h of [a, b]) {
      expect(isPrehashedParentPin(h)).toBe(true);
      const [, iterations, salt, key] = h.split("$");
      expect(Number(iterations)).toBe(PARENT_PIN_KDF.iterations);
      expect(Buffer.from(salt, "base64")).toHaveLength(16);
      expect(Buffer.from(key, "base64")).toHaveLength(32);
      expect(await verifyParentPinForTest(PIN, h)).toBe(true);
      expect(await verifyParentPinForTest("4728", h)).toBe(false);
    }
  });

  it("hashes an Arabic-keyboard PIN as the same PIN (#771)", async () => {
    expect(normalizePinDigits("٤٧۲۹")).toBe("4729");
    expect(await verifyParentPinForTest(PIN, await hashParentPin("٤٧٢٩"))).toBe(true);
  });

  it("matches the known vector byte for byte for a fixed salt", async () => {
    const salt = Buffer.from("AAECAwQFBgcICQoLDA0ODw==", "base64");
    expect(await hashParentPin(PIN, salt)).toBe("pbkdf2$120000$AAECAwQFBgcICQoLDA0ODw==$Zz5BjmcTJWsWodarg1ATvRcZTtRsaDM8dnrc7YvWMjo=");
  });
});

describe("POST /v1/devices/:id/parent-pin", () => {
  it("queues one set_parent_pin row holding only the hash, with a 15-minute TTL, and returns no payload", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    primeHappyPath();
    const before = Date.now();
    const res = await post(app, { pin: PIN, password: PASSWORD });
    expect(res.statusCode).toBe(202);
    const body = res.json();
    expect(body).toEqual({ published: true, status: "pending", id: "cmd-pin-1", expiresAt: expect.any(String) });
    expect(res.body).not.toContain("pbkdf2");
    expect(res.body).not.toContain(PIN);

    const data = prismaMock.deviceCommand.create.mock.calls[0][0].data;
    expect(data).toMatchObject({ deviceId: "dev-1", type: "set_parent_pin", requestedBy: "parent-1" });
    expect(Object.keys(data.payload)).toEqual(["pinHash"]);
    expect(isPrehashedParentPin(data.payload.pinHash)).toBe(true);
    expect(await verifyParentPinForTest(PIN, data.payload.pinHash)).toBe(true);
    expect(ttlFor("set_parent_pin")).toBe(15 * 60);
    expect(data.expiresAt.getTime() - before).toBeLessThanOrEqual(15 * 60 * 1000 + 100);
    await app.close();
  });

  it("refuses an iPhone (or any non-Android) device without queueing", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    primeHappyPath();
    prismaMock.device.findUnique.mockResolvedValue({ ...DEVICE, platform: "ios" });
    const res = await post(app, { pin: PIN, password: PASSWORD });
    expect(res.statusCode).toBe(409);
    expect(res.json()).toEqual({ error: "command_not_supported" });
    expect(prismaMock.deviceCommand.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("refuses a weak or malformed PIN with a code, not the PIN", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    primeHappyPath();
    for (const [pin, code] of [["1234", "pin_weak"], ["7777", "pin_weak"], ["472", "pin_too_short"], ["47a9", "pin_not_digits"], ["472947294", "pin_too_long"]]) {
      const res = await post(app, { pin, password: PASSWORD });
      expect(res.statusCode).toBe(400);
      expect(res.json()).toEqual({ error: code });
    }
    expect(prismaMock.deviceCommand.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("refuses a body with extra fields (a parent cannot hand the API a hash of their own)", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    primeHappyPath();
    const res = await post(app, { pin: PIN, password: PASSWORD, pinHash: "pbkdf2$120000$x$y" });
    expect(res.statusCode).toBe(400);
    expect(res.json()).toEqual({ error: "invalid_body" });
    expect(res.body).not.toContain(PASSWORD);
    await app.close();
  });

  it("is not reachable with a device token", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    primeHappyPath();
    const res = await app.inject({ method: "POST", url: "/v1/devices/dev-1/parent-pin", headers: deviceHeader(app), payload: { pin: PIN, password: PASSWORD } });
    expect(res.statusCode).toBe(403);
    expect(prismaMock.deviceCommand.create).not.toHaveBeenCalled();
    await app.close();
  });
});

describe("re-auth and limits (condition 4)", () => {
  it("a wrong password is 401 reauth_failed and queues nothing", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    primeHappyPath();
    vi.mocked(argon2.verify).mockResolvedValue(false);
    const res = await post(app, { pin: PIN, password: "wrong" });
    expect(res.statusCode).toBe(401);
    expect(res.json()).toEqual({ error: "reauth_failed" });
    expect(prismaMock.deviceCommand.create).not.toHaveBeenCalled();
    expect(prismaMock.deviceCommand.updateMany).not.toHaveBeenCalled();
    await app.close();
  });

  it("with MFA on, the password alone is not enough and a fresh code is", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    primeHappyPath();
    prismaMock.parent.findUnique.mockResolvedValue({ ...PARENT, mfaEnabled: true, mfaSecret: "enc" });
    const noCode = await post(app, { pin: PIN, password: PASSWORD });
    expect(noCode.statusCode).toBe(401);
    vi.mocked(verifyTotpFresh).mockResolvedValue(true);
    const withCode = await post(app, { pin: PIN, password: PASSWORD, mfaCode: "123456" });
    expect(withCode.statusCode).toBe(202);
    await app.close();
  });

  it("a sixth change on the same device inside an hour is 429 and queues nothing", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    primeHappyPath();
    prismaMock.deviceCommand.count.mockResolvedValue(5);
    const res = await post(app, { pin: PIN, password: PASSWORD });
    expect(res.statusCode).toBe(429);
    expect(res.json()).toMatchObject({ error: "pin_change_limit" });
    expect(prismaMock.deviceCommand.create).not.toHaveBeenCalled();
    const where = prismaMock.deviceCommand.count.mock.calls[0][0].where;
    expect(where).toMatchObject({ deviceId: "dev-1", type: "set_parent_pin" });
    expect(Date.now() - where.createdAt.gte.getTime()).toBeGreaterThanOrEqual(60 * 60 * 1000 - 1000);
    await app.close();
  });

  it("carries the auth routes' fail-closed rate limit", () => {
    const source = readFileSync(new URL("../src/routes/devices.ts", import.meta.url), "utf8");
    expect(source).toMatch(/"\/:id\/parent-pin",\s*\{[\s\S]{0,300}config: \{ rateLimit: AUTH_RATE_LIMIT \}/);
  });
});

describe("pinHash is a secret: supersede, ack, expiry, history, pub/sub (condition 2)", () => {
  it("a new PIN supersedes the earlier ones still on their way and clears their hash", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    primeHappyPath();
    await post(app, { pin: PIN, password: PASSWORD });
    const supersede = prismaMock.deviceCommand.updateMany.mock.calls.find((c: any[]) => c[0].where?.type === "set_parent_pin");
    expect(supersede?.[0]).toMatchObject({
      where: { deviceId: "dev-1", type: "set_parent_pin", status: { in: ["pending", "delivered"] } },
      data: { status: "failed", payload: {}, result: { reason: "superseded" } },
    });
    // Superseded before the new row exists, so the new row is not closed by its own supersede.
    const supersedeOrder = prismaMock.deviceCommand.updateMany.mock.invocationCallOrder[0];
    expect(supersedeOrder).toBeLessThan(prismaMock.deviceCommand.create.mock.invocationCallOrder[0]);
    await app.close();
  });

  it("the ack clears the hash whatever the outcome", async () => {
    for (const outcome of ["ok", "failed"] as const) {
      resetPrismaMock();
      prismaMock.deviceCommand.updateMany.mockResolvedValue({ count: 1 });
      prismaMock.deviceCommand.findUnique.mockResolvedValue({ id: "cmd-pin-1", type: "set_parent_pin", payload: {} });
      await ackDeviceCommand("dev-1", "cmd-pin-1", outcome);
      const scrub = prismaMock.deviceCommand.updateMany.mock.calls.find((c: any[]) => c[0].where?.type === "set_parent_pin")?.[0];
      expect(scrub).toEqual({ where: { id: "cmd-pin-1", type: "set_parent_pin" }, data: { payload: {} } });
    }
  });

  it("the expiry sweep clears a hash the phone never acknowledged", async () => {
    prismaMock.mfaResetRequest.updateMany.mockResolvedValue({ count: 0 });
    prismaMock.mfaResetRequest.deleteMany.mockResolvedValue({ count: 0 });
    prismaMock.$executeRaw.mockResolvedValue(1);
    const now = new Date();
    const run = await runMfaResetExpiry(now);
    const sweep = prismaMock.$executeRaw.mock.calls.find((c: any[]) => c[0].join("?").includes("set_parent_pin"));
    expect(sweep).toBeDefined();
    const sql = sweep![0].join("?");
    expect(sql).toContain(`SET "payload" = '{}'::jsonb`);
    expect(sql).toContain(`"expiresAt" <= ?`);
    expect(sweep).toContain(now);
    expect(run.pinHashesCleared).toBe(1);
  });

  it("history never shows the hash, even on a row not yet cleared", async () => {
    prismaMock.deviceCommand.findMany.mockResolvedValue([
      { id: "cmd-pin-1", type: "set_parent_pin", payload: { pinHash: "pbkdf2$120000$a$b" }, status: "pending", expiresAt: new Date(Date.now() + 60_000), createdAt: new Date() },
    ]);
    const [row] = await listDeviceCommands("dev-1");
    expect(row.payload).toEqual({});
  });

  it("the pub/sub wake carries no hash", async () => {
    await wakeForDeviceCommand({ id: "cmd-pin-1", deviceId: "dev-1", type: "set_parent_pin", payload: { pinHash: "pbkdf2$120000$a$b" }, ts: "", expiresAt: "", attempt: 0 });
    expect(publishJson).toHaveBeenCalledWith("device:dev-1:commands", expect.objectContaining({ id: "cmd-pin-1", payload: {} }));
    expect(JSON.stringify(vi.mocked(publishJson).mock.calls)).not.toContain("pbkdf2");
  });
});

describe("audit and co-parent notice (condition 5)", () => {
  it("records an alert naming the parent, with no PIN and no hash", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    primeHappyPath();
    await post(app, { pin: PIN, password: PASSWORD });
    expect(raiseAlertOnce).toHaveBeenCalledTimes(1);
    const input = vi.mocked(raiseAlertOnce).mock.calls[0][0];
    expect(input).toMatchObject({
      childId: "child-1",
      familyId: "fam-1",
      deviceId: "dev-1",
      category: "security",
      metadata: { type: "parent_pin_changed", changedBy: "parent-1", commandId: "cmd-pin-1" },
    });
    expect(input.body).toContain("Karim");
    const text = JSON.stringify(input);
    expect(text).not.toContain(PIN);
    expect(text).not.toContain("pbkdf2");
    await app.close();
  });

  it("a failed audit write does not undo a PIN change that is already queued", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    primeHappyPath();
    vi.mocked(raiseAlertOnce).mockRejectedValueOnce(new Error("db down"));
    const res = await post(app, { pin: PIN, password: PASSWORD });
    expect(res.statusCode).toBe(202);
    await app.close();
  });
});

describe("the PIN and password never reach a log (condition 1)", () => {
  async function appWithCapturedLog() {
    const lines: string[] = [];
    const stream = new Writable({
      write(chunk, _enc, cb) {
        lines.push(chunk.toString());
        cb();
      },
    });
    const app = Fastify({ logger: { level: "trace", serializers: LOGGER_SERIALIZERS, redact: LOGGER_REDACT, stream } });
    await app.register(fastifyJwt, { secret: "test-secret" });
    registerErrorHandler(app);
    await app.register(deviceRoutes, { prefix: "/v1/devices" });
    await app.ready();
    return { app, lines };
  }

  it("on success, on refusal and on an audit failure, no line, error or response holds them", async () => {
    const { app, lines } = await appWithCapturedLog();
    primeHappyPath();
    const PIN2 = "58392176";
    const ok = await post(app, { pin: PIN2, password: PASSWORD });
    expect(ok.statusCode).toBe(202);
    vi.mocked(raiseAlertOnce).mockRejectedValueOnce(Object.assign(new Error("db down"), { body: { pin: PIN2, password: PASSWORD } }));
    const auditFail = await post(app, { pin: PIN2, password: PASSWORD });
    expect(auditFail.statusCode).toBe(202);
    vi.mocked(argon2.verify).mockResolvedValue(false);
    const wrong = await post(app, { pin: PIN2, password: PASSWORD });
    expect(wrong.statusCode).toBe(401);
    const bad = await post(app, { pin: PIN2, password: PASSWORD, extra: true });
    expect(bad.statusCode).toBe(400);

    expect(lines.length).toBeGreaterThan(4);
    const hash = prismaMock.deviceCommand.create.mock.calls[0][0].data.payload.pinHash as string;
    for (const text of [lines.join("\n"), ok.body, auditFail.body, wrong.body, bad.body]) {
      expect(text).not.toContain(PIN2);
      expect(text).not.toContain(PASSWORD);
      expect(text).not.toContain(hash);
    }
    // The audit failure was logged, so the redaction was exercised and not merely never reached.
    expect(lines.join("\n")).toContain("parent_pin_audit_not_recorded");
    await app.close();
  });

  it("Pino redacts the fields if one is ever attached to a log object", async () => {
    const { app, lines } = await appWithCapturedLog();
    app.log.info({ body: { pin: "8173", password: "p4ss-w0rd!", mfaCode: "654321" }, payload: { pinHash: "pbkdf2$120000$s$h" } }, "probe");
    const text = lines.join("\n");
    expect(text).toContain("probe");
    for (const secret of ["8173", "p4ss-w0rd!", "654321", "pbkdf2$120000$s$h"]) expect(text).not.toContain(secret);
    await app.close();
  });
});
