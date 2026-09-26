/**
 * FamilyShield end-to-end smoke test against a LIVE API (Postgres + Redis required).
 *
 * Covers the §13 acceptance flow: seeded login -> child consent gate (428) ->
 * child + inline consent (201) -> device registration -> rules PUT + Redis rules
 * publish -> HMAC location ping + geofence enter/exit alerts -> HMAC internal
 * alert + WebSocket delivery -> ack -> device command queue -> telemetry ->
 * cross-family isolation (403).
 *
 * Usage: node scripts/e2e.mjs   (auto-re-executes with --experimental-websocket on
 * Node 20, where the global WebSocket is behind a flag; no flags needed on Node 22+).
 */
import { createHmac, randomBytes } from "node:crypto";
import { spawn } from "node:child_process";
import { Redis } from "ioredis";

// Node 20 hides the global WebSocket behind a flag — re-exec ourselves with it.
if (typeof globalThis.WebSocket === "undefined" && !process.env.FS_WS_FLAGGED) {
  const child = spawn(process.execPath, ["--experimental-websocket", process.argv[1]], {
    stdio: "inherit",
    env: { ...process.env, FS_WS_FLAGGED: "1" },
  });
  child.on("exit", (code) => process.exit(code ?? 1));
  // Keep the parent alive until the child finishes.
  await new Promise(() => {});
}

const API = process.env.API_BASE ?? "http://localhost:3000";
// Default matches start-backend.bat (BUG-003): the e2e and the backend must share one secret.
const HMAC_SECRET = process.env.INTERNAL_HMAC_SECRET ?? "e2e-hmac-secret";
const PASS = [], FAIL = [];
const check = (name, cond, extra = "") => {
  (cond ? PASS : FAIL).push(name);
  console.log(`${cond ? "PASS" : "FAIL"}  ${name}${extra ? ` — ${extra}` : ""}`);
};

const sign = (body) => createHmac("sha256", HMAC_SECRET).update(body).digest("hex");

async function call(method, path, { token, body, hmac } = {}) {
  const raw = body === undefined ? undefined : JSON.stringify(body);
  const res = await fetch(`${API}${path}`, {
    method,
    headers: {
      ...(raw ? { "content-type": "application/json" } : {}),
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(hmac ? { "x-familyshield-signature": sign(raw ?? "") } : {}),
    },
    body: raw,
  });
  let data = null;
  try { data = await res.json(); } catch { /* empty body */ }
  return { status: res.status, data };
}

const redis = new Redis(process.env.REDIS_URL ?? "redis://localhost:6379");
const nextMessage = (channel) =>
  new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`timeout waiting for ${channel}`)), 8000);
    redis.subscribe(channel).then(() => {}).catch(reject);
    redis.once("message", (ch, msg) => {
      if (ch === channel) { clearTimeout(timer); resolve(JSON.parse(msg)); }
    });
  });

// --- 1. Seeded parent login + /me envelope ---
const login = await call("POST", "/v1/auth/login", { body: { email: "demo@familyshield.dev", password: "CorrectHorseBatteryStaple!" } });
check("seeded parent login", login.status === 200 && !!login.data?.token);
const token = login.data.token;

const me = await call("GET", "/v1/family/me", { token });
check("GET /me returns family envelope", me.status === 200 && !!me.data?.family?.id && Array.isArray(me.data?.children) && Array.isArray(me.data?.devices));
check("/me strips passwordHash", me.status === 200 && JSON.stringify(me.data).indexOf("passwordHash") === -1 && JSON.stringify(me.data).indexOf("argon2") === -1);
const alex = me.data.children.find((c) => c.displayName === "Alex");
check("seeded child Alex present with device + ruleset", !!alex && alex.devices.length >= 1 && !!alex.ruleSet);

// --- 2. Consent gate: child without consent -> 428 ---
const noConsent = await call("POST", "/v1/family/children", { token, body: { displayName: "GateCheck", birthYear: 2015 } });
check("child without consent -> 428", noConsent.status === 428, `got ${noConsent.status}`);

// --- 3. Child with inline consent -> 201 ---
const withConsent = await call("POST", "/v1/family/children", { token, body: { displayName: "Sam", birthYear: 2014, consent: { method: "sms_plus", jurisdiction: "US" } } });
check("child with inline consent -> 201", withConsent.status === 201 && !!withConsent.data?.child?.id && withConsent.data?.consent?.method === "sms_plus", `got ${withConsent.status}`);
const sam = withConsent.data?.child;

// --- 4. Device registration ---
const dev = await call("POST", "/v1/devices/register", { token, body: { childId: sam.id, platform: "windows", model: "TestPC", osVersion: "10", pushToken: "e2e-token" } });
check("device registration -> 201", dev.status === 201 && !!dev.data?.device?.id, `got ${dev.status}`);
const deviceId = dev.data?.device?.id;

