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

/**
 * The agent's reporting cadences, mirrored from the app because the server cannot ask a device how
 * often it will call (issue #166). The silence window must tolerate at least one missed report, or a
 * healthy phone gets flagged `device_silent` — a critical alert saying the child's phone went silent.
 *
 * `test/device-silence.test.ts` reads the Kotlin sources and fails if either number drifts, so these
 * are not free-standing guesses: `WorkScheduler.kt:48` schedules telemetry every 15 minutes and
 * `LocationService.kt:430` pings every 5 minutes while stationary (the ping is faster, so telemetry
 * is what the window must cover). Since #353 a stationary phone uploads its fixes every 10 minutes and
 * an idle phone that can be woken by push polls every 10 (never more than 15, `IdleCadence.kt`); both
 * still report at least as often as telemetry, so the window is unchanged, and `poll-cadence.test.ts`
 * fails if either outgrows it. The 5-minute job tick (`TICK_MS`) is the server-side sampling
 * granularity and deliberately not part of the floor: a coarse tick delays detection, it does not
 * cause a false one.
 */
export const TELEMETRY_INTERVAL_MINUTES = 15;
export const STATIONARY_PING_INTERVAL_MINUTES = 5;

/** Two telemetry intervals: one late or missed report must not read as silence. */
export const SILENT_MIN_SAFE_MINUTES = 2 * TELEMETRY_INTERVAL_MINUTES;

/** Historic floor, kept so the test-only override cannot be set below something absurd. */
export const SILENT_FLOOR_MINUTES = 5;

/** Test-only escape hatch for the TR-22 hardware row; never for a real deployment. */
export const SILENT_TIGHT_OVERRIDE_ENV = "DEVICE_SILENT_ALLOW_TIGHT";

export interface SilenceConfig {
  /** Effective window after the fallback and the safe-minimum clamp. */
  minutes: number;
  /** Parsed value, or the default when the variable is unset. */
  configured: number;
  /** The variable as given, for warnings (`null` when unset). */
  raw: string | null;
  /** A valid value below the safe minimum that was raised to it. */
  clamped: boolean;
  /** A valid value below the safe minimum kept because the test-only override is set. */
  tightOverride: boolean;
  /** A set value that is not an integer ≥ `SILENT_FLOOR_MINUTES`; the default was used. */
  invalid: boolean;
}

/**
 * The single place the silence policy is decided (issue #166). Defaults keep the pre-#166 behaviour
 * (30 minutes); the only behaviour change is that a too-tight configured window is raised to
 * `SILENT_MIN_SAFE_MINUTES` instead of being accepted, because a false `device_silent` is worse than
 * a late one. `DEVICE_SILENT_ALLOW_TIGHT=1` restores the old floor of 5 for the hardware row and is
 * logged as test-only.
 */
export function resolveSilenceConfig(env: NodeJS.ProcessEnv = process.env): SilenceConfig {
  const raw = env.DEVICE_SILENT_MINUTES;
  const isSet = raw !== undefined && raw.trim() !== "";
  const configured = isSet ? Number(raw) : SILENT_MIN_SAFE_MINUTES;
  const valid = Number.isInteger(configured) && configured >= SILENT_FLOOR_MINUTES;

  if (isSet && !valid) {
    return { minutes: SILENT_MIN_SAFE_MINUTES, configured, raw: raw ?? null, clamped: false, tightOverride: false, invalid: true };
  }
  if (configured >= SILENT_MIN_SAFE_MINUTES) {
    return { minutes: configured, configured, raw: isSet ? (raw ?? null) : null, clamped: false, tightOverride: false, invalid: false };
  }
  if (env[SILENT_TIGHT_OVERRIDE_ENV] === "1") {
    return { minutes: configured, configured, raw: raw ?? null, clamped: false, tightOverride: true, invalid: false };
  }
  return { minutes: SILENT_MIN_SAFE_MINUTES, configured, raw: raw ?? null, clamped: true, tightOverride: false, invalid: false };
}

