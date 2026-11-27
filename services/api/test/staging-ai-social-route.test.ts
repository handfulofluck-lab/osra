import { randomBytes } from "node:crypto";
import { Writable } from "node:stream";
import Fastify, { type FastifyInstance } from "fastify";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { signV2 } from "../src/lib/internalAuth.js";
import { assertStagingAiScope } from "../src/lib/stagingQaModel.js";
import { socialRoutes } from "../src/routes/social.js";
import { prismaMock, resetPrismaMock } from "./helpers.js";

const reserve = vi.hoisted(() => vi.fn());
vi.mock("../src/lib/stagingAiQuota.js", () => ({ reserveStagingAiCall: reserve }));
vi.mock("../src/db.js", async () => ({ prisma: (await import("./helpers.js")).prismaMock }));
vi.mock("ioredis", async () => ({ Redis: (await import("./helpers.js")).MockRedis }));

const pairs = ["a", "b", "c", "d"].map((name, i) => ({
  id: `fixture-device-${name}`,
  childId: `fixture-child-${name}`,
  familyId: i < 2 ? "fixture-family-one" : "fixture-family-two",
  internalSecret: randomBytes(32).toString("hex"),
}));

const safeFixture = "A synthetic sample about tomorrow's picnic.";
const ruleFixture = "Synthetic cap fixture: you are a loser.";
const scores = {
  cyberbullying: 0, self_harm: 0, grooming: 0, violence: 0, sexual_content: 0,
  substance_use: 0, hate_speech: 0,
};

