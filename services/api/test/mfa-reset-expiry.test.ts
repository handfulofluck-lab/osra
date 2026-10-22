import { beforeEach, describe, expect, it, vi } from "vitest";
import { runMfaResetExpiry, startMfaResetExpiryScheduler, stopMfaResetExpiryScheduler } from "../src/jobs/mfaResetExpiry.js";
import { prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

/**
 * ADR-0031 expiry job. It does one thing per request kind and nothing else — in particular it sends
 * no mail, no push and no 24-hour reminder: those are templates that are not built yet (decision 4's
 * reminder step is deferred, recorded in the changelog fragment).
 */

const HOUR = 60 * 60 * 1000;
const DAY = 24 * HOUR;
const NOW = new Date("2026-10-22T12:00:00.000Z");

interface Row {
  id: string;
  parentId: string;
  state: string;
  createdAt: Date;
  emailConfirmedAt: Date | null;
  windowEndsAt: Date | null;
  outcomeAt: Date | null;
  codeHash: string | null;
}
interface CommandRow {
  id: string;
  deviceId: string;
  type: string;
  payload: Record<string, unknown>;
  status: string;
  expiresAt: Date;
}

let rows: Row[];
let commands: CommandRow[];

function install() {
  rows = [];
  commands = [];
  prismaMock.mfaResetRequest.updateMany.mockImplementation(async ({ where, data }: { where: Record<string, any>; data: Record<string, unknown> }) => {
    let count = 0;
    for (const row of rows) {
      if (row.state !== where.state) continue;
      if (where.emailConfirmedAt?.lte && !(row.emailConfirmedAt && row.emailConfirmedAt <= where.emailConfirmedAt.lte)) continue;
      if (where.createdAt?.lte && !(row.createdAt <= where.createdAt.lte)) continue;
      Object.assign(row, data);
      count += 1;
    }
    return { count };
  });
  prismaMock.mfaResetRequest.deleteMany.mockImplementation(async ({ where }: { where: { outcomeAt: { lt: Date } } }) => {
    const before = rows.length;
    rows = rows.filter((r) => !(r.outcomeAt && r.outcomeAt < where.outcomeAt.lt));
    return { count: before - rows.length };
  });
  prismaMock.$executeRaw.mockImplementation(async (strings: TemplateStringsArray, ...values: unknown[]) => {
    const sql = String(strings);
    if (!sql.includes("show_reset_code")) return 0;
    const cutoff = values[0] as Date;
    let count = 0;
    for (const command of commands) {
      if (command.type !== "show_reset_code" || command.expiresAt > cutoff) continue;
      if (typeof command.payload.code !== "string") continue;
      command.payload = {};
      count += 1;
    }
    return count;
  });
}

const row = (over: Partial<Row>): Row => ({
  id: `req-${rows.length + 1}`, parentId: "parent-1", state: "mailbox_confirmed",
  createdAt: new Date(NOW.getTime() - 2 * DAY), emailConfirmedAt: new Date(NOW.getTime() - 2 * DAY),
  windowEndsAt: null, outcomeAt: null, codeHash: "a".repeat(64), ...over,
});

describe("MFA reset expiry job (ADR-0031 decision 3 'expiry', decision 8 retention)", () => {
  beforeEach(() => {
    resetPrismaMock();
    install();
  });

  it("expires a request whose witness step is not done within 24 hours of the mailbox confirmation", async () => {
    rows.push(row({ id: "late", emailConfirmedAt: new Date(NOW.getTime() - 25 * HOUR) }));
    rows.push(row({ id: "on-time", emailConfirmedAt: new Date(NOW.getTime() - 23 * HOUR) }));

    const run = await runMfaResetExpiry(NOW);
    expect(run.witnessExpired).toBe(1);
    expect(rows.find((r) => r.id === "late")!.state).toBe("expired");
    expect(rows.find((r) => r.id === "late")!.outcomeAt).toEqual(NOW);
    expect(rows.find((r) => r.id === "on-time")!.state).toBe("mailbox_confirmed");
  });

  it("expires a request whose mailbox link was never clicked, so it does not block the next request forever", async () => {
    rows.push(row({ id: "never-confirmed", state: "requested", emailConfirmedAt: null, createdAt: new Date(NOW.getTime() - 25 * HOUR) }));
    rows.push(row({ id: "just-asked", state: "requested", emailConfirmedAt: null, createdAt: new Date(NOW.getTime() - 10 * 60_000) }));

    const run = await runMfaResetExpiry(NOW);
    expect(run.mailboxExpired).toBe(1);
    expect(rows.find((r) => r.id === "never-confirmed")!.state).toBe("expired");
    expect(rows.find((r) => r.id === "just-asked")!.state).toBe("requested");
  });

  it("leaves a passed witness alone: windowEndsAt opens `complete`, it does not close the request", async () => {
    rows.push(row({ id: "in-window", state: "witness_passed", windowEndsAt: new Date(NOW.getTime() + HOUR) }));
    rows.push(row({ id: "window-over", state: "witness_passed", windowEndsAt: new Date(NOW.getTime() - HOUR) }));

    const run = await runMfaResetExpiry(NOW);
    expect(run.witnessExpired).toBe(0);
    expect(run.mailboxExpired).toBe(0);
    expect(rows.map((r) => r.state)).toEqual(["witness_passed", "witness_passed"]);
  });

  it("clears the plaintext reset code from every show_reset_code payload at its expiry (claim 6)", async () => {
    commands.push({ id: "c1", deviceId: "dev-1", type: "show_reset_code", payload: { requestId: "req-1", code: "12345678" }, status: "delivered", expiresAt: new Date(NOW.getTime() - 1000) });
    commands.push({ id: "c2", deviceId: "dev-2", type: "show_reset_code", payload: { requestId: "req-1", code: "12345678" }, status: "pending", expiresAt: new Date(NOW.getTime() - 1000) });
    commands.push({ id: "c3", deviceId: "dev-1", type: "show_reset_code", payload: { requestId: "req-2", code: "87654321" }, status: "acked", expiresAt: new Date(NOW.getTime() + HOUR) });
    commands.push({ id: "c4", deviceId: "dev-1", type: "lock", payload: { reason: "bedtime" }, status: "pending", expiresAt: new Date(NOW.getTime() - 1000) });

    const run = await runMfaResetExpiry(NOW);
    expect(run.codesCleared).toBe(2);
    expect(JSON.stringify(commands)).not.toContain("12345678");
    expect(commands.find((c) => c.id === "c3")!.payload.code).toBe("87654321");
    expect(commands.find((c) => c.id === "c4")!.payload).toEqual({ reason: "bedtime" });
  });

  it("deletes rows 12 months after the outcome, per ADR-0031 decision 8", async () => {
    rows.push(row({ id: "old", state: "completed", outcomeAt: new Date(NOW.getTime() - 366 * DAY) }));
    rows.push(row({ id: "recent", state: "completed", outcomeAt: new Date(NOW.getTime() - 30 * DAY) }));
    rows.push(row({ id: "open", state: "witness_passed", outcomeAt: null }));

    const run = await runMfaResetExpiry(NOW);
    expect(run.retentionDeleted).toBe(1);
    expect(rows.map((r) => r.id).sort()).toEqual(["open", "recent"]);
  });

  it("sends no email, push or reminder (the templates are not built)", async () => {
    rows.push(row({ id: "expiring", emailConfirmedAt: new Date(NOW.getTime() - 25 * HOUR) }));
    await runMfaResetExpiry(NOW);
    expect(prismaMock.parentPushToken.findMany).not.toHaveBeenCalled();
    expect(prismaMock.deviceCommand.create).not.toHaveBeenCalled();
    expect(prismaMock.alert.create).not.toHaveBeenCalled();
  });

  it("respects JOBS_ENABLED=0 and NODE_ENV=test (no timer started)", () => {
    expect(() => startMfaResetExpiryScheduler({ JOBS_ENABLED: "0" } as NodeJS.ProcessEnv)).not.toThrow();
    expect(() => startMfaResetExpiryScheduler({ NODE_ENV: "test" } as NodeJS.ProcessEnv)).not.toThrow();
    stopMfaResetExpiryScheduler();
  });
});
