import { prisma } from "../db.js";
import { getRedis } from "../redis.js";
import { wakeDeviceDetached } from "../lib/push/notify.js";

/**
 * Ring re-push job (#760 redesign). A locked or suspended iPhone may receive the first ring push
 * but not launch the app in time; the child may also dismiss the system alert without opening the
 * app. The server re-sends the ring wake every 30 seconds for any ring command that is still
 * pending or delivered but un-acked, up to the 5-minute ring cap. A Redis claim prevents several
 * API instances from flooding the same device.
 */

const TICK_MS = 30_000;
const RING_CAP_SECONDS = 300;
const CLAIM_TTL_SECONDS = 25;

function claimKey(deviceId: string, commandId: string): string {
  const environment = process.env.NODE_ENV ?? "development";
  return `jobs:ring-repush:${environment}:${deviceId}:${commandId}`;
}

export interface RingRepushRun {
  checked: number;
  repushed: string[];
}

export async function runRingRepush(now: Date = new Date()): Promise<RingRepushRun> {
  const cap = new Date(now.getTime() - RING_CAP_SECONDS * 1000);
  const commands = await prisma.deviceCommand.findMany({
    where: {
      type: "ring",
      status: { in: ["pending", "delivered"] },
      ackedAt: null,
      expiresAt: { gt: now },
      createdAt: { gt: cap },
    },
    select: { id: true, deviceId: true },
  });

  const repushed: string[] = [];
  for (const command of commands) {
    const key = claimKey(command.deviceId, command.id);
    const claim = await getRedis()
      .set(key, now.toISOString(), "EX", CLAIM_TTL_SECONDS, "NX")
      .catch(() => null);
    if (claim !== "OK") continue;
    wakeDeviceDetached(command.deviceId, "ring");
    repushed.push(command.id);
  }
  return { checked: commands.length, repushed };
}

let timer: NodeJS.Timeout | null = null;

export function startRingRepushScheduler(env: NodeJS.ProcessEnv = process.env): void {
  if (env.JOBS_ENABLED === "0" || env.NODE_ENV === "test") return;
  if (timer) return;
  const tick = () => runRingRepush(new Date()).catch((err) => console.error("[ring-repush] tick failed", err));
  timer = setInterval(tick, TICK_MS);
  timer.unref();
  console.log(`[ring-repush] scheduler started (tick=${TICK_MS / 1000}s)`);
}

export function stopRingRepushScheduler(): void {
  if (timer) clearInterval(timer);
  timer = null;
}
