import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createHash, createHmac, randomBytes } from "node:crypto";
import { signV2 } from "../src/lib/internalAuth.js";
import { decryptForFamily, encryptForFamily } from "@familyshield/crypto";
import { localDay, socialRoutes } from "../src/routes/social.js";
import { deviceRoutes } from "../src/routes/devices.js";
import { reportsRoutes } from "../src/routes/reports.js";
import { rulesRoutes } from "../src/routes/rules.js";
import { getRedis } from "../src/redis.js";
import { MockRedis, authHeader, buildApp, deviceHeader, prismaMock, resetPrismaMock } from "./helpers.js";
import { expectKeyedAlertBody } from "./alertBody.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

const SECRET = "test-internal-secret";
const VAULT_KEY = Buffer.alloc(32, 7).toString("base64");
const CHILD = { id: "child-1", familyId: "fam-1", birthYear: 2012, family: { timezone: "Asia/Dubai" } };
const FLAGGED_TEXT = "seriously you should kill yourself";

const sign = (raw: string) => createHmac("sha256", SECRET).update(raw).digest("hex");

const aiOk = (body: unknown) =>
  vi.fn(async () => ({ ok: true, json: async () => body })) as unknown as typeof fetch;

/** Post a validly-signed scan request. */
function postScan(app: Awaited<ReturnType<typeof buildApp>>, body: Record<string, unknown>) {
  const raw = JSON.stringify(body);
  return app.inject({
    method: "POST",
    url: "/v1/social/scan",
    headers: { "content-type": "application/json", ...signV2(SECRET, raw, { caller: "ai-engine" }) },
    payload: raw,
  });
}

const scanBody = (overrides: Record<string, unknown> = {}) => ({
  childId: CHILD.id,
  app: "whatsapp",
  contact: "bully-1",
  text: FLAGGED_TEXT,
  ...overrides,
});

/** In-memory NX-capable SET implementation for throttle tests. */
const throttleStore = new Map<string, string>();

function mockThrottleSet() {
  const set = getRedis().set as unknown as {
    mockImplementation: (fn: (key: string, value: string, ...rest: unknown[]) => Promise<string | null>) => void;
  };
  set.mockImplementation((key, value, ...rest) => {
    if (rest.includes("NX")) {
      if (throttleStore.has(key)) return Promise.resolve(null);
      throttleStore.set(key, value);
      return Promise.resolve("OK");
    }
    return Promise.resolve("OK");
  });
}

const familyAlertPublishes = () =>
  MockRedis.instances.flatMap((r) => r.publish.mock.calls).filter(
    ([channel, msg]) => channel === "family:fam-1:events" && JSON.parse(msg as string).type === "alert",
  );

