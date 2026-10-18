import { prisma } from "../db.js";
import { getRedis } from "../redis.js";
import { raiseAlert } from "../lib/alerts.js";

/**
 * Device-silence watch (found by the plan-1.9 bypass probe: `pm clear` wipes the agent's pairing with
 * no client-side alert possible — the only witness is the server noticing the device stopped
 * reporting). Every tick, each `online` device whose `lastSeen` is older than `DEVICE_SILENT_MINUTES`
 * gets one `device_silent` alert (critical) and its status set to `offline`, so the parent hears
 * "the phone has not reported for 30 minutes" instead of nothing. A device that reports again goes
 * back to `online` through the telemetry, ping and pair/claim writers, which is what re-arms the watch.
 *
 * Vocabulary (audit finding 4): the column is a free string, so the writers are the contract. Pair/claim
 * (`routes/devices.ts:187`), telemetry (`:338`), location ping (`routes/location.ts:239`) and the seed
 * (`scripts/seed.ts:60`) all write `online`; the schema default and this job write `offline`; the parent
 * app and `DeviceStatus` in `packages/shared-types` speak `online`/`offline`/`locked`/`sos`. This job
 * therefore watches `online`, not the `active` it was written against: nothing ever wrote `active`, so
 * the watch matched no device and `pm clear` stayed silent.
 *
 * Same shape as the other jobs: a tick, a Redis `SET NX` claim per (device, silence window) so several
 * API instances do not double-alert, `JOBS_ENABLED=0` for deployments that call
 * `runDeviceSilenceCheck()` from an external cron.
 */

const TICK_MS = 5 * 60_000;

export function silentAfterMinutes(env: NodeJS.ProcessEnv = process.env): number {
  const m = Number(env.DEVICE_SILENT_MINUTES ?? 30);
  return Number.isInteger(m) && m >= 5 ? m : 30;
}

/** Pure rule: a device is silent when it is marked online but has not been seen for the window. */
export function isSilent(status: string, lastSeen: Date, now: Date, minutes: number): boolean {
  return status === "online" && now.getTime() - lastSeen.getTime() > minutes * 60_000;
}

export interface SilenceRun {
  checked: number;
  alerted: string[];
}

export async function runDeviceSilenceCheck(now: Date = new Date(), env: NodeJS.ProcessEnv = process.env): Promise<SilenceRun> {
  const minutes = silentAfterMinutes(env);
  const cutoff = new Date(now.getTime() - minutes * 60_000);
  const devices = await prisma.device.findMany({
    where: { status: "online", lastSeen: { lt: cutoff } },
    select: { id: true, status: true, lastSeen: true, childId: true, model: true, child: { select: { familyId: true, displayName: true } } },
  });
  const alerted: string[] = [];
  for (const d of devices) {
    if (!isSilent(d.status, d.lastSeen, now, minutes)) continue;
    // One alert per silence episode: the claim lives until the device is seen again (TTL as a backstop).
    const claim = await getRedis()
      .set(`jobs:device-silent:${d.id}:${d.lastSeen.toISOString()}`, now.toISOString(), "EX", 7 * 24 * 3600, "NX")
      .catch(() => null);
    if (claim !== "OK") continue;
    await prisma.device.update({ where: { id: d.id }, data: { status: "offline" } });
    await raiseAlert({
      childId: d.childId,
      familyId: d.child.familyId,
      deviceId: d.id,
      severity: "critical",
      category: "tamper",
      title: "Device stopped reporting",
      body: `${d.model} has not reported for ${minutes} minutes. The agent may have been removed, its data wiped, or the phone switched off.`,
      metadata: { type: "device_silent", lastSeen: d.lastSeen.toISOString(), silentMinutes: minutes },
      childName: d.child.displayName,
    });
    alerted.push(d.id);
  }
  return { checked: devices.length, alerted };
}

let timer: NodeJS.Timeout | null = null;

export function startDeviceSilenceScheduler(env: NodeJS.ProcessEnv = process.env): void {
  if (env.JOBS_ENABLED === "0" || env.NODE_ENV === "test") return;
  if (timer) return;
  const tick = () => runDeviceSilenceCheck(new Date(), env).catch((err) => console.error("[device-silent] tick failed", err));
  timer = setInterval(tick, TICK_MS);
  timer.unref();
  console.log(`[device-silent] scheduler started (after=${silentAfterMinutes(env)}m, tick=${TICK_MS / 60000}m)`);
}

export function stopDeviceSilenceScheduler(): void {
  if (timer) clearInterval(timer);
  timer = null;
}