// --- 5. Rules PUT + Redis publish on child channel ---
const rulesPromise = nextMessage(`child:${sam.id}:rules`);
const rulesBody = {
  screenTime: { dailyLimitMinutes: 120, weekendLimitMinutes: 180, bedtimeStart: "20:30", bedtimeEnd: "07:00", schoolHours: { start: "08:00", end: "15:00", days: [1, 2, 3, 4, 5] } },
  webFilter: { blockedCategories: ["gambling"], allowedDomains: ["wikipedia.org"], blockedDomains: ["bad.example"], safeSearchEnforced: true },
  appRules: [{ packageId: "com.minecraft", appName: "Minecraft", action: "time_limit", dailyLimitMinutes: 45 }],
  routines: [{ name: "Homework", startTime: "16:00", endTime: "18:00", days: [1, 2, 3, 4, 5], blockedApps: ["com.youtube"], allowedApps: [] }],
};
const putRules = await call("PUT", `/v1/rules/${sam.id}`, { token, body: rulesBody });
check("PUT rules -> 200 with nested shape", putRules.status === 200 && putRules.data?.screenTime?.dailyLimitMinutes === 120, `got ${putRules.status}`);
const publishedRules = await rulesPromise;
check("rules published to Redis child channel", publishedRules?.screenTime?.dailyLimitMinutes === 120);

const overlap = await call("PUT", `/v1/rules/${sam.id}`, { token, body: { ...rulesBody, screenTime: { ...rulesBody.screenTime, bedtimeStart: "09:00", bedtimeEnd: "12:00" } } });
check("overlapping bedtime/school window -> 400", overlap.status === 400, `got ${overlap.status}`);
await call("PUT", `/v1/rules/${sam.id}`, { token, body: rulesBody }); // restore

const gotRules = await call("GET", `/v1/rules/${sam.id}`, { token });
check("GET rules round-trips", gotRules.status === 200 && gotRules.data?.webFilter?.blockedDomains?.includes("bad.example"));

const fanout = await call("GET", `/v1/devices/${deviceId}/commands`, { token });
check("rules write fans rules_updated out to devices", fanout.status === 200 && Array.isArray(fanout.data) && fanout.data.some((c) => c.type === "rules_updated"));

// --- 6. HMAC location ping + geofence transitions (own throwaway fence on Sam, erased at the end) ---
const fenceRes = await call("POST", "/v1/location/geofences", { token, body: { childId: sam.id, label: "E2E Fence", lat: 40.0, lng: -74.0, radiusM: 200, notifyOnEnter: true, notifyOnExit: true } });
check("create geofence -> 201", fenceRes.status === 201, `got ${fenceRes.status}`);
const far = { lat: 40.6, lng: -73.4 };
const at = { lat: 40.0, lng: -74.0 };
const pingFar = await call("POST", "/v1/location/ping", { hmac: true, body: { childId: sam.id, deviceId, lat: far.lat, lng: far.lng, accuracyM: 10 } });
check("HMAC location ping (outside) -> 201", pingFar.status === 201, `got ${pingFar.status} ${JSON.stringify(pingFar.data)}`);
await new Promise((r) => setTimeout(r, 300));
const pingAt = await call("POST", "/v1/location/ping", { hmac: true, body: { childId: sam.id, deviceId, lat: at.lat, lng: at.lng, accuracyM: 5 } });
check("HMAC location ping (inside fence) -> 201", pingAt.status === 201, `got ${pingAt.status}`);
await new Promise((r) => setTimeout(r, 300));

const geoAlerts = await call("GET", `/v1/alerts?category=geofence&limit=10`, { token });
check("geofence enter/exit alerts raised", geoAlerts.status === 200 && (geoAlerts.data?.meta?.total ?? 0) >= 1, `total=${geoAlerts.data?.meta?.total}`);

// --- 7. HMAC internal alert -> WebSocket delivery to parent ---
const ticketRes = await call("POST", "/v1/ws-ticket", { token });
check("WS ticket issued", ticketRes.status === 200 && !!ticketRes.data?.ticket);
const wsUrl = `${API.replace(/^http/, "ws")}/v1/ws?ticket=${encodeURIComponent(ticketRes.data.ticket)}`;
const ws = new WebSocket(wsUrl);
const wsMessage = new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error("ws timeout")), 8000);
  ws.addEventListener("message", (ev) => { clearTimeout(timer); resolve(JSON.parse(ev.data)); });
  ws.addEventListener("error", reject);
});
await new Promise((res, rej) => { ws.addEventListener("open", res); ws.addEventListener("error", rej); });
check("parent WebSocket connected", ws.readyState === 1);

