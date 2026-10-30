import { readFileSync } from "node:fs";
import { Writable } from "node:stream";
import { fileURLToPath } from "node:url";
import Fastify from "fastify";
import fastifyJwt from "@fastify/jwt";
import argon2 from "argon2";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { DELETION_REQUEST_ACCEPTED, accountRoutes, settleDeletionRequests } from "../src/routes/account.js";
import { FAMILY_SCOPED_DELETES } from "../src/lib/accountDeletion.js";
import { ACCOUNT_DELETION_TTL_MS, hashDeletionToken } from "../src/lib/accountDeletionLink.js";
import { setEmailSender, type EmailMessage } from "../src/lib/email/index.js";
import { verifyTotpFresh } from "../src/lib/mfaVerify.js";
import { AUTH_RATE_LIMIT } from "../src/lib/rateLimits.js";
import { LOGGER_SERIALIZERS, redactUrl } from "../src/lib/logRedaction.js";
import { CHILD_SCOPED_DELETE_ORDER } from "../src/lib/usageModel.js";
import { getRedis } from "../src/redis.js";
import { MockRedis, buildApp, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});
vi.mock("argon2", () => ({
  default: { verify: vi.fn(async () => true), hash: vi.fn(async () => "argon2$stub") },
}));
vi.mock("../src/lib/mfaVerify.js", () => ({ verifyTotpFresh: vi.fn(async () => false) }));

/**
 * #442 PR 3: account deletion from the web link (design §7, comment 6495864112). The erase itself is
 * PR 1's and is tested in account-deletion.test.ts; these rows test the link around it.
 *
 * Each test names its mutant: the one-line change to the production code that makes it fail.
 */

const OWNER = {
  id: "parent-1", familyId: "fam-1", email: "owner@example.com", displayName: "Owner",
  role: "owner", permissions: [] as string[], passwordHash: "argon2$owner-hash", mfaEnabled: false, mfaSecret: null as string | null, sessionVersion: 3,
};
const CO = { ...OWNER, id: "parent-2", email: "co@example.com", displayName: "Co", role: "co-parent", passwordHash: "argon2$co-hash" };
const PASSWORD = "CorrectHorseBatteryStaple!";

type TokenRow = { id: string; parentId: string; tokenHash: string; expiresAt: Date; usedAt: Date | null; createdAt: Date };
type Where = Record<string, unknown>;

/** An in-memory `AccountDeletionToken` table, honouring the `where` shapes the code sends. */
function wireTokenTable(): TokenRow[] {
  const rows: TokenRow[] = [];
  let next = 0;
  const t = prismaMock.accountDeletionToken;
  const matches = (row: TokenRow, where: Where): boolean =>
    Object.entries(where).every(([key, cond]) => {
      const value = (row as unknown as Record<string, unknown>)[key];
      if (cond === null) return value === null;
      if (cond && typeof cond === "object" && !(cond instanceof Date)) {
        const c = cond as { in?: unknown[]; gt?: Date };
        if (c.in) return c.in.includes(value);
        if (c.gt) return value instanceof Date && value.getTime() > c.gt.getTime();
      }
      return value === cond;
    });
  t.findUnique.mockImplementation(async ({ where }: { where: Where }) => rows.find((r) => matches(r, where)) ?? null);
  t.findFirst.mockImplementation(async ({ where }: { where: Where }) => rows.find((r) => matches(r, where)) ?? null);
  t.create.mockImplementation(async ({ data }: { data: Omit<TokenRow, "id" | "usedAt"> }) => {
    const row = { id: `tok-${++next}`, usedAt: null, ...data };
    rows.push(row);
    return row;
  });
  t.deleteMany.mockImplementation(async ({ where }: { where: Where }) => {
    const gone = rows.filter((r) => matches(r, where));
    for (const row of gone) rows.splice(rows.indexOf(row), 1);
    return { count: gone.length };
  });
  t.updateMany.mockImplementation(async ({ where, data }: { where: Where; data: Partial<TokenRow> }) => {
    const hit = rows.filter((r) => matches(r, where));
    for (const row of hit) Object.assign(row, data);
    return { count: hit.length };
  });
  return rows;
}