describe("social routes", () => {
  beforeEach(() => {
    resetPrismaMock();
    // Publish events now go through the shared lazy singleton (review API-4 fix),
    // so reset call history instead of dropping the instance registry.
    for (const r of MockRedis.instances) r.publish.mockClear();
    throttleStore.clear();
    process.env.INTERNAL_HMAC_SECRET = SECRET;
    process.env.VAULT_KEY = VAULT_KEY;
    process.env.AI_ENGINE_URL = "http://ai-engine:8000";
    mockThrottleSet();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    vi.unstubAllEnvs();
  });

  it.each([false, true])("writes a model-only notification alert (exploratory mode=%s)", async (exploratory) => {
    const fixture = "The group wants to leave one classmate out of every lunch table.";
    const sample = exploratory ? "They agreed to leave one classmate out every day." : fixture;
    const benign = "The window is open.";
    const deviceId = "qa-device-fixture";
    const syntheticKey = randomBytes(32).toString("hex");
    vi.stubEnv("OSRA_DEPLOYMENT_SCOPE", "staging");
    vi.stubEnv("OSRA_STAGING_QA_ANALYZER_ENABLED", "1");
    vi.stubEnv("OSRA_STAGING_QA_ALLOW_SYNTHETIC_PAIR_TEXT", exploratory ? "1" : "0");
    vi.stubEnv("OSRA_STAGING_QA_DEVICE_ID", deviceId);
    vi.stubEnv("OSRA_STAGING_QA_CHILD_ID", CHILD.id);
    vi.stubEnv("OSRA_STAGING_QA_EXPIRES_AT", new Date(Date.now() + 15 * 60 * 1000).toISOString());
    vi.stubEnv("OSRA_STAGING_QA_FIXTURE_SHA256", createHash("sha256").update(fixture).digest("hex"));
    vi.stubEnv("OSRA_STAGING_QA_ANALYZER_URL", "http://ai-engine.osra-qa.internal:8000");
    const analyze = vi.fn(async (_url: URL, options: RequestInit) => {
      const request = JSON.parse(String(options.body)) as { text: string; trace_id: string };
      return { ok: true, json: async () => ({
        trace_id: request.trace_id, model: "openai.gpt-oss-20b-1:0", region: "eu-central-1",
        flagged: request.text !== benign, severity: request.text === benign ? "info" : "warning",
        categories: request.text === benign ? { safe: 1 } : { cyberbullying: 0.9, safe: 0.1 },
      }) };
    });
    vi.stubGlobal("fetch", analyze);
    prismaMock.device.findUnique.mockResolvedValue({ id: deviceId, childId: CHILD.id, internalSecret: syntheticKey });
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.socialEvent.create.mockResolvedValue({ id: "synthetic-event" });
    prismaMock.alert.create.mockResolvedValue({ id: "synthetic-alert" });
    const app = await buildApp(socialRoutes, "/v1/social");
    const scan = (body: Record<string, unknown>) => {
      const raw = JSON.stringify({ deviceId, items: [scanBody({ deviceId, source: "notification", ...body })] });
      return app.inject({ method: "POST", url: "/v1/social/scan",
        headers: { "content-type": "application/json", ...signV2(syntheticKey, raw) }, payload: raw });
    };
    try {
      const harmless = await scan({ text: benign });
      expect(harmless.statusCode).toBe(200);
      expect(harmless.json().results[0]).toMatchObject({ flagged: false });
      expect(prismaMock.alert.create).not.toHaveBeenCalled();
      expect(analyze).toHaveBeenCalledTimes(exploratory ? 1 : 0);

      const res = await scan({ text: sample });
      expect(res.statusCode).toBe(200);
      expect(res.json().results[0]).toMatchObject({ flagged: true, concernTypes: ["cyberbullying"] });
      expect(analyze).toHaveBeenCalledTimes(exploratory ? 2 : 1);
      const [url, options] = analyze.mock.calls[exploratory ? 1 : 0];
      expect(url.href).toBe("http://ai-engine.osra-qa.internal:8000/analyze/staging-qa");
      expect(options.redirect).toBe("error");
      expect(JSON.parse(String(options.body))).toEqual({ text: sample, trace_id: expect.any(String) });
      expect(prismaMock.socialEvent.create).toHaveBeenCalledTimes(1);
      expect(prismaMock.alert.create).toHaveBeenCalledTimes(1);
    } finally {
      await app.close();
    }
  });

  it("returns {flagged:false} for clean text and writes no alert or vault row", async () => {
    const app = await buildApp(socialRoutes, "/v1/social");
    vi.stubGlobal("fetch", aiOk({ flagged: false, severity: "info", categories: { safe: 0.95 } }));
    prismaMock.child.findUnique.mockResolvedValue(CHILD);

    const res = await postScan(app, scanBody({ text: "want to play soccer later?" }));
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ flagged: false, severity: "info", concernTypes: [] });
    expect(prismaMock.socialEvent.create).not.toHaveBeenCalled();
    expect(prismaMock.alert.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("counts each scan against the family's own day (#890 cost accounting)", async () => {
    // The pricing debate needs "measured cost per family"; this row is what makes it a query. The counters
    // are per family-local day, because a UTC date would move a Dubai family's evening into tomorrow.
    const app = await buildApp(socialRoutes, "/v1/social");
    vi.stubGlobal("fetch", aiOk({ flagged: false, severity: "info", categories: { safe: 0.9 } }));
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.family.findUnique.mockResolvedValue({ timezone: "Asia/Dubai" });

    await postScan(app, scanBody({ text: "want to play soccer later?" }));

    expect(prismaMock.aiScanUsage.upsert).toHaveBeenCalledTimes(1);
    const call = prismaMock.aiScanUsage.upsert.mock.calls[0][0] as {
      where: { familyId_day: { familyId: string; day: string } };
      create: { scans: number; aiCalls: number };
      update: Record<string, unknown>;
    };
    expect(call.where.familyId_day.familyId).toBe("fam-1");
    expect(call.where.familyId_day.day).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    expect(call.create).toMatchObject({ scans: 1, aiCalls: 1 });
    expect(call.update).toEqual({ scans: { increment: 1 }, aiCalls: { increment: 1 } });
    await app.close();
  });

  it("a scan the engine never answered is a scan but not a model call (#890)", async () => {
    // The fallback path is free: counting it as an AI call would overstate every family's bill, and the
    // whole point of the counter is to be the number a price is set from.
    const app = await buildApp(socialRoutes, "/v1/social");
    vi.stubGlobal("fetch", vi.fn(async () => { throw new Error("ECONNREFUSED"); }));
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.family.findUnique.mockResolvedValue({ timezone: "UTC" });

    await postScan(app, scanBody({ text: "want to play soccer later?" }));

    const call = prismaMock.aiScanUsage.upsert.mock.calls[0][0] as {
      create: { scans: number; aiCalls: number };
      update: Record<string, unknown>;
    };
    expect(call.create).toMatchObject({ scans: 1, aiCalls: 0 });
    // The mutant — always incrementing aiCalls — would bill a family for an engine that never ran.
    expect(call.update).toEqual({ scans: { increment: 1 } });
    await app.close();
  });

  it("a broken counter cannot fail the scan or lose the alert (#897 review, u5)", async () => {
    // The route is the child-safety path: a scan that 500s is a message never classified and an alert never
    // raised. The counter is allowed to fail; the verdict and the alert are not. Mutant: let the counter's
    // error escape (or move the write above the verdict) and this row goes red.
    const app = await buildApp(socialRoutes, "/v1/social");
    vi.stubGlobal("fetch", aiOk({ flagged: true, severity: "warning", categories: { self_harm: 0.9 } }));
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.socialEvent.create.mockResolvedValue({ id: "se-1" });
    prismaMock.alert.create.mockResolvedValue({ id: "a-1" });
    prismaMock.aiScanUsage.upsert.mockRejectedValue(new Error("counter down"));

    const res = await postScan(app, scanBody());

    expect(res.statusCode).toBe(200);
    // #938 B3: the union keeps the higher severity. The text hits the local self-harm list, which is
    // critical by policy, so the model's "warning" no longer downgrades it.
    expect(res.json()).toMatchObject({ flagged: true, severity: "critical" });
    expect(prismaMock.socialEvent.create).toHaveBeenCalledTimes(1);
    expect(prismaMock.alert.create).toHaveBeenCalledTimes(1);
    // One retry on the way out, and still no throw: a unique-index race is not a scan failure either.
    expect(prismaMock.aiScanUsage.upsert).toHaveBeenCalledTimes(2);
    await app.close();
  });

  it("the day key is the family's zone, and a broken zone falls back to UTC (#897 review, u4/u9)", () => {
    // 21:30 UTC is 01:30 the next day in Dubai. A UTC key would file that scan under yesterday, and a
    // monthly figure would drift by a day per family without anyone seeing it. Tested on the pure function
    // rather than through the route: fake timers stall the rate limiter's own timers, and the property under
    // test is the arithmetic, not the transport.
    expect(localDay(new Date("2026-11-17T21:30:00Z"), "Asia/Dubai")).toBe("2026-11-18");
    expect(localDay(new Date("2026-11-17T21:30:00Z"), "UTC")).toBe("2026-11-17");
    // A zone the database should never hold: fall back to UTC, do not throw inside the scan path.
    expect(() => localDay(new Date("2026-11-17T21:30:00Z"), "Mars/Olympus")).not.toThrow();
    expect(localDay(new Date("2026-11-17T21:30:00Z"), "Mars/Olympus")).toBe("2026-11-17");
  });

  it("the counter's day is the family's, taken from the child row the route already read", async () => {
    // The route-level half of the same claim: the key written for a Dubai family is the Dubai day, and the
    // zone came from the query that already ran (no second family lookup on the scan path).
    const app = await buildApp(socialRoutes, "/v1/social");
    vi.stubGlobal("fetch", aiOk({ flagged: false, severity: "info", categories: { safe: 0.9 } }));
    prismaMock.child.findUnique.mockResolvedValue(CHILD);

    await postScan(app, scanBody({ text: "want to play soccer later?" }));

    const call = prismaMock.aiScanUsage.upsert.mock.calls[0][0] as { where: { familyId_day: { day: string } } };
    expect(call.where.familyId_day.day).toBe(localDay(new Date(), "Asia/Dubai"));
    expect(prismaMock.family.findUnique).not.toHaveBeenCalled();
    await app.close();
  });

  it("a scan whose engine call timed out is still a model attempt (#897 review, point a)", async () => {
    // A request that reached the engine and ran past the 5 s timeout was paid for; recording it as a free
    // local-pattern scan under-counts every family, which is the unsafe direction for a cost floor.
    const app = await buildApp(socialRoutes, "/v1/social");
    const timeout = Object.assign(new Error("timed out"), { name: "TimeoutError" });
    vi.stubGlobal("fetch", vi.fn(async () => { throw timeout; }));
    prismaMock.child.findUnique.mockResolvedValue(CHILD);

    await postScan(app, scanBody({ text: "want to play soccer later?" }));

    const call = prismaMock.aiScanUsage.upsert.mock.calls[0][0] as { create: { scans: number; aiCalls: number } };
    expect(call.create).toMatchObject({ scans: 1, aiCalls: 1 });
    await app.close();
  });

  it("flags risky text: vault row holds only ciphertext, alert has no preview snippet", async () => {
    const app = await buildApp(socialRoutes, "/v1/social");
    vi.stubGlobal("fetch", aiOk({ flagged: true, severity: "warning", categories: { self_harm: 0.8, safe: 0.2 } }));
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.socialEvent.create.mockResolvedValue({ id: "se-1" });
    prismaMock.alert.create.mockResolvedValue({ id: "a-1" });

    const res = await postScan(app, scanBody());
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ flagged: true, severity: "critical", concernTypes: ["self_harm"] });

    // The vault row stores the AES-GCM payload — plaintext must never appear.
    const cipher = prismaMock.socialEvent.create.mock.calls[0][0] as {
      data: { previewCipher: string; severity: string; concernTypes: string[]; app: string; contact: string; childId: string };
    };
    expect(cipher.data).toMatchObject({ childId: CHILD.id, app: "whatsapp", contact: "bully-1", severity: "critical", concernTypes: ["self_harm"] });
    expect(cipher.data.previewCipher).not.toContain(FLAGGED_TEXT);
    const payload = JSON.parse(cipher.data.previewCipher) as Parameters<typeof decryptForFamily>[0];
    expect(decryptForFamily(payload, VAULT_KEY)).toBe(FLAGGED_TEXT);

    // The alert metadata carries app/contact/concernTypes and localization values — no snippet.
    const alertData = prismaMock.alert.create.mock.calls[0][0] as { data: Record<string, unknown> };
    expect(alertData.data.category).toBe("social_concern");
    expect(alertData.data.metadata).toEqual({
      app: "whatsapp",
      contact: "bully-1",
      concernTypes: ["self_harm"],
      bodyKey: "alertBodySocialConcern",
      bodyParams: { app: "whatsapp", contact: "bully-1" },
    });
    expectKeyedAlertBody(alertData.data, "alertBodySocialConcern", { app: "whatsapp", contact: "bully-1" });
    expect(alertData.data.metadata).not.toHaveProperty("preview");

    // The family realtime channel received the alert.
    expect(familyAlertPublishes().length).toBe(1);
    await app.close();
  });

  it("a scan with no contact carries no contact param, so the app never renders a placeholder (Fable n4)", async () => {
    // The English body says "A contact"; the PARAM must not. If the producer filled the param with the
    // English placeholder, a parent reading Arabic would see an English sentence fragment inside it.
    const app = await buildApp(socialRoutes, "/v1/social");
    vi.stubGlobal("fetch", aiOk({ flagged: true, severity: "warning", categories: { self_harm: 0.9 } }));
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.socialEvent.create.mockResolvedValue({ id: "event-nc" });
    prismaMock.alert.create.mockResolvedValue({ id: "a-nc" });

    const res = await postScan(app, scanBody({ contact: "" }));
    expect(res.statusCode).toBe(200);

    const alertData = (prismaMock.alert.create.mock.calls[0][0] as { data: Record<string, unknown> }).data;
    expect((alertData.metadata as { bodyParams: unknown }).bodyParams).toEqual({ app: "whatsapp" });
    expect((alertData.metadata as { bodyParams: Record<string, unknown> }).bodyParams).not.toHaveProperty("contact");
    await app.close();
  });

  it("truncates vault snippets to 240 characters before encrypting", async () => {
    const app = await buildApp(socialRoutes, "/v1/social");
    vi.stubGlobal("fetch", aiOk({ flagged: true, severity: "warning", categories: { self_harm: 0.9 } }));
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    const long = "x".repeat(600);
    const res = await postScan(app, scanBody({ text: long }));
    expect(res.statusCode).toBe(200);
    const cipher = (prismaMock.socialEvent.create.mock.calls[0][0] as { data: { previewCipher: string } }).data;
    const payload = JSON.parse(cipher.previewCipher) as Parameters<typeof decryptForFamily>[0];
    expect(decryptForFamily(payload, VAULT_KEY)).toBe(long.slice(0, 240));
    await app.close();
  });

  it("fails open to a local keyword check when the AI engine is down", async () => {
    const app = await buildApp(socialRoutes, "/v1/social");
    vi.stubGlobal("fetch", vi.fn(async () => { throw new Error("ECONNREFUSED"); }));
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.alert.create.mockResolvedValue({ id: "a-1" });

    const res = await postScan(app, scanBody());
    expect(res.statusCode).toBe(200);
    expect(res.json().flagged).toBe(true);
    expect(prismaMock.socialEvent.create).toHaveBeenCalledWith(
      expect.objectContaining({ data: expect.objectContaining({ concernTypes: expect.arrayContaining(["self_harm"]) }) }),
    );
    expect(prismaMock.alert.create).toHaveBeenCalled();
    await app.close();
  });

  // #863: the child sent Arabic insults and drug words over WhatsApp and nothing reached the parent.
  // These rows pin the two halves of the fix: the local list now reads Arabic, and a local hit survives a
  // model answer of "not flagged" instead of being suppressed by it.
  it("the local fallback reads Arabic insults, drug words and self-harm phrasing (#863)", async () => {
    const app = await buildApp(socialRoutes, "/v1/social");
    vi.stubGlobal("fetch", vi.fn(async () => { throw new Error("ECONNREFUSED"); }));
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.alert.create.mockResolvedValue({ id: "a-1" });

    const cases: Array<[string, string]> = [
      ["غبي وما أحد يحبك", "cyberbullying"],
      ["أريد أن أموت", "self_harm"],
      ["عندي حشيش في الشارع", "substance_use"],
      ["he offered me weed after school", "substance_use"],
    ];
    for (const [text, concern] of cases) {
      prismaMock.socialEvent.create.mockClear();
      const res = await postScan(app, scanBody({ text }));
      expect(res.statusCode).toBe(200);
      expect(res.json().flagged, text).toBe(true);
      expect(prismaMock.socialEvent.create).toHaveBeenCalledWith(
        expect.objectContaining({ data: expect.objectContaining({ concernTypes: expect.arrayContaining([concern]) }) }),
      );
    }
    await app.close();
  });

  it("a local hit is not suppressed by a model that answered \"not flagged\" (#863)", async () => {
    const app = await buildApp(socialRoutes, "/v1/social");
    // The engine is reachable and says safe — the rules layer did exactly this for Arabic.
    vi.stubGlobal("fetch", aiOk({ flagged: false, severity: "info", categories: { safe: 0.99 } }));
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.alert.create.mockResolvedValue({ id: "a-1" });

    const res = await postScan(app, scanBody({ text: "أريد أن أموت" }));
    expect(res.statusCode).toBe(200);
    expect(res.json().flagged).toBe(true);
    expect(prismaMock.alert.create).toHaveBeenCalled();
    await app.close();
  });

  // Antigravity's #938 B2: token boundaries. Each of these is a real word whose stem appears in the
  // Arabic list, and each once raised a false drug or bullying alert to a parent.
  it("Arabic stems do not fire inside ordinary words (#938 B2)", async () => {
    const app = await buildApp(socialRoutes, "/v1/social");
    vi.stubGlobal("fetch", aiOk({ flagged: false, severity: "info", categories: { safe: 0.99 } }));
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.alert.create.mockResolvedValue({ id: "a-1" });

    const benign = [
      "فيبدأ الدرس بعد الجرس",
      "قميص خمري جديد",
      "نشاهد مباراة رغبي الليلة",
    ];
    for (const text of benign) {
      prismaMock.socialEvent.create.mockClear();
      const res = await postScan(app, scanBody({ text }));
      expect(res.statusCode).toBe(200);
      expect(res.json().flagged, text).toBe(false);
      expect(prismaMock.socialEvent.create).not.toHaveBeenCalled();
    }
    await app.close();
  });

  it("a mixed message keeps the critical concern the model missed (#938 B3)", async () => {
    const app = await buildApp(socialRoutes, "/v1/social");
    // The model sees the English insult and stops there; the Arabic clause is a self-harm statement.
    vi.stubGlobal("fetch", aiOk({ flagged: true, severity: "warning", categories: { cyberbullying: 0.9, safe: 0.1 } }));
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.alert.create.mockResolvedValue({ id: "a-1" });

    const text = "you loser, أريد أن أموت";
    const res = await postScan(app, scanBody({ text }));
    expect(res.statusCode).toBe(200);
    expect(res.json().flagged).toBe(true);
    expect(res.json().severity).toBe("critical");
    expect(res.json().concernTypes).toEqual(expect.arrayContaining(["cyberbullying", "self_harm"]));
    await app.close();
  });

  it("throttles repeat alerts per app within 10 minutes but always writes the vault row", async () => {
    const app = await buildApp(socialRoutes, "/v1/social");
    vi.stubGlobal("fetch", aiOk({ flagged: true, severity: "warning", categories: { self_harm: 0.8, safe: 0.2 } }));
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.alert.create.mockResolvedValue({ id: "a-1" });

    const first = await postScan(app, scanBody({ text: "first kill yourself" }));
    expect(first.json().flagged).toBe(true);
    const second = await postScan(app, scanBody({ text: "second kill yourself" }));
    expect(second.json().flagged).toBe(true);

    expect(prismaMock.socialEvent.create).toHaveBeenCalledTimes(2);
    expect(prismaMock.alert.create).toHaveBeenCalledTimes(1);
    expect(familyAlertPublishes().length).toBe(1);
    await app.close();
  });

  it("uses the gaming_chat category for Discord messages", async () => {
    const app = await buildApp(socialRoutes, "/v1/social");
    vi.stubGlobal("fetch", aiOk({ flagged: true, severity: "warning", categories: { cyberbullying: 0.9 } }));
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.alert.create.mockResolvedValue({ id: "a-1" });

    const res = await postScan(app, scanBody({ app: "discord" }));
    expect(res.statusCode).toBe(200);
    expect((prismaMock.alert.create.mock.calls[0][0] as { data: { category: string } }).data.category).toBe("gaming_chat");
    await app.close();
  });

  it("rejects a scan without a valid HMAC signature (401)", async () => {
    const app = await buildApp(socialRoutes, "/v1/social");
    const res = await app.inject({ method: "POST", url: "/v1/social/scan", payload: scanBody() });
    expect(res.statusCode).toBe(401);
    expect(prismaMock.socialEvent.create).not.toHaveBeenCalled();
    await app.close();
  });

  it("rejects a well-signed scan with an invalid payload (400)", async () => {
    const app = await buildApp(socialRoutes, "/v1/social");
    const raw = JSON.stringify({ childId: CHILD.id, app: "whatsapp" }); // missing text
    const res = await app.inject({
      method: "POST",
      url: "/v1/social/scan",
      headers: { "content-type": "application/json", ...signV2(SECRET, raw, { caller: "ai-engine" }) },
      payload: raw,
    });
    expect(res.statusCode).toBe(400);
    await app.close();
  });

  it("returns 404 for a well-signed scan naming an unknown child", async () => {
    const app = await buildApp(socialRoutes, "/v1/social");
    vi.stubGlobal("fetch", aiOk({ flagged: false, severity: "info", categories: { safe: 1 } }));
    prismaMock.child.findUnique.mockResolvedValue(null);
    const res = await postScan(app, scanBody());
    expect(res.statusCode).toBe(404);
    expect(res.json().error).toBe("child_not_found");
    await app.close();
  });

  /**
   * #490: an agent sends a flush as one `{ items: [...] }` request. Each item is answered on its own,
   * in order, so one bad item doesn't drop the others; more than SCAN_BATCH_MAX (6) is a 400.
   */
  describe("batched scans (#490)", () => {
    const flaggedAi = () => aiOk({ flagged: true, severity: "warning", categories: { self_harm: 0.8, safe: 0.2 } });

    it("scans an array body and answers each item in order", async () => {
      const app = await buildApp(socialRoutes, "/v1/social");
      vi.stubGlobal("fetch", flaggedAi());
      prismaMock.child.findUnique.mockResolvedValue(CHILD);
      const res = await postScan(app, { items: [scanBody({ text: "one kill yourself" }), scanBody({ text: "two kill yourself" })] });
      expect(res.statusCode).toBe(200);
      expect(res.json()).toEqual({
        results: [
          { ok: true, flagged: true, severity: "critical", concernTypes: ["self_harm"] },
          { ok: true, flagged: true, severity: "critical", concernTypes: ["self_harm"] },
        ],
      });
      expect(prismaMock.socialEvent.create).toHaveBeenCalledTimes(2);
      await app.close();
    });

    it("takes exactly 6 items and refuses 7 as a whole", async () => {
      const app = await buildApp(socialRoutes, "/v1/social");
      vi.stubGlobal("fetch", aiOk({ flagged: false, severity: "info", categories: { safe: 1 } }));
      prismaMock.child.findUnique.mockResolvedValue(CHILD);
      const six = await postScan(app, { items: Array.from({ length: 6 }, (_, i) => scanBody({ text: `hello ${i}` })) });
      expect(six.statusCode).toBe(200);
      expect(six.json().results).toHaveLength(6);
      const seven = await postScan(app, { items: Array.from({ length: 7 }, (_, i) => scanBody({ text: `hello ${i}` })) });
      expect(seven.statusCode).toBe(400);
      expect(seven.json()).not.toHaveProperty("results");
      await app.close();
    });

    it("a failing item 2 is reported on its own; items 1 and 3 are stored", async () => {
      const app = await buildApp(socialRoutes, "/v1/social");
      vi.stubGlobal("fetch", flaggedAi());
      prismaMock.child.findUnique.mockImplementation((async (args: { where: { id: string } }) =>
        args.where.id === CHILD.id ? CHILD : null) as never);
      const res = await postScan(app, {
        items: [
          scanBody({ text: "one kill yourself" }),
          scanBody({ childId: "child-unknown", text: "two kill yourself" }),
          scanBody({ text: "three kill yourself" }),
        ],
      });
      expect(res.statusCode).toBe(200);
      const results = res.json().results as Array<Record<string, unknown>>;
      expect(results.map((r) => r.ok)).toEqual([true, false, true]);
      expect(results[1]).toEqual({ ok: false, reason: "child_not_found" });
      expect(prismaMock.socialEvent.create).toHaveBeenCalledTimes(2);
      const stored = prismaMock.socialEvent.create.mock.calls.map((c) => (c[0] as { data: { childId: string } }).data.childId);
      expect(stored).toEqual([CHILD.id, CHILD.id]);
      await app.close();
    });

    it("an invalid item is reported as invalid_item without failing the batch", async () => {
      const app = await buildApp(socialRoutes, "/v1/social");
      vi.stubGlobal("fetch", aiOk({ flagged: false, severity: "info", categories: { safe: 1 } }));
      prismaMock.child.findUnique.mockResolvedValue(CHILD);
      const res = await postScan(app, { items: [{ childId: CHILD.id, app: "whatsapp" }, scanBody({ text: "hi" })] });
      expect(res.statusCode).toBe(200);
      expect(res.json().results).toEqual([
        { ok: false, reason: "invalid_item" },
        { ok: true, flagged: false, severity: "info", concernTypes: [] },
      ]);
      await app.close();
    });

    it("scans the items concurrently, so a slow AI engine costs one wait, not six (#498 review)", async () => {
      const app = await buildApp(socialRoutes, "/v1/social");
      const DELAY_MS = 300;
      vi.stubGlobal("fetch", vi.fn(async () => {
        await new Promise((resolve) => setTimeout(resolve, DELAY_MS));
        return { ok: true, json: async () => ({ flagged: false, severity: "info", categories: { safe: 1 } }) };
      }) as unknown as typeof fetch);
      prismaMock.child.findUnique.mockResolvedValue(CHILD);
      const started = Date.now();
      const res = await postScan(app, { items: Array.from({ length: 6 }, (_, i) => scanBody({ text: `hello ${i}` })) });
      const elapsed = Date.now() - started;
      expect(res.statusCode).toBe(200);
      expect(res.json().results).toHaveLength(6);
      // Serial would take 6 × 300 ms; concurrent takes about one delay.
      expect(elapsed).toBeLessThan(2 * DELAY_MS);
      await app.close();
    });

    it("the single-item body older agents send still works, unchanged", async () => {
      const app = await buildApp(socialRoutes, "/v1/social");
      vi.stubGlobal("fetch", flaggedAi());
      prismaMock.child.findUnique.mockResolvedValue(CHILD);
      const res = await postScan(app, scanBody());
      expect(res.statusCode).toBe(200);
      // #938 B3: the union keeps the higher severity, so the local self-harm hit makes this critical.
      expect(res.json()).toEqual({ flagged: true, severity: "critical", concernTypes: ["self_harm"] });
      expect(prismaMock.socialEvent.create).toHaveBeenCalledTimes(1);
      await app.close();
    });

    /**
     * Per-device v2 HMAC regression coverage for #967 (tracked in osra-security#46):
     * `postScan` above signs with the global service secret (`caller: "ai-engine"`), which bypasses
     * per-device secret lookup in `authenticateInternalRequest`. These four cases exercise the real
     * child-agent wire path (per-device `internalSecret`, no `x-familyshield-caller`, no `x-device-id`).
     *
     * Mutants killed:
     * - Removing root `deviceId` from the batch envelope turns case 1 into 401 `invalid_signature` (proven in case 2).
     * - Removing the `device.childId !== childId` or `deviceId !== device.id` check in `scanOne` lets the
     *   foreign items in case 3 pass instead of returning `cross_child_forbidden` / `device_mismatch`.
     */
    describe("per-device v2 HMAC batch authentication (#967)", () => {
      const DEVICE_SECRET = "test-device-a-hmac-secret";
      const DEVICE_A = { id: "dev-a", childId: CHILD.id, internalSecret: DEVICE_SECRET };

      function mockPairedDevice() {
        prismaMock.device.findUnique.mockImplementation((async (args: { where: { id: string } }) =>
          args.where.id === DEVICE_A.id ? DEVICE_A : null) as never);
      }

      it("accepts the #967 root-deviceId batch envelope signed with the device's own secret", async () => {
        const app = await buildApp(socialRoutes, "/v1/social");
        mockPairedDevice();
        vi.stubGlobal("fetch", flaggedAi());
        prismaMock.child.findUnique.mockResolvedValue(CHILD);
        const raw = JSON.stringify({
          deviceId: DEVICE_A.id,
          items: [scanBody({ deviceId: DEVICE_A.id, source: "notification" })],
        });
        const res = await app.inject({
          method: "POST",
          url: "/v1/social/scan",
          headers: { "content-type": "application/json", ...signV2(DEVICE_SECRET, raw) },
          payload: raw,
        });
        expect(res.statusCode).toBe(200);
        expect(res.json()).toEqual({
          results: [{ ok: true, flagged: true, severity: "critical", concernTypes: ["self_harm"] }],
        });
        await app.close();
      });

      it("rejects a batch without root deviceId under per-device v2 HMAC with 401 invalid_signature", async () => {
        const app = await buildApp(socialRoutes, "/v1/social");
        mockPairedDevice();
        const raw = JSON.stringify({
          items: [scanBody({ deviceId: DEVICE_A.id, source: "notification" })],
        });
        const res = await app.inject({
          method: "POST",
          url: "/v1/social/scan",
          headers: { "content-type": "application/json", ...signV2(DEVICE_SECRET, raw) },
          payload: raw,
        });
        expect(res.statusCode).toBe(401);
        expect(res.json()).toEqual({ error: "invalid_signature", reason: "invalid_signature" });
        await app.close();
      });

      it("refuses foreign childId and foreign deviceId items inside a valid device-A batch without dropping valid items", async () => {
        const app = await buildApp(socialRoutes, "/v1/social");
        mockPairedDevice();
        const fetchMock = aiOk({ flagged: false, severity: "info", categories: { safe: 1 } });
        vi.stubGlobal("fetch", fetchMock);
        prismaMock.child.findUnique.mockResolvedValue(CHILD);
        const raw = JSON.stringify({
          deviceId: DEVICE_A.id,
          items: [
            scanBody({ deviceId: DEVICE_A.id, text: "benign message" }),
            scanBody({ childId: "child-other", deviceId: DEVICE_A.id, text: "foreign child" }),
            scanBody({ deviceId: "dev-other", text: "foreign device" }),
          ],
        });
        const res = await app.inject({
          method: "POST",
          url: "/v1/social/scan",
          headers: { "content-type": "application/json", ...signV2(DEVICE_SECRET, raw) },
          payload: raw,
        });
        expect(res.statusCode).toBe(200);
        expect(res.json()).toEqual({
          results: [
            { ok: true, flagged: false, severity: "info", concernTypes: [] },
            { ok: false, reason: "cross_child_forbidden" },
            { ok: false, reason: "device_mismatch" },
          ],
        });
        // Codex (#970 7062553658): rejected entries must never invoke the analyzer or create stored side effects.
        expect(fetchMock).toHaveBeenCalledTimes(1);
        expect(JSON.parse(String(fetchMock.mock.calls[0]?.[1]?.body ?? "{}"))).toMatchObject({
          text: "benign message",
        });
        expect(prismaMock.socialEvent.create).not.toHaveBeenCalled();
        expect(prismaMock.alert.create).not.toHaveBeenCalled();
        await app.close();
      });

      it("preserves single-item compatibility under per-device v2 HMAC", async () => {
        const app = await buildApp(socialRoutes, "/v1/social");
        mockPairedDevice();
        vi.stubGlobal("fetch", aiOk({ flagged: false, severity: "info", categories: { safe: 1 } }));
        prismaMock.child.findUnique.mockResolvedValue(CHILD);
        const raw = JSON.stringify(scanBody({ deviceId: DEVICE_A.id, text: "benign single" }));
        const res = await app.inject({
          method: "POST",
          url: "/v1/social/scan",
          headers: { "content-type": "application/json", ...signV2(DEVICE_SECRET, raw) },
          payload: raw,
        });
        expect(res.statusCode).toBe(200);
        expect(res.json()).toEqual({ flagged: false, severity: "info", concernTypes: [] });
        await app.close();
      });
    });
  });

  it("lists vault events decrypted, newest first, with filters", async () => {
    const app = await buildApp(socialRoutes, "/v1/social");
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    const previewCipher = JSON.stringify(encryptForFamily("are you alone tonight?", VAULT_KEY));
    prismaMock.socialEvent.findMany.mockResolvedValue([
      { id: "se-1", app: "whatsapp", contact: "c-1", severity: "critical", previewCipher, concernTypes: ["grooming"], createdAt: "2026-09-16T10:00:00Z" },
    ]);

    const res = await app.inject({
      method: "GET",
      url: "/v1/social/events?childId=child-1&app=whatsapp&severity=critical&limit=10",
      headers: authHeader(app),
    });
    expect(res.statusCode).toBe(200);
    expect(prismaMock.socialEvent.findMany).toHaveBeenCalledWith(
      expect.objectContaining({
        where: { childId: "child-1", app: "whatsapp", severity: "critical" },
        orderBy: { createdAt: "desc" },
        take: 10,
      }),
    );
    const item = res.json().items[0];
    expect(item.preview).toBe("are you alone tonight?");
    expect(item).toMatchObject({ id: "se-1", app: "whatsapp", contact: "c-1", severity: "critical", concernTypes: ["grooming"] });
    await app.close();
  });

  it("requires a parent JWT for the vault (401 without, 403 for device tokens, 403 cross-family)", async () => {
    const app = await buildApp(socialRoutes, "/v1/social");
    const noAuth = await app.inject({ method: "GET", url: "/v1/social/events?childId=child-1" });
    expect(noAuth.statusCode).toBe(401);

    const device = await app.inject({ method: "GET", url: "/v1/social/events?childId=child-1", headers: deviceHeader(app) });
    expect(device.statusCode).toBe(403);

    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    const foreign = await app.inject({ method: "GET", url: "/v1/social/events?childId=child-1", headers: authHeader(app, "fam-2") });
    expect(foreign.statusCode).toBe(403);
    expect(prismaMock.socialEvent.findMany).not.toHaveBeenCalled();
    await app.close();
  });
});