const internal = await call("POST", "/v1/alerts/internal", { hmac: true, body: { childId: sam.id, deviceId, severity: "critical", category: "grooming", title: "E2E alert", body: "simulated AI concern", metadata: { source: "e2e" } } });
check("HMAC internal alert -> 201", internal.status === 201, `got ${internal.status}`);
const evt = await wsMessage;
check("WebSocket delivered {type:alert}", evt?.type === "alert" && evt?.payload?.title === "E2E alert", JSON.stringify(evt).slice(0, 120));
ws.close();

const badSig = await call("POST", "/v1/alerts/internal", { body: { childId: sam.id, severity: "info", category: "sos", title: "x", body: "y" } });
check("internal alert without HMAC -> 401", badSig.status === 401, `got ${badSig.status}`);

const list = await call("GET", "/v1/alerts?ack=false&limit=5", { token });
check("alerts list uses {items,meta} envelope", list.status === 200 && Array.isArray(list.data?.items) && typeof list.data?.meta?.total === "number");
const ackTarget = list.data.items.find((a) => a.title === "E2E alert");
const ack = await call("POST", `/v1/alerts/${ackTarget.id}/ack`, { token });
check("acknowledge alert", ack.status === 200 && ack.data?.alert?.acknowledged === true);

// --- 8. Device command queue (pub/sub + polled drain) ---
const cmdSub = nextMessage(`device:${deviceId}:commands`);
const cmd = await call("POST", `/v1/devices/${deviceId}/command`, { token, body: { command: "ring" } });
check("POST command -> published", cmd.status === 200 && cmd.data?.type === "ring");
const pubMsg = await cmdSub;
check("command on Redis pub/sub {type}", pubMsg?.type === "ring");
const drained = await call("GET", `/v1/devices/${deviceId}/commands`, { token });
check("GET commands drains queue [{type,payload}]", drained.status === 200 && Array.isArray(drained.data) && drained.data[0]?.type === "ring");
const drainedAgain = await call("GET", `/v1/devices/${deviceId}/commands`, { token });
check("command queue is consumed", drainedAgain.data.length === 0);

const pauseCmd = await call("POST", `/v1/devices/${deviceId}/command`, { token, body: { command: "pause" } });
const pauseDrain = await call("GET", `/v1/devices/${deviceId}/commands`, { token });
check("pause command accepted and queued", pauseCmd.status === 200 && pauseDrain.data.some((c) => c.type === "pause"));

// --- 9. Telemetry ---
const tel = await call("POST", `/v1/devices/${deviceId}/telemetry`, { token, body: { batteryPct: 77, appUsage: [{ packageId: "com.minecraft", minutes: 12 }] } });
check("POST telemetry -> 202", tel.status === 202, `got ${tel.status}`);
const devGet = await call("GET", `/v1/devices/${deviceId}`, { token });
check("GET device merges telemetry", devGet.status === 200 && devGet.data?.telemetry?.batteryPct === 77);

// --- 10. Cross-family isolation ---
// Fixed email + login fallback: re-runs must not mint a new family every time.
let reg2 = await call("POST", "/v1/auth/register", { body: { email: "e2e-crossfamily@example.com", password: "AnotherCorrectHorse!", displayName: "Eve", familyName: "Other Family", region: "EU" } });
if (reg2.status === 409) reg2 = await call("POST", "/v1/auth/login", { body: { email: "e2e-crossfamily@example.com", password: "AnotherCorrectHorse!" } });
check("second family register/login -> token", (reg2.status === 201 || reg2.status === 200) && !!reg2.data?.token, `got ${reg2.status}`);
const token2 = reg2.data.token;
const crossChild = await call("GET", `/v1/family/children/${sam.id}`, { token: token2 });
check("cross-family child access -> 403", crossChild.status === 403, `got ${crossChild.status}`);
const crossRules = await call("GET", `/v1/rules/${sam.id}`, { token: token2 });
check("cross-family rules access -> 403", crossRules.status === 403, `got ${crossRules.status}`);
const crossDevice = await call("POST", `/v1/devices/${deviceId}/command`, { token: token2, body: { command: "lock" } });
check("cross-family device command -> 403", crossDevice.status === 403, `got ${crossDevice.status}`);

// --- 11. World-class spot checks (blocklists, bonus, social AI vault, invites, reports) ---
const bl = await call("GET", "/v1/blocklists", { token });
check("blocklist pack serves 13 categories", bl.status === 200 && bl.data?.categories?.length === 13 && bl.data.categories.every((c) => c.domains.length > 0));

