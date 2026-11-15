import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import Fastify, { type FastifyInstance } from "fastify";
import fastifyJwt from "@fastify/jwt";
import argon2 from "argon2";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { authRoutes } from "../src/routes/auth.js";
import { linkPageRoutes } from "../src/routes/linkPages.js";
import { setEmailSender, type EmailMessage } from "../src/lib/email/index.js";
import { verifyTotpFresh } from "../src/lib/mfaVerify.js";
import { AUTH_RATE_LIMIT, registerRateLimits } from "../src/lib/rateLimits.js";
import { getRedis } from "../src/redis.js";
import { FakeRateLimitRedis, MockRedis, buildApp, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});
vi.mock("argon2", () => ({
  default: { verify: vi.fn(async () => true), hash: vi.fn(async () => "argon2$new-hash") },
}));
vi.mock("../src/lib/mfaVerify.js", () => ({ verifyTotpFresh: vi.fn(async () => false) }));

/**
 * #789: the pages the mailed links open. The state changes themselves are tested where they live
 * (auth.test.ts, mfa-reset.test.ts, invites.test.ts); these rows test the page around each one.
 *
 * Each test names its mutant: the one-line change to the production code that makes it fail.
 */

const PARENT = {
  id: "parent-1", familyId: "fam-own", email: "invitee@example.com", displayName: "Invitee",
  role: "owner", permissions: [] as string[], passwordHash: "argon2$hash", mfaEnabled: false, mfaSecret: null as string | null, sessionVersion: 3,
};
const PASSWORD = "CorrectHorseBatteryStaple!";
const NEW_PASSWORD = "NewCorrectHorse12!";
const INVITE_ID = "0b5c1f0e-7a54-4c1e-9d6b-3f2a1c9e8d77";

/** The mocked Redis backed by a Map, with the Lua GET+DEL consume the routes use. */
function wireRedis(): Map<string, string> {
  const redis = getRedis() as unknown as MockRedis;
  const store = new Map<string, string>();
  redis.get.mockImplementation(async (k: string) => store.get(k) ?? null);
  redis.set.mockImplementation(async (k: string, v: string, ...args: unknown[]) => {
    if (args.includes("NX") && store.has(k)) return null;
    store.set(k, String(v));
    return "OK";
  });
  redis.eval.mockImplementation(async (_script: string, _n: number, key: string) => {
    const v = store.get(key) ?? null;
    store.delete(key);
    return v;
  });
  redis.del.mockImplementation(async (...ks: string[]) => ks.reduce((n, k) => n + (store.delete(k) ? 1 : 0), 0));
  redis.incrby.mockImplementation(async () => 1);
  redis.smembers.mockImplementation(async () => []);
  redis.sadd.mockImplementation(async () => 1);
  redis.srem.mockImplementation(async () => 1);
  redis.expire.mockImplementation(async () => 1);
  return store;
}

const sent: EmailMessage[] = [];
/** The real auth routes under /v1/auth and the pages at the root, as server.ts mounts them. */
const realApp = () =>
  buildApp(async (app) => {
    await app.register(authRoutes, { prefix: "/v1/auth" });
    await app.register(linkPageRoutes);
  }, "");

const form = (fields: Record<string, string>) => ({
  headers: { "content-type": "application/x-www-form-urlencoded" },
  payload: new URLSearchParams(fields).toString(),
});

/** No parent, family, invite or reset-request row was written. */
function expectNoWrites() {
  expect(prismaMock.parent.update).not.toHaveBeenCalled();
  expect(prismaMock.familyInvite.update).not.toHaveBeenCalled();
  expect(prismaMock.mfaResetRequest.update).not.toHaveBeenCalled();
  expect(prismaMock.mfaResetRequest.updateMany).not.toHaveBeenCalled();
}

function expectPageHeaders(res: { headers: Record<string, unknown> }) {
  expect(res.headers["content-type"]).toBe("text/html; charset=utf-8");
  expect(res.headers["cache-control"]).toBe("no-store");
  expect(res.headers["referrer-policy"]).toBe("no-referrer");
  expect(String(res.headers["content-security-policy"])).toContain("default-src 'none'");
  expect(String(res.headers["content-security-policy"])).toContain("frame-ancestors 'none'");
}

