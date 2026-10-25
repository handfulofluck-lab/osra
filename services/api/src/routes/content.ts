import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { prisma } from "../db.js";
import { raiseAlert } from "../lib/alerts.js";
import { getRedis } from "../redis.js";
import { registerRawBodyParser, authenticateInternalRequest } from "../lib/internalAuth.js";
import { assertProcessingAllowed } from "../lib/consent.js";
import { requireFamily, requireParent } from "../middleware/requireFamily.js";
import { decryptSnippet, encryptSnippet } from "../lib/snippetVault.js";

const SearchEventSchema = z.object({
  childId: z.string().min(1),
  deviceId: z.string().optional(),
  engine: z.string().min(1),
  query: z.string().min(1),
  url: z.string().optional(),
  timestamp: z.string().optional(),
});

const YouTubeWatchSchema = z.object({
  childId: z.string().min(1),
  deviceId: z.string().optional(),
  videoId: z.string().min(1),
  title: z.string().min(1),
  channel: z.string().default(""),
  timestamp: z.string().optional(),
});

const SearchHistoryQuerySchema = z.object({
  childId: z.string().min(1),
  limit: z.coerce.number().int().min(1).max(200).default(50),
});

const AI_TIMEOUT_MS = 5000;
const THROTTLE_SECONDS = 300;
const PREVIEW_MAX_CHARS = 240;

type Severity = "info" | "warning" | "critical";
interface Verdict { flagged: boolean; severity: Severity; concernTypes: string[] }

const SEARCH_LOCAL_PATTERNS: Array<{ pattern: RegExp; concern: string }> = [
  { pattern: /\b((how (to|can I|do I)|ways to|want to)\s+(kill myself|commit suicide|end my life)|suicide methods|painless (ways to die|death|suicide)|ways to die|kill myself)\b/i, concern: "self_harm" },
  { pattern: /\b(buy (guns?|glock|ammo|drugs|weed|fentanyl)|how to make a bomb|pipe bomb)\b/i, concern: "substance_abuse" },
  { pattern: /\b(free porn|hentai|xxx|sex video|nude pics)\b/i, concern: "adult_content" },
  { pattern: /\b(how to hack|ddos tool|dox someone)\b/i, concern: "cyberbullying" },
];

export function localSearchCheck(query: string): Verdict {
  const concerns = [...new Set(
    SEARCH_LOCAL_PATTERNS.filter((p) => p.pattern.test(query)).map((p) => p.concern),
  )];
  if (concerns.length === 0) return { flagged: false, severity: "info", concernTypes: [] };
  const severity = concerns.includes("self_harm") ? "critical" : "warning";
  return { flagged: true, severity, concernTypes: concerns };
}

function aiVerdictFrom(data: unknown): Verdict | null {
  const d = data as { flagged?: unknown; severity?: unknown; categories?: unknown } | null;
  if (!d || typeof d.flagged !== "boolean") return null;
  const severity: Severity = d.severity === "info" || d.severity === "warning" || d.severity === "critical"
    ? d.severity
    : "warning";
  const categories = (d.categories ?? {}) as Record<string, unknown>;
  const concernTypes = Object.entries(categories)
    .filter(([k, v]) => k !== "safe" && typeof v === "number" && v >= 0.5)
    .sort((a, b) => Number(b[1]) - Number(a[1]))
    .slice(0, 3)
    .map(([k]) => k);
  if (d.flagged && concernTypes.length === 0) concernTypes.push("ai_concern");
  return { flagged: d.flagged, severity, concernTypes };
}

async function analyzeContentWithAi(text: string, context: "search" | "web" = "search", childAge?: number): Promise<Verdict | null> {
  const base = process.env.AI_ENGINE_URL;
  if (!base) return null;
  try {
    const res = await fetch(`${base.replace(/\/$/, "")}/analyze`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ text, context, ...(childAge !== undefined ? { child_age: childAge } : {}) }),
      signal: AbortSignal.timeout(AI_TIMEOUT_MS),
    });
    if (!res.ok) return null;
    return aiVerdictFrom(await res.json());
  } catch {
    return null;
  }
}

