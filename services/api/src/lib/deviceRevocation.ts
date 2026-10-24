import { prisma } from "../db.js";
import { getRedis } from "../redis.js";
import { DEVICE_TOKEN_TTL_SECONDS } from "./deviceToken.js";

/**
 * Is a device still paired? (ADR-0032 / roadmap 2.7)
 *
 * The `Device` row is the record. Until ADR-0032 the only thing that made an unpaired phone's
 * 10-year token answer 401 was `revoked:device:<id>` in Redis — so a restarted or evicted node, or
 * `snapshot_retention_limit = 0`, let that phone read the child's rules, location history and
 * geofences again. The row cannot be evicted, so it decides; the two keys are caches around it.
 *
 * Three steps, in this order:
 *  1. `revoked:device:<id>` present → revoked. The tombstone an unpair writes, with the token's own
 *     10-year lifetime; it answers the common case without touching the database.
 *  2. `device:live:<id>` present → live. The positive cache: one primary-key lookup per device per
 *     5 minutes instead of one per request.
 *  3. Neither → look the row up by primary key. Absent → revoked (and write the tombstone so the
 *     next request is one GET). Present → live (and write the positive cache).
 *
 * A Redis error on a read is treated as a miss, not as a verdict: the database still answers the
 * question. A Redis error on a cache **write** here is swallowed — the answer is already correct,
 * and the next request simply reads the row again. `markDeviceRevoked` is the opposite: it is the
 * write path, where a silent failure means a revocation nobody can see, so it throws.
 */
export const revokedDeviceKey = (deviceId: string) => `revoked:device:${deviceId}`;
export const liveDeviceKey = (deviceId: string) => `device:live:${deviceId}`;

/** The positive cache lives 5 minutes: bounded enough that a deleted row is noticed without a
 * database round trip per request, long enough that a location ping does not pay for a lookup. */
export const DEVICE_LIVE_TTL_SECONDS = 5 * 60;

export type DeviceVerdict = "live" | "revoked";

export async function deviceVerdict(deviceId: string): Promise<DeviceVerdict> {
  const redis = getRedis();
  const revoked = await redis.get(revokedDeviceKey(deviceId)).catch(() => null);
  if (revoked) return "revoked";
  const live = await redis.get(liveDeviceKey(deviceId)).catch(() => null);
  if (live) return "live";

  const row = await prisma.device.findUnique({ where: { id: deviceId }, select: { id: true } });
  if (!row) {
    await redis
      .set(revokedDeviceKey(deviceId), new Date().toISOString(), "EX", DEVICE_TOKEN_TTL_SECONDS)
      .catch(() => {});
    return "revoked";
  }
  await redis.set(liveDeviceKey(deviceId), "1", "EX", DEVICE_LIVE_TTL_SECONDS).catch(() => {});
  return "live";
}

/**
 * Publish a revocation: drop the positive cache and write the tombstone.
 *
 * Called after the `Device` row is gone (unpair, child erase), so the row check would answer 401 on
 * its own; these keys keep that answer to one Redis GET. **Not** best-effort: if Redis rejects the
 * write the caller must fail (5xx) rather than report an unpair whose cache still says the device is
 * live. The positive key goes first so that no interleaving leaves both keys present with `live`
 * winning a read that runs between them.
 */
export async function markDeviceRevoked(
  deviceId: string,
  revokedAt: string = new Date().toISOString(),
  ttlSeconds: number = DEVICE_TOKEN_TTL_SECONDS,
): Promise<void> {
  const redis = getRedis();
  await redis.del(liveDeviceKey(deviceId));
  await redis.set(revokedDeviceKey(deviceId), revokedAt, "EX", ttlSeconds);
}