/** The family as the erase reads it: two parents, two children. */
function seedFamily() {
  prismaMock.parent.findUnique.mockImplementation(async ({ where }: { where: { id?: string; email?: string } }) => {
    const all = [OWNER, CO];
    return all.find((p) => (where.id !== undefined ? p.id === where.id : p.email === where.email)) ?? null;
  });
  prismaMock.parent.findMany.mockResolvedValue([{ id: OWNER.id }, { id: CO.id }]);
  prismaMock.parent.update.mockResolvedValue({});
  prismaMock.child.findMany.mockResolvedValue([{ id: "child-1" }, { id: "child-2" }]);
  prismaMock.child.delete.mockResolvedValue({});
  prismaMock.family.delete.mockResolvedValue({});
  prismaMock.consentRecord.count.mockResolvedValue(0);
  for (const model of new Set([...CHILD_SCOPED_DELETE_ORDER, ...Object.keys(FAMILY_SCOPED_DELETES)])) {
    if (model !== "child" && model !== "accountDeletionToken") {
      (prismaMock as unknown as Record<string, Record<string, ReturnType<typeof vi.fn>>>)[model].deleteMany.mockResolvedValue({ count: 1 });
    }
  }
  const redis = getRedis() as unknown as MockRedis;
  redis.smembers.mockResolvedValue([]);
  redis.publish.mockResolvedValue(0);
}

const sent: EmailMessage[] = [];
const app = () => buildApp(accountRoutes, "/v1/account");
const form = (fields: Record<string, string>) => ({
  headers: { "content-type": "application/x-www-form-urlencoded" },
  payload: new URLSearchParams(fields).toString(),
});
/** The token in the one mail sent to `to`, read from the link exactly as the recipient would. */
const tokenMailedTo = (to: string) => {
  const mail = sent.filter((m) => m.to === to).at(-1);
  const match = mail?.text.match(/\/v1\/account\/delete\/confirm\?token=([a-f0-9]+)/);
  if (!match) throw new Error(`no deletion link mailed to ${to}`);
  return match[1];
};

async function requestLink(a: Awaited<ReturnType<typeof app>>, email: string) {
  const res = await a.inject({ method: "POST", url: "/v1/account/deletion-request", payload: { email } });
  await settleDeletionRequests();
  return res;
}

const confirm = (a: Awaited<ReturnType<typeof app>>, fields: Record<string, string>) =>
  a.inject({ method: "POST", url: "/v1/account/delete/confirm", ...form(fields) });

let rows: TokenRow[];
beforeEach(() => {
  resetPrismaMock();
  vi.mocked(argon2.verify).mockReset().mockResolvedValue(true);
  vi.mocked(verifyTotpFresh).mockReset().mockResolvedValue(false);
  sent.length = 0;
  setEmailSender({ name: "test", send: async (m) => { sent.push(m); return { ok: true }; } });
  rows = wireTokenTable();
  seedFamily();
});
afterEach(() => {
  setEmailSender(null);
  vi.useRealTimers();
});