describe("activity ingest and reports", () => {
  beforeEach(() => {
    resetPrismaMock();
    process.env.VAULT_KEY = VAULT_KEY;
  });

  it("ingests an activity batch with a device JWT (202) and persists via createMany", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-1", childId: "child-1", child: { familyId: "fam-1" } });
    // #841: an unblocked url is kept only with the site-name flag on; with it off this batch would be
    // reduced to the call row, which `site-names.test.ts` asserts separately.
    vi.stubEnv("SITE_NAMES_ENABLED", "true");

    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/activity",
      headers: deviceHeader(app),
      payload: {
        events: [
          { type: "url", payload: { url: "https://example.com" } },
          { ts: "2026-09-16T10:00:00.000Z", type: "call", payload: { number: "+201001234567", direction: "in" } },
        ],
      },
    });
    expect(res.statusCode).toBe(202);
    const data = (prismaMock.activityEvent.createMany.mock.calls[0][0] as { data: Array<Record<string, unknown>> }).data;
    expect(data).toHaveLength(2);
    expect(data[0]).toMatchObject({ childId: "child-1", deviceId: "dev-1", type: "url", payload: { url: "example.com", domain: "example.com", blocked: false } });
    expect(data[0].ts).toBeInstanceOf(Date);
    expect(data[1]).toMatchObject({ type: "call" });
    vi.unstubAllEnvs();
    await app.close();
  });

  it("rejects batches over 500 events and unknown event types (400)", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-1", childId: "child-1", child: { familyId: "fam-1" } });

    const tooMany = Array.from({ length: 501 }, () => ({ type: "url", payload: {} }));
    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/activity",
      headers: deviceHeader(app),
      payload: { events: tooMany },
    });
    expect(res.statusCode).toBe(400);
    expect(prismaMock.activityEvent.createMany).not.toHaveBeenCalled();
    await app.close();
  });

  it("blocks ingest for a device outside the family (403)", async () => {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-1", childId: "child-1", child: { familyId: "fam-2" } });
    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/activity",
      headers: deviceHeader(app, { deviceId: "dev-1", childId: "child-1", familyId: "fam-1" }),
      payload: { events: [{ type: "url", payload: {} }] },
    });
    expect(res.statusCode).toBe(403);
    expect(prismaMock.activityEvent.createMany).not.toHaveBeenCalled();
    await app.close();
  });

  it("lists activity reports filtered by type, scoped to the family, default limit 200", async () => {
    const app = await buildApp(reportsRoutes, "/v1/reports");
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.activityEvent.findMany.mockResolvedValue([{ id: "ae-1", type: "call" }]);

    const res = await app.inject({
      method: "GET",
      url: "/v1/reports/activity?childId=child-1&type=call",
      headers: authHeader(app),
    });
    expect(res.statusCode).toBe(200);
    expect(prismaMock.activityEvent.findMany).toHaveBeenCalledWith(
      expect.objectContaining({
        where: expect.objectContaining({ childId: "child-1", type: "call" }),
        orderBy: { ts: "desc" },
        take: 200,
      }),
    );
    expect(res.json().items).toEqual([{ id: "ae-1", type: "call" }]);
    await app.close();
  });

  it("#830: the activity report accepts type=lock_period", async () => {
    const app = await buildApp(reportsRoutes, "/v1/reports");
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.activityEvent.findMany.mockResolvedValue([{ id: "lp-1", type: "lock_period" }]);

    const res = await app.inject({
      method: "GET",
      url: "/v1/reports/activity?childId=child-1&type=lock_period",
      headers: authHeader(app),
    });
    expect(res.statusCode).toBe(200);
    expect(prismaMock.activityEvent.findMany).toHaveBeenCalledWith(
      expect.objectContaining({ where: expect.objectContaining({ childId: "child-1", type: "lock_period" }) }),
    );
    expect(res.json().items).toEqual([{ id: "lp-1", type: "lock_period" }]);
    await app.close();
  });

  it("passes from/to bounds into the activity report query", async () => {
    const app = await buildApp(reportsRoutes, "/v1/reports");
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    await app.inject({
      method: "GET",
      url: "/v1/reports/activity?childId=child-1&from=2026-09-01T00:00:00.000Z&to=2026-09-16T00:00:00.000Z",
      headers: authHeader(app),
    });
    const arg = prismaMock.activityEvent.findMany.mock.calls[0][0] as { where: { ts: { gte: Date; lte: Date } } };
    expect(arg.where.ts.gte).toBeInstanceOf(Date);
    expect(arg.where.ts.lte).toBeInstanceOf(Date);
    await app.close();
  });

  it("requires a parent JWT for reports (401 without, 403 cross-family)", async () => {
    const app = await buildApp(reportsRoutes, "/v1/reports");
    const noAuth = await app.inject({ method: "GET", url: "/v1/reports/activity?childId=child-1" });
    expect(noAuth.statusCode).toBe(401);

    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    const foreign = await app.inject({ method: "GET", url: "/v1/reports/activity?childId=child-1", headers: authHeader(app, "fam-2") });
    expect(foreign.statusCode).toBe(403);
    expect(prismaMock.activityEvent.findMany).not.toHaveBeenCalled();
    await app.close();
  });
});