let store: Map<string, string>;

beforeEach(() => {
  resetPrismaMock();
  sent.length = 0;
  setEmailSender({ name: "capture", send: async (m) => (sent.push(m), { ok: true as const }) });
  store = wireRedis();
  vi.mocked(argon2.verify).mockResolvedValue(true);
  vi.mocked(verifyTotpFresh).mockResolvedValue(false);
  prismaMock.parent.findUnique.mockImplementation(async ({ where }: { where: { id?: string; email?: string } }) =>
    (where.id !== undefined ? where.id === PARENT.id : where.email === PARENT.email) ? { ...PARENT } : null,
  );
  prismaMock.parent.update.mockResolvedValue({ ...PARENT });
});

afterEach(() => setEmailSender(null));

async function mailedResetToken(app: FastifyInstance): Promise<string> {
  const res = await app.inject({ method: "POST", url: "/v1/auth/reset/request", payload: { email: PARENT.email } });
  expect(res.statusCode).toBe(200);
  const match = sent.at(-1)!.text.match(/(\/reset\?token=)([^\s"'<]+)/);
  expect(match).toBeTruthy();
  return decodeURIComponent(match![2]);
}

describe("password reset page", () => {
  it("L1 the mailed link opens a form that posts to /reset, and opening it spends nothing", async () => {
    // Mutant: make GET /reset call /v1/auth/reset/confirm, or drop the route.
    const app = await realApp();
    const token = await mailedResetToken(app);
    const before = new Map(store);
    const res = await app.inject({ method: "GET", url: `/reset?token=${encodeURIComponent(token)}` });
    expect(res.statusCode).toBe(200);
    expectPageHeaders(res);
    expect(res.body).toContain('<form method="post" action="/reset">');
    expect(res.body).toContain(`name="token" value="${token}"`);
    expect(res.body).toContain("اختيار كلمة مرور جديدة");
    expect(res.body).not.toContain("<script");
    expect(new Map(store)).toEqual(before);
    expectNoWrites();
  });

  it("L2 the form changes the password once; the same link then shows the expired page", async () => {
    // Mutant: answer the done page without calling the confirm route.
    const app = await realApp();
    const token = await mailedResetToken(app);
    const ok = await app.inject({ method: "POST", url: "/reset", ...form({ token, password: NEW_PASSWORD, passwordRepeat: NEW_PASSWORD }) });
    expect(ok.statusCode).toBe(200);
    expect(ok.body).toContain("Password changed");
    expect(prismaMock.parent.update).toHaveBeenCalledWith({ where: { id: PARENT.id }, data: { passwordHash: "argon2$new-hash" } });
    const again = await app.inject({ method: "POST", url: "/reset", ...form({ token, password: NEW_PASSWORD, passwordRepeat: NEW_PASSWORD }) });
    expect(again.statusCode).toBe(404);
    expect(again.body).toContain("expired or was already used");
  });

  it("L3 two different passwords, or a short one, show the form again and do not spend the link", async () => {
    // Mutant: drop the `password !== passwordRepeat` check (the first password would be set). A short
    // password is refused twice (here and by the JSON route), so no single mutant shows it.
    const app = await realApp();
    const token = await mailedResetToken(app);
    const mismatch = await app.inject({ method: "POST", url: "/reset", ...form({ token, password: NEW_PASSWORD, passwordRepeat: `${NEW_PASSWORD}x` }) });
    expect(mismatch.statusCode).toBe(400);
    expect(mismatch.body).toContain("The two passwords are not the same.");
    expect(mismatch.body).toContain(`name="token" value="${token}"`);
    const short = await app.inject({ method: "POST", url: "/reset", ...form({ token, password: "short", passwordRepeat: "short" }) });
    expect(short.statusCode).toBe(400);
    expect(short.body).toContain("at least 12 characters");
    expectNoWrites();
    const ok = await app.inject({ method: "POST", url: "/reset", ...form({ token, password: NEW_PASSWORD, passwordRepeat: NEW_PASSWORD }) });
    expect(ok.statusCode).toBe(200);
  });

  it("L4 a failure on our side shows the form again with the link still usable (#162 retry contract)", async () => {
    // Mutant: map a 5xx from the confirm route to the expired page.
    const app = await realApp();
    const token = await mailedResetToken(app);
    prismaMock.parent.update.mockRejectedValueOnce(new Error("connection reset"));
    const failed = await app.inject({ method: "POST", url: "/reset", ...form({ token, password: NEW_PASSWORD, passwordRepeat: NEW_PASSWORD }) });
    expect(failed.statusCode).toBe(503);
    expect(failed.body).toContain("Something went wrong on our side");
    expect(failed.body).toContain(`name="token" value="${token}"`);
    const retry = await app.inject({ method: "POST", url: "/reset", ...form({ token, password: NEW_PASSWORD, passwordRepeat: NEW_PASSWORD }) });
    expect(retry.statusCode).toBe(200);
  });

  it("L5 a malformed token, a token of another purpose and a forged one all get the same page, and none is echoed", async () => {
    // Mutant: drop the purpose comparison in `signedFor`, or render the token without the pattern check.
    const app = await realApp();
    const session = app.jwt.sign({ sub: PARENT.id, familyId: PARENT.familyId, role: "parent" });
    const forged = Fastify().register(fastifyJwt, { secret: "another-secret" });
    await forged.ready();
    const other = (forged as unknown as FastifyInstance).jwt.sign({ sub: PARENT.id, purpose: "password_reset", jti: "j1" });
    const bodies = new Set<string>();
    for (const token of ['"><script>alert(1)</script>', "", session, other]) {
      const res = await app.inject({ method: "GET", url: `/reset?token=${encodeURIComponent(token)}` });
      expect(res.statusCode).toBe(404);
      expect(res.body).not.toContain("<script");
      expect(res.body).not.toContain('<form');
      bodies.add(res.body);
      const post = await app.inject({ method: "POST", url: "/reset", ...form({ token, password: NEW_PASSWORD, passwordRepeat: NEW_PASSWORD }) });
      expect(post.statusCode).toBe(404);
    }
    expect(bodies.size).toBe(1);
    expectNoWrites();
  });
});

describe("MFA reset pages (ADR-0031)", () => {
  const REQUEST = { id: "req-1", parentId: PARENT.id, familyId: PARENT.familyId, state: "requested" };

  function seedConfirm(app: FastifyInstance): string {
    store.set("mfa:reset:confirm:jti-1", `${REQUEST.id}|${PARENT.id}`);
    return app.jwt.sign({ sub: PARENT.id, purpose: "mfa_reset_confirm", jti: "jti-1" }, { expiresIn: "30m" });
  }

  it("L6 GET /mfa/reset/confirm shows one button and changes no state; the button then confirms", async () => {
    // Mutant: confirm on GET (a mail scanner following the link would pass the mailbox step).
    const app = await realApp();
    const token = seedConfirm(app);
    const state = { ...REQUEST };
    prismaMock.mfaResetRequest.findUnique.mockImplementation(async () => ({ ...state }));
    prismaMock.mfaResetRequest.updateMany.mockImplementation(async ({ data }: { data: { state: string } }) => {
      state.state = data.state;
      return { count: 1 };
    });
    prismaMock.device.findMany.mockResolvedValue([]);

    const get = await app.inject({ method: "GET", url: `/mfa/reset/confirm?token=${encodeURIComponent(token)}` });
    expect(get.statusCode).toBe(200);
    expectPageHeaders(get);
    expect(get.body).toContain('<form method="post" action="/mfa/reset/confirm">');
    expect(store.has("mfa:reset:confirm:jti-1")).toBe(true);
    expect(state.state).toBe("requested");
    expectNoWrites();

    const post = await app.inject({ method: "POST", url: "/mfa/reset/confirm", ...form({ token }) });
    expect(post.statusCode).toBe(200);
    expect(post.body).toContain("Another parent in your family must now approve");
    expect(state.state).toBe("mailbox_confirmed");
    expect(store.has("mfa:reset:confirm:jti-1")).toBe(false);

    const again = await app.inject({ method: "POST", url: "/mfa/reset/confirm", ...form({ token }) });
    expect(again.statusCode).toBe(404);
    expect(again.body).toContain("expired or was already used");
  });

  it("L7 GET /mfa/reset/cancel changes no state; the button cancels, and only a cancelled request is called cancelled", async () => {
    // Mutants: cancel on GET; report "cancelled" for any 200 (a completed reset would read as stopped).
    const app = await realApp();
    const token = app.jwt.sign({ sub: PARENT.id, purpose: "mfa_reset_cancel", requestId: REQUEST.id }, { expiresIn: "7d" });
    const state = { ...REQUEST };
    prismaMock.mfaResetRequest.findUnique.mockImplementation(async () => ({ ...state }));
    prismaMock.mfaResetRequest.updateMany.mockImplementation(async ({ data }: { data: { state: string } }) => {
      if (state.state === "completed") return { count: 0 };
      state.state = data.state;
      return { count: 1 };
    });

    const get = await app.inject({ method: "GET", url: `/mfa/reset/cancel?token=${encodeURIComponent(token)}` });
    expect(get.statusCode).toBe(200);
    expect(get.body).toContain('<form method="post" action="/mfa/reset/cancel">');
    expect(state.state).toBe("requested");
    expectNoWrites();

    const post = await app.inject({ method: "POST", url: "/mfa/reset/cancel", ...form({ token }) });
    expect(post.statusCode).toBe(200);
    expect(post.body).toContain("The reset was cancelled");
    expect(state.state).toBe("cancelled_by_link");

    state.state = "completed";
    const late = await app.inject({ method: "POST", url: "/mfa/reset/cancel", ...form({ token }) });
    expect(late.statusCode).toBe(200);
    expect(late.body).toContain("This request is already closed");
    expect(late.body).not.toContain("The reset was cancelled");
  });

  it("L8 a confirm token does not open the cancel page, nor the other way round", async () => {
    // Mutant: one shared purpose check for both pages.
    const app = await realApp();
    const confirm = seedConfirm(app);
    const cancel = app.jwt.sign({ sub: PARENT.id, purpose: "mfa_reset_cancel", requestId: REQUEST.id });
    expect((await app.inject({ method: "GET", url: `/mfa/reset/cancel?token=${confirm}` })).statusCode).toBe(404);
    expect((await app.inject({ method: "GET", url: `/mfa/reset/confirm?token=${cancel}` })).statusCode).toBe(404);
    expect((await app.inject({ method: "POST", url: "/mfa/reset/confirm", ...form({ token: cancel }) })).statusCode).toBe(404);
    expectNoWrites();
  });
});

/**
 * The pages in front of stand-in JSON routes, to pin how each answer is shown and which address the
 * inner call counts against. The stand-ins answer what the real routes answer (auth.ts).
 */
describe("how the pages read the JSON routes' answers", () => {
  type Answer = { status: number; body: Record<string, unknown> };
  async function stubApp(answer: Answer, seen: { ip?: string; payload?: unknown } = {}, trustProxy: number | false = false) {
    const app = Fastify({ logger: false, trustProxy });
    await app.register(fastifyJwt, { secret: "test-secret" });
    for (const url of ["/v1/auth/reset/confirm", "/v1/auth/mfa/reset/confirm", "/v1/auth/mfa/reset/cancel"]) {
      app.post(url, async (req, reply) => {
        seen.ip = req.ip;
        seen.payload = req.body;
        return reply.code(answer.status).send(answer.body);
      });
    }
    await app.register(linkPageRoutes);
    await app.ready();
    return app;
  }
  const confirmToken = (app: FastifyInstance) => app.jwt.sign({ sub: "p", purpose: "mfa_reset_confirm", jti: "j" });

  it("L9 the confirm page tells a device witness from a parent witness", async () => {
    // Mutant: always show the "another parent" page.
    const app = await stubApp({ status: 200, body: { ok: true, witness: "device" } });
    const res = await app.inject({ method: "POST", url: "/mfa/reset/confirm", ...form({ token: confirmToken(app) }) });
    expect(res.statusCode).toBe(200);
    expect(res.body).toContain("A code is now shown on your child's phone");
  });

  it("L10 not-open, store-down, dispatch-failed and rate-limited each get their own page", async () => {
    // Mutant: collapse the branches into the expired page.
    const cases: Array<[Answer, number, string, boolean]> = [
      [{ status: 409, body: { error: "request_not_open" } }, 409, "no longer open", false],
      [{ status: 503, body: { error: "reset_unavailable" } }, 503, "Try again in a minute", true],
      [{ status: 503, body: { error: "witness_dispatch_failed" } }, 503, "start the reset again", false],
      [{ status: 429, body: { error: "rate_limited" } }, 429, "Too many attempts", true],
      [{ status: 401, body: { error: "invalid_or_expired_token" } }, 404, "expired or was already used", false],
    ];
    for (const [answer, status, text, keepsButton] of cases) {
      const app = await stubApp(answer);
      const res = await app.inject({ method: "POST", url: "/mfa/reset/confirm", ...form({ token: confirmToken(app) }) });
      expect(res.statusCode).toBe(status);
      expect(res.body).toContain(text);
      expect(res.body.includes("<form")).toBe(keepsButton);
    }
  });

  it("L11 the inner call carries the caller's address, with and without a trusted proxy", async () => {
    // Mutant: drop `remoteAddress: req.ip` from `call`: every web reset would then share 127.0.0.1's
    // auth bucket. Behind the ALB `req.ip` is already the forwarded address, so the same line covers both.
    const direct: { ip?: string } = {};
    const a = await stubApp({ status: 200, body: { ok: true, witness: "parent" } }, direct, false);
    await a.inject({ method: "POST", url: "/mfa/reset/confirm", remoteAddress: "203.0.113.7", ...form({ token: confirmToken(a) }) });
    expect(direct.ip).toBe("203.0.113.7");

    const proxied: { ip?: string } = {};
    const b = await stubApp({ status: 200, body: { ok: true, witness: "parent" } }, proxied, 1);
    await b.inject({
      method: "POST",
      url: "/mfa/reset/confirm",
      remoteAddress: "10.0.0.5",
      headers: { "content-type": "application/x-www-form-urlencoded", "x-forwarded-for": "198.51.100.9" },
      payload: new URLSearchParams({ token: confirmToken(b) }).toString(),
    });
    expect(proxied.ip).toBe("198.51.100.9");
  });

  it("L12 the auth bucket counts a web reset against the person, so one address cannot lock the form for all", async () => {
    // Mutant: as L11. Twenty-one submits from one address: the 21st is refused there; another address still passes.
    const redis = new FakeRateLimitRedis();
    const app = Fastify({ logger: false });
    await app.register(fastifyJwt, { secret: "test-secret" });
    await registerRateLimits(app, redis as never);
    app.post("/v1/auth/reset/confirm", { config: { rateLimit: AUTH_RATE_LIMIT } }, async () => ({ ok: true }));
    await app.register(linkPageRoutes);
    await app.ready();
    const token = app.jwt.sign({ sub: "p", purpose: "password_reset", jti: "j" });
    const submit = (ip: string) =>
      app.inject({ method: "POST", url: "/reset", remoteAddress: ip, ...form({ token, password: NEW_PASSWORD, passwordRepeat: NEW_PASSWORD }) });
    for (let i = 0; i < AUTH_RATE_LIMIT.max; i++) expect((await submit("203.0.113.7")).statusCode).toBe(200);
    const blocked = await submit("203.0.113.7");
    expect(blocked.statusCode).toBe(429);
    expect(blocked.body).toContain("Too many attempts");
    expect((await submit("203.0.113.8")).statusCode).toBe(200);
  });
});

describe("family invite page", () => {
  const TOKEN = { familyId: "fam-inviting", email: PARENT.email, role: "co-parent", permissions: ["alerts"] };
  const invite = { id: INVITE_ID, familyId: TOKEN.familyId, email: PARENT.email, role: "co-parent", permissions: ["alerts"], status: "pending" };

  beforeEach(() => {
    store.set(`invite:${INVITE_ID}`, JSON.stringify(TOKEN));
    invite.status = "pending";
    prismaMock.familyInvite.findUnique.mockImplementation(async ({ where }: { where: { id: string } }) => (where.id === INVITE_ID ? { ...invite } : null));
    prismaMock.familyInvite.update.mockImplementation(async ({ data }: { data: { status: string } }) => {
      invite.status = data.status;
      return { ...invite };
    });
  });

  const app = () => buildApp(linkPageRoutes, "");

  it("L13 the link opens the password form for an existing account, and opening it changes nothing", async () => {
    // Mutant: accept on GET.
    const res = await (await app()).inject({ method: "GET", url: `/invite/accept?token=${INVITE_ID}` });
    expect(res.statusCode).toBe(200);
    expectPageHeaders(res);
    expect(res.body).toContain('<form method="post" action="/invite/accept">');
    expect(res.body).toContain(`name="token" value="${INVITE_ID}"`);
    expect(res.body).not.toContain('name="mfaCode"');
    expect(res.body).not.toContain(PARENT.email);
    expect(invite.status).toBe("pending");
    expectNoWrites();
  });

  it("L14 an invited address with no account is told to create one first, and the form is not shown", async () => {
    // Mutant: show the password form when no account uses the invited address.
    prismaMock.parent.findUnique.mockResolvedValue(null);
    const a = await app();
    const res = await a.inject({ method: "GET", url: `/invite/accept?token=${INVITE_ID}` });
    expect(res.statusCode).toBe(200);
    expect(res.body).toContain("First create your account");
    expect(res.body).not.toContain("<form");
    const post = await a.inject({ method: "POST", url: "/invite/accept", ...form({ token: INVITE_ID, password: PASSWORD }) });
    expect(post.body).toContain("First create your account");
    expectNoWrites();
  });

  it("L15 the right password moves the account into the inviting family and spends the invitation", async () => {
    // Mutant: skip `acceptInvite` and answer the done page.
    const a = await app();
    const res = await a.inject({ method: "POST", url: "/invite/accept", ...form({ token: INVITE_ID, password: PASSWORD }) });
    expect(res.statusCode).toBe(200);
    expect(res.body).toContain("You have joined the family");
    expect(argon2.verify).toHaveBeenCalledWith(PARENT.passwordHash, PASSWORD);
    expect(prismaMock.parent.update).toHaveBeenCalledWith({
      where: { id: PARENT.id },
      data: { familyId: "fam-inviting", role: "co-parent", permissions: ["alerts"] },
    });
    // Every session minted in the previous family dies with the move (#117).
    expect(prismaMock.parent.update).toHaveBeenCalledWith({ where: { id: PARENT.id }, data: { sessionVersion: { increment: 1 } } });
    expect(invite.status).toBe("accepted");
    const again = await a.inject({ method: "POST", url: "/invite/accept", ...form({ token: INVITE_ID, password: PASSWORD }) });
    expect(again.statusCode).toBe(404);
    expect(again.body).toContain("expired or was already used");
  });

  it("L16 holding the mail is not enough: a wrong password moves nobody and leaves the invitation usable", async () => {
    // Mutant: drop the `checkReauth` call.
    vi.mocked(argon2.verify).mockResolvedValue(false);
    const a = await app();
    const res = await a.inject({ method: "POST", url: "/invite/accept", ...form({ token: INVITE_ID, password: "wrong-password" }) });
    expect(res.statusCode).toBe(401);
    expect(res.body).toContain("is not right");
    expect(res.body).toContain(`name="token" value="${INVITE_ID}"`);
    expect(invite.status).toBe("pending");
    expectNoWrites();
    const empty = await a.inject({ method: "POST", url: "/invite/accept", ...form({ token: INVITE_ID, password: "" }) });
    expect(empty.statusCode).toBe(400);
    expect(empty.body).toContain("Enter your password.");
  });

  it("L17 an account with two-step sign-in must give its code too", async () => {
    // Mutant: pass `{ password }` to `checkReauth` and ignore MFA.
    prismaMock.parent.findUnique.mockResolvedValue({ ...PARENT, mfaEnabled: true, mfaSecret: "enc:secret" });
    const a = await app();
    const get = await a.inject({ method: "GET", url: `/invite/accept?token=${INVITE_ID}` });
    expect(get.body).toContain('name="mfaCode"');
    const noCode = await a.inject({ method: "POST", url: "/invite/accept", ...form({ token: INVITE_ID, password: PASSWORD, mfaCode: "" }) });
    expect(noCode.statusCode).toBe(401);
    const wrong = await a.inject({ method: "POST", url: "/invite/accept", ...form({ token: INVITE_ID, password: PASSWORD, mfaCode: "000000" }) });
    expect(wrong.statusCode).toBe(401);
    expectNoWrites();
    vi.mocked(verifyTotpFresh).mockResolvedValue(true);
    const ok = await a.inject({ method: "POST", url: "/invite/accept", ...form({ token: INVITE_ID, password: PASSWORD, mfaCode: "123 456" }) });
    expect(ok.statusCode).toBe(200);
    expect(verifyTotpFresh).toHaveBeenLastCalledWith(PARENT.id, "enc:secret", "123456");
    expect(invite.status).toBe("accepted");
  });

  it("L18 unknown, revoked and malformed invitations get one page; the POST carries the auth rate limit", async () => {
    // Mutants: render for a non-pending invite; drop `config: { rateLimit: AUTH_RATE_LIMIT }`.
    const a = await app();
    const bodies = new Set<string>();
    invite.status = "revoked";
    bodies.add((await a.inject({ method: "GET", url: `/invite/accept?token=${INVITE_ID}` })).body);
    bodies.add((await a.inject({ method: "GET", url: "/invite/accept?token=11111111-2222-3333-4444-555555555555" })).body);
    const bad = await a.inject({ method: "GET", url: `/invite/accept?token=${encodeURIComponent('"><script>x</script>')}` });
    expect(bad.statusCode).toBe(404);
    bodies.add(bad.body);
    expect(bodies.size).toBe(1);
    expect([...bodies][0]).not.toContain("<script");

    const seen = new Map<string, unknown>();
    const f = Fastify({ logger: false });
    await f.register(fastifyJwt, { secret: "test-secret" });
    f.addHook("onRoute", (route) => {
      if (route.method === "POST") seen.set(route.url, (route.config as { rateLimit?: unknown } | undefined)?.rateLimit);
    });
    await f.register(linkPageRoutes);
    await f.ready();
    expect(seen.get("/invite/accept")).toBe(AUTH_RATE_LIMIT);
  });
});

describe("dashboard page and wiring", () => {
  it("L19 /dashboard answers a page, and every path a mail carries has a GET here", async () => {
    // Mutant: drop a route, or change a mailed path without its page (the paths are read from the source).
    const app = await buildApp(linkPageRoutes, "");
    const res = await app.inject({ method: "GET", url: "/dashboard" });
    expect(res.statusCode).toBe(200);
    expectPageHeaders(res);
    expect(res.body).toContain("Open the OSRA app");

    const read = (rel: string) => readFileSync(fileURLToPath(new URL(rel, import.meta.url)), "utf8");
    const sources = ["../src/routes/auth.ts", "../src/routes/invites.ts", "../src/jobs/digestScheduler.ts"].map(read).join("\n");
    const mailed = new Set<string>();
    for (const m of sources.matchAll(/\$\{appPublicUrl\(\)\}(\/[a-z/]+)/g)) mailed.add(m[1]);
    // auth.ts builds the two MFA links from one base.
    if (mailed.delete("/mfa/reset")) for (const tail of ["/confirm", "/cancel"]) mailed.add(`/mfa/reset${tail}`);
    expect([...mailed].sort()).toEqual(["/dashboard", "/invite/accept", "/mfa/reset/cancel", "/mfa/reset/confirm", "/reset"]);
    const pages = read("../src/routes/linkPages.ts");
    for (const path of mailed) expect(pages).toContain(`app.get("${path}"`);
    expect(read("../src/server.ts")).toContain("await app.register(linkPageRoutes);");
  });
});
