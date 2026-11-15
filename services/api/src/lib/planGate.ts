import type { FastifyReply, FastifyRequest } from "fastify";
import { prisma } from "../db.js";
import { entitlement, STORE_MAX_RECOVERY_DAYS } from "./entitlement.js";
import { isValidTimeZone, localParts, utcOffsetMinutes } from "./digestSchedule.js";

/** M3 decides which fields are premium. Until then this table deliberately gates nothing. */
export const PREMIUM_FEATURES: Record<string, true> = {};

/** The next family-local 10:00 after an eligibility-ending event. */
export function nextEnforcementAt(endedAt: Date, timeZone: string): Date {
  const zone = isValidTimeZone(timeZone) ? timeZone : "UTC";
  const local = localParts(endedAt, zone);
  const day = new Date(`${local.date}T00:00:00.000Z`);
  if (local.hour >= 10) day.setUTCDate(day.getUTCDate() + 1);
  const nominal = Date.UTC(day.getUTCFullYear(), day.getUTCMonth(), day.getUTCDate(), 10);
  let instant = nominal;
  // Resolve the offset at the target instant, not the event's offset: it may differ across DST.
  for (let i = 0; i < 3; i++) instant = nominal - utcOffsetMinutes(new Date(instant), zone) * 60_000;
  return new Date(instant);
}

/** A response can say the plan has lapsed while enforcement still waits for local 10:00. */
export async function hasEnforcingPlan(familyId: string, now = new Date()): Promise<boolean> {
  if ((await entitlement(familyId, now)).plan) return true;
  const [family, rows] = await Promise.all([
    prisma.family.findUnique({ where: { id: familyId }, select: { timezone: true } }),
    prisma.familyPurchase.findMany({ where: { familyId } }),
  ]);
  const endings = rows.flatMap((row) => {
    let endedAt;
    if (row.status === "active") {
      endedAt = row.expiresAt;
    } else if (row.status === "grace" || row.status === "on_hold") {
      endedAt = row.expiresAt && new Date(row.expiresAt.getTime() + STORE_MAX_RECOVERY_DAYS * 24 * 60 * 60 * 1000);
    } else {
      endedAt = row.endedAt ?? row.lastVerifiedAt;
    }
    return endedAt && endedAt <= now ? [endedAt.getTime()] : [];
  });
  if (!endings.length) return false;
  return now < nextEnforcementAt(new Date(Math.max(...endings)), family?.timezone ?? "UTC");
}

/** No premium route opts in until M3; this is the typed refusal for one that does. */
export function requirePlan(now: () => Date = () => new Date()) {
  return async (req: FastifyRequest, reply: FastifyReply): Promise<void> => {
    const user = req.user as { sub?: string; role?: string; familyId?: string } | undefined;
    let familyId = user?.familyId;
    if (user?.role === "parent") {
      const parent = user.sub ? await prisma.parent.findUnique({ where: { id: user.sub }, select: { familyId: true } }) : null;
      if (!parent) {
        await reply.code(401).send({ error: "unauthorized" });
        return;
      }
      if (familyId && familyId !== parent.familyId) {
        await reply.code(403).send({ error: "forbidden" });
        return;
      }
      familyId = parent.familyId;
    }
    if (!familyId) {
      await reply.code(401).send({ error: "unauthorized" });
      return;
    }
    if (!(await hasEnforcingPlan(familyId, now()))) await reply.code(402).send({ error: "plan_required" });
  };
}
