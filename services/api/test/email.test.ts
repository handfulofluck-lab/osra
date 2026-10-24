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
import { runDigestsDue, sendFamilyDigest } from "../src/jobs/digestScheduler.js";
import { digestsDueAt } from "../src/lib/digestSchedule.js";
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

  it("clips a stored name to 80 characters, so a long row cannot stretch a digest (roadmap 2.7)", () => {
    // The writes are bounded too, but a row created before that bound is what this protects.
    // Mutant: remove `clip(...)` around `opts.familyName` in digestEmail -> the subject carries all 200.
    const longFamily = "F".repeat(200);
    const m = digestEmail("a@x", {
      familyName: longFamily,
      days: 7,
      link: "https://x/dashboard",
      children: [
        {
          displayName: "C".repeat(200),
          totalAppMinutes: 1,
          topApps: [],
          urlVisits: 0,
          topBlockedDomains: [],
          socialConcerns: 0,
          calls: 0,
          sms: 0,
        },
      ],
    });
    expect(m.subject).toContain("F".repeat(80));
    expect(m.subject).not.toContain("F".repeat(81));
    expect(m.text).toContain(`${"C".repeat(80)}: 1 min on screen`);
    expect(m.text).not.toContain("C".repeat(81));
    // The invite carries the same two names; it is the other way out of the family.
    const invite = inviteEmail("co@example.com", { inviterName: "I".repeat(200), familyName: longFamily, role: "guardian", link: "l" });
    expect(invite.subject).not.toContain("F".repeat(81));
    expect(invite.text).not.toContain("I".repeat(81));
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
    expect(await sender.send({ to: "p@x", subject: "S", html: "", text: "" })).toEqual({
      ok: false,
      reason: "HTTP 429 rate limited",
      retryable: true,
    });
  });

  it("Resend sender calls 5xx and rate limits retryable, other 4xx permanent (ADR-0024)", async () => {
    const msg = { to: "p@x", subject: "S", html: "", text: "" };
    const withStatus = (status: number) =>
      new ResendEmailSender("re_test", "a@b", (async () => new Response("no", { status })) as never);
    expect(await withStatus(503).send(msg)).toMatchObject({ ok: false, retryable: true });
    expect(await withStatus(408).send(msg)).toMatchObject({ ok: false, retryable: true });
    expect(await withStatus(422).send(msg)).toMatchObject({ ok: false, retryable: false });
    expect(await withStatus(403).send(msg)).toMatchObject({ ok: false, retryable: false });
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
  /**
   * A faithful stand-in for the `DigestSend` unique key: a create for a period already claimed throws
   * `P2002`, exactly like Postgres. Without it, "the next tick retries" cannot be tested — a mock that
   * always accepts the create hides the bug F1 describes.
   */
  let claims: Map<string, { failedReason?: string }>;
  const ck = (w: { familyId: string; kind: string; period: string }) => `${w.familyId}|${w.kind}|${w.period}`;
  beforeEach(() => {
    resetPrismaMock();
    capture.sent = [];
    setEmailSender(capture);
    delete process.env.DIGEST_HOUR_UTC;
    claims = new Map();
    prismaMock.digestSend.create.mockImplementation(async ({ data }: { data: { familyId: string; kind: string; period: string } }) => {
      if (claims.has(ck(data))) throw Object.assign(new Error("Unique constraint failed"), { code: "P2002" });
      claims.set(ck(data), {});
      return { id: `send-${claims.size}`, ...data };
    });
    prismaMock.digestSend.delete.mockImplementation(async ({ where }: { where: { familyId_kind_period: { familyId: string; kind: string; period: string } } }) => {
      claims.delete(ck(where.familyId_kind_period));
      return {};
    });
    prismaMock.digestSend.update.mockImplementation(async ({ where, data }: { where: { familyId_kind_period: { familyId: string; kind: string; period: string } }; data: { failedReason?: string } }) => {
      const key = ck(where.familyId_kind_period);
      const row = claims.get(key);
      if (!row) throw new Error("Record to update not found");
      Object.assign(row, data);
      return { id: "send-1", ...where.familyId_kind_period, ...data };
    });
  });
  afterEach(() => setEmailSender(null));

  /** One family, daily digest only, UTC — the 18:00Z tick of 2026-10-14 (a Wednesday) is due. */
  function dueFamily(): void {
    prismaMock.digestPrefs.findMany.mockResolvedValue([{ familyId: "fam-1", dailyEmail: true, weeklyEmail: false, emails: ["a@x"] }]);
    prismaMock.family.findMany.mockResolvedValue([{ id: "fam-1", timezone: "UTC" }]);
    prismaMock.family.findUnique.mockResolvedValue({ id: "fam-1", name: "Demo" });
    prismaMock.digestPrefs.findUnique.mockResolvedValue({ familyId: "fam-1", emails: ["a@x"] });
    prismaMock.parent.findMany.mockResolvedValue([]);
    prismaMock.child.findMany.mockResolvedValue([]);
    // Roadmap 2.7: `a@x` is not one of the family's parents, so it is a recipient only because it
    // confirmed. These tests are about the send/claim state machine, not about who may be mailed.
    prismaMock.digestRecipient.findMany.mockResolvedValue([
      { familyId: "fam-1", email: "a@x", confirmedAt: new Date("2026-10-01T00:00:00Z") },
    ]);
  }

  it("is due from the configured local hour; weekly only on the local Sunday (ADR-0017)", () => {
    expect(digestsDueAt(new Date("2026-10-14T17:30:00Z"), "UTC", 18)).toEqual([]);
    expect(digestsDueAt(new Date("2026-10-14T18:05:00Z"), "UTC", 18)).toEqual(["daily"]); // Wednesday
    expect(digestsDueAt(new Date("2026-10-18T18:05:00Z"), "UTC", 18)).toEqual(["daily", "weekly"]); // Sunday
    // The same instant in Dubai is 22:05 local: past the hour, still the same local Sunday.
    expect(digestsDueAt(new Date("2026-10-18T18:05:00Z"), "Asia/Dubai", 18)).toEqual(["daily", "weekly"]);
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

  it("claims each (family, kind, period) in the database and skips outside the local send hour (ADR-0017)", async () => {
    prismaMock.digestPrefs.findMany.mockResolvedValue([{ familyId: "fam-1", dailyEmail: true, weeklyEmail: true, emails: ["a@x"] }]);
    prismaMock.family.findMany.mockResolvedValue([{ id: "fam-1", timezone: "UTC" }]);
    prismaMock.family.findUnique.mockResolvedValue({ id: "fam-1", name: "Demo" });
    prismaMock.digestPrefs.findUnique.mockResolvedValue({ familyId: "fam-1", emails: ["a@x"] });
    prismaMock.parent.findMany.mockResolvedValue([]);
    prismaMock.child.findMany.mockResolvedValue([]);
    // Roadmap 2.7: the requested address is a recipient because it confirmed (see `dueFamily`).
    prismaMock.digestRecipient.findMany.mockResolvedValue([
      { familyId: "fam-1", email: "a@x", confirmedAt: new Date("2026-10-01T00:00:00Z") },
    ]);
    prismaMock.digestSend.create.mockResolvedValue({ id: "send-1" });

    // 09:00 UTC is before DIGEST_HOUR (18): nothing is claimed, nothing is sent.
    expect(await runDigestsDue(new Date("2026-10-14T09:00:00Z"))).toEqual({ attempted: 0, sent: 0 });
    expect(prismaMock.digestSend.create).not.toHaveBeenCalled();

    // 18:00 UTC on a Wednesday: one daily send, claimed for the local date.
    expect(await runDigestsDue(new Date("2026-10-14T18:00:00Z"))).toEqual({ attempted: 1, sent: 1 });
    expect(prismaMock.digestSend.create).toHaveBeenCalledWith({
      data: { familyId: "fam-1", kind: "daily", period: "2026-10-14" },
    });

    // The unique key is the claim: a duplicate period is skipped, not sent again.
    const dup = Object.assign(new Error("unique"), { code: "P2002" });
    prismaMock.digestSend.create.mockRejectedValueOnce(dup);
    expect(await runDigestsDue(new Date("2026-10-14T18:20:00Z"))).toEqual({ attempted: 0, sent: 0 });
  });

  it("a thrown send releases the claim and the next tick retries the same period (F1)", async () => {
    dueFamily();
    const error = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    const boom: EmailSender = {
      name: "boom",
      send: async () => {
        throw new Error("provider timeout");
      },
    };
    setEmailSender(boom);

    expect(await runDigestsDue(new Date("2026-10-14T18:00:00Z"))).toEqual({ attempted: 1, sent: 0 });
    expect(prismaMock.digestSend.delete).toHaveBeenCalledWith({
      where: { familyId_kind_period: { familyId: "fam-1", kind: "daily", period: "2026-10-14" } },
    });
    expect(claims.size).toBe(0);
    expect(error.mock.calls.flat().join(" ")).toContain("will retry");

    // The 18:15 tick finds no claim for the period and sends it.
    setEmailSender(capture);
    expect(await runDigestsDue(new Date("2026-10-14T18:15:00Z"))).toEqual({ attempted: 1, sent: 1 });
    expect(capture.sent).toHaveLength(1);
    expect(claims.size).toBe(1);
    error.mockRestore();
    warn.mockRestore();
  });

  it("a permanent provider refusal keeps the claim terminal and is not retried (F2)", async () => {
    dueFamily();
    const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    const send = vi.fn(async () => ({ ok: false as const, reason: "HTTP 422 invalid to", retryable: false }));
    setEmailSender({ name: "refuse", send });

    expect(await runDigestsDue(new Date("2026-10-14T18:00:00Z"))).toEqual({ attempted: 1, sent: 0 });
    expect(prismaMock.digestSend.delete).not.toHaveBeenCalled();
    expect(claims.get("fam-1|daily|2026-10-14")).toEqual({ failedReason: "HTTP 422 invalid to" });

    // Two later ticks in the same period: the unique key skips it, the provider is not called again.
    expect(await runDigestsDue(new Date("2026-10-14T18:15:00Z"))).toEqual({ attempted: 0, sent: 0 });
    expect(await runDigestsDue(new Date("2026-10-14T18:30:00Z"))).toEqual({ attempted: 0, sent: 0 });
    expect(send).toHaveBeenCalledTimes(1);
    warn.mockRestore();
  });

  it("a transient provider refusal releases the claim so the next tick retries", async () => {
    dueFamily();
    const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    const send = vi.fn(async () => ({ ok: false as const, reason: "HTTP 503 unavailable", retryable: true }));
    setEmailSender({ name: "flaky", send });

    expect(await runDigestsDue(new Date("2026-10-14T18:00:00Z"))).toEqual({ attempted: 1, sent: 0 });
    expect(claims.size).toBe(0);

    setEmailSender(capture);
    expect(await runDigestsDue(new Date("2026-10-14T18:15:00Z"))).toEqual({ attempted: 1, sent: 1 });
    expect(capture.sent).toHaveLength(1);
    warn.mockRestore();
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
