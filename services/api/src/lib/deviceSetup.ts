import type { GrantKey } from "@familyshield/shared-types";
import { CapabilitiesSchema, type Capabilities } from "./capabilities.js";

export const SETUP_WINDOW_MS = 30 * 60_000;

export const ANDROID_REQUIRED_GRANTS = [
  "accessibility",
  "usage_access",
  "overlay",
  "device_admin",
  "web_filter",
  "location",
  "private_dns",
] as const satisfies readonly GrantKey[];

/**
 * osra-security#82 (26 Nov): the Full build asks for notification access as a required grant (#1208), so the
 * server waits for it too, or the phone and the server disagree about when protection starts. Play has no
 * notification listener at all and keeps its seven. The flavour comes from the capabilities contract.
 * A pairing that already completed keeps its completion: nothing here re-opens it (completion is only ever
 * set, never cleared, by a report).
 */
export const ANDROID_FULL_REQUIRED_GRANTS = [
  ...ANDROID_REQUIRED_GRANTS,
  "notification_listener",
] as const satisfies readonly GrantKey[];

export function requiredGrantsFor(capabilities: Pick<Capabilities, "client">): readonly GrantKey[] {
  return capabilities.client.flavour === "full" ? ANDROID_FULL_REQUIRED_GRANTS : ANDROID_REQUIRED_GRANTS;
}

const TAMPER_GRANT: Readonly<Record<string, GrantKey>> = {
  accessibility_off: "accessibility",
  accessibility: "accessibility",
  device_admin_removed: "device_admin",
  content_filter_disconnected: "web_filter",
  overlay_revoked: "overlay",
  usage_access_off: "usage_access",
  notification_listener_off: "notification_listener",
};

export interface SetupDevice {
  pairedAt: Date | null;
  setupCompletedAt: Date | null;
  capabilities: unknown;
  platform?: string;
}

function parsedCapabilities(raw: unknown): Capabilities | null {
  const parsed = CapabilitiesSchema.safeParse(raw);
  return parsed.success ? parsed.data : null;
}

export function requiredMissingGrants(raw: unknown): GrantKey[] | null {
  const capabilities = parsedCapabilities(raw);
  if (!capabilities || capabilities.client.app !== "child-android") return null;
  return requiredGrantsFor(capabilities).filter((grant) => capabilities.grants[grant] !== "granted");
}

export function shouldHoldTamperDuringSetup(
  device: SetupDevice,
  category: string,
  type: string | null,
  now: Date,
): boolean {
  if (category !== "tamper" || !type || device.setupCompletedAt || !device.pairedAt) return false;
  if (now.getTime() - device.pairedAt.getTime() >= SETUP_WINDOW_MS) return false;
  const grant = TAMPER_GRANT[type];
  if (!grant) return false;
  const capabilities = parsedCapabilities(device.capabilities);
  return capabilities?.client.app === "child-android" && capabilities.grants[grant] === "missing";
}

export function setupIncompleteDue(device: SetupDevice, now: Date): boolean {
  if (device.setupCompletedAt || !device.pairedAt) return false;
  if (now.getTime() - device.pairedAt.getTime() < SETUP_WINDOW_MS) return false;
  const capabilities = parsedCapabilities(device.capabilities);
  return capabilities?.client.app === "child-android" || (!capabilities && device.platform === "android");
}

function episode(pairedAt: Date): string {
  return pairedAt.toISOString();
}

export function completionDedupeKey(deviceId: string, pairedAt: Date): string {
  return `setup_complete|${deviceId}|${episode(pairedAt)}`;
}

/**
 * #1208: ONE key per pairing, shared by the phone's immediate setup notice and the server's 30-minute
 * reminder, so the two upsert a single parent row instead of paging twice. A device row is one pairing.
 */
export function incompleteDedupeKey(deviceId: string): string {
  return `setup_incomplete:${deviceId}`;
}
