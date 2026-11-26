import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import argon2 from "argon2";
import { authRoutes } from "../src/routes/auth.js";
import { encryptSecret } from "../src/lib/secretVault.js";
import { totpAtCounter } from "../src/lib/totp.js";
import { hashRecoveryCode, normaliseRecoveryCode } from "../src/lib/mfaRecovery.js";
import { setEmailSender, type EmailMessage, type EmailSender } from "../src/lib/email/index.js";
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
 * #716: change the password while signed in. The route must ask for the current password (and the second
 * factor when MFA is on), end every other session, hand this device a fresh token pair, and email the parent.
 */

const PASSWORD = "CorrectHorseBatteryStaple!";
const NEW_PASSWORD = "AnotherLongPassphrase#2026";
const EMAIL = "change@example.com";
const SECRET = "JBSWY3DPEHPK3PXP";
const RECOVERY = "ABCD-EFGH-JKMN-PQRS";

class CaptureSender implements EmailSender {
  readonly name = "capture";
  sent: EmailMessage[] = [];
  fail = false;
  async send(message: EmailMessage) {
    if (this.fail) return { ok: false as const, reason: "provider_unavailable" };
    this.sent.push(message);
    return { ok: true as const };
  }
}

interface ParentRow {
  id: string; familyId: string; email: string; passwordHash: string; displayName: string; role: string;
  mfaEnabled: boolean; mfaSecret: string | null;
}
interface CodeRow { id: string; parentId: string; codeHash: string; createdAt: Date; usedAt: Date | null }

let parents: ParentRow[];
let codeRows: CodeRow[];
let store: Map<string, string>;
let capture: CaptureSender;

async function setup(opts: { mfa?: boolean } = {}) {
  const app = await buildApp(authRoutes, "/v1/auth");
  store = new Map();
  capture = new CaptureSender();
  setEmailSender(capture);
  parents = [{
    id: "parent-1", familyId: "fam-1", email: EMAIL, passwordHash: await argon2.hash(PASSWORD),
    displayName: "Change Parent", role: "owner",
    mfaEnabled: opts.mfa ?? false, mfaSecret: opts.mfa ? encryptSecret(SECRET) : null,
  }];
  codeRows = opts.mfa
    ? [{ id: "code-1", parentId: "parent-1", codeHash: hashRecoveryCode(normaliseRecoveryCode(RECOVERY)), createdAt: new Date(), usedAt: null }]
    : [];

  prismaMock.parent.findUnique.mockImplementation(async ({ where }: { where: { id?: string; email?: string } }) => {
    const p = where.email ? parents.find((x) => x.email === where.email) : parents.find((x) => x.id === where.id);
    return p ? { ...p } : null;
  });
  prismaMock.parent.update.mockImplementation(async ({ where, data }: { where: { id: string }; data: Record<string, unknown> }) => {
    const p = parents.find((x) => x.id === where.id)!;
    for (const [k, v] of Object.entries(data)) {
      // The revocation writes `sessionVersion: { increment: 1 }`; keep only plain fields on the row.
      if (v === null || typeof v !== "object" || v instanceof Date) (p as unknown as Record<string, unknown>)[k] = v;
    }
    return { ...p };
  });
  prismaMock.parentMfaRecoveryCode.findFirst.mockImplementation(async ({ where }: { where: { parentId: string; codeHash: string; usedAt?: null } }) =>
    codeRows.find((r) => r.parentId === where.parentId && r.codeHash === where.codeHash && (where.usedAt !== null || r.usedAt === null)) ?? null,
  );
  prismaMock.parentMfaRecoveryCode.updateMany.mockImplementation(async ({ where, data }: { where: { id: string; usedAt: null }; data: { usedAt: Date } }) => {
    let count = 0;
    for (const row of codeRows) {
      if (row.id !== where.id || (where.usedAt === null && row.usedAt !== null)) continue;
      row.usedAt = data.usedAt;
      count += 1;
    }
    return { count };
  });

  const { getRedis } = await import("../src/redis.js");
  const redis = getRedis() as unknown as Record<string, ReturnType<typeof vi.fn>>;
  redis.get!.mockImplementation(async (k: string) => store.get(k) ?? null);
  redis.set!.mockImplementation(async (k: string, v: string) => { store.set(k, String(v)); return "OK"; });
  redis.del!.mockImplementation(async (...ks: string[]) => ks.reduce((n, k) => n + (store.delete(k) ? 1 : 0), 0));
  redis.incrby!.mockImplementation(async (k: string, n: number) => {
    const next = Number(store.get(k) ?? 0) + n;
    store.set(k, String(next));
    return next;
  });
  redis.smembers!.mockImplementation(async () => []);
  redis.sadd!.mockImplementation(async () => 1);
  redis.srem!.mockImplementation(async () => 1);
  return app;
}

const counter = () => Math.floor(Date.now() / 1000 / 30);
const change = (app: Awaited<ReturnType<typeof setup>>, body: Record<string, unknown>) =>
  app.inject({ method: "POST", url: "/v1/auth/password", headers: authHeader(app), payload: body });
const svKey = "auth:session-version:parent-1";