describe("POST /v1/account/deletion-request — says nothing about whether an account exists", () => {
  it("W1 a known and an unknown address get the same status and the same body, JSON and form", async () => {
    // Mutant: answer 404 (or any other body) when issueDeletionLink finds no parent.
    const a = await app();
    const known = await requestLink(a, OWNER.email);
    const unknown = await requestLink(a, "nobody@example.com");
    expect(known.statusCode).toBe(202);
    expect(unknown.statusCode).toBe(202);
    expect(known.json()).toEqual(DELETION_REQUEST_ACCEPTED);
    expect(unknown.body).toBe(known.body);

    const knownForm = await a.inject({ method: "POST", url: "/v1/account/deletion-request", ...form({ email: CO.email }) });
    const unknownForm = await a.inject({ method: "POST", url: "/v1/account/deletion-request", ...form({ email: "nobody2@example.com" }) });
    await settleDeletionRequests();
    expect(knownForm.statusCode).toBe(202);
    expect(unknownForm.statusCode).toBe(202);
    expect(unknownForm.body).toBe(knownForm.body);
    expect(knownForm.body).not.toContain(CO.email); // nothing typed is echoed back
  });

  it("W2 the answer does not wait for the lookup, so the time to answer cannot tell the two apart", async () => {
    // Mutant: `await work` before replying (look the address up, then answer).
    let release!: () => void;
    prismaMock.parent.findUnique.mockImplementation(() => new Promise((resolve) => { release = () => resolve(null); }));
    const a = await app();
    const answered = await Promise.race([
      a.inject({ method: "POST", url: "/v1/account/deletion-request", payload: { email: OWNER.email } }),
      new Promise<"timeout">((resolve) => setTimeout(() => resolve("timeout"), 1000)),
    ]);
    expect(answered).not.toBe("timeout");
    expect((answered as { statusCode: number }).statusCode).toBe(202);
    release();
    await settleDeletionRequests();
  });

  it("W3 only the known address is mailed, and the address is normalised as /login does", async () => {
    const a = await app();
    await requestLink(a, "nobody@example.com");
    expect(sent).toEqual([]);
    expect(rows).toEqual([]);
    // Mutant: drop the trim/lower-case transform, and "Owner@Example.COM" finds no account.
    await requestLink(a, "Owner@Example.COM");
    expect(prismaMock.parent.findUnique).toHaveBeenCalledWith({ where: { email: OWNER.email }, select: { id: true, email: true } });
    expect(sent.map((m) => m.to)).toEqual([OWNER.email]);
    expect(sent[0].text).toContain("30 minutes");
    // A malformed address is refused without a lookup; that answer is about the input, not an account.
    const bad = await a.inject({ method: "POST", url: "/v1/account/deletion-request", payload: { email: "not-an-email" } });
    expect(bad.statusCode).toBe(400);
  });

  it("W4 only the token's hash is stored, with a 30-minute expiry; the plaintext is in the mail alone", async () => {
    // Mutant: store `token` instead of `hashDeletionToken(token)`.
    const a = await app();
    const before = Date.now();
    await requestLink(a, OWNER.email);
    const token = tokenMailedTo(OWNER.email);
    expect(token).toMatch(/^[a-f0-9]{64}$/); // 32 random bytes
    expect(rows).toHaveLength(1);
    expect(rows[0].tokenHash).toBe(hashDeletionToken(token));
    expect(rows[0].parentId).toBe(OWNER.id);
    const ttl = rows[0].expiresAt.getTime() - before;
    expect(ttl).toBeGreaterThanOrEqual(ACCOUNT_DELETION_TTL_MS - 1000);
    expect(ttl).toBeLessThanOrEqual(ACCOUNT_DELETION_TTL_MS + 1000);
    const everythingWritten = JSON.stringify(
      Object.values(prismaMock.accountDeletionToken).flatMap((fn) => (fn as ReturnType<typeof vi.fn>).mock.calls),
    );
    expect(everythingWritten).not.toContain(token);
  });

  it("W5 a new request invalidates the older link; a second request inside a minute mails nothing", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-10-30T10:00:00Z"));
    const a = await app();
    await requestLink(a, OWNER.email);
    const first = tokenMailedTo(OWNER.email);
    // Inside the cooldown: no second mail, and the first link still works.
    vi.setSystemTime(new Date("2026-10-30T10:00:30Z"));
    await requestLink(a, OWNER.email);
    expect(sent).toHaveLength(1);
    // Mutant: drop the deleteMany from issueDeletionLink's transaction, and the first link stays live.
    vi.setSystemTime(new Date("2026-10-30T10:02:00Z"));
    await requestLink(a, OWNER.email);
    expect(sent).toHaveLength(2);
    const second = tokenMailedTo(OWNER.email);
    expect(second).not.toBe(first);
    expect((await a.inject({ method: "GET", url: `/v1/account/delete/confirm?token=${first}` })).statusCode).toBe(404);
    expect((await a.inject({ method: "GET", url: `/v1/account/delete/confirm?token=${second}` })).statusCode).toBe(200);
    expect(rows).toHaveLength(1);
  });

  it("W6 a mail that failed to send leaves no live link behind", async () => {
    setEmailSender({ name: "down", send: async () => ({ ok: false, reason: "HTTP 503", retryable: true }) });
    const a = await app();
    const res = await requestLink(a, OWNER.email);
    expect(res.statusCode).toBe(202);
    expect(rows).toEqual([]);
  });
});

