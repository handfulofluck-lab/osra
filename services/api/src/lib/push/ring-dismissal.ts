import { getRedis } from "../../redis.js";
import type { AlertLike } from "./notify.js";

const WINDOW_MS = 60_000;
const TTL_SECONDS = 600;

type Reservation = { key: string; now: string; previous: string | null };

export async function reserveRingDismissalPush(
  familyId: string,
  alert: Pick<AlertLike, "category" | "metadata" | "createdAt">,
): Promise<{ coalesced: boolean; reservation?: Reservation }> {
  if (alert.category !== "ring" || alert.metadata?.state !== "child_dismissed") return { coalesced: false };
  const ringId = alert.metadata.ringId;
  if (typeof ringId !== "string" || !ringId) return { coalesced: false };
  const key = `push:ring-dismissal:${familyId}:${ringId}`;
  const timestamp = alert.createdAt ? new Date(alert.createdAt).getTime() : Date.now();
  const now = Number.isFinite(timestamp) ? timestamp : Date.now();
  try {
    const result = await getRedis().eval(
      `local old = redis.call('GET', KEYS[1])
       if old and tonumber(old) > tonumber(ARGV[1]) then return { 0, old } end
       redis.call('SET', KEYS[1], ARGV[2], 'EX', ARGV[3])
       return { 1, old }`,
      1, key, String(now - WINDOW_MS), String(now), TTL_SECONDS,
    ) as [number, string | null];
    if (!Array.isArray(result) || result[0] !== 1) return { coalesced: true };
    return { coalesced: false, reservation: { key, now: String(now), previous: result[1] ?? null } };
  } catch {
    return { coalesced: false };
  }
}

export async function releaseRingDismissalPush(reservation: Reservation): Promise<void> {
  try {
    await getRedis().eval(
      `if redis.call('GET', KEYS[1]) == ARGV[1] then
         if ARGV[2] ~= '' then
           redis.call('SET', KEYS[1], ARGV[2], 'EX', ARGV[3])
         else
           redis.call('DEL', KEYS[1])
         end
       end
       return 1`,
      1, reservation.key, reservation.now, reservation.previous ?? "", TTL_SECONDS,
    );
  } catch {
    /* Push stays best-effort; an expiring reservation is not a lost alert. */
  }
}
