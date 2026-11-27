import { createHash } from "node:crypto";
import { getRedis } from "../redis.js";

const KEY_PREFIX = "{staging-ai-quota}";
const DAY_KEY_TTL_SECONDS = 48 * 60 * 60;
const RESERVATION_TIMEOUT_MS = 500;

// Both keys use the same Redis slot. Cap rejections leave both counts unchanged
// and mark the first rejection on the limiting day key.
const RESERVE = `
local family = tonumber(redis.call("HGET", KEYS[1], "count") or "0")
local global = tonumber(redis.call("HGET", KEYS[2], "count") or "0")
if global >= tonumber(ARGV[2]) then
  return {"global", family, global, redis.call("HSETNX", KEYS[2], "warned", "1")}
end
if family >= tonumber(ARGV[1]) then
  return {"family", family, global, redis.call("HSETNX", KEYS[1], "warned", "1")}
end
family = redis.call("HINCRBY", KEYS[1], "count", 1)
if family == 1 then redis.call("EXPIRE", KEYS[1], ARGV[3]) end
global = redis.call("HINCRBY", KEYS[2], "count", 1)
if global == 1 then redis.call("EXPIRE", KEYS[2], ARGV[3]) end
return {"allowed", family, global, 0}
`;

export interface StagingAiReservation {
  allowed: boolean;
  reason?: "family" | "global" | "unavailable";
  log?: boolean;
  familyCount?: number;
  globalCount?: number;
}

function dailyCap(value: string | undefined, defaultValue: number): number | undefined {
  if (value === undefined) return defaultValue;
  if (!/^[1-9]\d*$/.test(value)) return undefined;
  const cap = Number(value);
  return Number.isSafeInteger(cap) ? cap : undefined;
}

/** Reserves one attempt before contacting the staging AI analyzer. */
export async function reserveStagingAiCall(
  familyId: string,
  familyDay: string,
  now: Date = new Date(),
  env: NodeJS.ProcessEnv = process.env,
): Promise<StagingAiReservation> {
  const familyCap = dailyCap(env.OSRA_STAGING_AI_FAMILY_DAILY_CAP, 250);
  const globalCap = dailyCap(env.OSRA_STAGING_AI_GLOBAL_DAILY_CAP, 2000);
  const unavailable = { allowed: false, reason: "unavailable" } as const;
  if (!familyCap || !globalCap || !familyId || !/^\d{4}-\d{2}-\d{2}$/.test(familyDay)
      || !Number.isFinite(now.getTime())) {
    return unavailable;
  }

  const familyKey = `${KEY_PREFIX}:family:${familyDay}:${createHash("sha256").update(familyId).digest("hex")}`;
  const globalKey = `${KEY_PREFIX}:global:${now.toISOString().slice(0, 10)}`;
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    const redis = getRedis();
    if (redis.status !== "ready") return unavailable;
    // A timed-out operation may still consume a reservation, but cannot
    // authorize an analyzer request or allow a day to exceed its cap.
    const result = await Promise.race([
      redis.eval(RESERVE, 2, familyKey, globalKey, familyCap, globalCap, DAY_KEY_TTL_SECONDS),
      new Promise<null>((resolve) => {
        timer = setTimeout(() => resolve(null), RESERVATION_TIMEOUT_MS);
      }),
    ]);
    if (!Array.isArray(result) || result.length !== 4) return unavailable;
    const [outcome, familyCount, globalCount, firstDenial] = result;
    if (!Number.isSafeInteger(familyCount) || familyCount < 0
        || !Number.isSafeInteger(globalCount) || globalCount < 0) {
      return unavailable;
    }
    if (outcome === "allowed") return { allowed: true, familyCount, globalCount };
    if ((outcome === "family" || outcome === "global") && (firstDenial === 0 || firstDenial === 1)) {
      return { allowed: false, reason: outcome, log: firstDenial === 1, familyCount, globalCount };
    }
    return unavailable;
  } catch {
    return unavailable;
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
}