describe("GET /v1/account/delete and the confirm page", () => {
  it("W7 the public page has the in-app steps and the form, in English and Arabic (RTL)", async () => {
    const a = await app();
    const res = await a.inject({ method: "GET", url: "/v1/account/delete" });
    expect(res.statusCode).toBe(200);
    expect(res.headers["content-type"]).toMatch(/text\/html/);
    expect(res.body).toContain("Settings, then Delete account");
    expect(res.body).toContain('action="/v1/account/deletion-request"');
    expect(res.body).toContain('lang="ar" dir="rtl"');
    expect(res.body).toContain("حذف حسابك في أسرة");
  });

  it("W8 the confirm page spends nothing, is never cached or sent as a referrer, and holds no account secret", async () => {
    const a = await app();
    prismaMock.parent.findUnique.mockImplementation(async ({ where }: { where: { id?: string; email?: string } }) =>
      where.email === OWNER.email || where.id === OWNER.id ? { ...OWNER, mfaEnabled: true, mfaSecret: "enc:totp-secret" } : null,
    );
    await requestLink(a, OWNER.email);
    const token = tokenMailedTo(OWNER.email);
    const res = await a.inject({ method: "GET", url: `/v1/account/delete/confirm?token=${token}` });
    expect(res.statusCode).toBe(200);
    expect(res.headers["cache-control"]).toBe("no-store");
    expect(res.headers["referrer-policy"]).toBe("no-referrer");
    expect(res.headers["content-security-policy"]).toContain("frame-ancestors 'none'");
    expect(res.body).toContain('name="password"');
    expect(res.body).toContain('name="mfaCode"'); // MFA is on, so the code is asked for
    expect(res.body).toContain("Delete the family and all its data"); // the owner is told what goes
    for (const secret of ["enc:totp-secret", OWNER.passwordHash, OWNER.email, OWNER.id]) expect(res.body).not.toContain(secret);
    expect(rows[0].usedAt).toBeNull();
    expect(prismaMock.family.delete).not.toHaveBeenCalled();
  });

  it("W9 an expired link shows the expired page on GET and on POST, and deletes nothing", async () => {
    // Mutant: drop the `expiresAt <= now` check in findLiveDeletionLink, and the page offers the form.
    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(new Date("2026-10-30T10:00:00Z"));
    const a = await app();
    await requestLink(a, OWNER.email);
    const token = tokenMailedTo(OWNER.email);
    vi.setSystemTime(new Date("2026-10-30T10:30:01Z"));
    const page = await a.inject({ method: "GET", url: `/v1/account/delete/confirm?token=${token}` });
    expect(page.statusCode).toBe(404);
    expect(page.body).toContain("expired or was already used");
    expect(page.body).not.toContain('name="password"');
    const post = await confirm(a, { token, password: PASSWORD });
    expect(post.statusCode).toBe(404);
    expect(prismaMock.family.delete).not.toHaveBeenCalled();
    expect(argon2.verify).not.toHaveBeenCalled();
  });

  it("W10 malformed, unknown and missing tokens get the same expired page, never an error body", async () => {
    const a = await app();
    for (const url of ["/v1/account/delete/confirm", "/v1/account/delete/confirm?token=xyz", `/v1/account/delete/confirm?token=${"a".repeat(64)}`]) {
      const res = await a.inject({ method: "GET", url });
      expect([400, 404]).toContain(res.statusCode);
      expect(res.body).toContain("expired or was already used");
    }
    const post = await a.inject({ method: "POST", url: "/v1/account/delete/confirm", payload: { password: PASSWORD } });
    expect(post.statusCode).toBe(400);
    expect(post.body).toContain("expired or was already used");
  });
});

