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
 * screen is on, so a child using the phone still gets a lock within a minute if a push is lost. Since
 * #673 it polls every 10 s while a lock or a pause is up: the overlay keeps the screen on, and that is
 * exactly when a parent is waiting to lift the restriction — the Flip4's `resume_internet` waited 52 s
 * for the 60 s cap on 12 Nov.
 */
export const POLL_AFTER_HEADER = "X-Poll-After";

/**
 * Whether the server still holds this device's push token (#383), so the phone can re-upload one the
 * server cleared. A wake that fails as "dead token" clears `Device.pushToken`, and the agent used to
 * have no way to learn that: it uploads only when Firebase rotates the token, so push stayed dead
 * until the next rotation. Two values, so the agent never has to guess from an absent header:
 *  - `on-file` — the row holds a token;
 *  - `none`    — it holds none, so the stored one should be sent again on this poll.
 */
export const PUSH_TOKEN_HEADER = "X-Push-Token";
export const PUSH_TOKEN_ON_FILE = "on-file";
export const PUSH_TOKEN_NONE = "none";
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
 *
 * `markOnline: false` writes `lastSeen` and nothing else (issue #601): the rules fetch proves the agent is
 * awake, but `status` belongs to the calls that already own it — the poll, the telemetry upload and the
 * location ping — so an agent read is not a second status writer.
 */
export async function touchLastSeen(
  device: PolledDevice,
  now: Date = new Date(),
  opts: { markOnline?: boolean } = {},
): Promise<void> {
  if (!lastSeenIsStale(device.lastSeen, now)) return;
  try {
    await prisma.device.updateMany({
      where: { id: device.id, lastSeen: { lt: new Date(now.getTime() - LAST_SEEN_REFRESH_MS) } },
      data: opts.markOnline === false ? { lastSeen: now } : { lastSeen: now, status: "online" },
    });
  } catch (err) {
    console.warn(`[poll] lastSeen refresh failed device=${device.id}`, err);
  }
}

/**
 * Refresh `lastSeen` for the device behind an agent token on a read that means "the agent is alive"
 * (issue #601): today the rules fetch, `GET /v1/rules/:childId`.
 *
 * Parent tokens return immediately — a parent opening the dashboard must not make the phone look alive —
 * and so does a device token with no id. There is deliberately no select first: the caller does not have
 * the row in hand, `lastSeenIsStale(undefined)` is true, and the `lt` guard in the WHERE is what makes this
 * one no-op statement when the clock is already fresh — one write, not a read plus a conditional write.
 */
export async function touchAgentLastSeen(
  user: { role?: string; deviceId?: string; sub?: string } | undefined,
  now: Date = new Date(),
): Promise<void> {
  if (user?.role !== "device") return;
  const id = user.deviceId ?? user.sub;
  if (!id) return;
  await touchLastSeen({ id }, now, { markOnline: false });
}
