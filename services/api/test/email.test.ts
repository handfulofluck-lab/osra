import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { prismaMock, resetPrismaMock, buildApp, authHeader, MockRedis } from "./helpers.js";

vi.mock("../src/db.js", () => ({ prisma: prismaMock }));
vi.mock("../src/redis.js", async () => {
  const redis = new MockRedis();
  return {
    getRedis: () => redis,
    setJson: vi.fn(async () => undefined),
    getJson: vi.fn(async () => null),
    publishJson: vi.fn(async () => undefined),
    setJsonNx: vi.fn(async () => true),
  };
});

import { ConsoleEmailSender, ResendEmailSender, setEmailSender, type EmailMessage, type EmailSender } from "../src/lib/email/index.js";
import { digestEmail, inviteEmail, passwordResetEmail } from "../src/lib/email/templates.js";
import { digestsDueAt, runDigestsDue, sendFamilyDigest } from "../src/jobs/digestScheduler.js";
import { authRoutes } from "../src/routes/auth.js";
import { inviteRoutes } from "../src/routes/invites.js";
import { meRoutes } from "../src/routes/me.js";

class CaptureSender implements EmailSender {
  readonly name = "capture";
  sent: EmailMessage[] = [];
  async send(message: EmailMessage) {
    this.sent.push(message);
    return { ok: true as const };
  }
}

describe("templates", () => {
  it("password reset carries the link in both languages, HTML-escaped", () => {
    const m = passwordResetEmail("p@example.com", "https://app.osra.family/reset?token=a<b");
    expect(m.to).toBe("p@example.com");
    expect(m.text).toContain("https://app.osra.family/reset?token=a<b");
    expect(m.html).toContain("https://app.osra.family/reset?token=a&lt;b");
    expect(m.html).toContain('dir="rtl"');
    expect(m.html).toContain("إعادة تعيين");
  });

  it("invite names the inviter, family and role, with an idempotency key", () => {
    const m = inviteEmail("co@example.com", { inviterName: "Sara", familyName: "Haddad", role: "co-parent", link: "https://x/invite/accept?token=i1" });
    expect(m.subject).toContain("Haddad");
    expect(m.text).toContain("Sara invited you to the Haddad family");
    expect(m.text).toContain("co-parent");
    expect(m.idempotencyKey).toBe("invite:https://x/invite/accept?token=i1");
  });

  it("digest lists each child once and handles an empty week", () => {
    const m = digestEmail(["a@x", "b@x"], {
      familyName: "Demo",
      days: 7,
      link: "https://x/dashboard",
      children: [{ displayName: "Alex", totalAppMinutes: 310, topApps: [{ name: "YouTube", minutes: 120 }], urlVisits: 44, topBlockedDomains: [{ domain: "bad.example", count: 3 }], socialConcerns: 1, calls: 2, sms: 5 }],
    });
    expect(m.to).toEqual(["a@x", "b@x"]);
    expect(m.text).toContain("Alex: 310 min on screen; top apps YouTube 120m; 44 sites visited, 1 blocked; 1 social concern(s); 2 calls, 5 SMS.");
    const empty = digestEmail("a@x", { familyName: "Demo", days: 1, link: "l", children: [] });
    expect(empty.text).toContain("No activity was recorded.");
  });
});

describe("senders", () => {
  it("Resend sender posts the envelope with bearer auth and idempotency header", async () => {
    const fetchMock = vi.fn(async () => new Response(JSON.stringify({ id: "em_1" }), { status: 200 }));
    const sender = new ResendEmailSender("re_test", "OSRA <no-reply@osra.family>", fetchMock as never);
    const r = await sender.send({ to: "p@x", subject: "S", html: "<b>h</b>", text: "t", idempotencyKey: "k1" });
    expect(r).toEqual({ ok: true, id: "em_1" });
    const [url, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe("https://api.resend.com/emails");
    expect(init.headers).toMatchObject({ authorization: "Bearer re_test", "idempotency-key": "k1" });
    expect(JSON.parse(init.body as string)).toEqual({ from: "OSRA <no-reply@osra.family>", to: ["p@x"], subject: "S", html: "<b>h</b>", text: "t" });
  });

  it("Resend sender surfaces provider errors without throwing", async () => {
    const fetchMock = vi.fn(async () => new Response("rate limited", { status: 429 }));
    const sender = new ResendEmailSender("re_test", "a@b", fetchMock as never);
    expect(await sender.send({ to: "p@x", subject: "S", html: "", text: "" })).toEqual({ ok: false, reason: "HTTP 429 rate limited" });
  });

  it("console sender never prints the body in production", async () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => undefined);
    const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    await new ConsoleEmailSender(true).send({ to: "p@x", subject: "Reset", html: "", text: "SECRET-LINK" });
    expect(log).not.toHaveBeenCalled();
    expect(warn.mock.calls[0][0]).not.toContain("SECRET-LINK");
    await new ConsoleEmailSender(false).send({ to: "p@x", subject: "Reset", html: "", text: "DEV-LINK" });
    expect(log.mock.calls[0][0]).toContain("DEV-LINK");
    log.mockRestore();
    warn.mockRestore();
  });
});