describe("POST /v1/account/delete/confirm — the same erase as the app, after the same re-authentication", () => {
  it("W11 the owner's link deletes the whole family, through PR 1's eraseFamilyData", async () => {
    const a = await app();
    await requestLink(a, OWNER.email);
    const res = await confirm(a, { token: tokenMailedTo(OWNER.email), password: PASSWORD });
    expect(res.statusCode).toBe(200);
    expect(res.body).toContain("The family and all its data have been deleted");
    expect(argon2.verify).toHaveBeenCalledWith(OWNER.passwordHash, PASSWORD);
    expect(prismaMock.child.delete).toHaveBeenCalledWith({ where: { id: "child-1" } });
    expect(prismaMock.child.delete).toHaveBeenCalledWith({ where: { id: "child-2" } });
    expect(prismaMock.parent.deleteMany).toHaveBeenCalledWith({ where: { familyId: "fam-1" } });
    expect(prismaMock.family.delete).toHaveBeenCalledWith({ where: { id: "fam-1" } });
    expect(rows).toEqual([]); // every parent's link rows go with the family
  });

  it("W12 a co-parent's link deletes only that person, through PR 1's eraseParentAccount", async () => {
    // Mutant: call eraseFamilyData whatever the role, and a co-parent's link deletes the family.
    const a = await app();
    await requestLink(a, CO.email);
    const res = await confirm(a, { token: tokenMailedTo(CO.email), password: PASSWORD });
    expect(res.statusCode).toBe(200);
    expect(res.body).toContain("Your account has been deleted");
    expect(prismaMock.parent.deleteMany).toHaveBeenCalledWith({ where: { id: CO.id } });
    expect(prismaMock.parentPushToken.deleteMany).toHaveBeenCalledWith({ where: { parentId: CO.id } });
    expect(prismaMock.family.delete).not.toHaveBeenCalled();
    expect(prismaMock.child.delete).not.toHaveBeenCalled();
    expect(prismaMock.parent.deleteMany).not.toHaveBeenCalledWith({ where: { familyId: "fam-1" } });
  });

  it("W13 a wrong password deletes nothing, shows the form again and leaves the link usable", async () => {
    // Mutant: skip checkReauth, and the link alone deletes the family.
    // Mutant: spend the link before checkReauth, and the retry with the right password finds it used.
    const a = await app();
    await requestLink(a, OWNER.email);
    const token = tokenMailedTo(OWNER.email);
    vi.mocked(argon2.verify).mockResolvedValueOnce(false);
    const wrong = await confirm(a, { token, password: "wrong" });
    expect(wrong.statusCode).toBe(401);
    expect(wrong.body).toContain("That password or authenticator code is not right");
    expect(wrong.body).toContain('name="password"');
    expect(wrong.headers["cache-control"]).toBe("no-store");
    expect(prismaMock.family.delete).not.toHaveBeenCalled();
    expect(prismaMock.parent.update).not.toHaveBeenCalled(); // not even the session bump
    expect(rows[0].usedAt).toBeNull();

    const right = await confirm(a, { token, password: PASSWORD });
    expect(right.statusCode).toBe(200);
    expect(prismaMock.family.delete).toHaveBeenCalledTimes(1);
  });

  it("W14 with MFA on, the password alone is not enough; a fresh code is", async () => {
    const mfaOwner = { ...OWNER, mfaEnabled: true, mfaSecret: "enc:secret" };
    prismaMock.parent.findUnique.mockImplementation(async ({ where }: { where: { id?: string; email?: string } }) =>
      where.email === OWNER.email || where.id === OWNER.id ? mfaOwner : null,
    );
    const a = await app();
    await requestLink(a, OWNER.email);
    const token = tokenMailedTo(OWNER.email);
    const noCode = await confirm(a, { token, password: PASSWORD, mfaCode: "" });
    expect(noCode.statusCode).toBe(401);
    expect(prismaMock.family.delete).not.toHaveBeenCalled();
    vi.mocked(verifyTotpFresh).mockResolvedValue(true);
    const ok = await confirm(a, { token, password: PASSWORD, mfaCode: "123 456" });
    expect(ok.statusCode).toBe(200);
    expect(verifyTotpFresh).toHaveBeenCalledWith(OWNER.id, "enc:secret", "123456");
  });

  it("W15 a link deletes once: a used link is the expired page, even when the erase failed after spending it", async () => {
    // Mutant: drop `consumeDeletionLink` (or ignore its answer), and the same link erases twice.
    const a = await app();
    await requestLink(a, OWNER.email);
    const token = tokenMailedTo(OWNER.email);
    prismaMock.child.delete.mockRejectedValueOnce(new Error("db exploded: internal detail"));
    const failed = await confirm(a, { token, password: PASSWORD });
    expect(failed.statusCode).toBe(500);
    expect(failed.body).toContain("The deletion did not finish");
    expect(failed.body).not.toContain("internal detail"); // a page, never the error
    expect(rows[0].usedAt).toBeInstanceOf(Date);

    const again = await confirm(a, { token, password: PASSWORD });
    expect(again.statusCode).toBe(404);
    expect(again.body).toContain("expired or was already used");
    expect(prismaMock.child.delete).toHaveBeenCalledTimes(1);
  });

  it("W16 two submits racing on one link: exactly one erases", async () => {
    const a = await app();
    await requestLink(a, OWNER.email);
    const token = tokenMailedTo(OWNER.email);
    // Hold both password checks until both requests have read the link as live.
    let waiting: Array<() => void> = [];
    vi.mocked(argon2.verify).mockImplementation(
      () => new Promise<boolean>((resolve) => {
        waiting.push(() => resolve(true));
        if (waiting.length === 2) { for (const go of waiting) go(); waiting = []; }
      }),
    );
    const [one, two] = await Promise.all([confirm(a, { token, password: PASSWORD }), confirm(a, { token, password: PASSWORD })]);
    expect([one.statusCode, two.statusCode].sort()).toEqual([200, 404]);
    expect(prismaMock.family.delete).toHaveBeenCalledTimes(1);
  });

  it("W17 a consent record held in another family refuses the deletion and keeps the link", async () => {
    const a = await app();
    await requestLink(a, OWNER.email);
    const token = tokenMailedTo(OWNER.email);
    prismaMock.consentRecord.count.mockResolvedValue(1);
    const res = await confirm(a, { token, password: PASSWORD });
    expect(res.statusCode).toBe(409);
    expect(res.body).toContain("consent record");
    expect(prismaMock.family.delete).not.toHaveBeenCalled();
    expect(rows[0].usedAt).toBeNull();
  });
});

