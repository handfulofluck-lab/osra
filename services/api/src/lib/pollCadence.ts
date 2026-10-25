import { prisma } from "../db.js";
import { canWakeDevice } from "./push/notify.js";

/**
 * Roadmap 5.8, issue #353: how often an idle child phone polls `GET /v1/devices/:id/commands`.
 *
 * Measured on the Flip4 before this: 22–24 requests per idle 10 minutes against a budget of 3, ten of
 * them this poll. The poll is the fallback for the push wake (#319), so it only needs to be fast when
 * there is no push: the server, which knows whether it can wake the device, says so in a response
 * header and the body stays the same array older agents expect.
 *
 * The agent clamps the value to 30–900 s and polls every 60 s whatever the header says while the
 * screen is on, so a child using the phone still gets a lock within a minute if a push is lost.
 */
export const POLL_AFTER_HEADER = "X-Poll-After";
/** No way to wake the device: poll every minute, as every agent did before #353. */
export const POLL_FAST_SECONDS = 60;
/** The server can wake the device: the poll is a safety net, once per idle 10 minutes. */
export const POLL_PUSH_SECONDS = 600;

/**
 * The poll also refreshes `lastSeen`, because once a stationary phone batches its location pings the
 * poll is the call that proves it is alive. At most once per this window per device, so a poll is
 * a read, not a write, almost every time.
 */
export const LAST_SEEN_REFRESH_MS = 5 * 60_000;

export interface PolledDevice {
  id: string;
  platform?: string | null;
  pushToken?: string | null;
  lastSeen?: Date | null;
}

export function pollAfterSeconds(device: PolledDevice | null | undefined): number {
  return canWakeDevice(device) ? POLL_PUSH_SECONDS : POLL_FAST_SECONDS;
}

export function lastSeenIsStale(lastSeen: Date | null | undefined, now: Date = new Date()): boolean {
  return !lastSeen || now.getTime() - lastSeen.getTime() >= LAST_SEEN_REFRESH_MS;
}

/**
 * Refreshes `lastSeen` when it is older than [LAST_SEEN_REFRESH_MS]. The `lt` condition makes two
 * concurrent polls one write, and a failure never fails the poll (the commands are already claimed).
 */
export async function touchLastSeen(device: PolledDevice, now: Date = new Date()): Promise<void> {
  if (!lastSeenIsStale(device.lastSeen, now)) return;
  try {
    await prisma.device.updateMany({
      where: { id: device.id, lastSeen: { lt: new Date(now.getTime() - LAST_SEEN_REFRESH_MS) } },
      data: { lastSeen: now, status: "online" },
    });
  } catch (err) {
    console.warn(`[poll] lastSeen refresh failed device=${device.id}`, err);
  }
}
