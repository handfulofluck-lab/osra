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
  return ANDROID_REQUIRED_GRANTS.filter((grant) => capabilities.grants[grant] !== "granted");
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

export function incompleteDedupeKey(deviceId: string, pairedAt: Date): string {
  return `setup_incomplete|${deviceId}|${episode(pairedAt)}`;
}
