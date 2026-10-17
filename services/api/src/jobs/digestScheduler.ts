import { prisma } from "../db.js";
import { summarizeChildActivity } from "../lib/activitySummary.js";
import { appPublicUrl, getEmailSender } from "../lib/email/index.js";
import { digestEmail, type DigestChild } from "../lib/email/templates.js";
import {
  digestHour,
  digestPeriod,
  digestsDueAt,
  localParts,
  type DigestKind,
} from "../lib/digestSchedule.js";

/**
 * Daily/weekly digest delivery at the **family's local hour** (ADR-0017).
 *
 * The scheduler wakes every 15 minutes and, for each family with a digest enabled, asks
 * `digestSchedule.digestsDueAt` whether that family's local clock is at or past `DIGEST_HOUR` (default
 * 18:00 local). A due send is claimed by inserting a `DigestSend(familyId, kind, period)` row: the
 * unique key is what makes a restart, two API instances or a DST-repeated hour send exactly once, and
 * the row is written *before* the email so a crash cannot double-send. `JOBS_ENABLED=0` still turns the
 * internal timer off for deployments that drive `runDigestsDue()` from an external cron.
 */

const TICK_MS = 15 * 60_000;

export type { DigestKind };

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

/**
 * Send one digest for one family now. Exported for `/send-now` and for external cron use.
 * `period` is the idempotency period (local date or ISO week) when the caller already computed it.
 */
export async function sendFamilyDigest(
  familyId: string,
  kind: DigestKind,
  period?: string,
): Promise<{ sent: boolean; to: string[]; reason?: string }> {
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
  message.idempotencyKey = `digest:${familyId}:${kind}:${period ?? new Date().toISOString().slice(0, 10)}`;
  const result = await getEmailSender().send(message);
  return result.ok ? { sent: true, to } : { sent: false, to, reason: result.reason };
}

/** True when a Prisma error is the `(familyId, kind, period)` unique-key conflict. */
function isDuplicateClaim(err: unknown): boolean {
  return typeof err === "object" && err !== null && (err as { code?: string }).code === "P2002";
}

/** One scheduler pass: find families whose local clock is due, claim the period, send. */
export async function runDigestsDue(now = new Date()): Promise<{ attempted: number; sent: number }> {
  const hour = digestHour();
  const prefs = await prisma.digestPrefs.findMany({
    where: { OR: [{ dailyEmail: true }, { weeklyEmail: true }] },
  });
  if (prefs.length === 0) return { attempted: 0, sent: 0 };

  const families = await prisma.family.findMany({
    where: { id: { in: prefs.map((p) => p.familyId) } },
    select: { id: true, timezone: true },
  });
  const zoneOf = new Map(families.map((f) => [f.id, f.timezone || "UTC"]));

  let attempted = 0;
  let sent = 0;
  for (const pref of prefs) {
    const timeZone = zoneOf.get(pref.familyId) ?? "UTC";
    const due = digestsDueAt(now, timeZone, hour).filter((kind) =>
      kind === "daily" ? pref.dailyEmail : pref.weeklyEmail,
    );
    if (due.length === 0) continue;
    for (const kind of due) {
      const period = digestPeriod(kind, localParts(now, timeZone));
      try {
        await prisma.digestSend.create({ data: { familyId: pref.familyId, kind, period } });
      } catch (err) {
        if (isDuplicateClaim(err)) continue; // already sent this period
        console.error(`[digest] family=${pref.familyId} kind=${kind} claim failed`, err);
        continue;
      }
      attempted += 1;
      try {
        const r = await sendFamilyDigest(pref.familyId, kind, period);
        if (r.sent) sent += 1;
        else {
          // The provider refused: give the next tick a chance instead of losing the period.
          await prisma.digestSend
            .delete({ where: { familyId_kind_period: { familyId: pref.familyId, kind, period } } })
            .catch(() => undefined);
          console.warn(`[digest] family=${pref.familyId} kind=${kind} not sent: ${r.reason}`);
        }
      } catch (err) {
        console.error(`[digest] family=${pref.familyId} kind=${kind} failed`, err);
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
  console.log(`[digest] scheduler started (local hour=${digestHour(env)}:00 per family's timezone, tick=${TICK_MS / 60000}m)`);
}

export function stopDigestScheduler(): void {
  if (timer) clearInterval(timer);
  timer = null;
}