describe("POST /v1/auth/password (#716)", () => {
  beforeEach(() => resetPrismaMock());
  afterEach(() => setEmailSender(null));

  it("changes the password, ends other sessions, returns a fresh token pair and emails the parent", async () => {
    const app = await setup();
    const svBefore = Number(store.get(svKey) ?? "0");
    const res = await change(app, { currentPassword: PASSWORD, newPassword: NEW_PASSWORD });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.ok).toBe(true);
    expect(typeof body.token).toBe("string");
    expect(typeof body.refreshToken).toBe("string");
    expect(await argon2.verify(parents[0].passwordHash, NEW_PASSWORD)).toBe(true);
    expect(await argon2.verify(parents[0].passwordHash, PASSWORD)).toBe(false);
    // Every earlier session is now stale; the new token carries the bumped version.
    const sv = Number(store.get(svKey));
    expect(sv).toBe(svBefore + 1);
    const claims = app.jwt.verify(body.token) as { sub: string; sv: number; role: string };
    expect(claims.sub).toBe("parent-1");
    expect(claims.role).toBe("parent");
    expect(claims.sv).toBe(sv);
    expect(capture.sent).toHaveLength(1);
    expect(capture.sent[0].to).toBe(EMAIL);
    // The email carries no link: a phished copy cannot lead anywhere.
    expect(capture.sent[0].html).not.toMatch(/href=/i);
    await app.close();
  });

  it("refuses a wrong current password and changes nothing", async () => {
    const app = await setup();
    const hash = parents[0].passwordHash;
    const res = await change(app, { currentPassword: "not-the-password", newPassword: NEW_PASSWORD });
    expect(res.statusCode).toBe(401);
    expect(res.json().error).toBe("invalid_credentials");
    expect(parents[0].passwordHash).toBe(hash);
    expect(store.get(svKey)).toBeUndefined();
    expect(capture.sent).toHaveLength(0);
    await app.close();
  });

  it("refuses a new password shorter than 12 characters", async () => {
    const app = await setup();
    const res = await change(app, { currentPassword: PASSWORD, newPassword: "short1!" });
    expect(res.statusCode).toBe(400);
    expect(await argon2.verify(parents[0].passwordHash, PASSWORD)).toBe(true);
    await app.close();
  });

  it("refuses a new password equal to the current one", async () => {
    const app = await setup();
    const res = await change(app, { currentPassword: PASSWORD, newPassword: PASSWORD });
    expect(res.statusCode).toBe(400);
    expect(res.json().error).toBe("password_unchanged");
    await app.close();
  });

  it("the session that asked is revoked too: only the returned token works afterwards", async () => {
    const app = await setup();
    const old = authHeader(app);
    const res = await app.inject({ method: "POST", url: "/v1/auth/password", headers: old, payload: { currentPassword: PASSWORD, newPassword: NEW_PASSWORD } });
    expect(res.statusCode).toBe(200);
    const stale = await app.inject({ method: "POST", url: "/v1/auth/password", headers: old, payload: { currentPassword: NEW_PASSWORD, newPassword: "YetAnotherPassphrase!99" } });
    expect(stale.statusCode).toBe(401);
    expect(stale.json().error).toBe("session_revoked");
    await app.close();
  });

  it("needs a session", async () => {
    const app = await setup();
    const res = await app.inject({ method: "POST", url: "/v1/auth/password", payload: { currentPassword: PASSWORD, newPassword: NEW_PASSWORD } });
    expect(res.statusCode).toBe(401);
    await app.close();
  });

  it("with MFA on, refuses without a code or with a wrong code", async () => {
    const app = await setup({ mfa: true });
    const none = await change(app, { currentPassword: PASSWORD, newPassword: NEW_PASSWORD });
    expect(none.statusCode).toBe(401);
    expect(none.json().error).toBe("mfa_required");
    const wrong = await change(app, { currentPassword: PASSWORD, newPassword: NEW_PASSWORD, code: "000000" === totpAtCounter(SECRET, counter()) ? "111111" : "000000" });
    expect(wrong.statusCode).toBe(401);
    expect(await argon2.verify(parents[0].passwordHash, PASSWORD)).toBe(true);
    await app.close();
  });

  it("with MFA on, accepts a current authenticator code", async () => {
    const app = await setup({ mfa: true });
    const res = await change(app, { currentPassword: PASSWORD, newPassword: NEW_PASSWORD, code: totpAtCounter(SECRET, counter()) });
    expect(res.statusCode).toBe(200);
    expect(await argon2.verify(parents[0].passwordHash, NEW_PASSWORD)).toBe(true);
    await app.close();
  });

  it("with MFA on, accepts an unused recovery code once and spends it", async () => {
    const app = await setup({ mfa: true });
    const first = await change(app, { currentPassword: PASSWORD, newPassword: NEW_PASSWORD, code: RECOVERY.toLowerCase() });
    expect(first.statusCode).toBe(200);
    expect(codeRows[0].usedAt).toBeInstanceOf(Date);
    // The old session ended with the change; the replay comes from the fresh token the change handed back.
    const again = await app.inject({
      method: "POST", url: "/v1/auth/password", headers: { authorization: `Bearer ${first.json().token}` },
      payload: { currentPassword: NEW_PASSWORD, newPassword: "YetAnotherPassphrase!99", code: RECOVERY },
    });
    expect(again.statusCode).toBe(401);
    expect(again.json().error).toBe("mfa_required");
    expect(await argon2.verify(parents[0].passwordHash, NEW_PASSWORD)).toBe(true);
    await app.close();
  });

  it("a mail outage does not turn a finished change into an error", async () => {
    const app = await setup();
    capture.fail = true;
    const res = await change(app, { currentPassword: PASSWORD, newPassword: NEW_PASSWORD });
    expect(res.statusCode).toBe(200);
    expect(await argon2.verify(parents[0].passwordHash, NEW_PASSWORD)).toBe(true);
    await app.close();
  });
});