describe("routes use the email sender", () => {
  const capture = new CaptureSender();
  beforeEach(() => {
    resetPrismaMock();
    capture.sent = [];
    setEmailSender(capture);
    process.env.APP_PUBLIC_URL = "https://app.osra.family/";
  });
  afterEach(() => {
    setEmailSender(null);
    delete process.env.APP_PUBLIC_URL;
    delete process.env.RESEND_API_KEY;
    delete process.env.EMAIL_FROM;
  });

  it("password reset emails a 15-minute link and does not log the token", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    const log = vi.spyOn(console, "log").mockImplementation(() => undefined);
    prismaMock.parent.findUnique.mockResolvedValue({ id: "parent-1", email: "p@example.com" });
    const res = await app.inject({ method: "POST", url: "/v1/auth/reset/request", payload: { email: "P@Example.com" } });
    expect(res.statusCode).toBe(200);
    expect(capture.sent).toHaveLength(1);
    const link = capture.sent[0].text.match(/https:\/\/app\.osra\.family\/reset\?token=([^\s]+)/)?.[1];
    expect(link).toBeTruthy();
    const payload = app.jwt.verify<{ sub: string; purpose: string }>(decodeURIComponent(link!));
    expect(payload).toMatchObject({ sub: "parent-1", purpose: "password_reset" });
    expect(log.mock.calls.flat().join(" ")).not.toContain(decodeURIComponent(link!));
    log.mockRestore();
    await app.close();
  });

  it("unknown email still returns 200 and sends nothing (no account enumeration)", async () => {
    const app = await buildApp(authRoutes, "/v1/auth");
    prismaMock.parent.findUnique.mockResolvedValue(null);
    const res = await app.inject({ method: "POST", url: "/v1/auth/reset/request", payload: { email: "nobody@example.com" } });
    expect(res.statusCode).toBe(200);
    expect(capture.sent).toHaveLength(0);
    await app.close();
  });

  it("invite emails the accept link; the token is echoed only without a provider", async () => {
    const app = await buildApp(inviteRoutes, "/v1/family");
    prismaMock.parent.findUnique.mockResolvedValue({ id: "parent-1", familyId: "fam-1", role: "owner", displayName: "Sara" });
    prismaMock.family.findUnique.mockResolvedValue({ id: "fam-1", name: "Haddad", region: "US" });
    prismaMock.familyInvite.create.mockResolvedValue({ id: "inv-1", familyId: "fam-1", email: "co@example.com", role: "co-parent", permissions: [], status: "pending" });

    const dev = await app.inject({ method: "POST", url: "/v1/family/invites", headers: authHeader(app), payload: { email: "co@example.com", role: "co-parent" } });
    expect(dev.statusCode).toBe(201);
    expect(dev.json()).toMatchObject({ acceptToken: "inv-1", emailed: false });
    expect(capture.sent[0].text).toContain("https://app.osra.family/invite/accept?token=inv-1");
    expect(capture.sent[0].text).toContain("Sara invited you to the Haddad family");

    process.env.RESEND_API_KEY = "re_x";
    process.env.EMAIL_FROM = "a@b";
    const prod = await app.inject({ method: "POST", url: "/v1/family/invites", headers: authHeader(app), payload: { email: "co@example.com", role: "co-parent" } });
    expect(prod.json()).toMatchObject({ emailed: true });
    expect(prod.json().acceptToken).toBeUndefined();
    await app.close();
  });
});

