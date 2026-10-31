import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { prisma } from "../db.js";
import { raiseAlert } from "../lib/alerts.js";
import { getRedis } from "../redis.js";
import { registerRawBodyParser, authenticateInternalRequest } from "../lib/internalAuth.js";
import { checkActiveConsent } from "../lib/consent.js";
import { requireFamily, requireGuardianRead, requireParent } from "../middleware/requireFamily.js";
import { decryptSnippet, encryptSnippet } from "../lib/snippetVault.js";

const ScanSchema = z.object({
  childId: z.string().min(1),
  deviceId: z.string().optional(),
  app: z.string().min(1),
  contact: z.string().default(""),
  text: z.string().min(1),
  /** Plan 2.6: where the agent captured the text — screen (accessibility) or notification. */
  source: z.enum(["screen", "notification"]).optional(),
});

/**
 * #490: an agent sends a flush as one request of up to [SCAN_BATCH_MAX] items instead of one request per
 * row. Must match the agent's `ScanQueuePolicy.ITEMS_PER_REQUEST`. Items are scanned concurrently, so a
 * batch waits about one [AI_TIMEOUT_MS] on a slow AI engine, not six.
 */
export const SCAN_BATCH_MAX = 6;

const ScanBatchSchema = z.object({ items: z.array(z.unknown()).min(1).max(SCAN_BATCH_MAX) });

const EventsQuerySchema = z.object({
  childId: z.string().min(1),
  app: z.string().optional(),
  severity: z.enum(["info", "warning", "critical"]).optional(),
  limit: z.coerce.number().int().min(1).max(500).default(50),
});

const AI_TIMEOUT_MS = 5000;
const THROTTLE_SECONDS = 600;
const PREVIEW_MAX_CHARS = 240;
const GAMING_APPS = new Set(["discord", "roblox"]);

type Severity = "info" | "warning" | "critical";
interface Verdict { flagged: boolean; severity: Severity; concernTypes: string[] }

// NOTE: fail-open — when the AI engine is unreachable the scan falls back to a local
// keyword/regex check so obvious self-harm language is never silently dropped.
const LOCAL_PATTERNS: Array<{ pattern: RegExp; concern: string }> = [
  { pattern: /\b(kill yourself|kys|suicide|end (your|my) life|want to die|wanna die|self[- ]?harm)\b/i, concern: "self_harm" },
  { pattern: /\b(sext(?:ing)?\b|nudes?\b|send (me )?(pics|pictures|photos)|meet (up|me) (alone|in secret)|don't tell your (parents|mom|dad))\b/i, concern: "grooming" },
  { pattern: /\b(ugly|loser|worthless|nobody likes you|die in a fire|everyone hates you)\b/i, concern: "cyberbullying" },
];

/** Local keyword fallback used only when the AI engine cannot be reached. */
export function localKeywordCheck(text: string): Verdict {
  const concerns = [...new Set(
    LOCAL_PATTERNS.filter((p) => p.pattern.test(text)).map((p) => p.concern),
  )];
  if (concerns.length === 0) return { flagged: false, severity: "info", concernTypes: [] };
  return { flagged: true, severity: concerns.includes("self_harm") ? "critical" : "warning", concernTypes: concerns };
}

/** Normalize the ai-engine /analyze response into a verdict; null when the payload is unusable. */
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

/** Call the AI engine /analyze with a 5 s timeout; null on any failure (caller falls back). */
async function analyzeWithAi(text: string, childAge?: number): Promise<Verdict | null> {
  const base = process.env.AI_ENGINE_URL;
  if (!base) return null;
  try {
    const res = await fetch(`${base.replace(/\/$/, "")}/analyze`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ text, context: "message", ...(childAge !== undefined ? { child_age: childAge } : {}) }),
      signal: AbortSignal.timeout(AI_TIMEOUT_MS),
    });
    if (!res.ok) return null;
    return aiVerdictFrom(await res.json());
  } catch {
    return null;
  }
}

type ScanDevice = { id: string; childId: string } | null | undefined;

/** One item's outcome. `status` and `body` keep the single-item response exactly as it was. */
type ScanItemResult =
  | { ok: true; flagged: boolean; severity: Severity; concernTypes: string[] }
  | { ok: false; reason: string; status: number; body?: Record<string, unknown> };

/**
 * Scans one capture: ownership, consent, the verdict, the vault write and the throttled alert. Shared
 * by the single-item body and each item of a batch (#490), so the checks are identical for both.
 */
