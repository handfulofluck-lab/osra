import { prisma } from "../db.js";
import { getRedis } from "../redis.js";
import { summarizeChildActivity } from "../lib/activitySummary.js";
import { appPublicUrl, getEmailSender } from "../lib/email/index.js";
import { digestEmail, type DigestChild } from "../lib/email/templates.js";

/**
 * Daily/weekly digest delivery (Phase 2a). Replaces the "production cron job" that the digest
 * route referred to but which did not exist.
 *
 * Schedule: a daily digest at `DIGEST_HOUR_UTC` (default 18:00 UTC) for families with
 * `dailyEmail`, and a weekly one on Sunday at the same hour for `weeklyEmail`. The scheduler
 * ticks every 15 minutes and claims each (family, kind, date) once through a Redis `SET NX`, so
 * several API instances can run it without double-sending. `JOBS_ENABLED=0` turns it off for
 * deployments that drive `runDigestsDue()` from an external cron instead.
 */

const TICK_MS = 15 * 60_000;
const CLAIM_TTL_SECONDS = 36 * 3600;

export type DigestKind = "daily" | "weekly";

export function digestHourUtc(env: NodeJS.ProcessEnv = process.env): number {
  const h = Number(env.DIGEST_HOUR_UTC ?? 18);
  return Number.isInteger(h) && h >= 0 && h <= 23 ? h : 18;
}

/** Which digests are due at `now`: none outside the send hour; daily every day; weekly on Sunday. */
export function digestsDueAt(now: Date, hourUtc: number): DigestKind[] {
  if (now.getUTCHours() !== hourUtc) return [];
  return now.getUTCDay() === 0 ? ["daily", "weekly"] : ["daily"];
}

async function buildChildren(familyId: string, days: number): Promise<DigestChild[]> {
  const children = await prisma.child.findMany({ where: { familyId } });
  const out: DigestChild[] = [];
  for (const child of children) {
    const s = await summarizeChildActivity(child.id, days);
    out.push({
      displayName: child.displayName,
      totalAppMinutes: s.totalAppMinutes,
      topApps: s.topApps,
      urlVisits: s.urlVisits,
      topBlockedDomains: s.topBlockedDomains,
      socialConcerns: s.socialConcerns,
      calls: s.calls,
      sms: s.sms,
    });
  }
  return out;
}

/** Send one digest for one family now. Exported for `/send-now` and for external cron use. */
export async function sendFamilyDigest(familyId: string, kind: DigestKind): Promise<{ sent: boolean; to: string[]; reason?: string }> {
  const [family, prefs, parents] = await Promise.all([
    prisma.family.findUnique({ where: { id: familyId } }),
    prisma.digestPrefs.findUnique({ where: { familyId } }),
    prisma.parent.findMany({ where: { familyId }, select: { email: true } }),
  ]);
  if (!family) return { sent: false, to: [], reason: "family_not_found" };
  const to = prefs?.emails?.length ? prefs.emails : parents.map((p) => p.email);
  if (to.length === 0) return { sent: false, to, reason: "no_recipients" };
  const days = kind === "daily" ? 1 : 7;
  const children = await buildChildren(familyId, days);
  const message = digestEmail(to, { familyName: family.name, days, children, link: `${appPublicUrl()}/dashboard` });
  message.idempotencyKey = `digest:${familyId}:${kind}:${new Date().toISOString().slice(0, 10)}`;
  const result = await getEmailSender().send(message);
  return result.ok ? { sent: true, to } : { sent: false, to, reason: result.reason };
}

/** One scheduler pass: find families whose digest is due and not yet claimed today, send them. */
export async function runDigestsDue(now = new Date()): Promise<{ attempted: number; sent: number }> {
  const due = digestsDueAt(now, digestHourUtc());
  if (due.length === 0) return { attempted: 0, sent: 0 };
  const day = now.toISOString().slice(0, 10);
  const redis = getRedis();
  let attempted = 0;
  let sent = 0;
  for (const kind of due) {
    const families = await prisma.digestPrefs.findMany({ where: kind === "daily" ? { dailyEmail: true } : { weeklyEmail: true } });
    for (const prefs of families) {
      const claimed = (await redis.set(`digest:claim:${prefs.familyId}:${kind}:${day}`, "1", "EX", CLAIM_TTL_SECONDS, "NX")) === "OK";
      if (!claimed) continue;
      attempted += 1;
      try {
        const r = await sendFamilyDigest(prefs.familyId, kind);
        if (r.sent) sent += 1;
        else console.warn(`[digest] family=${prefs.familyId} kind=${kind} not sent: ${r.reason}`);
      } catch (err) {
        console.error(`[digest] family=${prefs.familyId} kind=${kind} failed`, err);
      }
    }
  }
  return { attempted, sent };
}

let timer: NodeJS.Timeout | null = null;

export function startDigestScheduler(env: NodeJS.ProcessEnv = process.env): void {
  if (env.JOBS_ENABLED === "0" || env.NODE_ENV === "test") return;
  if (timer) return;
  const tick = () => runDigestsDue().catch((err) => console.error("[digest] tick failed", err));
  timer = setInterval(tick, TICK_MS);
  timer.unref();
  console.log(`[digest] scheduler started (hour=${digestHourUtc(env)}:00 UTC, tick=${TICK_MS / 60000}m)`);
}

export function stopDigestScheduler(): void {
  if (timer) clearInterval(timer);
  timer = null;
}
