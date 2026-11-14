import { randomUUID } from "node:crypto";
import { getRedis } from "../../redis.js";
import type { AlertLike } from "./notify.js";

const TTL_SECONDS = 60;

type Reservation = { key: string; token: string };

export function ringMetadataObject(metadata: unknown): Record<string, unknown> {
  return typeof metadata === "object" && metadata !== null && !Array.isArray(metadata)
    ? metadata as Record<string, unknown>
    : {};
}

export async function reserveRingDismissalPush(
  familyId: string,
  alert: Pick<AlertLike, "category" | "metadata" | "createdAt">,
): Promise<{ coalesced: boolean; reservation?: Reservation }> {
  const metadata = ringMetadataObject(alert.metadata);
  if (alert.category !== "ring" || metadata.state !== "child_dismissed") return { coalesced: false };
  const ringId = metadata.ringId;
  if (typeof ringId !== "string" || !ringId) return { coalesced: false };
  const environment = process.env.NODE_ENV ?? "development";
  const key = `push:${environment}:ring-dismissal:${familyId}:${ringId}`;
  const token = randomUUID();
  try {
    const result = await getRedis().set(key, token, "EX", TTL_SECONDS, "NX");
    if (result !== "OK") return { coalesced: true };
    return { coalesced: false, reservation: { key, token } };
  } catch {
    return { coalesced: false };
  }
}

export async function releaseRingDismissalPush(reservation: Reservation): Promise<void> {
  try {
    await getRedis().eval(
      `if redis.call('GET', KEYS[1]) == ARGV[1] then
         return redis.call('DEL', KEYS[1])
       end
       return 0`,
      1, reservation.key, reservation.token,
    );
  } catch {
    /* Push stays best-effort; an expiring reservation is not a lost alert. */
  }
}
