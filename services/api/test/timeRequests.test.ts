import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { FastifyInstance } from "fastify";
import { alertsRoutes } from "../src/routes/alerts.js";
import { authHeader, buildApp, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

const ALERT_ID = "time-request-1";
const CHILD_ID = "child-1";
const FAMILY = { id: "fam-1", region: "AE" };
const PARENTS = [
  { id: "parent-1", displayName: "Sarah", familyId: FAMILY.id, role: "owner", permissions: [] },
  { id: "parent-2", displayName: "Mariam", familyId: FAMILY.id, role: "co-parent", permissions: ["alerts", "rules"] },
];

type Resolution = {
  alertId: string;
  action: "grant" | "decline";
  minutes: number | null;
  actorName: string;
  resolvedAt: Date;
};

function wireTimeRequest() {
  const child = { id: CHILD_ID, familyId: FAMILY.id, family: FAMILY };
  const alert = {
    id: ALERT_ID,
    childId: CHILD_ID,
    category: "app_blocked",
    metadata: { requestType: "time", reason: "daily_limit", minutes: "15" },
    heldDuringSetup: false,
    child,
  };
  const state = { acknowledged: false, bonus: 0, commands: 0, resolution: null as Resolution | null };
  const parentFor = ({ where }: { where: { id: string } }) =>
    PARENTS.find((row) => row.id === where.id) ?? null;
  const consent = { childId: CHILD_ID, jurisdiction: FAMILY.region, revokedAt: null, expiresAt: null };
  prismaMock.parent.findUnique.mockImplementation(async (args) => parentFor(args));
  prismaMock.parent.findFirst.mockImplementation(async (args) => parentFor(args));
  prismaMock.family.findUnique.mockResolvedValue(FAMILY);
  prismaMock.alert.findUnique.mockImplementation(async () => ({ ...alert, ...state }));

  let failAck = false;
  let consentActive = true;
  let lastTransaction = Promise.resolve();
  prismaMock.$transaction.mockImplementation((work) => {
    // The real row lock serializes updates to this alert. This test double also keeps a private
    // copy until commit so a failed acknowledgement cannot publish a grant or command.
    const transaction = lastTransaction.then(async () => {
      const draft = { ...state };
      const tx = {
        $queryRaw: async () => [{ id: ALERT_ID }],
        parent: prismaMock.parent,
        consentRecord: { findFirst: async () => consentActive ? consent : null },
        alert: {
          findUnique: async () => ({
            ...alert,
            acknowledged: draft.acknowledged,
            timeRequestResolution: draft.resolution,
          }),
          update: async () => {
            if (failAck) throw new Error("ack write failed");
            draft.acknowledged = true;
            return { ...alert, acknowledged: true };
          },
        },
        timeRequestResolution: {
          create: async ({ data }: { data: Resolution }) => {
            draft.resolution = data;
            return data;
          },
        },
        ruleSet: {
          upsert: async ({ update }: { update: { bonusMinutesToday: { increment: number } } }) => {
            draft.bonus += update.bonusMinutesToday.increment;
            return { childId: CHILD_ID, bonusMinutesToday: draft.bonus };
          },
        },
        device: { findMany: async () => [{ id: "dev-1" }] },
        deviceCommand: {
          createManyAndReturn: async ({ data }: { data: Record<string, unknown>[] }) => {
            draft.commands += data.length;
            return data.map((row) => ({ ...row, id: "cmd-1", attempts: 0 }));
          },
        },
      };
      const result = await work(tx);
      Object.assign(state, draft);
      return result;
    });
    lastTransaction = transaction.then(() => undefined, () => undefined);
    return transaction;
  });

  return {
    state,
    failAck: () => { failAck = true; },
    removeConsent: () => { consentActive = false; },
  };
}

describe("request-keyed screen time decisions", () => {
  let app: FastifyInstance;
  let request: ReturnType<typeof wireTimeRequest>;
  beforeEach(async () => {
    resetPrismaMock();
    request = wireTimeRequest();
    app = await buildApp(alertsRoutes, "/v1/alerts");
  });
  afterEach(async () => {
    await app.close();
  });

  function resolve(payload: Record<string, unknown>, parentId = "parent-1") {
    return app.inject({
      method: "POST",
      url: `/v1/alerts/${ALERT_ID}/time-decision`,
      headers: authHeader(app, FAMILY.id, parentId),
      payload,
    });
  }

  it("grants once when the same parent submits the decision twice", async () => {
    const responses = await Promise.all([
      resolve({ action: "grant", minutes: 15 }),
      resolve({ action: "grant", minutes: 15 }),
    ]);
    expect(responses.map((r) => r.statusCode).sort()).toEqual([200, 409]);
    expect(request.state).toMatchObject({ acknowledged: true, bonus: 15, commands: 1 });
    expect(responses.find((r) => r.statusCode === 409)?.json().resolution)
      .toMatchObject({ actorName: "Sarah", action: "grant", minutes: 15 });
  });

  it("keeps the first decision when two caregivers answer the same request", async () => {
    const responses = await Promise.all([
      resolve({ action: "grant", minutes: 15 }),
      resolve({ action: "grant", minutes: 30 }, "parent-2"),
    ]);
    const winner = responses.find((r) => r.statusCode === 200)?.json().resolution;
    const duplicate = responses.find((r) => r.statusCode === 409)?.json().resolution;
    expect(winner).toBeDefined();
    expect(duplicate).toEqual(winner);
    expect(request.state).toMatchObject({ acknowledged: true, bonus: winner.minutes, commands: 1 });
  });

  it("rolls back a grant and queued commands if the acknowledgement fails", async () => {
    request.failAck();
    const res = await resolve({ action: "grant", minutes: 30 });
    expect(res.statusCode).toBe(500);
    expect(request.state).toEqual({ acknowledged: false, bonus: 0, commands: 0, resolution: null });
  });

  it("acknowledges Not today without granting bonus time", async () => {
    const res = await resolve({ action: "decline" });
    expect(res.statusCode).toBe(200);
    expect(res.json().resolution).toMatchObject({ actorName: "Sarah", action: "decline", minutes: null });
    expect(request.state).toMatchObject({ acknowledged: true, bonus: 0, commands: 0 });
  });

  it("rejects unsupported durations before writing or acknowledging", async () => {
    const res = await resolve({ action: "grant", minutes: 60 });
    expect(res.statusCode).toBe(400);
    expect(request.state).toEqual({ acknowledged: false, bonus: 0, commands: 0, resolution: null });
  });

  it("requires active consent before deciding a time request", async () => {
    request.removeConsent();
    const res = await resolve({ action: "grant", minutes: 15 });
    expect(res.statusCode).toBe(428);
    expect(res.json().error).toBe("parental_consent_required");
    expect(request.state).toEqual({ acknowledged: false, bonus: 0, commands: 0, resolution: null });
  });

  it("leaves a time request open when the ordinary acknowledgement route is used", async () => {
    const res = await app.inject({
      method: "POST",
      url: `/v1/alerts/${ALERT_ID}/ack`,
      headers: authHeader(app, FAMILY.id, "parent-1"),
    });
    expect(res.statusCode).toBe(409);
    expect(res.json().error).toBe("time_request_requires_decision");
    expect(prismaMock.alert.update).not.toHaveBeenCalled();
    expect(request.state).toEqual({ acknowledged: false, bonus: 0, commands: 0, resolution: null });
  });
});