describe("rules passthrough: socialMonitoring + contactAllowlist", () => {
  const validRuleSet = {
    screenTime: {
      dailyLimitMinutes: 180,
      weekendLimitMinutes: 300,
      bedtimeStart: "21:00",
      bedtimeEnd: "07:00",
      schoolHours: { start: "08:00", end: "15:00", days: [1, 2, 3, 4, 5] },
    },
    webFilter: { blockedCategories: ["pornography"], allowedDomains: [], blockedDomains: [], safeSearchEnforced: true },
    appRules: [],
    routines: [],
    socialMonitoring: { whatsapp: true, tiktok: false },
    contactAllowlist: ["+15551234567", "+201001234567"],
  };

  const flatRow = {
    id: "rs-1",
    childId: "child-1",
    dailyLimitMinutes: 180,
    weekendLimitMinutes: 300,
    bedtimeStart: "21:00",
    bedtimeEnd: "07:00",
    schoolHoursStart: "08:00",
    schoolHoursEnd: "15:00",
    schoolDays: [1, 2, 3, 4, 5],
    blockedCategories: ["pornography"],
    allowedDomains: [],
    blockedDomains: [],
    safeSearchEnforced: true,
    appRules: [],
    routines: [],
    alwaysAllowedApps: [],
    bonusMinutesToday: 0,
    socialMonitoring: { whatsapp: true, tiktok: false },
    contactAllowlist: ["+15551234567", "+201001234567"],
    updatedAt: "2026-09-16T10:00:00.000Z",
  };

  beforeEach(() => {
    resetPrismaMock();
  });

  it("round-trips socialMonitoring and contactAllowlist through PUT", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.ruleSet.upsert.mockResolvedValue(flatRow);
    prismaMock.device.findMany.mockResolvedValue([]);

    const res = await app.inject({
      method: "PUT",
      url: "/v1/rules/child-1",
      headers: authHeader(app),
      payload: validRuleSet,
    });
    expect(res.statusCode).toBe(200);
    expect(res.json().socialMonitoring).toEqual({ whatsapp: true, tiktok: false });
    expect(res.json().contactAllowlist).toEqual(["+15551234567", "+201001234567"]);
    expect(prismaMock.ruleSet.upsert).toHaveBeenCalledWith(
      expect.objectContaining({
        create: expect.objectContaining({
          socialMonitoring: { whatsapp: true, tiktok: false },
          contactAllowlist: ["+15551234567", "+201001234567"],
        }),
        update: expect.objectContaining({ socialMonitoring: { whatsapp: true, tiktok: false } }),
      }),
    );
    await app.close();
  });

  it("defaults the new fields when a legacy ruleset payload omits them", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.ruleSet.upsert.mockResolvedValue(flatRow);
    prismaMock.device.findMany.mockResolvedValue([]);

    const { socialMonitoring: _sm, contactAllowlist: _ca, ...legacy } = validRuleSet;
    const res = await app.inject({
      method: "PUT",
      url: "/v1/rules/child-1",
      headers: authHeader(app),
      payload: legacy,
    });
    expect(res.statusCode).toBe(200);
    expect(prismaMock.ruleSet.upsert).toHaveBeenCalledWith(
      expect.objectContaining({
        create: expect.objectContaining({ socialMonitoring: {}, contactAllowlist: [] }),
      }),
    );
    await app.close();
  });

  it("deep-merges socialMonitoring and contactAllowlist on PATCH", async () => {
    const app = await buildApp(rulesRoutes, "/v1/rules");
    prismaMock.child.findUnique.mockResolvedValue(CHILD);
    prismaMock.ruleSet.upsert.mockResolvedValue(flatRow);
    prismaMock.device.findMany.mockResolvedValue([]);

    const res = await app.inject({
      method: "PATCH",
      url: "/v1/rules/child-1",
      headers: authHeader(app),
      payload: { socialMonitoring: { discord: true } },
    });
    expect(res.statusCode).toBe(200);
    expect(prismaMock.ruleSet.upsert).toHaveBeenCalledWith(
      expect.objectContaining({
        update: expect.objectContaining({ socialMonitoring: { discord: true } }),
      }),
    );
    await app.close();
  });
});