export async function contentRoutes(app: FastifyInstance) {
  registerRawBodyParser(app);

  /** Ingest and analyze a search query from web/video search engines (Track 1). */
  app.post("/search-event", async (req, reply) => {
    const rawBody = (req as { rawBody?: string }).rawBody;
    const auth = await authenticateInternalRequest(
      rawBody,
      req.headers["x-familyshield-signature"],
      req.headers as Record<string, string | string[] | undefined>,
    );
    if (!auth.valid) {
      return reply.code(401).send({ error: "invalid_signature", reason: auth.reason });
    }

    const parsed = SearchEventSchema.safeParse(req.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    const { childId, deviceId, engine, query, url } = parsed.data;

    if (auth.device) {
      if (auth.device.childId && auth.device.childId !== childId) {
        return reply.code(400).send({ error: "cross_child_content_forbidden" });
      }
      if (deviceId && deviceId !== auth.device.id) {
        return reply.code(400).send({ error: "device_mismatch" });
      }
    }

    const child = await prisma.child.findUnique({
      where: { id: childId },
      select: { id: true, familyId: true, birthYear: true, displayName: true },
    });
    if (!child) return reply.code(404).send({ error: "child_not_found" });
    // ADR-0008 §2b: withdrawal of consent stops collection.
    if (!(await assertProcessingAllowed(childId, reply))) return;

    const childAge = child.birthYear
      ? new Date().getFullYear() - child.birthYear
      : undefined;

    const verdict = (await analyzeContentWithAi(query, "search", childAge)) ?? localSearchCheck(query);
    if (!verdict.flagged) {
      return reply.code(200).send({ flagged: false, severity: "info" as Severity, concernTypes: [] });
    }

    // Encrypt flagged query in snippet vault
    const appKey = `search:${engine.toLowerCase()}`;
    const previewCipher = encryptSnippet(query.slice(0, PREVIEW_MAX_CHARS));
    await prisma.socialEvent.create({
      data: {
        childId,
        app: appKey,
        contact: engine,
        severity: verdict.severity,
        previewCipher,
        concernTypes: verdict.concernTypes,
      },
    });

    // Alert rate-throttling per child and engine
    const throttleKey = `content:search-alert:${childId}:${engine.toLowerCase()}`;
    const throttled = (await getRedis().set(throttleKey, "1", "EX", THROTTLE_SECONDS, "NX")) !== "OK";
    let alertId: string | undefined;

    const effectiveDeviceId = deviceId ?? auth.device?.id;

    if (!throttled) {
      const alert = await raiseAlert({
        childId,
        familyId: child.familyId,
        deviceId: effectiveDeviceId,
        severity: verdict.severity,
        category: verdict.concernTypes.includes("self_harm") ? "self_harm" : "ai_concern",
        title: `Search query concern on ${engine}`,
        body: `A concerning search was conducted on ${engine}`,
        metadata: { engine, concernTypes: verdict.concernTypes, url },
        childName: child.displayName,
      });
      alertId = alert.id;
    }

    return reply.code(201).send({
      flagged: true,
      severity: verdict.severity,
      concernTypes: verdict.concernTypes,
      alertId,
    });
  });

  /** Ingest and analyze YouTube watch events (Track 1). */
  app.post("/youtube-watch", async (req, reply) => {
    const rawBody = (req as { rawBody?: string }).rawBody;
    const auth = await authenticateInternalRequest(
      rawBody,
      req.headers["x-familyshield-signature"],
      req.headers as Record<string, string | string[] | undefined>,
    );
    if (!auth.valid) {
      return reply.code(401).send({ error: "invalid_signature", reason: auth.reason });
    }

    const parsed = YouTubeWatchSchema.safeParse(req.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: parsed.error.flatten() });
    }

    const { childId, deviceId, videoId, title, channel } = parsed.data;

    if (auth.device) {
      if (auth.device.childId && auth.device.childId !== childId) {
        return reply.code(400).send({ error: "cross_child_content_forbidden" });
      }
      if (deviceId && deviceId !== auth.device.id) {
        return reply.code(400).send({ error: "device_mismatch" });
      }
    }

    const child = await prisma.child.findUnique({
      where: { id: childId },
      select: { id: true, familyId: true, birthYear: true, displayName: true },
    });
    if (!child) return reply.code(404).send({ error: "child_not_found" });
    // ADR-0008 §2b: withdrawal of consent stops collection.
    if (!(await assertProcessingAllowed(childId, reply))) return;

    const verdict = (await analyzeContentWithAi(title, "web")) ?? localSearchCheck(title);
    if (!verdict.flagged) {
      return reply.code(200).send({ flagged: false, severity: "info" as Severity, concernTypes: [] });
    }

    const previewCipher = encryptSnippet(`[YouTube] ${title} (Channel: ${channel})`.slice(0, PREVIEW_MAX_CHARS));
    await prisma.socialEvent.create({
      data: {
        childId,
        app: "youtube",
        contact: channel,
        severity: verdict.severity,
        previewCipher,
        concernTypes: verdict.concernTypes,
      },
    });

    const effectiveDeviceId = deviceId ?? auth.device?.id;

    const alert = await raiseAlert({
      childId,
      familyId: child.familyId,
      deviceId: effectiveDeviceId,
      severity: verdict.severity,
      category: "ai_concern",
      title: `YouTube video flagged: ${title.slice(0, 40)}`,
      body: `A video with sensitive content was opened on YouTube (${channel})`,
      metadata: { videoId, channel, concernTypes: verdict.concernTypes },
      childName: child.displayName,
    });

    return reply.code(201).send({
      flagged: true,
      severity: verdict.severity,
      concernTypes: verdict.concernTypes,
      alertId: alert.id,
    });
  });

  /** Parent-facing flagged search queries listing (Track 1 & 2). */
  app.get(
    "/searches",
    { preHandler: [requireParent, requireFamily({ param: "childId", model: "child", source: "query" })] },
    async (req, reply) => {
      const parsed = SearchHistoryQuerySchema.safeParse(req.query ?? {});
      if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
      const q = parsed.data;

      const rows = await prisma.socialEvent.findMany({
        where: {
          childId: q.childId,
          app: { startsWith: "search:" },
        },
        orderBy: { createdAt: "desc" },
        take: q.limit,
      });

      const items = rows.map((row) => ({
        id: row.id,
        engine: row.app.replace(/^search:/, ""),
        query: decryptSnippet(row.previewCipher),
        severity: row.severity,
        concernTypes: row.concernTypes,
        createdAt: row.createdAt,
      }));

      return { items };
    },
  );
}