describe("staging own-model scoring for opted-in pairings", () => {
  let app: FastifyInstance;
  let logs: string[];
  let receiptRegion: string;
  let monitoring: unknown;
  let familyRegion: string | undefined;
  let analyze: ReturnType<typeof vi.fn>;

  beforeEach(async () => {
    resetPrismaMock();
    reserve.mockReset().mockResolvedValue({ allowed: true });
    logs = [];
    receiptRegion = "eu-north-1";
    monitoring = { whatsapp: true };
    familyRegion = "US";
    vi.stubEnv("OSRA_DEPLOYMENT_SCOPE", "staging");
    vi.stubEnv("OSRA_STAGING_AI_ALL_CHILDREN", "1");
    vi.stubEnv("OSRA_STAGING_QA_ANALYZER_ENABLED", "1");
    vi.stubEnv("OSRA_STAGING_QA_ENGINE", "own");
    vi.stubEnv("OSRA_OWN_MODEL_REGION", "eu-north-1");
    vi.stubEnv("AWS_REGION", "eu-north-1");
    vi.stubEnv("OSRA_STAGING_QA_ANALYZER_URL", "http://analyzer.qa.internal:8000");
    vi.stubEnv("AI_ENGINE_URL", "http://legacy-analyzer.invalid");
    vi.stubEnv("VAULT_KEY", Buffer.alloc(32, 7).toString("base64"));
    prismaMock.device.findUnique.mockImplementation(async ({ where }) =>
      pairs.find((device) => device.id === where.id) ?? null);
    prismaMock.child.findUnique.mockImplementation(async ({ where }) => {
      const paired = pairs.find((device) => device.childId === where.id);
      if (!paired) return null;
      return { id: paired.childId, familyId: paired.familyId, family: { region: familyRegion, timezone: "UTC" },
        ruleSet: { socialMonitoring: monitoring } };
    });
    prismaMock.socialEvent.create.mockResolvedValue({ id: "fixture-social-event" });
    analyze = vi.fn(async (_url: URL, options: RequestInit) => {
      const request = JSON.parse(String(options.body));
      return { ok: true, json: async () => ({
        trace_id: request.trace_id, region: receiptRegion, mode: "own",
        outcomes: { own: { status: "scored", model: "v9", flagged: false, severity: "info",
          categories: scores, flagged_categories: [] } },
      }) };
    });
    vi.stubGlobal("fetch", analyze);
    const stream = new Writable({
      write(chunk, _encoding, next) { logs.push(String(chunk)); next(); },
    });
    // info, so the staging QA proof line (#1227 score receipt) is visible to the receipt controls below.
    app = Fastify({ logger: { level: "info", stream } });
    await app.register(socialRoutes, { prefix: "/v1/social" });
    await app.ready();
  });

  afterEach(async () => {
    await app?.close();
    vi.unstubAllEnvs();
    vi.unstubAllGlobals();
  });

  function scan(pair = pairs[0], text = safeFixture) {
    const body = JSON.stringify({
      deviceId: pair.id, childId: pair.childId, app: "whatsapp", source: "notification", text,
    });
    return app.inject({ method: "POST", url: "/v1/social/scan",
      headers: { "content-type": "application/json", ...signV2(pair.internalSecret, body) }, payload: body });
  }

  it("scores two independently paired children from each of two families", async () => {
    const results = await Promise.all(pairs.map((pair) => scan(pair)));
    for (const res of results) {
      expect(res.statusCode).toBe(200);
      expect(res.json()).toMatchObject({ flagged: false });
    }
    expect(analyze).toHaveBeenCalledTimes(4);
    expect(reserve.mock.calls.map(([id]) => id).sort()).toEqual(pairs.map(({ familyId }) => familyId).sort());
    for (const [url, options] of analyze.mock.calls) {
      expect(url.pathname).toBe("/analyze/staging-qa");
      expect(options.redirect).toBe("error");
      expect(JSON.parse(options.body)).toMatchObject({ include_provider_outcomes: true, consented_staging: true });
    }
    expect(prismaMock.stagingScanOutcome.create).toHaveBeenCalledTimes(4);
    expect(prismaMock.alert.create).not.toHaveBeenCalled();
  });

  it("requires active, jurisdiction-matched consent before quota or inference", async () => {
    familyRegion = "FR";
    const mismatch = await scan();
    expect(mismatch.statusCode).toBe(428);
    expect(mismatch.json().error).toBe("consent_jurisdiction_mismatch");
    prismaMock.consentRecord.findFirst.mockResolvedValue(null);
    const missing = await scan();
    expect(missing.statusCode).toBe(428);
    expect(missing.json().error).toBe("parental_consent_required");
    expect(reserve).not.toHaveBeenCalled();
    expect(analyze).not.toHaveBeenCalled();
  });

  it.each([false, undefined, "true"])("does not reserve a slot with app setting %j", async (setting) => {
    monitoring = { whatsapp: setting };
    expect((await scan()).statusCode).toBe(200);
    expect(reserve).not.toHaveBeenCalled();
    expect(analyze).not.toHaveBeenCalled();
  });

  it("uses local rules with no broad flag or no known family jurisdiction", async () => {
    familyRegion = undefined;
    expect((await scan()).statusCode).toBe(200);
    vi.stubEnv("OSRA_STAGING_AI_ALL_CHILDREN", undefined);
    expect((await scan()).statusCode).toBe(200);
    expect(reserve).not.toHaveBeenCalled();
    expect(analyze).not.toHaveBeenCalled();
  });

  it("refuses the broad flag outside staging and does not call the default analyzer", async () => {
    vi.stubEnv("OSRA_DEPLOYMENT_SCOPE", "production");
    expect(() => assertStagingAiScope()).toThrow("requires staging");
    expect((await scan()).statusCode).toBe(200);
    expect(reserve).not.toHaveBeenCalled();
    expect(analyze).not.toHaveBeenCalled();
  });

  it.each(["family", "global", "unavailable"])("falls back to local rules at a %s quota refusal", async (reason) => {
    reserve.mockResolvedValueOnce({
      allowed: false, reason, log: reason !== "unavailable", familyCount: 250, globalCount: 2000,
    }).mockResolvedValueOnce({ allowed: false, reason, log: false });
    for (let i = 0; i < 2; i++) {
      const result = await scan(pairs[0], ruleFixture);
      expect(result.statusCode).toBe(200);
      expect(result.json()).toMatchObject({ flagged: true, concernTypes: ["cyberbullying"] });
    }
    expect(analyze).not.toHaveBeenCalled();
    const records = logs.map((line) => JSON.parse(line))
      .filter(({ msg }) => msg === "staging social AI daily cap reached");
    expect(records).toHaveLength(reason === "unavailable" ? 0 : 1);
    if (records.length > 0) expect(records[0]).toMatchObject({ reason, familyCount: 250, globalCount: 2000 });
    expect(logs.join("")).not.toContain(ruleFixture);
    expect(logs.join("")).not.toContain(pairs[0].familyId);
  });

  it("discards an own-model receipt outside Stockholm", async () => {
    receiptRegion = "eu-central-1";
    expect((await scan()).statusCode).toBe(200);
    expect(prismaMock.stagingScanOutcome.create).toHaveBeenCalledWith({
      data: expect.objectContaining({ providers: { own: { status: "unavailable", reason: "unavailable" } } }),
    });
  });

  function ownLogs(): Array<Record<string, unknown>> {
    return logs.flatMap((line) => line.split(/\r?\n/)).filter(Boolean).map((line) => JSON.parse(line))
      .filter((entry) => typeof entry.msg === "string" && entry.msg.startsWith("staging QA scan resolved"));
  }

  function respondWith(extra: { trace?: string; own: Record<string, unknown> }) {
    analyze.mockImplementationOnce(async (_url: URL, options: RequestInit) => {
      const request = JSON.parse(String(options.body));
      return { ok: true, json: async () => ({
        trace_id: extra.trace ?? request.trace_id, region: "eu-north-1", mode: "own", outcomes: { own: extra.own },
      }) };
    });
  }

  it("#1227: a quiet scan logs the validated own score and language, never the text", async () => {
    respondWith({ own: { status: "scored", model: "v9", flagged: false, severity: "info", flagged_categories: [],
      categories: { ...scores, cyberbullying: 0.41234, violence: 0.2 }, language: "en" } });
    expect((await scan()).statusCode).toBe(200);
    const [entry] = ownLogs();
    expect(entry?.own).toEqual({ modelVersion: "v9", lang: "en", topCategory: "cyberbullying", topScore: 0.4123 });
    expect(logs.join("")).not.toContain(safeFixture);
  });

  it("#1227: a mismatched trace logs no own score beside its unavailable verdict", async () => {
    respondWith({ trace: "someone-elses-trace", own: { status: "scored", model: "v9", flagged: false, severity: "info",
      flagged_categories: [], categories: { ...scores, cyberbullying: 0.9 }, language: "en" } });
    expect((await scan()).statusCode).toBe(200);
    expect(prismaMock.stagingScanOutcome.create).toHaveBeenCalledWith({
      data: expect.objectContaining({ providers: { own: { status: "unavailable", reason: "unavailable" } } }),
    });
    // Codex (#1227 point 2): the proof line must exist, so the omission check below cannot pass vacuously.
    const proof = ownLogs();
    expect(proof.length).toBeGreaterThan(0);
    for (const entry of proof) expect(entry).not.toHaveProperty("own");
  });
});
