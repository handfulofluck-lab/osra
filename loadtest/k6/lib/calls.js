// The request mix (load-test plan section 3), as plain data so k6 and the Node smoke share it.
// Each builder returns { name, method, path, body?, auth } where auth is "device" (device JWT),
// "device-hmac" (signed with the device's own secret) or "parent" (parent JWT).

const rnd = (a, b) => a + Math.random() * (b - a);
const APPS = ["com.google.android.youtube", "com.roblox.client", "com.whatsapp", "com.instagram.android", "com.mojang.minecraftpe"];

export const deviceCalls = {
  commandPoll: (d) => ({ name: "device_command_poll", method: "GET", path: `/v1/devices/${d.deviceId}/commands`, auth: "device" }),
  activity: (d) => ({
    name: "device_activity", method: "POST", path: `/v1/devices/${d.deviceId}/activity`, auth: "device",
    body: { events: [{ type: "app_usage", payload: { app: "YouTube", minutes: 1, live: true } }] },
  }),
  locationPing: (d) => ({
    name: "device_location_ping", method: "POST", path: "/v1/location/ping", auth: "device",
    body: { childId: d.childId, deviceId: d.deviceId, pings: [{ lat: rnd(24.2, 25.4), lng: rnd(54.3, 55.6), accuracyM: 12, timestamp: new Date().toISOString() }] },
  }),
  telemetry: (d) => ({
    name: "device_telemetry", method: "POST", path: `/v1/devices/${d.deviceId}/telemetry`, auth: "device",
    body: { batteryPct: Math.floor(rnd(20, 100)), totalMinutes: Math.floor(rnd(0, 15)), appUsage: [{ packageId: APPS[Math.floor(rnd(0, APPS.length))], minutes: Math.floor(rnd(1, 15)) }] },
  }),
  ruleSync: (d) => ({ name: "device_rule_sync", method: "GET", path: `/v1/rules/${d.childId}`, auth: "device" }),
  socialScan: (d) => ({
    name: "device_social_scan", method: "POST", path: "/v1/social/scan", auth: "device-hmac",
    body: { childId: d.childId, deviceId: d.deviceId, app: "whatsapp", contact: "LT Contact", text: "see you at school tomorrow", source: "notification" },
  }),
  searchEvent: (d) => ({
    name: "device_search_event", method: "POST", path: "/v1/content/search-event", auth: "device-hmac",
    body: { childId: d.childId, deviceId: d.deviceId, engine: "google", query: "homework help fractions" },
  }),
  blocklists: (d) => ({ name: "device_blocklists", method: "GET", path: "/v1/blocklists", auth: "device" }),
};

export const parentReads = {
  familyMe: () => ({ name: "parent_family_me", method: "GET", path: "/v1/family/me", auth: "parent" }),
  alerts: () => ({ name: "parent_alerts", method: "GET", path: "/v1/alerts?limit=20", auth: "parent" }),
  summary: (p) => ({ name: "parent_report_summary", method: "GET", path: `/v1/reports/summary?childId=${p.children[0]}&days=7`, auth: "parent" }),
  location: (p) => ({ name: "parent_location_latest", method: "GET", path: `/v1/location/${p.children[0]}/latest`, auth: "parent" }),
  devices: () => ({ name: "parent_devices", method: "GET", path: "/v1/devices", auth: "parent" }),
};

export const parentActions = {
  bonus: (p) => ({ name: "parent_bonus", method: "POST", path: `/v1/controls/children/${p.children[0]}/bonus`, auth: "parent", body: { minutes: 15 } }),
  pause: (p) => ({ name: "parent_pause", method: "POST", path: `/v1/controls/children/${p.children[1]}/pause`, auth: "parent" }),
  resume: (p) => ({ name: "parent_resume", method: "POST", path: `/v1/controls/children/${p.children[1]}/resume`, auth: "parent" }),
  rulesPatch: (p) => ({ name: "parent_rules_patch", method: "PATCH", path: `/v1/rules/${p.children[0]}`, auth: "parent", body: { dailyLimitMinutes: 120 + Math.floor(rnd(0, 120)) } }),
};

/**
 * Weights of the steady mix (plan section 3), as calls per second per family at the test target of
 * 0.15 req/s/family. Sums to 0.15.
 */
export const MIX_PER_FAMILY = {
  commandPoll: 0.045, activity: 0.03, locationPing: 0.03, telemetry: 0.0075, ruleSync: 0.0075,
  socialScan: 0.0075, searchEvent: 0.0045, blocklists: 0.0015,
  parentRead: 0.0135, parentAction: 0.003,
};