describe("rate limit and logs", () => {
  it("W18 both POST routes carry AUTH_RATE_LIMIT", async () => {
    // Mutant: drop `config: { rateLimit: AUTH_RATE_LIMIT }` from either POST.
    const seen = new Map<string, unknown>();
    const f = Fastify({ logger: false });
    await f.register(fastifyJwt, { secret: "test-secret" });
    f.addHook("onRoute", (route) => {
      if (route.method === "POST") seen.set(route.url, (route.config as { rateLimit?: unknown } | undefined)?.rateLimit);
    });
    await f.register(accountRoutes, { prefix: "/v1/account" });
    await f.ready();
    expect(seen.get("/v1/account/deletion-request")).toBe(AUTH_RATE_LIMIT);
    expect(seen.get("/v1/account/delete/confirm")).toBe(AUTH_RATE_LIMIT);
  });

  it("W19 the request log carries the confirm URL without its token", async () => {
    // Mutant: drop `token` from SECRET_QUERY_PARAMS. And server.ts must install the serializer: it listens on
    // import, so the wiring is read from its source, as the §4 guard reads schema.prisma.
    // Mutant: drop `serializers: LOGGER_SERIALIZERS` from server.ts.
    const server = readFileSync(fileURLToPath(new URL("../src/server.ts", import.meta.url)), "utf8");
    expect(server).toMatch(/logger: \{[^}]*serializers: LOGGER_SERIALIZERS/);
    expect(server).toContain('app.register(accountRoutes, { prefix: "/v1/account" })');
    expect(redactUrl("/v1/account/delete/confirm?token=abc&x=1")).toBe("/v1/account/delete/confirm?token=[redacted]&x=1");
    expect(redactUrl("/v1/ws?ticket=t1")).toBe("/v1/ws?ticket=[redacted]");
    const lines: string[] = [];
    const stream = new Writable({ write(chunk, _enc, done) { lines.push(String(chunk)); done(); } });
    const f = Fastify({ logger: { level: "info", serializers: LOGGER_SERIALIZERS, stream } });
    await f.register(fastifyJwt, { secret: "test-secret" });
    await f.register(accountRoutes, { prefix: "/v1/account" });
    await f.ready();
    await requestLink(f as unknown as Awaited<ReturnType<typeof app>>, OWNER.email);
    const token = tokenMailedTo(OWNER.email);
    await f.inject({ method: "GET", url: `/v1/account/delete/confirm?token=${token}` });
    await confirm(f as unknown as Awaited<ReturnType<typeof app>>, { token, password: PASSWORD });
    const log = lines.join("");
    expect(log).toContain("/v1/account/delete/confirm?token=[redacted]");
    expect(log).not.toContain(token);
  });
});