/** The configured window in minutes. */
export function silentAfterMinutes(env: NodeJS.ProcessEnv = process.env): number {
  return resolveSilenceConfig(env).minutes;
}

/**
 * The startup warning for a configuration that does not leave two telemetry intervals of headroom
 * (or that is not a usable number at all), or `null` when the configuration is safe. Pure so the
 * text can be asserted without capturing the console.
 */
export function silenceConfigWarning(config: SilenceConfig): string | null {
  const cadence = `2 × the ${TELEMETRY_INTERVAL_MINUTES}-minute telemetry cadence (WorkScheduler.kt:48)`;
  if (config.invalid) {
    return `[device-silent] DEVICE_SILENT_MINUTES=${config.raw} is not an integer ≥ ${SILENT_FLOOR_MINUTES}; using ${config.minutes}. The safe minimum is ${SILENT_MIN_SAFE_MINUTES} = ${cadence}.`;
  }
  if (config.tightOverride) {
    return `[device-silent] TEST ONLY — ${SILENT_TIGHT_OVERRIDE_ENV}=1 keeps DEVICE_SILENT_MINUTES=${config.configured}, below the safe minimum ${SILENT_MIN_SAFE_MINUTES} = ${cadence}. A healthy stationary phone can be flagged device_silent (issue #166). Never set this on a real deployment.`;
  }
  if (config.clamped) {
    return `[device-silent] DEVICE_SILENT_MINUTES=${config.configured} is below the safe minimum ${SILENT_MIN_SAFE_MINUTES} = ${cadence}; clamped to ${config.minutes} so one late report is not read as silence (issue #166). Set ${SILENT_TIGHT_OVERRIDE_ENV}=1 only to measure the floor on a test device.`;
  }
  return null;
}

/** Pure rule: a device is silent when it is marked online but has not been seen for the window. */
export function isSilent(status: string, lastSeen: Date, now: Date, minutes: number): boolean {
  return status === "online" && now.getTime() - lastSeen.getTime() > minutes * 60_000;
}

/**
 * #681: the window is per platform, because the reporting cadence is Apple's, not ours.
 *
 * On Android the agent reports on a schedule we control, and a 30-minute silence is news — that is the
 * `pm clear` case this job was built for. On an iPhone the app is suspended by the OS between wakes, so a
 * healthy phone can be quiet for hours; the same window would raise a *critical* "your child's phone went
 * silent" alert for a phone that is simply in a school bag. Six hours is the documented default, and it
 * is deliberately far above any plausible wake interval rather than tuned to one.
 *
 * Same clamp discipline as the Android window: below [APPLE_SILENT_MIN_SAFE_MINUTES] the value is raised,
 * because a false "the phone may have been removed" is worse than a late true one.
 */
export const APPLE_SILENT_DEFAULT_MINUTES = 360;
export const APPLE_SILENT_MIN_SAFE_MINUTES = 120;
export const APPLE_SILENT_ENV = "DEVICE_SILENT_MINUTES_APPLE";

/**
 * One place that decides what "Apple" means, because two places drifting is how a Mac gets an Android alert:
 * the window and the severity must read the same list (Claude's surviving fault on #705).
 */
export function isApplePlatform(platform: string | null | undefined): boolean {
  return platform === "ios" || platform === "macos";
}

/** Which window applies to a device, from the platform column the writers already set. */
export function silentMinutesForPlatform(platform: string | null | undefined, androidMinutes: number, env: NodeJS.ProcessEnv = process.env): number {
  if (!isApplePlatform(platform)) return androidMinutes;
  const raw = env[APPLE_SILENT_ENV];
  const parsed = raw === undefined ? APPLE_SILENT_DEFAULT_MINUTES : Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed)) return Math.max(APPLE_SILENT_DEFAULT_MINUTES, androidMinutes);
  // Never shorter than the Android window: whoever raises DEVICE_SILENT_MINUTES to 180 must not thereby
  // make an iPhone fire at 120 and be the *first* phone declared removed (Claude on #705).
  return Math.max(parsed, APPLE_SILENT_MIN_SAFE_MINUTES, androidMinutes);
}

