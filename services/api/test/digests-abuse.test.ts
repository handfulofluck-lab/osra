import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { digestRoutes } from "../src/routes/digests.js";
import { getRedis } from "../src/redis.js";
import { hashConfirmToken } from "../src/lib/digestRecipients.js";
import { setEmailSender, type EmailMessage, type EmailSender } from "../src/lib/email/index.js";
import { MockRedis, authHeader, buildApp, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

/**
 * Roadmap 2.7 (osra-security#2): a digest goes only to an address that proved it wants one.
 *
 * The tests below drive the route with the real `src/redis.js` over `MockRedis`, so `setJsonNx` (the
 * `SET NX EX` the send-now throttle is built on) runs the production code, and with a small in-memory
 * `DigestRecipient` table that answers the same queries and enforces the same unique keys as Postgres.
 * A stub that returned "pending" and then "confirmed" would assert the stub; this one asserts the flow.
 */

const OWNER = {
  id: "parent-1",
  familyId: "fam-1",
  email: "parent-1@example.com",
  role: "owner",
  permissions: [] as string[],
};

interface LedgerRow {
  id: string;
  familyId: string;
  email: string;
  confirmedAt: Date | null;
  tokenHash: string | null;
  tokenExpiresAt: Date | null;
  createdAt: Date;
}

let ledger: LedgerRow[] = [];
let ledgerSeq = 0;

/** The `DigestRecipient` table: rows, the (familyId,email) unique key, and the tokenHash unique key. */
function seedLedger(initial: Array<Partial<LedgerRow> & { familyId: string; email: string }> = []): void {
  ledger = initial.map((row) => ({
    id: `rec-${++ledgerSeq}`,
    confirmedAt: null,
    tokenHash: null,
    tokenExpiresAt: null,
    createdAt: new Date(),
    ...row,
  }));
  prismaMock.digestRecipient.findMany.mockImplementation(
    async ({ where }: { where: { familyId: string; email?: { in: string[] } } }) =>
      ledger.filter((row) => row.familyId === where.familyId && (!where.email || where.email.in.includes(row.email))),
  );
  prismaMock.digestRecipient.findUnique.mockImplementation(
    async ({ where }: { where: { tokenHash: string } }) =>
      ledger.find((row) => row.tokenHash !== null && row.tokenHash === where.tokenHash) ?? null,
  );
  prismaMock.digestRecipient.upsert.mockImplementation(
    async ({
      where,
      create,
      update,
    }: {
      where: { familyId_email: { familyId: string; email: string } };
      create: Partial<LedgerRow>;
      update: Partial<LedgerRow>;
    }) => {
      const found = ledger.find(
        (row) => row.familyId === where.familyId_email.familyId && row.email === where.familyId_email.email,
      );
      if (found) {
        Object.assign(found, update);
        return found;
      }
      const row: LedgerRow = {
        id: `rec-${++ledgerSeq}`,
        familyId: create.familyId!,
        email: create.email!,
        confirmedAt: null,
        tokenHash: create.tokenHash ?? null,
        tokenExpiresAt: create.tokenExpiresAt ?? null,
        createdAt: new Date(),
      };
      ledger.push(row);
      return row;
    },
  );
  prismaMock.digestRecipient.update.mockImplementation(
    async ({ where, data }: { where: { id: string }; data: Partial<LedgerRow> }) => {
      const row = ledger.find((r) => r.id === where.id);
      if (!row) throw new Error("Record to update not found");
      Object.assign(row, data);
      return row;
    },
  );
  prismaMock.digestRecipient.deleteMany.mockImplementation(
    async ({ where }: { where: { familyId: string; email?: { notIn: string[] } } }) => {
      const before = ledger.length;
      ledger = ledger.filter(
        (row) => row.familyId !== where.familyId || Boolean(where.email && where.email.notIn.includes(row.email)),
      );
      return { count: before - ledger.length };
    },
  );
}

const store = new Map<string, string>();

function wireRedis(): MockRedis {
  const redis = getRedis() as unknown as MockRedis;
  redis.set.mockImplementation(async (key: string, value: unknown, ...rest: unknown[]) => {
    // `SET key value EX ttl NX` — the shape `setJsonNx` sends, with NX's real meaning.
    if (rest.includes("NX") && store.has(key)) return null;
    store.set(key, String(value));
    return "OK";
  });
  redis.del.mockImplementation(async (...keys: string[]) =>
    keys.reduce((n, k) => n + (store.delete(k) ? 1 : 0), 0),
  );
  return redis;
}

/** Move past the hourly window the way a Redis TTL would: the key is simply gone. */
function advanceHour(): void {
  store.clear();
}

class CaptureSender implements EmailSender {
  readonly name = "capture";
  sent: EmailMessage[] = [];
  async send(message: EmailMessage) {
    this.sent.push(message);
    return { ok: true as const };
  }
}

const capture = new CaptureSender();

const CHILD = { id: "child-1", familyId: "fam-1", displayName: "Alex", birthYear: 2012 };

/** Everything `send-now` touches below the throttle: one child, no activity, prefs with two addresses. */
function wireSendNow(emails: string[]): void {
  prismaMock.child.findMany.mockResolvedValue([CHILD]);
  prismaMock.activityEvent.findMany.mockResolvedValue([]);
  prismaMock.socialEvent.count.mockResolvedValue(0);
  prismaMock.socialEvent.findMany.mockResolvedValue([]);
  prismaMock.digestPrefs.findUnique.mockResolvedValue({ familyId: "fam-1", dailyEmail: true, weeklyEmail: true, pushEnabled: true, emails });
  prismaMock.digestPrefs.findMany.mockResolvedValue([{ familyId: "fam-1", dailyEmail: true, weeklyEmail: true, emails }]);
}

describe("digest recipients (roadmap 2.7)", () => {
  beforeEach(() => {
    resetPrismaMock();
    store.clear();
    wireRedis();
    seedLedger();
    capture.sent = [];
    setEmailSender(capture);
    process.env.APP_PUBLIC_URL = "https://app.osra.family";
    prismaMock.parent.findUnique.mockResolvedValue(OWNER);
    prismaMock.parent.findMany.mockResolvedValue([{ email: OWNER.email }]);
  });
  afterEach(() => {
    setEmailSender(null);
    delete process.env.APP_PUBLIC_URL;
  });

  it("marks a non-parent address pending, mails it a single-use link, and send-now skips it until it confirms", async () => {
    const app = await buildApp(digestRoutes, "/v1/digests");
    prismaMock.family.findUnique.mockResolvedValue({ id: "fam-1", name: "Haddad", region: "US" });
    prismaMock.digestPrefs.upsert.mockImplementation(
      async ({ create }: { create: Record<string, unknown> }) => ({ ...create }),
    );

    const put = await app.inject({
      method: "PUT",
      url: "/v1/digests/prefs",
      headers: authHeader(app),
      payload: { dailyEmail: true, weeklyEmail: false, pushEnabled: true, emails: [OWNER.email, "grandma@example.com"] },
    });
    expect(put.statusCode).toBe(200);
    expect(put.json().recipients).toEqual([
      { email: "parent-1@example.com", status: "confirmed" },
      { email: "grandma@example.com", status: "pending" },
    ]);
    // The parent's own address is already verified: exactly one message, to the address that is not.
    expect(capture.sent.map((m) => m.to)).toEqual(["grandma@example.com"]);
    const link = capture.sent[0].text.match(/https:\/\/app\.osra\.family\/v1\/digests\/confirm\?token=([a-f0-9]{64})/)?.[1];
    expect(link).toBeTruthy();
    // Only the hash is stored, so a database read cannot replay the link.
    expect(ledger[0].tokenHash).toBe(hashConfirmToken(link!));
    expect(ledger[0].tokenHash).not.toBe(link);

    wireSendNow([OWNER.email, "grandma@example.com"]);
    const before = await app.inject({ method: "POST", url: "/v1/digests/send-now", headers: authHeader(app) });
    expect(before.statusCode).toBe(200);
    // Mutant: delete the `confirmedRecipients` filter in jobs/digestScheduler.ts (send to
    // `prefs.emails` as before) -> this list also carries grandma@example.com.
    expect(before.json().recipients).toEqual([OWNER.email]);

    advanceHour();
    const confirmed = await app.inject({
      method: "GET",
      url: `/v1/digests/confirm?token=${link}`,
    });
    expect(confirmed.statusCode).toBe(200);
    expect(confirmed.json()).toEqual({ confirmed: true, email: "grandma@example.com" });
    expect(ledger[0].confirmedAt).toBeInstanceOf(Date);
    expect(ledger[0].tokenHash).toBeNull();

    // Mutant: drop `confirmedAt` from the filter in lib/digestRecipients.ts -> both calls answer the
    // same list, and the "until confirmed" half of this test is untestable because it never changes.
    const after = await app.inject({ method: "POST", url: "/v1/digests/send-now", headers: authHeader(app) });
    expect(after.statusCode).toBe(200);
    expect(after.json().recipients).toEqual([OWNER.email, "grandma@example.com"]);

    // Single use: the same link a second time is refused.
    const replay = await app.inject({ method: "GET", url: `/v1/digests/confirm?token=${link}` });
    expect(replay.statusCode).toBe(404);
    await app.close();
  });

  it("refuses an expired link and one that was never issued", async () => {
    const app = await buildApp(digestRoutes, "/v1/digests");
    const expired = "d".repeat(64);
    seedLedger([
      {
        familyId: "fam-1",
        email: "late@example.com",
        tokenHash: hashConfirmToken(expired),
        tokenExpiresAt: new Date(Date.now() - 60_000),
      },
    ]);
    // Mutant: drop the `tokenExpiresAt` test in lib/digestRecipients.ts -> this answers 200 and confirms
    // a link whose 24 hours are over.
    const late = await app.inject({ method: "GET", url: `/v1/digests/confirm?token=${expired}` });
    expect(late.statusCode).toBe(404);
    expect(ledger[0].confirmedAt).toBeNull();

    const unknown = await app.inject({ method: "GET", url: `/v1/digests/confirm?token=${"e".repeat(64)}` });
    expect(unknown.statusCode).toBe(404);
    const malformed = await app.inject({ method: "GET", url: "/v1/digests/confirm?token=short" });
    expect(malformed.statusCode).toBe(400);
    await app.close();
  });

  it("is owner-only: a guardian with no permissions gets 403 on PUT and send-now, a co-parent can still read", async () => {
    const app = await buildApp(digestRoutes, "/v1/digests");
    prismaMock.parent.findUnique.mockResolvedValue({ ...OWNER, role: "guardian", permissions: [] });

    const put = await app.inject({
      method: "PUT",
      url: "/v1/digests/prefs",
      headers: authHeader(app),
      payload: { dailyEmail: true, weeklyEmail: true, pushEnabled: true, emails: [OWNER.email] },
    });
    // Mutant: drop `requireOwner` from either route -> both answer 200 and the writes happen.
    expect(put.statusCode).toBe(403);
    expect(put.json()).toEqual({ error: "owner_role_required" });
    expect(prismaMock.digestPrefs.upsert).not.toHaveBeenCalled();

    const send = await app.inject({ method: "POST", url: "/v1/digests/send-now", headers: authHeader(app) });
    expect(send.statusCode).toBe(403);
    expect(prismaMock.child.findMany).not.toHaveBeenCalled();

    prismaMock.parent.findUnique.mockResolvedValue({ ...OWNER, role: "co-parent", permissions: ["alerts"] });
    prismaMock.digestPrefs.findUnique.mockResolvedValue({
      familyId: "fam-1",
      dailyEmail: true,
      weeklyEmail: true,
      pushEnabled: true,
      emails: [OWNER.email, "grandma@example.com"],
    });
    const read = await app.inject({ method: "GET", url: "/v1/digests/prefs", headers: authHeader(app) });
    expect(read.statusCode).toBe(200);
    expect(read.json().emails).toEqual([OWNER.email, "grandma@example.com"]);
    await app.close();
  });

  it("serves one send-now an hour per family, then 429", async () => {
    const app = await buildApp(digestRoutes, "/v1/digests");
    wireSendNow([OWNER.email]);

    const first = await app.inject({ method: "POST", url: "/v1/digests/send-now", headers: authHeader(app) });
    expect(first.statusCode).toBe(200);

    // Mutant: drop `claimSendNow` from routes/digests.ts -> this answers 200 and a family can mail its
    // whole list as often as it likes inside the provider's daily idempotency window.
    const second = await app.inject({ method: "POST", url: "/v1/digests/send-now", headers: authHeader(app) });
    expect(second.statusCode).toBe(429);
    expect(second.json()).toEqual({ error: "digest_send_limit_reached" });

    // The key is the family, not the token or the address: another family is unaffected.
    prismaMock.parent.findUnique.mockResolvedValue({ ...OWNER, id: "parent-2", familyId: "fam-2" });
    const other = await app.inject({ method: "POST", url: "/v1/digests/send-now", headers: authHeader(app, "fam-2", "parent-2") });
    expect(other.statusCode).toBe(200);

    advanceHour();
    const later = await app.inject({ method: "POST", url: "/v1/digests/send-now", headers: authHeader(app) });
    expect(later.statusCode).toBe(200);
    await app.close();
  });
});
