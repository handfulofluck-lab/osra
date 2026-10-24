import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { FastifyInstance } from "fastify";
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

/** The `where` shapes the ledger is asked with; anything else is a test bug, not a silent pass. */
interface LedgerWhere {
  familyId?: string;
  email?: { in?: string[]; notIn?: string[] };
  tokenHash?: string;
  tokenExpiresAt?: { gt?: Date; lte?: Date };
  OR?: Array<{ tokenExpiresAt: null | { lte: Date } }>;
}

const timeOf = (value: Date | null): number | null => (value === null ? null : new Date(value).getTime());

/** Postgres would match `OR: [{ tokenExpiresAt: null }, { tokenExpiresAt: { lte: now } }]` as "no live link". */
function matches(row: LedgerRow, where: LedgerWhere): boolean {
  if (where.familyId && row.familyId !== where.familyId) return false;
  if (where.email?.in && !where.email.in.includes(row.email)) return false;
  if (where.email?.notIn && where.email.notIn.includes(row.email)) return false;
  if (where.tokenHash !== undefined && row.tokenHash !== where.tokenHash) return false;
  const expires = timeOf(row.tokenExpiresAt);
  if (where.tokenExpiresAt?.gt && !(expires !== null && expires > where.tokenExpiresAt.gt.getTime())) return false;
  if (where.tokenExpiresAt?.lte && !(expires === null || expires <= where.tokenExpiresAt.lte.getTime())) return false;
  if (where.OR) {
    const matched = where.OR.some((clause) =>
      clause.tokenExpiresAt === null
        ? row.tokenExpiresAt === null
        : expires !== null && expires <= clause.tokenExpiresAt.lte.getTime(),
    );
    if (!matched) return false;
  }
  return true;
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
  prismaMock.digestRecipient.findMany.mockImplementation(async ({ where }: { where: LedgerWhere }) =>
    ledger.filter((row) => matches(row, where)),
  );
  prismaMock.digestRecipient.count.mockImplementation(
    async ({ where }: { where: LedgerWhere }) => ledger.filter((row) => matches(row, where)).length,
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
    async ({
      where,
      data,
    }: {
      where: { id: string } | { familyId_email: { familyId: string; email: string } };
      data: Partial<LedgerRow>;
    }) => {
      const row =
        "id" in where
          ? ledger.find((r) => r.id === where.id)
          : ledger.find(
              (r) => r.familyId === where.familyId_email.familyId && r.email === where.familyId_email.email,
            );
      if (!row) throw new Error("Record to update not found");
      Object.assign(row, data);
      return row;
    },
  );
  prismaMock.digestRecipient.deleteMany.mockImplementation(async ({ where }: { where: LedgerWhere }) => {
    const before = ledger.length;
    ledger = ledger.filter((row) => !matches(row, where));
    return { count: before - ledger.length };
  });
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
    prismaMock.digestPrefs.upsert.mockImplementation(
      async ({ create }: { create: Record<string, unknown> }) => ({ ...create }),
    );
  });
  afterEach(() => {
    setEmailSender(null);
    delete process.env.APP_PUBLIC_URL;
  });

  /** One owner save of the recipient list, which is what issues the confirmation mail. */
  const putPrefs = (app: FastifyInstance, emails: string[]) =>
    app.inject({
      method: "PUT",
      url: "/v1/digests/prefs",
      headers: authHeader(app),
      payload: { dailyEmail: true, weeklyEmail: true, pushEnabled: true, emails },
    });

  /** The addresses the save actually mailed, in order. */
  const mailed = (): string[] => capture.sent.map((message) => String(message.to));

  it("refuses a sixth recipient with 400 and writes nothing", async () => {
    const app = await buildApp(digestRoutes, "/v1/digests");
    const six = ["a@example.com", "b@example.com", "c@example.com", "d@example.com", "e@example.com", "f@example.com"];

    const res = await putPrefs(app, six);
    // Mutant: remove `.max(MAX_DIGEST_RECIPIENTS)` from PrefsSchema -> 200, six addresses stored in
    // `DigestPrefs.emails`, and the family is at six recipients instead of the agreed five.
    expect(res.statusCode).toBe(400);
    expect(prismaMock.digestPrefs.upsert).not.toHaveBeenCalled();
    expect(mailed()).toEqual([]);

    // Five is the bound, and it still works.
    prismaMock.digestRecipient.findMany.mockResolvedValue([]);
    const five = await putPrefs(app, six.slice(0, 5));
    expect(five.statusCode).toBe(200);
    expect(five.json().recipients).toHaveLength(5);
    await app.close();
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
    // The button on the page, which is the only thing that spends a link (review of #354, item 3).
    const confirmed = await app.inject({
      method: "POST",
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
    const replay = await app.inject({ method: "POST", url: `/v1/digests/confirm?token=${link}` });
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
    const late = await app.inject({ method: "POST", url: `/v1/digests/confirm?token=${expired}` });
    expect(late.statusCode).toBe(404);
    expect(ledger[0].confirmedAt).toBeNull();

    const unknown = await app.inject({ method: "POST", url: `/v1/digests/confirm?token=${"e".repeat(64)}` });
    expect(unknown.statusCode).toBe(404);
    // Unknown, expired and used are one answer — the 404 above is the same body for all three.
    expect(unknown.json()).toEqual({ error: "confirmation_not_found_or_expired" });
    const malformed = await app.inject({ method: "POST", url: "/v1/digests/confirm?token=short" });
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

  it("mails a new address once when the same list is saved twice", async () => {
    const app = await buildApp(digestRoutes, "/v1/digests");

    expect((await putPrefs(app, [OWNER.email, "grandma@example.com"])).statusCode).toBe(200);
    expect((await putPrefs(app, [OWNER.email, "grandma@example.com"])).statusCode).toBe(200);
    // Mutant: remove the `liveToken` branch in lib/digestRecipients.ts (issue a link on every save) ->
    // two mails to the same stranger and a fresh token each time this screen is saved.
    expect(mailed()).toEqual(["grandma@example.com"]);
    expect(ledger).toHaveLength(1);
    await app.close();
  });

  it("says an address is unsent when the confirmation mail fails, and clears its link", async () => {
    const app = await buildApp(digestRoutes, "/v1/digests");
    setEmailSender({ name: "down", send: async () => ({ ok: false as const, reason: "HTTP 503 unavailable", retryable: true }) });

    const failed = await putPrefs(app, [OWNER.email, "grandma@example.com"]);
    // Mutant: answer the status `pending` without clearing the link -> the family waits 24 hours for a
    // message the provider never accepted, and the address holds a place under the cap all day.
    expect(failed.statusCode).toBe(200);
    expect(failed.json().recipients).toEqual([
      { email: "parent-1@example.com", status: "confirmed" },
      { email: "grandma@example.com", status: "unsent" },
    ]);
    expect(ledger).toHaveLength(1);
    expect(ledger[0].tokenHash).toBeNull();
    expect(ledger[0].tokenExpiresAt).toBeNull();

    // The next save, with the provider back, mails it again — the failure cost nothing but a retry.
    setEmailSender(capture);
    const retry = await putPrefs(app, [OWNER.email, "grandma@example.com"]);
    expect(retry.json().recipients[1]).toEqual({ email: "grandma@example.com", status: "pending" });
    expect(mailed()).toEqual(["grandma@example.com"]);
    await app.close();
  });

  it("does not mail an address again when it is removed and re-added inside the link's life", async () => {
    const app = await buildApp(digestRoutes, "/v1/digests");

    await putPrefs(app, ["a@example.com"]);
    await putPrefs(app, ["b@example.com"]);
    const third = await putPrefs(app, ["a@example.com"]);
    expect(third.statusCode).toBe(200);
    // Mutant: restore the pre-review `deleteMany` (drop `noLiveLink` from the where) -> removing `a`
    // deletes its live row, the third save mints a second link, and `a@example.com` is mailed twice.
    expect(mailed()).toEqual(["a@example.com", "b@example.com"]);
    const a = ledger.filter((row) => row.email === "a@example.com");
    expect(a).toHaveLength(1);
    expect(a[0].tokenExpiresAt).toBeInstanceOf(Date);
    await app.close();
  });

  it("stops issuing confirmation mail past ten live links a day, and says why", async () => {
    const app = await buildApp(digestRoutes, "/v1/digests");
    const batch = (from: number) => Array.from({ length: 5 }, (_, i) => `u${from + i}@example.com`);

    expect((await putPrefs(app, batch(1))).statusCode).toBe(200);
    expect((await putPrefs(app, batch(6))).statusCode).toBe(200);
    expect(mailed()).toHaveLength(10);

    const eleventh = await putPrefs(app, ["u11@example.com"]);
    // Mutant: remove the `budget <= 0` branch in stageRecipients -> an eleventh mail leaves, and a family
    // can mail a new stranger five at a time, forever, one save after another.
    expect(eleventh.statusCode).toBe(200);
    expect(eleventh.json().recipients).toEqual([
      { email: "u11@example.com", status: "pending", limited: true },
    ]);
    expect(mailed()).toHaveLength(10);
    // Nothing was stored for it either, so it does not hold a place under the cap.
    expect(ledger.some((row) => row.email === "u11@example.com")).toBe(false);
    await app.close();
  });

  it("serves a page on GET without confirming anything; the button's POST is what confirms", async () => {
    const app = await buildApp(digestRoutes, "/v1/digests");
    const token = "c".repeat(64);
    seedLedger([
      {
        familyId: "fam-1",
        email: "g@example.com",
        tokenHash: hashConfirmToken(token),
        tokenExpiresAt: new Date(Date.now() + 60 * 60 * 1000),
      },
    ]);

    const page = await app.inject({ method: "GET", url: `/v1/digests/confirm?token=${token}` });
    expect(page.statusCode).toBe(200);
    expect(page.headers["content-type"]).toContain("text/html");
    expect(page.body).toContain('method="post"');
    expect(page.body).toContain(token);
    // Mutant: call `confirmRecipient` in the GET handler -> a mail scanner or a link preview confirms an
    // address no person agreed to, which is the whole point of the split.
    expect(ledger[0].confirmedAt).toBeNull();
    expect(ledger[0].tokenHash).toBe(hashConfirmToken(token));

    // The page is the same for a token that was never issued: a GET discloses nothing.
    const stranger = await app.inject({ method: "GET", url: `/v1/digests/confirm?token=${"9".repeat(64)}` });
    expect(stranger.statusCode).toBe(200);
    expect(stranger.body).toContain('method="post"');

    const spent = await app.inject({ method: "POST", url: `/v1/digests/confirm?token=${token}` });
    expect(spent.statusCode).toBe(200);
    expect(spent.json()).toEqual({ confirmed: true, email: "g@example.com" });
    expect(ledger[0].confirmedAt).toBeInstanceOf(Date);
    await app.close();
  });

  it("answers a spent link with 404, the same answer as unknown and expired", async () => {
    const app = await buildApp(digestRoutes, "/v1/digests");
    const token = "b".repeat(64);
    seedLedger([
      {
        familyId: "fam-1",
        email: "h@example.com",
        tokenHash: hashConfirmToken(token),
        tokenExpiresAt: new Date(Date.now() + 60 * 60 * 1000),
      },
    ]);

    expect((await app.inject({ method: "POST", url: `/v1/digests/confirm?token=${token}` })).statusCode).toBe(200);
    const again = await app.inject({ method: "POST", url: `/v1/digests/confirm?token=${token}` });
    // Mutant: treat a confirmed row as success and keep its link (`if (row.confirmedAt) return { email }`
    // plus `data: { confirmedAt: now }` in confirmRecipient) -> the second POST answers 200 and a link is
    // reusable for the 24 hours it lives.
    expect(again.statusCode).toBe(404);
    expect(again.json()).toEqual({ error: "confirmation_not_found_or_expired" });
    await app.close();
  });
});