const bonus = await call("POST", `/v1/controls/children/${sam.id}/bonus`, { token, body: { minutes: 15 } });
check("bonus time grants + queues command", bonus.status === 200 && bonus.data?.bonusMinutesToday >= 15, `got ${bonus.status}`);
const rulesAfterBonus = await call("GET", `/v1/rules/${sam.id}`, { token });
check("rules payload carries bonusMinutesToday", (rulesAfterBonus.data?.bonusMinutesToday ?? 0) >= 15);

const scan = await call("POST", "/v1/social/scan", { hmac: true, body: { childId: sam.id, deviceId, app: "whatsapp", contact: "Unknown", text: "seriously just kill yourself already" } });
check("social AI scan flags self-harm (fail-open path)", scan.status === 200 && scan.data?.flagged === true, `got ${scan.status} ${JSON.stringify(scan.data)}`);
const events = await call("GET", `/v1/social/events?childId=${sam.id}`, { token });
check("vault stores decrypted concern event", events.status === 200 && events.data?.items?.some((e) => e.app === "whatsapp" && e.preview.length > 0));

const invite = await call("POST", "/v1/family/invites", { token, body: { email: "coparent@example.com", role: "co-parent", permissions: ["rules", "alerts"] } });
check("multi-parent invite created with accept token", invite.status === 201 && !!invite.data?.acceptToken, `got ${invite.status}`);
if (invite.data?.invite?.id) await call("DELETE", `/v1/family/invites/${invite.data.invite.id}`, { token });

const summary = await call("GET", `/v1/reports/summary?childId=${sam.id}&days=7`, { token });
check("reports summary endpoint live", summary.status === 200 && typeof summary.data?.totalAppMinutes === "number");

const windDown = await call("POST", `/v1/controls/children/${sam.id}/wind-down`, { token, body: { minutes: 15 } });
check("wind-down command accepted", windDown.status === 200);

const wkPause = await call("POST", `/v1/controls/children/${sam.id}/pause`, { token });
const wkStatus = await call("GET", `/v1/controls/children/${sam.id}/status`, { token });
check("pause internet status reflects", wkPause.status === 200 && wkStatus.data?.paused === true);
await call("POST", `/v1/controls/children/${sam.id}/resume`, { token });

// --- 11b. Token hygiene live: per-device HMAC (item 5) + device revocation (item 4) ---
const CODE2 = (await call("POST", "/v1/devices/pair", { token, body: { childId: sam.id } })).data?.code;
const CLAIM2 = await call("POST", "/v1/devices/pair/claim", { body: { code: CODE2, platform: "android", model: "HygienePhone", osVersion: "14" } });
const devSecret = CLAIM2.data?.hmacSecret;
const dev2 = CLAIM2.data?.device?.id;
check("pair/claim mints a per-device HMAC secret", CLAIM2.status === 201 && typeof devSecret === "string" && devSecret.length === 64);
const bodyWithDev = JSON.stringify({ childId: sam.id, deviceId: dev2, severity: "info", category: "web_threat", title: "hygiene", body: "x", metadata: {} });
const devSign = createHmac("sha256", devSecret).update(bodyWithDev).digest("hex");
check("alert signed with the DEVICE secret -> 201", (await fetch(`${API}/v1/alerts/internal`, { method: "POST", headers: { "content-type": "application/json", "x-familyshield-signature": devSign }, body: bodyWithDev })).status === 201);
const globalSign = createHmac("sha256", HMAC_SECRET).update(bodyWithDev).digest("hex");
check("same alert with the GLOBAL secret -> 401 (per-device isolation)", (await fetch(`${API}/v1/alerts/internal`, { method: "POST", headers: { "content-type": "application/json", "x-familyshield-signature": globalSign }, body: bodyWithDev })).status === 401);
const delDev2 = await call("DELETE", `/v1/devices/${dev2}`, { token });
check("unpair device -> success", delDev2.status === 200);
const revokedUse = await call("GET", `/v1/devices/${dev2}`, { token: CLAIM2.data.token });
check("unpaired device's JWT is revoked (401)", revokedUse.status === 401);

// --- 12. GDPR export + erasure ---
const exp = await call("GET", "/v1/family/export", { token });
check("GDPR export downloads JSON", exp.status === 200 && !!exp.data?.family?.children);
const erased = await call("DELETE", `/v1/family/children/${sam.id}`, { token });
check("GDPR erasure cascade", erased.status === 200 && erased.data?.erased === true);

redis.disconnect();
console.log(`\n=== E2E: ${PASS.length} passed, ${FAIL.length} failed ===`);
if (FAIL.length) { console.log("failures:", FAIL.join("; ")); process.exit(1); }
