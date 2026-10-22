import { beforeEach, describe, expect, it, vi } from "vitest";
import argon2 from "argon2";
import { createHash } from "node:crypto";
import { authRoutes } from "../src/routes/auth.js";
import { deviceRoutes } from "../src/routes/devices.js";
import { encryptSecret } from "../src/lib/secretVault.js";
import { totpAtCounter } from "../src/lib/totp.js";
import { hashRecoveryCode } from "../src/lib/mfaRecovery.js";
import { authHeader, buildApp, deviceHeader, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

/**
 * ADR-0031 — MFA reset with a family witness and a 72-hour window.
 *
 * The tests own in-memory tables for `MfaResetRequest`, `DeviceCommand` and the parent rows, so the
 * state machine, the one-time confirm link, the 5-attempt counter and the plaintext-code rule are
 * exercised against state rather than against call counts. Redis is a Map, as in `auth.test.ts`.
 *
 * Numbers are written out (72 h, 24 h, 30 min, 10 min, five attempts) instead of imported from the
 * implementation: the ADR is the authority, and a test that reads its constants from the code under
 * test can pass while both are wrong.
 */

const PASSWORD = "CorrectHorseBatteryStaple!";
const SUBJECT_EMAIL = "subject@example.com";
const CO_PARENT_EMAIL = "coparent@example.com";
const GUARDIAN_EMAIL = "guardian@example.com";
const FOREIGN_EMAIL = "foreign@example.com";
const OLD_SECRET = "JBSWY3DPEHPK3PXP";
const WINDOW_MS = 72 * 60 * 60 * 1000;
const CODE_TTL_MS = 10 * 60 * 1000;

interface ParentRow {
  id: string;
  familyId: string;
  email: string;
  passwordHash: string;
  displayName: string;
  role: string;
  permissions: string[];
  mfaEnabled: boolean;
  mfaSecret: string | null;
}
interface ResetRow {
  id: string;
  parentId: string;
  familyId: string;
  state: string;
  createdAt: Date;
  emailConfirmedAt: Date | null;
  witnessKind: string | null;
  witnessRef: string | null;
  witnessAt: Date | null;
  windowEndsAt: Date | null;
  failedCodeAttempts: number;
  codeHash: string | null;
  codeExpiresAt: Date | null;
  completedAt: Date | null;
  cancelledReason: string | null;
  outcomeAt: Date | null;
}
interface DeviceRow {
  id: string;
  childId: string;
  familyId: string;
  model: string;
}
interface CommandRow {
  id: string;
  deviceId: string;
  type: string;
  payload: Record<string, unknown>;
  status: string;
  requestedBy: string | null;
  createdAt: Date;
  expiresAt: Date;
  attempts: number;
  ackedAt: Date | null;
  result: unknown;
}
interface CodeRow {
  id: string;
  parentId: string;
  codeHash: string;
  createdAt: Date;
  usedAt: Date | null;
}

let parents: ParentRow[];
let resets: ResetRow[];
let devices: DeviceRow[];
let commands: CommandRow[];
let codeRows: CodeRow[];
let store: Map<string, string>;
let seq: number;

const subject = () => parents.find((p) => p.email === SUBJECT_EMAIL)!;

/** Install the stateful mocks. `familyDevices` is how many paired devices fam-1 has. */
async function setup(opts: { familyDevices?: number; mfaEnabled?: boolean } = {}) {
  const app = await buildApp(authRoutes, "/v1/auth");
  seq = 0;
  parents = [];
  resets = [];
  commands = [];
  codeRows = [];
  store = new Map();
  const passwordHash = await argon2.hash(PASSWORD);
  parents.push({
    id: "parent-1", familyId: "fam-1", email: SUBJECT_EMAIL, passwordHash,
    displayName: "Subject Parent", role: "owner", permissions: [],
    mfaEnabled: opts.mfaEnabled ?? true, mfaSecret: encryptSecret(OLD_SECRET),
  });
  parents.push({
    id: "parent-2", familyId: "fam-1", email: CO_PARENT_EMAIL, passwordHash,
    displayName: "Co Parent", role: "co-parent", permissions: [], mfaEnabled: false, mfaSecret: null,
  });
  parents.push({
    id: "parent-3", familyId: "fam-1", email: GUARDIAN_EMAIL, passwordHash,
    displayName: "Guardian", role: "guardian", permissions: ["devices"], mfaEnabled: false, mfaSecret: null,
  });
  parents.push({
    id: "parent-4", familyId: "fam-2", email: FOREIGN_EMAIL, passwordHash,
    displayName: "Foreign Owner", role: "owner", permissions: [], mfaEnabled: false, mfaSecret: null,
  });
  devices = [];
  for (let i = 1; i <= (opts.familyDevices ?? 2); i++) {
    devices.push({ id: `dev-${i}`, childId: `child-${i}`, familyId: "fam-1", model: `Pixel ${i}` });
  }

  prismaMock.parent.findUnique.mockImplementation(async ({ where }: { where: { id?: string; email?: string } }) => {
    const p = where.email ? parents.find((x) => x.email === where.email) : parents.find((x) => x.id === where.id);
    return p ? { ...p } : null;
  });
  prismaMock.parent.update.mockImplementation(async ({ where, data }: { where: { id: string }; data: Record<string, unknown> }) => {
    const p = parents.find((x) => x.id === where.id)!;
    Object.assign(p, data);
    return { ...p };
  });
  prismaMock.parent.count.mockImplementation(async ({ where }: { where: { familyId: string; id?: { not: string }; role?: { in: string[] } } }) =>
    parents.filter((p) =>
      p.familyId === where.familyId &&
      (!where.id?.not || p.id !== where.id.not) &&
      (!where.role?.in || where.role.in.includes(p.role)),
    ).length,
  );
  prismaMock.device.count.mockImplementation(async ({ where }: { where: { child: { familyId: string } } }) =>
    devices.filter((d) => d.familyId === where.child.familyId).length,
  );
  prismaMock.device.findMany.mockImplementation(async ({ where }: { where: { child?: { familyId: string } } }) =>
    devices.filter((d) => !where.child || d.familyId === where.child.familyId),
  );
  prismaMock.device.findUnique.mockImplementation(async ({ where }: { where: { id: string } }) => {
    const d = devices.find((x) => x.id === where.id);
    return d ? { ...d, child: { familyId: d.familyId } } : null;
  });

  prismaMock.mfaResetRequest.create.mockImplementation(async ({ data }: { data: Partial<ResetRow> }) => {
    const row: ResetRow = {
      id: `req-${++seq}`, state: "requested", createdAt: new Date(),
      emailConfirmedAt: null, witnessKind: null, witnessRef: null, witnessAt: null,
      windowEndsAt: null, failedCodeAttempts: 0, codeHash: null, codeExpiresAt: null,
      completedAt: null, cancelledReason: null, outcomeAt: null, ...data,
    } as ResetRow;
    resets.push(row);
    return { ...row };
  });
  prismaMock.mfaResetRequest.findUnique.mockImplementation(async ({ where }: { where: { id: string } }) =>
    resets.find((r) => r.id === where.id) ?? null,
  );
  // #305 review item 4: `/login` reads the open ids before cancelling, so the code payloads can be
  // cleared; `request` reads the open states before superseding. The mock filters the same way
  // `updateMany` does and honours `select`, as Prisma does — a caller that asks only for `id` must not
  // be handed a `state` the real query would not return.
  prismaMock.mfaResetRequest.findMany.mockImplementation(async ({ where, select }: { where: Record<string, any>; select?: Record<string, boolean> }) =>
    resets
      .filter((r) => matches(r, where ?? {}))
      .map((r) =>
        select
          ? Object.fromEntries(Object.keys(select).filter((key) => select[key]).map((key) => [key, (r as unknown as Record<string, unknown>)[key]]))
          : { ...r },
      ),
  );
  const matches = (r: ResetRow, where: Record<string, any>): boolean => {
    if (where.id && r.id !== where.id) return false;
    if (where.parentId && r.parentId !== where.parentId) return false;
    if (where.state === undefined) return true;
    if (typeof where.state === "string") return r.state === where.state;
    return Array.isArray(where.state.in) && where.state.in.includes(r.state);
  };
  prismaMock.mfaResetRequest.updateMany.mockImplementation(async ({ where, data }: { where: Record<string, any>; data: Record<string, unknown> }) => {
    let count = 0;
    for (const row of resets) {
      if (!matches(row, where)) continue;
      if (where.emailConfirmedAt?.lte && !(row.emailConfirmedAt && row.emailConfirmedAt <= where.emailConfirmedAt.lte)) continue;
      if (where.createdAt?.lte && !(row.createdAt <= where.createdAt.lte)) continue;
      Object.assign(row, data);
      count += 1;
    }
    return { count };
  });
  prismaMock.mfaResetRequest.count.mockImplementation(async ({ where }: { where: Record<string, any> }) => {
    if (where.state?.in) return resets.filter((r) => r.parentId === where.parentId && where.state.in.includes(r.state)).length;
    if (where.createdAt?.gt) return resets.filter((r) => r.parentId === where.parentId && r.createdAt > where.createdAt.gt).length;
    return resets.filter((r) => r.parentId === where.parentId).length;
  });
  prismaMock.mfaResetRequest.deleteMany.mockImplementation(async ({ where }: { where: Record<string, any> }) => {
    const before = resets.length;
    resets = resets.filter((r) => !(where.outcomeAt?.lt && r.outcomeAt && r.outcomeAt < where.outcomeAt.lt));
    return { count: before - resets.length };
  });
  // The witness counter is a single atomic increment + RETURNING, as in lib/deviceCommands.ts.
  prismaMock.$queryRaw.mockImplementation(async (strings: TemplateStringsArray, ...values: unknown[]) => {
    if (String(strings).includes("failedCodeAttempts")) {
      const row = resets.find((r) => r.id === values[0] && r.state === "mailbox_confirmed");
      if (!row) return [];
      row.failedCodeAttempts += 1;
      return [{ failedCodeAttempts: row.failedCodeAttempts }];
    }
    return [{}];
  });

  prismaMock.parentMfaRecoveryCode.findFirst.mockImplementation(async ({ where }: { where: { parentId: string; codeHash: string } }) =>
    codeRows.find((r) => r.parentId === where.parentId && r.codeHash === where.codeHash) ?? null,
  );
  prismaMock.parentMfaRecoveryCode.count.mockImplementation(async ({ where }: { where: { parentId: string; usedAt?: null } }) =>
    codeRows.filter((r) => r.parentId === where.parentId && (where.usedAt === undefined || r.usedAt === null)).length,
  );
  prismaMock.parentMfaRecoveryCode.createMany.mockImplementation(async ({ data }: { data: Array<Omit<CodeRow, "id" | "usedAt">> }) => {
    for (const row of data) codeRows.push({ id: `code-${++seq}`, usedAt: null, ...row });
    return { count: data.length };
  });
  prismaMock.parentMfaRecoveryCode.deleteMany.mockImplementation(async ({ where }: { where: { parentId: string } }) => {
    const before = codeRows.length;
    codeRows = codeRows.filter((r) => r.parentId !== where.parentId);
    return { count: before - codeRows.length };
  });

  prismaMock.deviceCommand.create.mockImplementation(async ({ data }: { data: Record<string, unknown> }) => {
    const row: CommandRow = {
      id: `cmd-${++seq}`, status: "pending", attempts: 0, createdAt: new Date(),
      ackedAt: null, result: null, requestedBy: "system", ...data,
    } as CommandRow;
    commands.push(row);
    return { ...row };
  });
  prismaMock.deviceCommand.updateMany.mockImplementation(async ({ where, data }: { where: Record<string, any>; data: Record<string, unknown> }) => {
    let count = 0;
    for (const row of commands) {
      if (where.id && row.id !== where.id) continue;
      if (where.deviceId && row.deviceId !== where.deviceId) continue;
      if (where.type && row.type !== where.type) continue;
      Object.assign(row, data);
      count += 1;
    }
    return { count };
  });
  prismaMock.deviceCommand.findUnique.mockImplementation(async ({ where }: { where: { id: string } }) =>
    commands.find((c) => c.id === where.id) ?? null,
  );
  // The two raw sweeps: cancel/witness clear by requestId, the expiry job clears by command expiry.
  prismaMock.$executeRaw.mockImplementation(async (strings: TemplateStringsArray, ...values: unknown[]) => {
    const sql = String(strings);
    let count = 0;
    if (sql.includes("show_reset_code") && sql.includes("requestId")) {
      const requestId = String(values[0]);
      for (const row of commands) {
        if (row.type !== "show_reset_code" || row.payload?.requestId !== requestId) continue;
        if (typeof row.payload.code === "string") { row.payload = {}; count += 1; }
      }
    } else if (sql.includes("show_reset_code") && sql.includes("expiresAt")) {
      const now = values[0] as Date;
      for (const row of commands) {
        if (row.type !== "show_reset_code" || row.expiresAt > now) continue;
        if (typeof row.payload.code === "string") { row.payload = {}; count += 1; }
      }
    }
    return count;
  });

  const { getRedis } = await import("../src/redis.js");
  const redis = getRedis() as unknown as Record<string, ReturnType<typeof vi.fn>>;
  redis.get!.mockImplementation(async (k: string) => store.get(k) ?? null);
  redis.set!.mockImplementation(async (k: string, v: string) => { store.set(k, String(v)); return "OK"; });
  redis.del!.mockImplementation(async (...ks: string[]) => ks.reduce((n, k) => n + (store.delete(k) ? 1 : 0), 0));
  redis.eval!.mockImplementation(async (_s: string, _n: number, key: string) => {
    const v = store.get(key) ?? null;
    if (v !== null) store.delete(key);
    return v;
  });
  redis.incrby!.mockImplementation(async (k: string, n: number) => {
    const next = Number(store.get(k) ?? 0) + n;
    store.set(k, String(next));
    return next;
  });
  redis.smembers!.mockImplementation(async () => []);
  redis.sadd!.mockImplementation(async () => 1);
  redis.srem!.mockImplementation(async () => 1);
  redis.expire!.mockImplementation(async () => 1);

  return { app, parent: subject() };
}

const currentCounter = () => Math.floor(Date.now() / 1000 / 30);
const sessionVersion = () => Number(store.get("auth:session-version:parent-1") ?? 0);

const request = (app: Awaited<ReturnType<typeof setup>>["app"], body: Record<string, unknown> = {}) =>
  app.inject({
    method: "POST",
    url: "/v1/auth/mfa/reset/request",
    payload: { email: SUBJECT_EMAIL, password: PASSWORD, ...body },
  });

/** The confirm link is emailed (stub) and echoed in dev; take whichever the run produced. */
function confirmTokenFor(app: Awaited<ReturnType<typeof setup>>["app"], response: { json(): any }): string {
  const body = response.json();
  if (body.confirmToken) return body.confirmToken as string;
  const key = [...store.keys()].find((k) => k.startsWith("mfa:reset:confirm:"));
  if (!key) throw new Error("no mfa reset confirm record in the store");
  return app.jwt.sign(
    { sub: "parent-1", purpose: "mfa_reset_confirm", jti: key.slice("mfa:reset:confirm:".length) },
    { expiresIn: "30m" },
  );
}

const confirm = (app: Awaited<ReturnType<typeof setup>>["app"], token: string) =>
  app.inject({ method: "POST", url: "/v1/auth/mfa/reset/confirm", payload: { token } });

const witness = (app: Awaited<ReturnType<typeof setup>>["app"], requestId: string, code: string) =>
  app.inject({ method: "POST", url: "/v1/auth/mfa/reset/witness", payload: { requestId, code } });

const complete = (app: Awaited<ReturnType<typeof setup>>["app"], requestId: string, body: Record<string, unknown> = {}) =>
  app.inject({
    method: "POST",
    url: "/v1/auth/mfa/reset/complete",
    payload: { email: SUBJECT_EMAIL, password: PASSWORD, requestId, ...body },
  });

/** Request → confirm, returning the request row and the plaintext 8-digit code the devices received. */
async function reachMailboxStep(app: Awaited<ReturnType<typeof setup>>["app"]) {
  const requested = await request(app);
  expect(requested.statusCode).toBe(200);
  const requestId = requested.json().requestId as string;
  const confirmed = await confirm(app, confirmTokenFor(app, requested));
  expect(confirmed.statusCode).toBe(200);
  const code = commands.find((c) => c.type === "show_reset_code" && c.payload.requestId === requestId)
    ?.payload.code as string | undefined;
  return { requestId, row: resets.find((r) => r.id === requestId)!, code };
}

/** Run the witness step to a passed window. */
async function reachWindow(app: Awaited<ReturnType<typeof setup>>["app"]) {
  const { requestId, code } = await reachMailboxStep(app);
  const passed = await witness(app, requestId, code!);
  expect(passed.statusCode).toBe(200);
  return { requestId, resolved: passed.json() };
}

describe("MFA reset — request (ADR-0031 claim 1a, 7)", () => {
  beforeEach(() => resetPrismaMock());

  it("claim 1a: a wrong password gets exactly /login's refusal; an unknown address is indistinguishable", async () => {
    const { app } = await setup();
    const loginWrong = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: SUBJECT_EMAIL, password: "WrongHorseBatteryStaple!" } });
    const resetWrong = await request(app, { password: "WrongHorseBatteryStaple!" });
    expect(loginWrong.statusCode).toBe(401);
    expect(resetWrong.statusCode).toBe(loginWrong.statusCode);
    expect(resetWrong.json()).toEqual(loginWrong.json());

    const unknown = await request(app, { email: `nobody-${Date.now()}@example.com` });
    expect(unknown.statusCode).toBe(401);
    expect(unknown.json()).toEqual({ error: "invalid_credentials" });
    // Nothing was stored for a refused request.
    expect(prismaMock.mfaResetRequest.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("claim 7: a family with no paired device and no other owner/co-parent is refused with no_witness, and nothing is stored", async () => {
    const { app } = await setup({ familyDevices: 0 });
    // Only the subject is left in fam-1: the co-parent and guardian are removed for this case.
    parents = parents.filter((p) => p.id === "parent-1" || p.familyId !== "fam-1");

    const res = await request(app);
    expect(res.statusCode).toBe(409);
    expect(res.json()).toEqual({ error: "no_witness" });
    expect(resets).toHaveLength(0);
    expect(commands).toHaveLength(0);
    // The refusal's own rate-limit counter is all that may be touched: no reset row exists.
    expect(prismaMock.mfaResetRequest.create).not.toHaveBeenCalled();
    expect(prismaMock.deviceCommand.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("claim 1b: no show_reset_code command exists before the mailbox link is clicked", async () => {
    const { app } = await setup();
    const requested = await request(app);
    expect(requested.statusCode).toBe(200);
    expect(prismaMock.deviceCommand.create).not.toHaveBeenCalled();

    const confirmed = await confirm(app, confirmTokenFor(app, requested));
    expect(confirmed.statusCode).toBe(200);
    // One command per paired device of the family, each carrying the same code.
    const sent = commands.filter((c) => c.type === "show_reset_code");
    expect(sent.map((c) => c.deviceId).sort()).toEqual(["dev-1", "dev-2"]);
    const codes = new Set<string>(sent.map((c) => String(c.payload.code)));
    expect(codes.size).toBe(1);
    expect([...codes][0]).toMatch(/^\d{8}$/);
    expect(resets[0].codeHash).toBe(createHash("sha256").update([...codes][0]).digest("hex"));
    await app.close();
  });

  it("refuses an account without MFA: there is no second factor to reset", async () => {
    const { app } = await setup({ mfaEnabled: false });
    const res = await request(app);
    expect(res.statusCode).toBe(409);
    expect(res.json()).toEqual({ error: "mfa_not_enabled" });
    expect(resets).toHaveLength(0);
    await app.close();
  });

  it("limits: one open request per parent, and three requests per 30 days", async () => {
    const { app } = await setup();
    expect((await request(app)).statusCode).toBe(200);
    // Amendment 2026-10-22 (gap 3): a second request supersedes the parent's own open request instead
    // of being refused, and the superseded attempt still counts toward the three per 30 days.
    expect((await request(app)).statusCode).toBe(200);
    const open = resets.filter((r) => r.parentId === "parent-1" && ["requested", "mailbox_confirmed", "witness_passed"].includes(r.state));
    expect(open).toHaveLength(1);
    expect(resets.filter((r) => r.parentId === "parent-1")).toHaveLength(2);

    expect((await request(app)).statusCode).toBe(200);
    const fourth = await request(app);
    expect(fourth.statusCode).toBe(429);
    expect(fourth.json()).toEqual({ error: "reset_limit_reached" });
    // Three rows, three attempts: the limit counts superseded requests too, so superseding grants none.
    expect(resets.filter((r) => r.parentId === "parent-1")).toHaveLength(3);
    // A refused request must not supersede the open one it could not replace.
    expect(resets.filter((r) => r.parentId === "parent-1" && ["requested", "mailbox_confirmed", "witness_passed"].includes(r.state))).toHaveLength(1);
    await app.close();
  });
});

describe("MFA reset — a new request supersedes the parent's own open one (amendment 2026-10-22)", () => {
  beforeEach(() => resetPrismaMock());

  it("while the first is mailbox_confirmed: the second succeeds, the first expires, and its code is cleared", async () => {
    const { app } = await setup();
    const first = await reachMailboxStep(app);
    expect(first.row.state).toBe("mailbox_confirmed");
    const live = () => commands.filter((c) => c.type === "show_reset_code" && c.payload?.requestId === first.requestId && typeof c.payload?.code === "string");
    expect(live()).toHaveLength(2);

    const second = await request(app);
    expect(second.statusCode).toBe(200);
    const secondId = second.json().requestId as string;
    expect(secondId).not.toBe(first.requestId);
    expect(first.row.state).toBe("expired");
    expect(first.row.outcomeAt).toBeInstanceOf(Date);
    // The dead request's code must not keep showing on the child's phones for its remaining 10 minutes.
    expect(live()).toHaveLength(0);
    // Still exactly one open request — the new one.
    expect(resets.filter((r) => r.state !== "expired").map((r) => r.id)).toEqual([secondId]);

    // And the superseded request is closed for good: its own confirm link is spent for nothing.
    store.set("mfa:reset:confirm:stale", `${first.requestId}|parent-1`);
    const staleConfirm = await confirm(app, app.jwt.sign({ sub: "parent-1", purpose: "mfa_reset_confirm", jti: "stale" }, { expiresIn: "30m" }));
    expect(staleConfirm.statusCode).toBe(409);
    expect(staleConfirm.json()).toEqual({ error: "request_not_open" });
    expect(commands.filter((c) => c.payload?.requestId === first.requestId && typeof c.payload?.code === "string")).toHaveLength(0);
    await app.close();
  });

  it("while the first is requested: the second succeeds and the first expires", async () => {
    const { app } = await setup();
    expect((await request(app)).statusCode).toBe(200);
    expect(resets[0].state).toBe("requested");

    const second = await request(app);
    expect(second.statusCode).toBe(200);
    expect(resets[0].state).toBe("expired");
    expect(resets[0].outcomeAt).toBeInstanceOf(Date);
    expect(resets[1].state).toBe("requested");
    await app.close();
  });

  it("while the first is witness_passed: still 409 reset_already_pending, and nothing is touched", async () => {
    const { app } = await setup();
    const { requestId } = await reachWindow(app);
    const row = resets.find((r) => r.id === requestId)!;

    const second = await request(app);
    expect(second.statusCode).toBe(409);
    expect(second.json()).toEqual({ error: "reset_already_pending" });
    // A passed witness opened a window nobody may overwrite: the row is untouched and still the only one.
    expect(row.state).toBe("witness_passed");
    expect(row.outcomeAt).toBeNull();
    expect(new Date(row.windowEndsAt!).getTime()).toBeGreaterThan(Date.now());
    expect(resets.filter((r) => r.parentId === "parent-1")).toHaveLength(1);
    await app.close();
  });
});

describe("MFA reset — mailbox confirmation", () => {
  beforeEach(() => resetPrismaMock());

  it("the confirm link is single-use, 30 minutes, and only valid for its own purpose", async () => {
    const { app } = await setup();
    const requested = await request(app);
    const token = confirmTokenFor(app, requested);
    // The link's record lives exactly as long as the token: 30 minutes.
    expect([...store.keys()].filter((k) => k.startsWith("mfa:reset:confirm:"))).toHaveLength(1);

    const wrongPurpose = await confirm(app, app.jwt.sign({ sub: "parent-1", purpose: "password_reset", jti: "x" }));
    expect(wrongPurpose.statusCode).toBe(401);
    expect(wrongPurpose.json().error).toBe("invalid_or_expired_token");

    expect((await confirm(app, token)).statusCode).toBe(200);
    const replay = await confirm(app, token);
    expect(replay.statusCode).toBe(401);
    expect(replay.json().error).toBe("invalid_or_expired_token");
    expect([...store.keys()].filter((k) => k.startsWith("mfa:reset:confirm:"))).toHaveLength(0);
    await app.close();
  });

  it("a second confirm of an already-confirmed request changes nothing", async () => {
    const { app } = await setup();
    const requested = await request(app);
    const requestId = requested.json().requestId as string;
    expect((await confirm(app, confirmTokenFor(app, requested))).statusCode).toBe(200);
    const commandsAfterFirst = commands.length;

    // A fresh link for the same request (the route mints one per request, so the store can hold one).
    const jti = "second-confirm-jti";
    store.set(`mfa:reset:confirm:${jti}`, `${requestId}|parent-1`);
    const again = await confirm(app, app.jwt.sign({ sub: "parent-1", purpose: "mfa_reset_confirm", jti }, { expiresIn: "30m" }));
    expect(again.statusCode).toBe(409);
    expect(again.json()).toEqual({ error: "request_not_open" });
    expect(commands.length).toBe(commandsAfterFirst);
    expect(resets.find((r) => r.id === requestId)!.emailConfirmedAt).toBeInstanceOf(Date);
    await app.close();
  });

  it("a family with no paired device confirms into the parent-witness branch and sends nothing", async () => {
    const { app } = await setup({ familyDevices: 0 });
    const requested = await request(app);
    expect(requested.statusCode).toBe(200);
    const confirmed = await confirm(app, confirmTokenFor(app, requested));
    expect(confirmed.statusCode).toBe(200);
    expect(confirmed.json().witness).toBe("parent");
    expect(commands).toHaveLength(0);
    expect(resets[0].codeHash).toBeNull();
    await app.close();
  });
});

describe("MFA reset — witness (ADR-0031 claims 1c, 2)", () => {
  beforeEach(() => resetPrismaMock());

  it("claim 1c: five wrong codes end the request as too_many_attempts, and the real code no longer works", async () => {
    const { app } = await setup();
    const { requestId, code } = await reachMailboxStep(app);

    for (let attempt = 1; attempt <= 4; attempt++) {
      const res = await witness(app, requestId, String(attempt).padStart(8, "0"));
      expect(res.statusCode).toBe(401);
      expect(res.json().error).toBe("invalid_witness");
      expect(res.json().attemptsRemaining).toBe(5 - attempt);
      expect(resets[0].failedCodeAttempts).toBe(attempt);
    }
    const fifth = await witness(app, requestId, "99999999");
    expect(fifth.statusCode).toBe(401);
    expect(fifth.json().error).toBe("too_many_attempts");
    expect(resets[0].state).toBe("too_many_attempts");
    expect(resets[0].outcomeAt).toBeInstanceOf(Date);

    const late = await witness(app, requestId, code!);
    expect(late.statusCode).toBe(409);
    expect(late.json().error).toBe("request_not_open");
    expect(sessionVersion()).toBe(0);
    await app.close();
  });

  it("claim 2: passing the witness bumps the parent's session version by exactly one", async () => {
    const { app } = await setup();
    const { requestId, code } = await reachMailboxStep(app);
    expect(sessionVersion()).toBe(0);

    const passed = await witness(app, requestId, code!);
    expect(passed.statusCode).toBe(200);
    expect(passed.json().state).toBe("witness_passed");
    expect(sessionVersion()).toBe(1);

    // The window starts at the witness and is 72 hours long.
    const row = resets[0];
    expect(row.witnessKind).toBe("device");
    expect(row.witnessAt).toBeInstanceOf(Date);
    const span = row.windowEndsAt!.getTime() - row.witnessAt!.getTime();
    expect(span).toBe(WINDOW_MS);
    await app.close();
  });

  it("a code past its 10-minute life is refused without spending an attempt", async () => {
    const { app } = await setup();
    const { requestId, code } = await reachMailboxStep(app);
    const row = resets[0];
    expect(row.codeExpiresAt!.getTime() - Date.now()).toBeLessThanOrEqual(CODE_TTL_MS);
    row.codeExpiresAt = new Date(Date.now() - 1000);

    const res = await witness(app, requestId, code!);
    expect(res.statusCode).toBe(401);
    expect(res.json().error).toBe("invalid_witness");
    expect(row.failedCodeAttempts).toBe(0);
    await app.close();
  });

  it("the witness step needs the mailbox confirmation first", async () => {
    const { app } = await setup();
    const requested = await request(app);
    const requestId = requested.json().requestId as string;
    const early = await witness(app, requestId, "12345678");
    expect(early.statusCode).toBe(409);
    expect(early.json().error).toBe("request_not_open");
    expect(sessionVersion()).toBe(0);
    await app.close();
  });
});

describe("MFA reset — approve (ADR-0031 claim 4)", () => {
  beforeEach(() => resetPrismaMock());

  const approve = (app: Awaited<ReturnType<typeof setup>>["app"], headers: Record<string, string>, requestId: string) =>
    app.inject({ method: "POST", url: "/v1/auth/mfa/reset/approve", headers, payload: { requestId } });

  it("claim 4: an owner or co-parent of the family approves; the guardian and another family's owner are refused", async () => {
    const { app } = await setup({ familyDevices: 0 });
    const requested = await request(app);
    const requestId = requested.json().requestId as string;
    expect((await confirm(app, confirmTokenFor(app, requested))).statusCode).toBe(200);

    const guardian = await approve(app, authHeader(app, "fam-1", "parent-3"), requestId);
    expect(guardian.statusCode).toBe(403);
    expect(guardian.json()).toEqual({ error: "role_not_allowed" });

    const foreign = await approve(app, authHeader(app, "fam-2", "parent-4"), requestId);
    expect(foreign.statusCode).toBe(403);
    expect(foreign.json()).toEqual({ error: "forbidden" });

    const self = await approve(app, authHeader(app, "fam-1", "parent-1"), requestId);
    expect(self.statusCode).toBe(403);

    expect(resets[0].state).toBe("mailbox_confirmed");
    expect(sessionVersion()).toBe(0);

    const coParent = await approve(app, authHeader(app, "fam-1", "parent-2"), requestId);
    expect(coParent.statusCode).toBe(200);
    expect(coParent.json().state).toBe("witness_passed");
    expect(resets[0].witnessKind).toBe("parent");
    expect(resets[0].witnessRef).toBe("parent-2");
    expect(sessionVersion()).toBe(1);
    await app.close();
  });

  it("an owner of the family may approve as well", async () => {
    const { app } = await setup({ familyDevices: 0 });
    // Promote parent-2 to owner for this case.
    parents.find((p) => p.id === "parent-2")!.role = "owner";
    const requested = await request(app);
    const requestId = requested.json().requestId as string;
    expect((await confirm(app, confirmTokenFor(app, requested))).statusCode).toBe(200);

    const res = await approve(app, authHeader(app, "fam-1", "parent-2"), requestId);
    expect(res.statusCode).toBe(200);
    expect(resets[0].witnessRef).toBe("parent-2");
    await app.close();
  });

  it("approval needs the mailbox step: a request still awaiting the link is not open to approval", async () => {
    const { app } = await setup({ familyDevices: 0 });
    const requested = await request(app);
    const res = await approve(app, authHeader(app, "fam-1", "parent-2"), requested.json().requestId);
    expect(res.statusCode).toBe(409);
    expect(res.json().error).toBe("request_not_open");
    await app.close();
  });
});

describe("MFA reset — cancel (ADR-0031 decision 3)", () => {
  beforeEach(() => resetPrismaMock());

  it("the cancel link cancels without a sign-in", async () => {
    const { app } = await setup();
    const { requestId } = await reachMailboxStep(app);
    const token = app.jwt.sign({ sub: "parent-1", purpose: "mfa_reset_cancel", requestId }, { expiresIn: "7d" });

    const res = await app.inject({ method: "POST", url: "/v1/auth/mfa/reset/cancel", payload: { token } });
    expect(res.statusCode).toBe(200);
    expect(res.json().state).toBe("cancelled_by_link");
    expect(resets[0].cancelledReason).toBe("link");
    expect(resets[0].outcomeAt).toBeInstanceOf(Date);
    // The plaintext code does not outlive the cancellation.
    expect(JSON.stringify(commands)).not.toContain(resets[0].codeHash!);
    expect(commands.every((c) => c.payload.code === undefined)).toBe(true);

    // One click, no sign-in, and a second click keeps things as they are.
    expect((await app.inject({ method: "POST", url: "/v1/auth/mfa/reset/cancel", payload: { token } })).statusCode).toBe(200);
    await app.close();
  });

  it("another owner or co-parent cancels from their app; a guardian or a stranger cannot", async () => {
    const { app } = await setup();
    const { requestId } = await reachMailboxStep(app);

    const guardian = await app.inject({ method: "POST", url: "/v1/auth/mfa/reset/cancel", headers: authHeader(app, "fam-1", "parent-3"), payload: { requestId } });
    expect(guardian.statusCode).toBe(403);
    const foreign = await app.inject({ method: "POST", url: "/v1/auth/mfa/reset/cancel", headers: authHeader(app, "fam-2", "parent-4"), payload: { requestId } });
    expect(foreign.statusCode).toBe(403);
    const unauthenticated = await app.inject({ method: "POST", url: "/v1/auth/mfa/reset/cancel", payload: { requestId } });
    expect(unauthenticated.statusCode).toBe(401);
    expect(resets[0].state).toBe("mailbox_confirmed");

    const coParent = await app.inject({ method: "POST", url: "/v1/auth/mfa/reset/cancel", headers: authHeader(app, "fam-1", "parent-2"), payload: { requestId } });
    expect(coParent.statusCode).toBe(200);
    expect(coParent.json().state).toBe("cancelled_by_parent");
    expect(resets[0].cancelledReason).toBe("parent");
    await app.close();
  });

  it("a cancel link for another parent's request is refused", async () => {
    const { app } = await setup();
    const { requestId } = await reachMailboxStep(app);
    const token = app.jwt.sign({ sub: "parent-2", purpose: "mfa_reset_cancel", requestId }, { expiresIn: "7d" });
    const res = await app.inject({ method: "POST", url: "/v1/auth/mfa/reset/cancel", payload: { token } });
    expect(res.statusCode).toBe(401);
    expect(resets[0].state).toBe("mailbox_confirmed");
    await app.close();
  });
});

describe("MFA reset — complete (ADR-0031 claims 1d, 5)", () => {
  beforeEach(() => resetPrismaMock());

  it("claim 1d: complete before windowEndsAt changes nothing", async () => {
    const { app } = await setup();
    const { requestId } = await reachWindow(app);
    const secretBefore = subject().mfaSecret;
    const versionBefore = sessionVersion();
    const createsBefore = prismaMock.parentMfaRecoveryCode.createMany.mock.calls.length;

    const res = await complete(app, requestId);
    expect(res.statusCode).toBe(409);
    expect(res.json()).toEqual({ error: "window_open" });
    expect(res.json().recoveryToken).toBeUndefined();
    expect(subject().mfaSecret).toBe(secretBefore);
    expect(sessionVersion()).toBe(versionBefore);
    expect(resets[0].state).toBe("witness_passed");
    expect(resets[0].completedAt).toBeNull();
    expect(prismaMock.parentMfaRecoveryCode.createMany.mock.calls.length).toBe(createsBefore);
    await app.close();
  });

  it("claim 5: after the window it produces exactly ADR-0023's recovered state", async () => {
    const { app } = await setup();
    const { requestId } = await reachWindow(app);
    // Seed the batch a recovery would have to clear.
    await prismaMock.parentMfaRecoveryCode.createMany({ data: [{ parentId: "parent-1", codeHash: hashRecoveryCode("ABCD1234ABCD1234"), createdAt: new Date() }] });
    expect(codeRows).toHaveLength(1);
    const versionBeforeComplete = sessionVersion();
    resets[0].windowEndsAt = new Date(Date.now() - 1000);

    const res = await complete(app, requestId);
    expect(res.statusCode).toBe(200);
    expect(Object.keys(res.json())).toEqual(["recoveryToken"]);

    // ADR-0023's state: policy on, no bound factor, no codes left, sessions revoked.
    expect(subject().mfaEnabled).toBe(true);
    expect(subject().mfaSecret).toBeNull();
    expect(codeRows).toHaveLength(0);
    expect(sessionVersion()).toBe(versionBeforeComplete + 1);
    expect(resets[0].state).toBe("completed");
    expect(resets[0].completedAt).toBeInstanceOf(Date);
    expect(resets[0].outcomeAt).toBeInstanceOf(Date);

    // The token is the purpose-scoped recovery credential, not a session.
    const token = res.json().recoveryToken as string;
    const claims = app.jwt.verify(token) as { sub: string; purpose?: string; role?: string; familyId?: string; jti?: string };
    expect(claims.sub).toBe("parent-1");
    expect(claims.purpose).toBe("mfa_recovery");
    expect(claims.role).toBeUndefined();
    expect(claims.familyId).toBeUndefined();
    expect(store.get(`mfa:recovery:${claims.jti}`)).toBe("parent-1");

    const auth = { authorization: `Bearer ${token}` };
    for (const [method, url] of [
      ["POST", "/v1/auth/logout-all"],
      ["POST", "/v1/auth/mfa/recovery-codes"],
    ] as const) {
      const refused = await app.inject({ method, url, headers: auth, payload: {} });
      expect({ url, status: refused.statusCode }).toEqual({ url, status: 401 });
    }
    // /mfa/enroll and /mfa/verify are the only two routes that accept it.
    expect((await app.inject({ method: "POST", url: "/v1/auth/mfa/enroll", headers: auth, payload: {} })).statusCode).toBe(200);
    const secret = (await app.inject({ method: "POST", url: "/v1/auth/mfa/enroll", headers: auth, payload: {} })).json().secret as string;
    const verify = await app.inject({
      method: "POST",
      url: "/v1/auth/mfa/verify",
      headers: auth,
      payload: { code: totpAtCounter(secret, currentCounter() + 1) },
    });
    expect(verify.statusCode).toBe(200);
    expect(verify.json().recoveryCodes).toHaveLength(10);
    await app.close();
  });

  it("complete needs the account password, and only for its own request", async () => {
    const { app } = await setup();
    const { requestId } = await reachWindow(app);
    resets[0].windowEndsAt = new Date(Date.now() - 1000);

    const wrong = await complete(app, requestId, { password: "WrongHorseBatteryStaple!" });
    expect(wrong.statusCode).toBe(401);
    expect(wrong.json()).toEqual({ error: "invalid_credentials" });

    const unknown = await complete(app, "no-such-request");
    expect(unknown.statusCode).toBe(404);
    expect(unknown.json().error).toBe("request_not_found");
    expect(subject().mfaSecret).not.toBeNull();
    await app.close();
  });

  it("a cancelled request cannot be completed, whichever way it was cancelled", async () => {
    const { app } = await setup();
    const { requestId } = await reachWindow(app);
    resets[0].windowEndsAt = new Date(Date.now() - 1000);
    const token = app.jwt.sign({ sub: "parent-1", purpose: "mfa_reset_cancel", requestId }, { expiresIn: "7d" });
    await app.inject({ method: "POST", url: "/v1/auth/mfa/reset/cancel", payload: { token } });

    const res = await complete(app, requestId);
    expect(res.statusCode).toBe(409);
    expect(res.json()).toEqual({ error: "request_cancelled" });
    expect(subject().mfaSecret).not.toBeNull();
    await app.close();
  });

  it("a request whose witness step never happened cannot be completed", async () => {
    const { app } = await setup();
    const { requestId } = await reachMailboxStep(app);
    resets[0].emailConfirmedAt = new Date(Date.now() - 25 * 60 * 60 * 1000);
    const res = await complete(app, requestId);
    expect(res.statusCode).toBe(409);
    expect(res.json()).toEqual({ error: "witness_required" });
    await app.close();
  });
});

describe("MFA reset — a sign-in cancels it (ADR-0031 claim 3)", () => {
  beforeEach(() => resetPrismaMock());

  it("claim 3: a successful /login during the window sets cancelled_by_signin and complete is refused", async () => {
    const { app } = await setup();
    const { requestId } = await reachWindow(app);
    resets[0].windowEndsAt = new Date(Date.now() - 1000);

    const login = await app.inject({
      method: "POST",
      url: "/v1/auth/login",
      payload: { email: SUBJECT_EMAIL, password: PASSWORD, code: totpAtCounter(OLD_SECRET, currentCounter() + 1) },
    });
    expect(login.statusCode).toBe(200);
    expect(login.json().token).toBeTruthy();

    expect(resets[0].state).toBe("cancelled_by_signin");
    expect(resets[0].cancelledReason).toBe("signin");
    expect(resets[0].outcomeAt).toBeInstanceOf(Date);

    const res = await complete(app, requestId);
    expect(res.statusCode).toBe(409);
    expect(res.json()).toEqual({ error: "request_cancelled" });
    expect(subject().mfaSecret).not.toBeNull();
    await app.close();
  });

  it("#305 review 4: a sign-in cancels the request AND clears the code on the child's phone", async () => {
    const { app } = await setup();
    const { requestId } = await reachMailboxStep(app);
    // The code is live at this point: the mailbox step is confirmed, the witness has not passed.
    expect(commands.find((c) => c.type === "show_reset_code" && c.payload?.code)).toBeTruthy();

    const login = await app.inject({
      method: "POST",
      url: "/v1/auth/login",
      payload: { email: SUBJECT_EMAIL, password: PASSWORD, code: totpAtCounter(OLD_SECRET, currentCounter() + 1) },
    });
    expect(login.statusCode).toBe(200);
    expect(resets.find((r) => r.id === requestId)!.state).toBe("cancelled_by_signin");
    // A cancelled request must not leave a code readable on the phone for its remaining 10 minutes.
    expect(commands.filter((c) => c.type === "show_reset_code" && c.payload?.code)).toHaveLength(0);
    await app.close();
  });

  it("a failed sign-in does not cancel anything", async () => {
    const { app } = await setup();
    await reachWindow(app);
    const login = await app.inject({
      method: "POST",
      url: "/v1/auth/login",
      payload: { email: SUBJECT_EMAIL, password: PASSWORD, code: "000000" },
    });
    expect(login.statusCode).toBe(401);
    expect(resets[0].state).toBe("witness_passed");
    await app.close();
  });
});

describe("MFA reset — claim 6: the plaintext code is never stored", () => {
  beforeEach(() => resetPrismaMock());

  it("the request row stores only the SHA-256, and the payload carries the plaintext", async () => {
    const { app } = await setup();
    const { requestId, code } = await reachMailboxStep(app);
    expect(code).toMatch(/^\d{8}$/);
    const row = resets.find((r) => r.id === requestId)!;
    expect(row.codeHash).toBe(createHash("sha256").update(code!).digest("hex"));
    // Nothing in the request row is the plaintext.
    expect(JSON.stringify(row)).not.toContain(code);
    expect(JSON.stringify(row)).not.toContain(JSON.stringify(code));
    await app.close();
  });

  it("acknowledgement by the device clears the payload, so no database row keeps the code", async () => {
    // The auth app installs the stateful tables; the device surface runs over the same ones.
    const { app: auth } = await setup();
    const app = await buildApp(deviceRoutes, "/v1/devices");
    const requested = await request(auth);
    expect((await confirm(auth, confirmTokenFor(auth, requested))).statusCode).toBe(200);
    const code = commands.find((c) => c.type === "show_reset_code")!.payload.code as string;
    expect(JSON.stringify(commands)).toContain(code);

    // The drain would hand the row to the phone; the ack is what must clear the plaintext.
    const command = commands.find((c) => c.type === "show_reset_code")!;
    command.status = "delivered";
    const ack = await app.inject({
      method: "POST",
      url: `/v1/devices/dev-1/commands/${command.id}/ack`,
      headers: deviceHeader(app, { deviceId: "dev-1", childId: "child-1", familyId: "fam-1" }),
      payload: { status: "ok" },
    });
    expect(ack.statusCode).toBe(200);
    // The acknowledged row is clear. The second device's row still carries the code because it has
    // neither been acknowledged nor expired — claim 6's other half is the expiry sweep, tested in
    // test/mfa-reset-expiry.test.ts.
    expect(command.payload).toEqual({});
    const live = commands.filter((c) => c.status !== "acked" && c.status !== "failed");
    expect(live.map((c) => c.id)).toEqual(["cmd-3"]);
    expect(JSON.stringify(commands.filter((c) => c.status === "acked"))).not.toContain(code);
    await auth.close();
    await app.close();
  });
});

describe("MFA reset — the show_reset_code command (ADR-0019, ADR-0031 decision 2.3)", () => {
  beforeEach(() => resetPrismaMock());

  it("is NOT parent-issueable: the reset flow is its only producer (#305 review)", async () => {
    await setup();
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-1", childId: "child-1", child: { familyId: "fam-1" } });
    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/command",
      headers: authHeader(app),
      payload: { command: "show_reset_code", payload: { requestId: "req-1", code: "12345678" } },
    });
    // Claude's finding: a parent-issueable command of this name lets a guardian — or the parent being
    // reset — put a reset notice with a chosen code on the child's phone. The schema refuses it before
    // any consent or device lookup, and nothing is queued.
    expect(res.statusCode).toBe(400);
    expect(commands).toHaveLength(0);
    expect(prismaMock.consentRecord.findFirst).not.toHaveBeenCalled();
    await app.close();
  });
});

describe("MFA reset — recovery codes that survive (sanity)", () => {
  beforeEach(() => resetPrismaMock());

  it("a completed reset issues no recovery code batch: re-enrolment does, through /mfa/verify", async () => {
    const { app } = await setup();
    const { requestId } = await reachWindow(app);
    resets[0].windowEndsAt = new Date(Date.now() - 1000);
    expect((await complete(app, requestId)).statusCode).toBe(200);
    // Recovery clears the batch; the plaintext codes are issued only by the existing verify route.
    expect(codeRows).toHaveLength(0);
    expect(prismaMock.parentMfaRecoveryCode.createMany).not.toHaveBeenCalled();
    await app.close();
  });
});
