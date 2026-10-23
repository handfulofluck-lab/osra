import { getRedis } from "../redis.js";

/**
 * Idle-request budget (roadmap 5.8).
 *
 * The acceptance's second half reads *"idle child phone ≤ 3 requests per 10 min with lock still ≤ 5 s"*, and
 * that rate has never been **counted** — 1.5 measured the lock's latency, not how often a backgrounded agent
 * wakes. A budget nobody measures is a wish, so this module counts.
 *
 * What is stored, and what is not: **counts only**, per device, per minute, per route key. No bodies, no
 * query strings, no IP addresses. A counting instrument that becomes a log of what a child did would be a
 * privacy defect dressed as telemetry, and the route key is deliberately coarsened (`/v1/devices/:id/commands`,
 * not `/v1/devices/abc-123/commands?ack=1`) for the same reason.
 *
 * Storage is one Redis hash per device — `idle:dev:<deviceId>` — whose fields are `<minuteEpoch>:<route>` with
 * a count. One key means the reader never SCANs the keyspace, and the hash expires on its own.
 */

/** Ten minutes, in minutes. The acceptance's window, named once. */
export const BUDGET_WINDOW_MINUTES = 10;

/** How long a count is kept. Longer than the window, shorter than a shift, so a read is cheap. */
export const RETENTION_MINUTES = 180;

const UUID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi;
const HEX_ID = /\b[0-9a-f]{24,32}\b/gi;

/**
 * The route key a count is filed under: the method and the path with identifiers coarsened.
 *
 * `GET /v1/devices/9f1c…/commands?ack=1` → `GET /v1/devices/:id/commands`. That is what makes the counts
 * comparable across devices and harmless to keep: a key cannot say which child, and cannot say which command.
 */
export function routeKey(method: string, url: string): string {
  const path = url.split("?")[0] ?? url;
  const coarsened = path
    .replace(UUID, ":id")
    .replace(HEX_ID, ":id")
    .replace(/\/\d+(?=\/|$)/g, "/:n");
  const trimmed = coarsened.length > 1 ? coarsened.replace(/\/$/, "") : coarsened;
  return `${method.toUpperCase()} ${trimmed}`;
}

/** The minute a timestamp falls in, as an integer — the field prefix in the hash. */
export function minuteOf(at: Date | number): number {
  const ms = typeof at === "number" ? at : at.getTime();
  return Math.floor(ms / 60_000);
}

export interface WindowResult {
  windowMinutes: number;
  total: number;
  byRoute: Record<string, number>;
  /** The busiest window of `windowMinutes` anywhere in the retained range. */
  busiest: { startMinute: number; count: number; byRoute: Record<string, number> } | null;
  minutesWithTraffic: number;
}

/**
 * Aggregate a device's counts into one window and the busiest window in the retained range.
 *
 * Pure over `{ [minute]: { [route]: count } }` so the acceptance's number can be tested without Redis, and so
 * a reviewer can check the arithmetic rather than trust a query.
 *
 * `busiest` is what the acceptance needs: "≤ 3 requests per 10 min" is a statement about the worst window, not
 * about the average, and an idle agent that wakes once every ten minutes and then four times in one of them is
 * not idle in the sense the row means.
 */
export function summarise(
  counts: Record<string, Record<string, number>>,
  options: { windowMinutes?: number; now?: Date | number } = {},
): WindowResult {
  const windowMinutes = options.windowMinutes ?? BUDGET_WINDOW_MINUTES;
  const nowMinute = minuteOf(options.now ?? Date.now());
  const from = nowMinute - windowMinutes + 1;

  const byRoute: Record<string, number> = {};
  let total = 0;
  for (const [minute, routes] of Object.entries(counts)) {
    const m = Number(minute);
    if (!Number.isFinite(m) || m < from || m > nowMinute) continue;
    for (const [route, count] of Object.entries(routes)) {
      if (!count) continue;
      byRoute[route] = (byRoute[route] ?? 0) + count;
      total += count;
    }
  }

  // Busiest window over the whole retained range, sliding by one minute.
  const minutes = Object.keys(counts)
    .map(Number)
    .filter((m) => Number.isFinite(m))
    .sort((a, b) => a - b);
  let busiest: WindowResult["busiest"] = null;
  if (minutes.length > 0) {
    for (let start = minutes[0]; start <= minutes[minutes.length - 1]; start += 1) {
      const inWindow: Record<string, number> = {};
      let count = 0;
      for (let m = start; m < start + windowMinutes; m += 1) {
        const routes = counts[String(m)];
        if (!routes) continue;
        for (const [route, c] of Object.entries(routes)) {
          inWindow[route] = (inWindow[route] ?? 0) + c;
          count += c;
        }
      }
      if (count > 0 && (!busiest || count > busiest.count)) busiest = { startMinute: start, count, byRoute: inWindow };
    }
  }

  return { windowMinutes, total, byRoute, busiest, minutesWithTraffic: minutes.length };
}

/** Field name inside the device hash. */
const field = (minute: number, route: string): string => `${minute}:${route}`;

/**
 * Count one authenticated device request. Best-effort by contract: a counting failure must never fail the
 * request it is counting, so every error is swallowed here and the caller does not await anything on the
 * request's critical path.
 */
export async function recordDeviceRequest(deviceId: string, method: string, url: string, at: Date = new Date()): Promise<void> {
  try {
    const redis = getRedis();
    const key = `idle:dev:${deviceId}`;
    await redis.hincrby(key, field(minuteOf(at), routeKey(method, url)), 1);
    await redis.expire(key, RETENTION_MINUTES * 60);
  } catch {
    /* counting is telemetry, not a gate on the request */
  }
}

/** Read a device's counts from Redis as the shape `summarise` takes. Empty on any failure. */
export async function readDeviceCounts(deviceId: string): Promise<Record<string, Record<string, number>>> {
  const counts: Record<string, Record<string, number>> = {};
  try {
    const redis = getRedis();
    const all = await redis.hgetall(`idle:dev:${deviceId}`);
    for (const [name, value] of Object.entries(all ?? {})) {
      const sep = name.indexOf(":");
      const minute = Number(name.slice(0, sep));
      const route = name.slice(sep + 1);
      const count = Number(value);
      if (!Number.isFinite(minute) || !Number.isFinite(count) || count <= 0) continue;
      (counts[String(minute)] ??= {})[route] = count;
    }
  } catch {
    /* a read failure reports as no traffic rather than as an error the parent cannot act on */
  }
  return counts;
}

/**
 * The threshold for the gating check, from the environment, **empty until it is measured**.
 *
 * Claude measures the idle rate on the Flip4 and supplies the number; until then this is `null` and the probe
 * reports the measured rate as a `target` rather than failing. A threshold invented here would be a gate that
 * measures the author's guess, which is the failure this row exists to stop repeating.
 */
export function idleBudgetThreshold(env: NodeJS.ProcessEnv = process.env): number | null {
  const raw = env.IDLE_BUDGET_M10;
  if (!raw) return null;
  const n = Number(raw);
  return Number.isFinite(n) && n >= 0 ? n : null;
}

/** True when the busiest window is within the threshold. `null` threshold means "not a gate yet". */
export function withinBudget(result: WindowResult, threshold: number | null): boolean | null {
  if (threshold === null) return null;
  return (result.busiest?.count ?? 0) <= threshold;
}
