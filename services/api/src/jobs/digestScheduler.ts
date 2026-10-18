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
 * Daily/weekly digest delivery at the **family's local hour** (ADR-0017, amended by ADR-0024).
 *
 * The scheduler wakes every 15 minutes and, for each family with a digest enabled, asks
 * `digestSchedule.digestsDueAt` whether that family's local clock is at or past `DIGEST_HOUR` (default
 * 18:00 local). A due send is claimed by inserting a `DigestSend(familyId, kind, period)` row: the
 * unique key is what makes a restart, two API instances or a DST-repeated hour send exactly once, and
 * the row is written *before* the email so a crash cannot double-send.
 *
 * The claim outlives a failure only when a retry cannot help (F1/F2 of the #93 review):
 * - a **transient** failure — the provider refused with `retryable: true`, or `send` threw — releases
 *   the claim (delete), so the next tick retries inside the same period. A throw is unclassified by
 *   definition and is treated as transient: losing the day is worse than one more attempt.
 * - a **permanent** failure — the provider refused with `retryable: false`, e.g. an address it will
 *   never accept — keeps the row and writes `failedReason`, which is terminal for that period: every
 *   later tick hits the unique key and moves on, and the row says why the family got nothing.
 * `JOBS_ENABLED=0` still turns the internal timer off for deployments that drive `runDigestsDue()`
 * from an external cron.
 */

const TICK_MS = 15 * 60_000;

export type { DigestKind };

export interface DigestDelivery {
  sent: boolean;
  to: string[];
  reason?: string;
  /** Only meaningful when `sent` is false: may the next tick succeed? */
  retryable?: boolean;
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

/**
 * Send one digest for one family now. Exported for `/send-now` and for external cron use.
 * `period` is the idempotency period (local date or ISO week) when the caller already computed it.
 */
export async function sendFamilyDigest(
  familyId: string,
  kind: DigestKind,
  period?: string,
): Promise<DigestDelivery> {
  const [family, prefs, parents] = await Promise.all([
    prisma.family.findUnique({ where: { id: familyId } }),
    prisma.digestPrefs.findUnique({ where: { familyId } }),
    prisma.parent.findMany({ where: { familyId }, select: { email: true } }),
  ]);
  // A row that no longer exists will not come back: terminal.
  if (!family) return { sent: false, to: [], reason: "family_not_found", retryable: false };
  const to = prefs?.emails?.length ? prefs.emails : parents.map((p) => p.email);
  // Cheap and local: a parent can add a recipient before the period ends.
  if (to.length === 0) return { sent: false, to, reason: "no_recipients", retryable: true };
  const days = kind === "daily" ? 1 : 7;
  const children = await buildChildren(familyId, days);
  const message = digestEmail(to, { familyName: family.name, days, children, link: `${appPublicUrl()}/dashboard` });
  message.idempotencyKey = `digest:${familyId}:${kind}:${period ?? new Date().toISOString().slice(0, 10)}`;
  const result = await getEmailSender().send(message);
  return result.ok
    ? { sent: true, to }
    : { sent: false, to, reason: result.reason, retryable: result.retryable };
}

/** True when a Prisma error is the `(familyId, kind, period)` unique-key conflict. */
function isDuplicateClaim(err: unknown): boolean {
  return typeof err === "object" && err !== null && (err as { code?: string }).code === "P2002";
}

/** Delete a claim so a later tick can take the same period again (transient failure). */
async function releaseClaim(familyId: string, kind: DigestKind, period: string): Promise<void> {
  await prisma.digestSend
    .delete({ where: { familyId_kind_period: { familyId, kind, period } } })
    .catch(() => undefined);
}

/** Keep a claim as a terminal record so the period is not retried (permanent failure). */
async function retireClaim(familyId: string, kind: DigestKind, period: string, reason: string): Promise<void> {
  await prisma.digestSend
    .update({ where: { familyId_kind_period: { familyId, kind, period } }, data: { failedReason: reason } })
    .catch(() => undefined);
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
        if (r.sent) {
          sent += 1;
        } else if (r.retryable === false) {
          // Permanent (e.g. the provider rejects the address): keep the claim terminal for this
          // period rather than retrying an identical request every 15 minutes.
          await retireClaim(pref.familyId, kind, period, r.reason ?? "refused");
          console.warn(
            `[digest] family=${pref.familyId} kind=${kind} given up for ${period}: ${r.reason}`,
          );
        } else {
          // Transient (5xx, 429, timeout): release the claim so the next tick retries this period.
          await releaseClaim(pref.familyId, kind, period);
          console.warn(`[digest] family=${pref.familyId} kind=${kind} not sent, will retry: ${r.reason}`);
        }
      } catch (err) {
        // A thrown send is unclassified, so treat it as transient: releasing the claim costs one extra
        // attempt, keeping it costs the family the whole period (F1 of the #93 review).
        await releaseClaim(pref.familyId, kind, period);
        console.error(`[digest] family=${pref.familyId} kind=${kind} failed, will retry`, err);
      }
    }
  }
  return { attempted, sent };
}

let timer: NodeJS.Timeout | null = null;

export function startDigestScheduler(env: NodeJS.ProcessEnv = process.env): void {
  if (env.JOBS_ENABLED === "0" || env.NODE_ENV === "test") return;
  if (timer) return;
  if (env.DIGEST_HOUR === undefined && env.DIGEST_HOUR_UTC !== undefined) {
    // The old name is honoured, but as a LOCAL hour (ADR-0017): a deployment still setting
    // DIGEST_HOUR_UTC=18 expecting 18:00 UTC now sends at 18:00 local. Say so once at boot.
    console.warn(
      "[digest] DIGEST_HOUR_UTC is deprecated and read as a LOCAL hour since ADR-0017; set DIGEST_HOUR",
    );
  }
  const tick = () => runDigestsDue().catch((err) => console.error("[digest] tick failed", err));
  timer = setInterval(tick, TICK_MS);
  timer.unref();
  console.log(`[digest] scheduler started (local hour=${digestHour(env)}:00 per family's timezone, tick=${TICK_MS / 60000}m)`);
}

export function stopDigestScheduler(): void {
  if (timer) clearInterval(timer);
  timer = null;
}