describe("digest scheduler", () => {
  const capture = new CaptureSender();
  beforeEach(() => {
    resetPrismaMock();
    capture.sent = [];
    setEmailSender(capture);
    delete process.env.DIGEST_HOUR_UTC;
  });
  afterEach(() => setEmailSender(null));

  it("is due only in the configured hour; weekly only on Sundays", () => {
    expect(digestsDueAt(new Date("2026-10-14T17:30:00Z"), 18)).toEqual([]);
    expect(digestsDueAt(new Date("2026-10-14T18:05:00Z"), 18)).toEqual(["daily"]); // Wednesday
    expect(digestsDueAt(new Date("2026-10-18T18:05:00Z"), 18)).toEqual(["daily", "weekly"]); // Sunday
  });

  it("sends to the prefs recipients, falling back to parent emails", async () => {
    prismaMock.family.findUnique.mockResolvedValue({ id: "fam-1", name: "Demo" });
    prismaMock.digestPrefs.findUnique.mockResolvedValue({ familyId: "fam-1", emails: [], dailyEmail: true, weeklyEmail: true, pushEnabled: true });
    prismaMock.parent.findMany.mockResolvedValue([{ email: "mum@x" }, { email: "dad@x" }]);
    prismaMock.child.findMany.mockResolvedValue([{ id: "child-1", displayName: "Alex", familyId: "fam-1" }]);
    prismaMock.activityEvent.findMany.mockResolvedValue([]);
    prismaMock.socialEvent.count.mockResolvedValue(0);
    prismaMock.socialEvent.findMany.mockResolvedValue([]);
    const r = await sendFamilyDigest("fam-1", "weekly");
    expect(r).toEqual({ sent: true, to: ["mum@x", "dad@x"] });
    expect(capture.sent[0].subject).toContain("Demo");
    expect(capture.sent[0].idempotencyKey).toMatch(/^digest:fam-1:weekly:\d{4}-\d{2}-\d{2}$/);
  });

  it("claims each family once per day via Redis NX and skips outside the send hour", async () => {
    prismaMock.digestPrefs.findMany.mockResolvedValue([{ familyId: "fam-1", dailyEmail: true, weeklyEmail: true, emails: ["a@x"] }]);
    prismaMock.family.findUnique.mockResolvedValue({ id: "fam-1", name: "Demo" });
    prismaMock.digestPrefs.findUnique.mockResolvedValue({ familyId: "fam-1", emails: ["a@x"] });
    prismaMock.parent.findMany.mockResolvedValue([]);
    prismaMock.child.findMany.mockResolvedValue([]);
    expect(await runDigestsDue(new Date("2026-10-14T09:00:00Z"))).toEqual({ attempted: 0, sent: 0 });
    const redis = MockRedis.instances[0];
    redis.set.mockResolvedValueOnce("OK").mockResolvedValueOnce(null);
    expect(await runDigestsDue(new Date("2026-10-14T18:00:00Z"))).toEqual({ attempted: 1, sent: 1 });
    expect(await runDigestsDue(new Date("2026-10-14T18:20:00Z"))).toEqual({ attempted: 0, sent: 0 });
  });
});

describe("/v1/me push tokens", () => {
  beforeEach(() => resetPrismaMock());

  it("registers, lists and removes a token for the signed-in parent", async () => {
    const app = await buildApp(meRoutes, "/v1/me");
    prismaMock.parentPushToken.upsert.mockResolvedValue({ id: "t1", platform: "android", createdAt: new Date("2026-10-16T00:00:00Z") });
    const reg = await app.inject({ method: "POST", url: "/v1/me/push-token", headers: authHeader(app), payload: { token: "f".repeat(40), platform: "android", appVersion: "1.2.0" } });
    expect(reg.statusCode).toBe(201);
    expect(prismaMock.parentPushToken.upsert).toHaveBeenCalledWith(expect.objectContaining({ where: { token: "f".repeat(40) }, create: expect.objectContaining({ parentId: "parent-1", platform: "android" }) }));

    const bad = await app.inject({ method: "POST", url: "/v1/me/push-token", headers: authHeader(app), payload: { token: "short", platform: "android" } });
    expect(bad.statusCode).toBe(400);

    prismaMock.parentPushToken.deleteMany.mockResolvedValue({ count: 1 });
    const del = await app.inject({ method: "DELETE", url: "/v1/me/push-token", headers: authHeader(app), payload: { token: "f".repeat(40) } });
    expect(del.json()).toEqual({ removed: 1 });
    expect(prismaMock.parentPushToken.deleteMany).toHaveBeenCalledWith({ where: { token: "f".repeat(40), parentId: "parent-1" } });

    const anon = await app.inject({ method: "POST", url: "/v1/me/push-token", payload: { token: "f".repeat(40), platform: "ios" } });
    expect(anon.statusCode).toBe(401);
    await app.close();
  });
});
