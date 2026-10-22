import { beforeEach, describe, expect, it, vi } from "vitest";
import argon2 from "argon2";
import { authRoutes } from "../src/routes/auth.js";
import { encryptSecret } from "../src/lib/secretVault.js";
import { totpAtCounter } from "../src/lib/totp.js";
import { hashRecoveryCode, normaliseRecoveryCode } from "../src/lib/mfaRecovery.js";
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
 * ADR-0023 Option A — one-time MFA recovery codes.
 *
 * These tests own an in-memory `ParentMfaRecoveryCode` table so the one-time-use gate and the
 * delete-all-on-use behaviour are exercised for real (the shared proxy mock cannot express "the
 * second claim finds `usedAt` already set"). Redis is a Map, as in `auth.test.ts`.
 */

const PASSWORD = "CorrectHorseBatteryStaple!";
const EMAIL = "recovery@example.com";
const OLD_SECRET = "JBSWY3DPEHPK3PXP";
/** Crockford base32: no I, L, O, U. */
const CODE_FORMAT = /^[0-9A-HJKMNP-TV-Z]{4}(-[0-9A-HJKMNP-TV-Z]{4}){3}$/;

interface CodeRow {
  id: string;
  parentId: string;
  codeHash: string;
  createdAt: Date;
  usedAt: Date | null;
}
interface ParentRow {
  id: string;
  familyId: string;
  email: string;
  passwordHash: string;
  displayName: string;
  role: string;
  mfaEnabled: boolean;
  mfaSecret: string | null;
}

let parents: ParentRow[];
let codeRows: CodeRow[];
let store: Map<string, string>;
let seq: number;

/** Install the stateful mocks. `secret` = an enrolled (encrypted) TOTP secret, `mfaEnabled` its state. */
async function setup(opts: { secret?: string | null; mfaEnabled?: boolean } = {}) {
  const app = await buildApp(authRoutes, "/v1/auth");
  seq = 0;
  codeRows = [];
  store = new Map();
  parents = [{
    id: "parent-1",
    familyId: "fam-1",
    email: EMAIL,
    passwordHash: await argon2.hash(PASSWORD),
    displayName: "Recovery Parent",
    role: "owner",
    mfaEnabled: opts.mfaEnabled ?? false,
    mfaSecret: opts.secret ? encryptSecret(opts.secret) : null,
  }];

  prismaMock.parent.findUnique.mockImplementation(async ({ where }: { where: { id?: string; email?: string } }) => {
    const p = where.email ? parents.find((x) => x.email === where.email) : parents.find((x) => x.id === where.id);
    return p ? { ...p } : null;
  });
  prismaMock.parent.update.mockImplementation(async ({ where, data }: { where: { id: string }; data: Record<string, unknown> }) => {
    const p = parents.find((x) => x.id === where.id)!;
    Object.assign(p, data);
    return { ...p };
  });
  // #199: honour `usedAt: null`, because the recovery route relies on it to keep a spent code from
  // reaching the (now earlier) revocation. Returning the spent row anyway would hide that.
  prismaMock.parentMfaRecoveryCode.findFirst.mockImplementation(async ({ where }: { where: { parentId: string; codeHash: string; usedAt?: null } }) =>
    codeRows.find((r) =>
      r.parentId === where.parentId &&
      r.codeHash === where.codeHash &&
      (where.usedAt !== null || r.usedAt === null),
    ) ?? null,
  );
  prismaMock.parentMfaRecoveryCode.updateMany.mockImplementation(async ({ where, data }: { where: { id: string; usedAt: null }; data: { usedAt: Date } }) => {
    let count = 0;
    for (const row of codeRows) {
      if (row.id !== where.id) continue;
      if (where.usedAt === null && row.usedAt !== null) continue;
      row.usedAt = data.usedAt;
      count += 1;
    }
    return { count };
  });
  prismaMock.parentMfaRecoveryCode.deleteMany.mockImplementation(async ({ where }: { where: { parentId: string; id?: { not: string } } }) => {
    const before = codeRows.length;
    codeRows = codeRows.filter((r) => !(r.parentId === where.parentId && (where.id?.not ? r.id !== where.id.not : true)));
    return { count: before - codeRows.length };
  });
  prismaMock.parentMfaRecoveryCode.createMany.mockImplementation(async ({ data }: { data: Array<Omit<CodeRow, "id" | "usedAt">> }) => {
    for (const row of data) codeRows.push({ id: `code-${++seq}`, usedAt: null, ...row });
    return { count: data.length };
  });
  // #183: the enrolment routes ask whether a complete batch already exists before they let a
  // recovery token through.
  prismaMock.parentMfaRecoveryCode.count.mockImplementation(async ({ where }: { where: { parentId: string; usedAt?: null } }) =>
    codeRows.filter((r) => r.parentId === where.parentId && (where.usedAt === undefined || r.usedAt === null)).length,
  );

  const { getRedis } = await import("../src/redis.js");
  const redis = getRedis() as unknown as {
    get: ReturnType<typeof vi.fn>;
    set: ReturnType<typeof vi.fn>;
    del: ReturnType<typeof vi.fn>;
    incrby: ReturnType<typeof vi.fn>;
    smembers: ReturnType<typeof vi.fn>;
    sadd: ReturnType<typeof vi.fn>;
    srem: ReturnType<typeof vi.fn>;
  };
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

  return { app, parent: parents[0] };
}

const currentCounter = () => Math.floor(Date.now() / 1000 / 30);

/** Enrol a secret and verify it, returning the response that is allowed to carry the plaintext codes. */
async function enrolAndVerify(app: Awaited<ReturnType<typeof setup>>["app"]) {
  const h = authHeader(app);
  const enroll = await app.inject({ method: "POST", url: "/v1/auth/mfa/enroll", headers: h, payload: {} });
  expect(enroll.statusCode).toBe(200);
  const secret = enroll.json().secret as string;
  const verify = await app.inject({
    method: "POST",
    url: "/v1/auth/mfa/verify",
    headers: h,
    payload: { code: totpAtCounter(secret, currentCounter()) },
  });
  return { secret, verify };
}

const recover = (app: Awaited<ReturnType<typeof setup>>["app"], body: Record<string, unknown>) =>
  app.inject({ method: "POST", url: "/v1/auth/mfa/recover", payload: body });

describe("MFA recovery codes (ADR-0023)", () => {
  beforeEach(() => {
    resetPrismaMock();
  });

  it("enrolment verification returns ten one-time codes and stores only their SHA-256 hashes", async () => {
    const { app } = await setup();
    const { verify } = await enrolAndVerify(app);

    expect(verify.statusCode).toBe(200);
    const body = verify.json();
    expect(body.ok).toBe(true);
    expect(body.mfaEnabled).toBe(true);
    expect(body.recoveryCodes).toHaveLength(10);
    expect(new Set(body.recoveryCodes).size).toBe(10);
    for (const code of body.recoveryCodes) expect(code).toMatch(CODE_FORMAT);
    expect(Date.parse(body.recoveryCodesIssuedAt)).toBeGreaterThan(0);

    // Storage: ten rows, each the sha256 of the normalised code — never the displayed value.
    expect(codeRows).toHaveLength(10);
    const plaintext = body.recoveryCodes.map((c: string) => normaliseRecoveryCode(c));
    const expectedHashes = plaintext.map((c: string) => hashRecoveryCode(c));
    for (const row of codeRows) {
      expect(row.codeHash).toMatch(/^[0-9a-f]{64}$/);
      expect(plaintext).not.toContain(row.codeHash);
    }
    expect(codeRows.map((r) => r.codeHash).sort()).toEqual(expectedHashes.sort());
    const serialisedRows = JSON.stringify(codeRows);
    for (const code of plaintext) expect(serialisedRows).not.toContain(code);
    await app.close();
  });

  it("a valid code recovers once: the factor is cleared, one row is spent, the rest deleted, sessions revoked", async () => {
    const { app } = await setup();
    const { verify } = await enrolAndVerify(app);
    const codes: string[] = verify.json().recoveryCodes;

    const revokedBefore = store.get("auth:session-version:parent-1") ?? "0";
    const res = await recover(app, { email: EMAIL, password: PASSWORD, code: codes[2] });
    expect(res.statusCode).toBe(200);
    // Codes are NOT in the response: the token is the whole answer.
    expect(Object.keys(res.json())).toEqual(["recoveryToken"]);

    const claims = app.jwt.verify(res.json().recoveryToken) as {
      sub: string; purpose?: string; jti?: string; role?: string; familyId?: string;
    };
    expect(claims.sub).toBe("parent-1");
    expect(claims.purpose).toBe("mfa_recovery");
    expect(claims.role).toBeUndefined();
    expect(claims.familyId).toBeUndefined();
    expect(typeof claims.jti).toBe("string");

    // The factor is cleared; only the used row is left, so the batch is bounded to a single use.
    // `mfaEnabled` stays true (#183): the policy did not go away with the authenticator, and a
    // password-only session must not exist until a new factor is verified.
    expect(parents[0].mfaEnabled).toBe(true);
    expect(parents[0].mfaSecret).toBeNull();
    expect(codeRows).toHaveLength(1);
    expect(codeRows[0].usedAt).toBeInstanceOf(Date);
    expect(codeRows[0].codeHash).toBe(hashRecoveryCode(codes[2]));

    // Every session is gone (the counter is what kills live access tokens, ADR-0025).
    expect(store.get("auth:session-version:parent-1")).toBe(String(1 + Number(revokedBefore)));
    // The token is a 15-minute Redis-backed credential, not a JWT the signature alone makes valid.
    expect(store.get(`mfa:recovery:${claims.jti}`)).toBe("parent-1");
    await app.close();
  });

  it("#199: a failed session revocation answers 5xx and leaves the recovery code unspent", async () => {
    const { app } = await setup();
    const { verify } = await enrolAndVerify(app);
    const codes: string[] = verify.json().recoveryCodes;
    const { getRedis } = await import("../src/redis.js");
    const redis = getRedis() as unknown as { incrby: ReturnType<typeof vi.fn> };

    // The version bump is the authoritative revocation and is deliberately not best-effort
    // (sessions.ts:113-114). Make it fail: the request must not answer with a token, and above all
    // must not consume the code — that is the lockout this test exists for.
    redis.incrby.mockRejectedValueOnce(new Error("redis unavailable"));
    const failed = await recover(app, { email: EMAIL, password: PASSWORD, code: codes[2] });

    expect(failed.statusCode).toBeGreaterThanOrEqual(500);
    expect(failed.statusCode).toBeLessThan(600);
    expect(failed.json().recoveryToken).toBeUndefined();
    // Nothing was spent: the whole batch is intact and the factor is still bound.
    expect(codeRows).toHaveLength(10);
    expect(codeRows.every((r) => r.usedAt === null)).toBe(true);
    expect(parents[0].mfaSecret).not.toBeNull();

    // The parent retries the same code once the session store is back; this time it recovers.
    const retry = await recover(app, { email: EMAIL, password: PASSWORD, code: codes[2] });
    expect(retry.statusCode).toBe(200);
    expect(retry.json().recoveryToken).toBeTruthy();
    expect(codeRows).toHaveLength(1);
    expect(codeRows[0].usedAt).toBeInstanceOf(Date);
    expect(codeRows[0].codeHash).toBe(hashRecoveryCode(codes[2]));
    expect(parents[0].mfaSecret).toBeNull();
    await app.close();
  });

  it("#199: replaying a spent code does not revoke the parent's sessions again", async () => {
    const { app } = await setup();
    const { verify } = await enrolAndVerify(app);
    const code: string = verify.json().recoveryCodes[0];

    const versionBefore = store.get("auth:session-version:parent-1") ?? "0";
    expect((await recover(app, { email: EMAIL, password: PASSWORD, code })).statusCode).toBe(200);
    const versionAfterRecovery = String(1 + Number(versionBefore));
    expect(store.get("auth:session-version:parent-1")).toBe(versionAfterRecovery);

    // The spent row is still there (it is the record of the batch being used), but it must not lead
    // to the revocation that now runs before the claim: a 401 with no side effect.
    const replay = await recover(app, { email: EMAIL, password: PASSWORD, code });
    expect(replay.statusCode).toBe(401);
    expect(replay.json().error).toBe("invalid_recovery");
    expect(store.get("auth:session-version:parent-1")).toBe(versionAfterRecovery);
    await app.close();
  });

  it("the same code uses up the batch: a replay and any sibling code both fail", async () => {
    const { app } = await setup();
    const { verify } = await enrolAndVerify(app);
    const codes: string[] = verify.json().recoveryCodes;

    expect((await recover(app, { email: EMAIL, password: PASSWORD, code: codes[0] })).statusCode).toBe(200);
    const replay = await recover(app, { email: EMAIL, password: PASSWORD, code: codes[0] });
    expect(replay.statusCode).toBe(401);
    expect(replay.json().error).toBe("invalid_recovery");
    const sibling = await recover(app, { email: EMAIL, password: PASSWORD, code: codes[1] });
    expect(sibling.statusCode).toBe(401);
    expect(sibling.json().error).toBe("invalid_recovery");
    expect(codeRows).toHaveLength(1);
    await app.close();
  });

  it("two concurrent requests with the same code: exactly one wins", async () => {
    const { app } = await setup();
    const { verify } = await enrolAndVerify(app);
    const code: string = verify.json().recoveryCodes[0];

    const [first, second] = await Promise.all([
      recover(app, { email: EMAIL, password: PASSWORD, code }),
      recover(app, { email: EMAIL, password: PASSWORD, code }),
    ]);
    expect([first.statusCode, second.statusCode].sort()).toEqual([200, 401]);
    expect(codeRows.filter((r) => r.usedAt !== null)).toHaveLength(1);
    await app.close();
  });

  it("a wrong code does not consume the batch — a real one still works afterwards", async () => {
    const { app } = await setup();
    const { verify } = await enrolAndVerify(app);
    const codes: string[] = verify.json().recoveryCodes;
    const updatesBefore = prismaMock.parent.update.mock.calls.length;
    const deletesBefore = prismaMock.parentMfaRecoveryCode.deleteMany.mock.calls.length;
    const claimsBefore = prismaMock.parentMfaRecoveryCode.updateMany.mock.calls.length;

    const wrong = await recover(app, { email: EMAIL, password: PASSWORD, code: "0000-0000-0000-0000" });
    expect(wrong.statusCode).toBe(401);
    expect(wrong.json().error).toBe("invalid_recovery");
    expect(codeRows).toHaveLength(10);
    expect(codeRows.every((r) => r.usedAt === null)).toBe(true);
    expect(prismaMock.parentMfaRecoveryCode.updateMany).toHaveBeenCalledTimes(claimsBefore);
    expect(prismaMock.parentMfaRecoveryCode.deleteMany).toHaveBeenCalledTimes(deletesBefore);
    // Enrolment already wrote the secret; nothing may be written by the failed recovery.
    expect(prismaMock.parent.update).toHaveBeenCalledTimes(updatesBefore);

    const ok = await recover(app, { email: EMAIL, password: PASSWORD, code: codes[4] });
    expect(ok.statusCode).toBe(200);
    expect(ok.json().recoveryToken).toBeTruthy();
    await app.close();
  });

  it("failure is indistinguishable: unknown address, wrong password and a non-MFA account all answer invalid_recovery", async () => {
    const { app } = await setup();
    const { verify } = await enrolAndVerify(app);
    const codes: string[] = verify.json().recoveryCodes;
    const updatesBefore = prismaMock.parent.update.mock.calls.length;

    const unknown = await recover(app, { email: `nobody-${Date.now()}@example.com`, password: PASSWORD, code: codes[0] });
    const wrongPassword = await recover(app, { email: EMAIL, password: "WrongHorseBatteryStaple!", code: codes[0] });
    parents[0].mfaEnabled = false;
    const notEnabled = await recover(app, { email: EMAIL, password: PASSWORD, code: codes[0] });

    for (const res of [unknown, wrongPassword, notEnabled]) {
      expect(res.statusCode).toBe(401);
      expect(res.json()).toEqual({ error: "invalid_recovery" });
    }
    expect(prismaMock.parentMfaRecoveryCode.updateMany).not.toHaveBeenCalled();
    expect(prismaMock.parent.update).toHaveBeenCalledTimes(updatesBefore);
    await app.close();
  });

  it("the recovery token reaches /mfa/enroll + /mfa/verify only, and dies once MFA is on again", async () => {
    const { app } = await setup();
    const first = await enrolAndVerify(app);
    const token: string = (await recover(app, {
      email: EMAIL,
      password: PASSWORD,
      code: first.verify.json().recoveryCodes[0],
    })).json().recoveryToken;
    const claims = app.jwt.verify(token) as { jti: string };
    const h = { authorization: `Bearer ${token}` };

    // Not a session: every requireJwt route refuses it (#146/#147 untouched).
    for (const [method, url] of [
      ["POST", "/v1/auth/logout-all"],
      ["POST", "/v1/auth/mfa/recovery-codes"],
    ] as const) {
      const res = await app.inject({ method, url, headers: h, payload: {} });
      expect({ url, status: res.statusCode }).toEqual({ url, status: 401 });
      expect(res.json().error).toBe("unauthorized");
    }

    // It does reach the two enrolment routes.
    const enroll = await app.inject({ method: "POST", url: "/v1/auth/mfa/enroll", headers: h, payload: {} });
    expect(enroll.statusCode).toBe(200);
    // A recovery token may replace an *unverified* secret (MFA is off): the #139 re-auth branch is
    // for replacing an enrolled factor, and this token already proved password + code.
    const reEnroll = await app.inject({ method: "POST", url: "/v1/auth/mfa/enroll", headers: h, payload: {} });
    expect(reEnroll.statusCode).toBe(200);
    const secret = reEnroll.json().secret as string;
    expect(secret).not.toBe(enroll.json().secret);
    const verify = await app.inject({
      method: "POST",
      url: "/v1/auth/mfa/verify",
      headers: h,
      payload: { code: totpAtCounter(secret, currentCounter() + 1) },
    });
    expect(verify.statusCode).toBe(200);
    const fresh: string[] = verify.json().recoveryCodes;
    expect(fresh).toHaveLength(10);

    // The batch that guarded the old secret is gone; the new rows are the new hashes.
    expect(codeRows).toHaveLength(10);
    expect(codeRows.map((r) => r.codeHash).sort()).toEqual(
      fresh.map((c) => hashRecoveryCode(c)).sort(),
    );
    // The token's marker is dropped on success, and the DB check refuses it while MFA is enabled.
    expect(store.has(`mfa:recovery:${claims.jti}`)).toBe(false);
    expect((await app.inject({ method: "POST", url: "/v1/auth/mfa/enroll", headers: h, payload: {} })).statusCode).toBe(401);
    expect((await app.inject({
      method: "POST",
      url: "/v1/auth/mfa/verify",
      headers: h,
      payload: { code: totpAtCounter(secret, currentCounter() + 1) },
    })).statusCode).toBe(401);
    await app.close();
  });

  it("an expired, unknown-jti, wrong-subject or wrong-purpose token is refused by /mfa/enroll", async () => {
    const { app } = await setup();
    const first = await enrolAndVerify(app);
    const token: string = (await recover(app, {
      email: EMAIL,
      password: PASSWORD,
      code: first.verify.json().recoveryCodes[0],
    })).json().recoveryToken;
    const { jti } = app.jwt.verify(token) as { jti: string };

    const cases: Array<[string, string]> = [
      ["unknown jti", app.jwt.sign({ sub: "parent-1", purpose: "mfa_recovery", jti: "not-in-redis" })],
      ["expired", app.jwt.sign({ sub: "parent-1", purpose: "mfa_recovery", jti, exp: Math.floor(Date.now() / 1000) - 60 })],
      ["another subject", app.jwt.sign({ sub: "parent-2", purpose: "mfa_recovery", jti })],
      ["password_reset purpose", app.jwt.sign({ sub: "parent-1", purpose: "password_reset" }, { expiresIn: "15m" })],
      ["device role", app.jwt.sign({ deviceId: "dev-1", childId: "child-1", familyId: "fam-1", role: "device" })],
      ["no claims", app.jwt.sign({})],
    ];
    for (const [label, jwt] of cases) {
      const res = await app.inject({
        method: "POST",
        url: "/v1/auth/mfa/enroll",
        headers: { authorization: `Bearer ${jwt}` },
        payload: {},
      });
      expect({ label, status: res.statusCode }).toEqual({ label, status: 401 });
      expect(res.json().error).toBe("unauthorized");
    }
    // Garbage signature is not a token at all.
    const garbage = await app.inject({
      method: "POST",
      url: "/v1/auth/mfa/enroll",
      headers: { authorization: "Bearer abc.def.ghi" },
      payload: {},
    });
    expect(garbage.statusCode).toBe(401);
    await app.close();
  });

  it("issuing recovery codes requires the #139 re-authentication and replaces the old batch", async () => {
    const { app } = await setup({ secret: OLD_SECRET, mfaEnabled: true });
    const h = authHeader(app);

    const bare = await app.inject({ method: "POST", url: "/v1/auth/mfa/recovery-codes", headers: h, payload: {} });
    expect(bare.statusCode).toBe(401);
    expect(bare.json().error).toBe("reauth_required");
    const wrong = await app.inject({
      method: "POST",
      url: "/v1/auth/mfa/recovery-codes",
      headers: h,
      payload: { password: "WrongHorseBatteryStaple!" },
    });
    expect(wrong.statusCode).toBe(401);
    expect(prismaMock.parentMfaRecoveryCode.createMany).not.toHaveBeenCalled();

    // Seed the batch that is about to be replaced.
    const seeded = await app.inject({
      method: "POST",
      url: "/v1/auth/mfa/recovery-codes",
      headers: h,
      payload: { password: PASSWORD },
    });
    expect(seeded.statusCode).toBe(200);
    const oldCodes: string[] = seeded.json().recoveryCodes;
    expect(oldCodes).toHaveLength(10);
    expect(oldCodes.every((c) => CODE_FORMAT.test(c))).toBe(true);

    // The authenticator is the alternative proof, and the new batch invalidates the old codes.
    const rotated = await app.inject({
      method: "POST",
      url: "/v1/auth/mfa/recovery-codes",
      headers: h,
      payload: { code: totpAtCounter(OLD_SECRET, currentCounter() + 1) },
    });
    expect(rotated.statusCode).toBe(200);
    const newCodes: string[] = rotated.json().recoveryCodes;
    expect(newCodes).toHaveLength(10);
    expect(codeRows.map((r) => r.codeHash).sort()).toEqual(newCodes.map((c) => hashRecoveryCode(c)).sort());

    const stale = await recover(app, { email: EMAIL, password: PASSWORD, code: oldCodes[0] });
    expect(stale.statusCode).toBe(401);
    const fresh = await recover(app, { email: EMAIL, password: PASSWORD, code: newCodes[3] });
    expect(fresh.statusCode).toBe(200);
    await app.close();
  });

  it("a first batch for an account with no secret needs only the session (onboarding stays open)", async () => {
    const { app } = await setup();
    const res = await app.inject({
      method: "POST",
      url: "/v1/auth/mfa/recovery-codes",
      headers: authHeader(app),
      payload: {},
    });
    expect(res.statusCode).toBe(200);
    expect(res.json().recoveryCodes).toHaveLength(10);
    await app.close();
  });

  it("the plaintext never comes back: the issued batch is not readable from any later response", async () => {
    const { app } = await setup({ secret: OLD_SECRET, mfaEnabled: true });
    const issued = await app.inject({
      method: "POST",
      url: "/v1/auth/mfa/recovery-codes",
      headers: authHeader(app),
      payload: { password: PASSWORD },
    });
    const codes: string[] = issued.json().recoveryCodes;

    // Re-reading is a replacement, not a reveal: without re-auth it is refused outright…
    const again = await app.inject({ method: "POST", url: "/v1/auth/mfa/recovery-codes", headers: authHeader(app), payload: {} });
    expect(again.statusCode).toBe(401);
    expect(JSON.stringify(again.json())).not.toContain(normaliseRecoveryCode(codes[0]));

    // …and recovery answers with a token and nothing else.
    const recovered = await recover(app, { email: EMAIL, password: PASSWORD, code: codes[0] });
    expect(recovered.statusCode).toBe(200);
    expect(Object.keys(recovered.json())).toEqual(["recoveryToken"]);
    for (const code of codes.map((c) => normaliseRecoveryCode(c))) {
      expect(JSON.stringify(recovered.json())).not.toContain(code);
    }
    // The one row left holds a hash, and the used code cannot be read back out of it.
    expect(codeRows.every((r) => /^[0-9a-f]{64}$/.test(r.codeHash))).toBe(true);
    await app.close();
  });

  it("#183: after a recovery the password alone opens no session — MFA stays on with no factor bound", async () => {
    const { app } = await setup();
    const first = await enrolAndVerify(app);
    const codes: string[] = first.verify.json().recoveryCodes;

    // Before the recovery a normal MFA account is asked for a code, as always.
    const noCode = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: EMAIL, password: PASSWORD } });
    expect(noCode.statusCode).toBe(401);
    expect(noCode.json().error).toBe("mfa_required");

    expect((await recover(app, { email: EMAIL, password: PASSWORD, code: codes[5] })).statusCode).toBe(200);
    // The policy survives the recovery; only the authenticator is gone.
    expect(parents[0].mfaEnabled).toBe(true);
    expect(parents[0].mfaSecret).toBeNull();

    // The password alone is refused with no session, no refresh token and no re-enrolment token:
    // minting one here would hand a stolen password the factor it needs, two calls later.
    const after = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: EMAIL, password: PASSWORD } });
    expect(after.statusCode).toBe(401);
    expect(after.json()).toEqual({ error: "mfa_reenroll_required" });
    // No session was minted: neither an access token nor a refresh record exists.
    expect(Object.keys(after.json())).toEqual(["error"]);
    expect([...store.keys()].some((k) => k.startsWith("refresh:"))).toBe(false);

    // A wrong password is still indistinguishable from any other failed login.
    const wrongPassword = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: EMAIL, password: "WrongHorseBatteryStaple!" } });
    expect(wrongPassword.statusCode).toBe(401);
    expect(wrongPassword.json().error).toBe("invalid_credentials");
    await app.close();
  });

  it("#183: recovery token → enrol → verify → login works, and the new authenticator is required afterwards", async () => {
    const { app } = await setup();
    const session = authHeader(app);
    // Verify one window *behind* now, so the recovery re-verification and the login after it both
    // have a strictly newer counter to present (replay protection is per parent, not per secret).
    const firstEnroll = await app.inject({ method: "POST", url: "/v1/auth/mfa/enroll", headers: session, payload: {} });
    expect(firstEnroll.statusCode).toBe(200);
    const firstSecret = firstEnroll.json().secret as string;
    const firstVerify = await app.inject({
      method: "POST",
      url: "/v1/auth/mfa/verify",
      headers: session,
      payload: { code: totpAtCounter(firstSecret, currentCounter() - 1) },
    });
    expect(firstVerify.statusCode).toBe(200);

    const token: string = (await recover(app, {
      email: EMAIL,
      password: PASSWORD,
      code: firstVerify.json().recoveryCodes[0],
    })).json().recoveryToken;
    const h = { authorization: `Bearer ${token}` };

    const enroll = await app.inject({ method: "POST", url: "/v1/auth/mfa/enroll", headers: h, payload: {} });
    expect(enroll.statusCode).toBe(200);
    const secret = enroll.json().secret as string;
    const verify = await app.inject({
      method: "POST",
      url: "/v1/auth/mfa/verify",
      headers: h,
      payload: { code: totpAtCounter(secret, currentCounter()) },
    });
    expect(verify.statusCode).toBe(200);
    expect(verify.json().recoveryCodes).toHaveLength(10);

    // The legitimate path still ends where it did before: the new authenticator signs in.
    const bare = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: EMAIL, password: PASSWORD } });
    expect(bare.statusCode).toBe(401);
    expect(bare.json().error).toBe("mfa_required");
    const login = await app.inject({
      method: "POST",
      url: "/v1/auth/login",
      payload: { email: EMAIL, password: PASSWORD, code: totpAtCounter(secret, currentCounter() + 1) },
    });
    expect(login.statusCode).toBe(200);
    expect(login.json().token).toBeTruthy();
    expect(login.json().refreshToken).toBeTruthy();
    await app.close();
  });

  it("#183: a normal MFA account is unchanged — no code, a wrong code, then the right one", async () => {
    const { app } = await setup({ secret: OLD_SECRET, mfaEnabled: true });
    const login = (body: Record<string, unknown>) =>
      app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: EMAIL, password: PASSWORD, ...body } });

    const noCode = await login({});
    expect(noCode.statusCode).toBe(401);
    expect(noCode.json().error).toBe("mfa_required");
    const wrong = await login({ code: "000000" });
    expect(wrong.statusCode).toBe(401);
    expect(wrong.json().error).toBe("mfa_required");
    const ok = await login({ code: totpAtCounter(OLD_SECRET, currentCounter()) });
    expect(ok.statusCode).toBe(200);
    expect(ok.json().token).toBeTruthy();
    await app.close();
  });

  it("#183: an account without MFA is unaffected — the password alone still signs in", async () => {
    const { app } = await setup();
    const login = await app.inject({ method: "POST", url: "/v1/auth/login", payload: { email: EMAIL, password: PASSWORD } });
    expect(login.statusCode).toBe(200);
    expect(login.json().token).toBeTruthy();
    expect(login.json().error).toBeUndefined();
    await app.close();
  });

  it("#183: a recovery token is refused once a new batch exists, even if its Redis marker survived", async () => {
    const { app } = await setup();
    const first = await enrolAndVerify(app);
    const token: string = (await recover(app, {
      email: EMAIL,
      password: PASSWORD,
      code: first.verify.json().recoveryCodes[0],
    })).json().recoveryToken;
    const { jti } = app.jwt.verify(token) as { jti: string };
    const h = { authorization: `Bearer ${token}` };
    const secret = (await app.inject({ method: "POST", url: "/v1/auth/mfa/enroll", headers: h, payload: {} })).json().secret as string;
    expect((await app.inject({
      method: "POST",
      url: "/v1/auth/mfa/verify",
      headers: h,
      payload: { code: totpAtCounter(secret, currentCounter() + 1) },
    })).statusCode).toBe(200);

    // The Redis delete is the primary boundary; the database is the second one, so a store failure
    // cannot keep a spent token alive.
    store.set(`mfa:recovery:${jti}`, "parent-1");
    expect((await app.inject({ method: "POST", url: "/v1/auth/mfa/enroll", headers: h, payload: {} })).statusCode).toBe(401);
    expect((await app.inject({
      method: "POST",
      url: "/v1/auth/mfa/verify",
      headers: h,
      payload: { code: totpAtCounter(secret, currentCounter() + 2) },
    })).statusCode).toBe(401);
    await app.close();
  });
});