async function scanOne(input: unknown, device: ScanDevice): Promise<ScanItemResult> {
  const parsed = ScanSchema.safeParse(input);
  if (!parsed.success) return { ok: false, reason: "invalid_item", status: 400, body: { error: parsed.error.flatten() } };
  const { childId, deviceId, app: appName, contact, text } = parsed.data;

  if (device) {
    if (device.childId !== childId) return { ok: false, reason: "cross_child_forbidden", status: 400 };
    if (deviceId && deviceId !== device.id) return { ok: false, reason: "device_mismatch", status: 400 };
  }

  const child = await prisma.child.findUnique({ where: { id: childId } });
  if (!child) return { ok: false, reason: "child_not_found", status: 404 };
  // ADR-0008 §2b: withdrawal of consent stops collection.
  const consent = await checkActiveConsent(childId);
  if (!consent.active) {
    const reason = consent.reason ?? "parental_consent_required";
    return { ok: false, reason, status: 428, body: { error: reason, childId } };
  }

  const childAge = typeof (child as { birthYear?: number }).birthYear === "number"
    ? new Date().getFullYear() - (child as { birthYear: number }).birthYear
    : undefined;
  const verdict = (await analyzeWithAi(text, childAge)) ?? localKeywordCheck(text);
  if (!verdict.flagged) {
    return { ok: true, flagged: false, severity: "info", concernTypes: [] };
  }

  // The snippet vault always records flagged messages; alerts are throttled separately.
  const previewCipher = encryptSnippet(text.slice(0, PREVIEW_MAX_CHARS));
  await prisma.socialEvent.create({
    data: { childId, app: appName, contact, severity: verdict.severity, previewCipher, concernTypes: verdict.concernTypes },
  });

  // NOTE: at most one alert per app per 10 minutes per child; the vault write above always
  // happens so parents can still review the full snippet history in /v1/social/events.
  const throttleKey = `social:alert:${childId}:${appName.toLowerCase()}`;
  const throttled = await getRedis().set(throttleKey, "1", "EX", THROTTLE_SECONDS, "NX") !== "OK";
  if (!throttled) {
    const category = GAMING_APPS.has(appName.toLowerCase()) ? "gaming_chat" : "social_concern";
    // Alerts never carry the message snippet — metadata is app/contact/concernTypes only;
    // the decrypted preview stays exclusively in the encrypted vault (#24).
    await raiseAlert({
      childId,
      familyId: child.familyId,
      deviceId,
      severity: verdict.severity,
      category,
      title: `Social concern in ${appName}`,
      body: `${contact || "A contact"} sent a flagged message on ${appName}`,
      metadata: { app: appName, contact, concernTypes: verdict.concernTypes },
      childName: child.displayName,
    });
  }
  return { ok: true, flagged: true, severity: verdict.severity, concernTypes: verdict.concernTypes };
}

export async function socialRoutes(app: FastifyInstance) {
  registerRawBodyParser(app);

  /** HMAC-signed social message scan from child agents (Accessibility/social capture). */
  app.post("/scan", async (req, reply) => {
    const rawBody = (req as { rawBody?: string }).rawBody;
    const auth = await authenticateInternalRequest(
      rawBody,
      req.headers["x-familyshield-signature"],
      req.headers as Record<string, string | string[] | undefined>,
    );
    if (!auth.valid) {
      return reply.code(401).send({ error: "invalid_signature", reason: auth.reason });
    }
    // #490: `{ items: [...] }` is a batch, answered item by item so one bad item doesn't drop the
    // rest. Anything else is the single-item body older agents send, answered exactly as before.
    const raw = req.body as { items?: unknown } | null;
    if (raw && typeof raw === "object" && "items" in raw) {
      const batch = ScanBatchSchema.safeParse(raw);
      if (!batch.success) return reply.code(400).send({ error: batch.error.flatten() });
      // Concurrently (#498 review): each item may wait AI_TIMEOUT_MS on the AI engine, and six in a row
      // reach the agent's 30 s read timeout, so a slow engine would fail a batch the server had already
      // stored, and the retry would store it twice. `Promise.all` keeps the order, and the alert
      // throttle is an atomic SET NX, so same-app items still raise at most one alert.
      const scanned = await Promise.all(batch.data.items.map((item) => scanOne(item, auth.device)));
      // A failed item carries its reason only; status codes belong to the single-item body.
      const results = scanned.map((r) => (r.ok ? r : { ok: false, reason: r.reason }));
      return { results };
    }
    const single = await scanOne(req.body, auth.device);
    if (!single.ok) {
      return reply.code(single.status).send(single.body ?? { error: single.reason });
    }
    return { flagged: single.flagged, severity: single.severity, concernTypes: single.concernTypes };
  });

  /**
   * Parent-facing vault listing: SocialEvents decrypted server-side, newest first.
   * NOTE (#24, trust copy — no code): the parent app must show transparency copy next to this
   * vault, e.g. "Message previews are encrypted at rest and only visible to parents" — the
   * vault exists to protect the child, and parents must know exactly who can read it.
   */
  app.get("/events", { preHandler: [requireParent, requireGuardianRead("social"), requireFamily({ param: "childId", model: "child", source: "query" })] }, async (req, reply) => {
    const parsed = EventsQuerySchema.safeParse(req.query ?? {});
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });
    const q = parsed.data;
    const rows = await prisma.socialEvent.findMany({
      where: {
        childId: q.childId,
        ...(q.app ? { app: q.app } : {}),
        ...(q.severity ? { severity: q.severity } : {}),
      },
      orderBy: { createdAt: "desc" },
      take: q.limit,
    });
    const items = rows.map((row) => ({
      id: row.id,
      app: row.app,
      contact: row.contact,
      severity: row.severity,
      preview: decryptSnippet(row.previewCipher),
      concernTypes: row.concernTypes,
      createdAt: row.createdAt,
    }));
    return { items };
  });
}