export interface SilenceRun {
  checked: number;
  alerted: string[];
}

export async function runDeviceSilenceCheck(now: Date = new Date(), env: NodeJS.ProcessEnv = process.env): Promise<SilenceRun> {
  const minutes = silentAfterMinutes(env);
  // The SQL cutoff uses the SHORTEST window in play; each device's own window is then tested below. Doing
  // it the other way round — one cutoff for everyone — would either miss every Android silence or let an
  // Apple device be judged by a 30-minute rule.
  const shortest = Math.min(minutes, silentMinutesForPlatform("ios", minutes, env));
  const cutoff = new Date(now.getTime() - shortest * 60_000);
  const devices = await prisma.device.findMany({
    where: { status: "online", lastSeen: { lt: cutoff } },
    select: { id: true, status: true, lastSeen: true, childId: true, model: true, platform: true, child: { select: { familyId: true, displayName: true } } },
  });
  const alerted: string[] = [];
  for (const d of devices) {
    const isApple = isApplePlatform(d.platform);
    const windowMinutes = silentMinutesForPlatform(d.platform, minutes, env);
    if (!isSilent(d.status, d.lastSeen, now, windowMinutes)) continue;
    // One alert per silence episode: the claim lives until the device is seen again (TTL as a backstop).
    const claim = await getRedis()
      .set(`jobs:device-silent:${d.id}:${d.lastSeen.toISOString()}`, now.toISOString(), "EX", 7 * 24 * 3600, "NX")
      .catch(() => null);
    if (claim !== "OK") continue;
    await prisma.device.update({ where: { id: d.id }, data: { status: "offline" } });
    const elapsedMinutes = Math.round((now.getTime() - d.lastSeen.getTime()) / 60_000);
    await raiseAlert({
      childId: d.childId,
      familyId: d.child.familyId,
      deviceId: d.id,
      // A phone that is off for six hours is not an emergency; a critical alarm there teaches parents to
      // ignore the one that matters, the Android `pm clear` silence (#705 review).
      severity: isApple ? "warning" : "critical",
      category: "tamper",
      title: "Device stopped reporting",
      // The sentence names the time the phone has ACTUALLY been quiet, not the window that fired: a parent
      // reading "360 minutes" about a phone unseen for seven hours is being told something untrue in the one
      // number they will act on. The window goes in the metadata, where the test and the audit read it.
      body: `${d.model} has not reported for ${elapsedMinutes} minutes. The agent may have been removed, its data wiped, or the phone switched off.`,
      bodyKey: "alertBodyDeviceSilent",
      params: { model: d.model, minutes: elapsedMinutes },
      metadata: {
        type: "device_silent",
        // The app and the reports can tell the two apart without a schema change (#705 review).
        window: isApple ? "apple" : "android",
        lastSeen: d.lastSeen.toISOString(),
        silentMinutes: windowMinutes,
      },
      childName: d.child.displayName,
    });
    alerted.push(d.id);
  }
  return { checked: devices.length, alerted };
}

let timer: NodeJS.Timeout | null = null;

export function startDeviceSilenceScheduler(env: NodeJS.ProcessEnv = process.env): void {
  const config = resolveSilenceConfig(env);
  // Warn at boot even when the in-process scheduler is off: with JOBS_ENABLED=0 the same value is
  // read by an external cron, and a too-tight window is exactly as misleading there. Tests stay quiet.
  if (env.NODE_ENV !== "test") {
    const warning = silenceConfigWarning(config);
    if (warning) console.warn(warning);
  }
  if (env.JOBS_ENABLED === "0" || env.NODE_ENV === "test") return;
  if (timer) return;
  const tick = () => runDeviceSilenceCheck(new Date(), env).catch((err) => console.error("[device-silent] tick failed", err));
  timer = setInterval(tick, TICK_MS);
  timer.unref();
  console.log(`[device-silent] scheduler started (after=${config.minutes}m, tick=${TICK_MS / 60000}m)`);
}

export function stopDeviceSilenceScheduler(): void {
  if (timer) clearInterval(timer);
  timer = null;
}
