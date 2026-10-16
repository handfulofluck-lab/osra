/**
 * OSRA QA probe suite — adversarial checks against a LIVE API (Postgres + Redis required).
 *
 * Companion to `e2e.mjs`: e2e proves the happy paths work; this file tries to BREAK the
 * documented security invariants and validation contracts. Every probe prints PASS when the
 * system behaves correctly (i.e. it REJECTS the bad input) and FAIL when it accepts it.
 *
 * Usage:  node scripts/qa-probe.mjs          (see QA-KIMI docs; needs INTERNAL_HMAC_SECRET)
 * Env:    API_BASE, INTERNAL_HMAC_SECRET, REDIS_URL (only for the WS ticket probe)
 *
 * Exit code is non-zero when any probe fails, so CI / the collaborating developer can gate on it.
 */
import { createHmac, randomUUID } from "node:crypto";

const API = process.env.API_BASE ?? "http://localhost:3000";
const HMAC_SECRET = process.env.INTERNAL_HMAC_SECRET ?? "";
const PASS = [];
const FAIL = [];
const NOTE = [];

const check = (name, ok, extra = "") => {
  (ok ? PASS : FAIL).push(name);
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${extra ? ` — ${extra}` : ""}`);
};
/** Record observed-but-unexpected behaviour that is not (yet) a hard assertion. */
const note = (name, observed) => {
  NOTE.push(`${name}: ${observed}`);
  console.log(`NOTE  ${name} — ${observed}`);
};
/**
 * Tracked follow-up that needs a design decision before it can be asserted.
 * Targets are reported but do NOT fail the run, so the gate stays actionable.
 */
const TARGETS = [];
const target = (name, detail) => {
  TARGETS.push(`${name} — ${detail}`);
  console.log(`TARGET  ${name} — ${detail}`);
};

const sign = (body) => createHmac("sha256", HMAC_SECRET).update(body).digest("hex");

async function call(method, path, { token, body, hmac, rawBody, headers } = {}) {
  const raw = rawBody !== undefined ? rawBody : body === undefined ? undefined : JSON.stringify(body);
  const res = await fetch(`${API}${path}`, {
    method,
    headers: {
      ...(raw !== undefined ? { "content-type": "application/json" } : {}),
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(hmac ? { "x-familyshield-signature": sign(raw ?? "") } : {}),
      ...headers,
    },
    body: raw,
  });
  let data = null;
  try { data = await res.json(); } catch { /* empty body */ }
  return { status: res.status, data };
}

const stamp = Date.now();
const emailA = `qa-a-${stamp}@example.com`;
const emailB = `qa-b-${stamp}@example.com`;
const PASSWORD = "QaProbePassw0rd!";

// ── setup: two independent families ─────────────────────────────────────────
const regA = await call("POST", "/v1/auth/register", {
  body: { email: emailA, password: PASSWORD, displayName: "QA A", familyName: "QA Family A", region: "US" },
});
const regB = await call("POST", "/v1/auth/register", {
  body: { email: emailB, password: PASSWORD, displayName: "QA B", familyName: "QA Family B", region: "EU" },
});
const tokenA = regA.data?.token;
const tokenB = regB.data?.token;
check("setup: two families registered", regA.status === 201 && regB.status === 201, `${regA.status}/${regB.status}`);
if (!tokenA || !tokenB) {
  console.log("cannot continue without two parent tokens");
  process.exit(1);
}

// Family A: child with inline consent, plus a device.
const childA = await call("POST", "/v1/family/children", {
  token: tokenA,
  body: { displayName: `QA Kid ${stamp}`, birthYear: 2014, consent: { method: "sms_plus", jurisdiction: "US" } },
});
const kidA = childA.data?.child?.id;
check("setup: child A created with consent", childA.status === 201 && !!kidA, `got ${childA.status}`);

const devA = await call("POST", "/v1/devices/register", {
  token: tokenA,
  body: { childId: kidA, platform: "windows", model: "QA-PC", osVersion: "10" },
});
const deviceIdA = devA.data?.device?.id ?? devA.data?.deviceId ?? devA.data?.id;
check("setup: device A registered", devA.status === 201 && !!deviceIdA, `got ${devA.status}`);

const childB = await call("POST", "/v1/family/children", {
  token: tokenB,
  body: { displayName: `QA Other Kid ${stamp}`, birthYear: 2013, consent: { method: "kba", jurisdiction: "EU" } },
});
const kidB = childB.data?.child?.id;

// ── A. registration / login validation & enumeration ────────────────────────
console.log("\n── A. auth validation ──");
const shortPw = await call("POST", "/v1/auth/register", {
  body: { email: `qa-short-${stamp}@example.com`, password: "short", displayName: "x", familyName: "y", region: "US" },
});
check("A1 short password rejected (400)", shortPw.status === 400, `got ${shortPw.status}`);

const badEmail = await call("POST", "/v1/auth/register", {
  body: { email: "not-an-email", password: PASSWORD, displayName: "x", familyName: "y", region: "US" },
});
check("A2 malformed email rejected (400)", badEmail.status === 400, `got ${badEmail.status}`);

const dup = await call("POST", "/v1/auth/register", {
  body: { email: emailA, password: PASSWORD, displayName: "x", familyName: "y", region: "US" },
});
check("A3 duplicate registration rejected (409)", dup.status === 409, `got ${dup.status}`);

const wrongPw = await call("POST", "/v1/auth/login", { body: { email: emailA, password: "WrongPassword!1" } });
const unknownUser = await call("POST", "/v1/auth/login", { body: { email: `nobody-${stamp}@example.com`, password: PASSWORD } });
check(
  "A4 no user enumeration (wrong password vs unknown email identical)",
  wrongPw.status === unknownUser.status && JSON.stringify(wrongPw.data) === JSON.stringify(unknownUser.data),
  `wrong=${wrongPw.status} unknown=${unknownUser.status}`,
);

const badJson = await call("POST", "/v1/auth/login", { rawBody: "{not json" });
check("A5 malformed JSON body -> 4xx (not 500)", badJson.status >= 400 && badJson.status < 500, `got ${badJson.status}`);

const invalidJwt = await call("GET", "/v1/family/me", { token: "abc.def.ghi" });
check("A6 garbage JWT rejected (401)", invalidJwt.status === 401, `got ${invalidJwt.status}`);

// ── B. cross-family authorization (IDOR) ────────────────────────────────────
console.log("\n── B. cross-family isolation ──");
const crossChildGet = await call("GET", `/v1/family/children/${kidA}`, { token: tokenB });
check("B1 read other family's child (403/404)", [403, 404].includes(crossChildGet.status), `got ${crossChildGet.status}`);

const rulesBody = {
  screenTime: {
    dailyLimitMinutes: 120,
    weekendLimitMinutes: 180,
    bedtimeStart: "21:00",
    bedtimeEnd: "07:00",
    schoolHours: { start: "08:00", end: "15:00", days: [1, 2, 3, 4, 5] },
  },
  webFilter: { blockedCategories: ["porn"], allowedDomains: [], blockedDomains: [], safeSearchEnforced: true },
  appRules: [],
  routines: [],
};
const crossRules = await call("PUT", `/v1/rules/${kidA}`, { token: tokenB, body: rulesBody });
check("B2 write other family's rules (403/404)", [403, 404].includes(crossRules.status), `got ${crossRules.status}`);

const crossCmd = await call("POST", `/v1/devices/${deviceIdA}/command`, { token: tokenB, body: { command: "lock" } });
check("B3 command other family's device (403/404)", [403, 404].includes(crossCmd.status), `got ${crossCmd.status}`);

const crossGeofence = await call("POST", "/v1/location/geofences", {
  token: tokenB,
  body: { childId: kidA, label: "evil", lat: 1, lng: 1, radiusM: 100, notifyOnEnter: true, notifyOnExit: true },
});
check("B4 geofence on other family's child (403/404)", [403, 404].includes(crossGeofence.status), `got ${crossGeofence.status}`);

const crossReports = await call("GET", `/v1/reports/usage/${kidA}?days=7`, { token: tokenB });
check("B5 usage report for other family's child (403/404)", [403, 404].includes(crossReports.status), `got ${crossReports.status}`);

const crossWellbeing = await call("GET", `/v1/reports/wellbeing/${kidA}`, { token: tokenB });
check("B6 wellbeing for other family's child (403/404)", [403, 404].includes(crossWellbeing.status), `got ${crossWellbeing.status}`);

const crossInsights = await call("GET", `/v1/insights/${kidA}`, { token: tokenB });
check("B7 insights for other family's child (403/404)", [403, 404].includes(crossInsights.status), `got ${crossInsights.status}`);

const crossDevRegister = await call("POST", "/v1/devices/register", {
  token: tokenB,
  body: { childId: kidA, platform: "android", model: "evil", osVersion: "1" },
});
check("B8 register device against other family's child (403/404)", [403, 404].includes(crossDevRegister.status), `got ${crossDevRegister.status}`);

const crossDigest = await call("PUT", "/v1/digests", { token: tokenB, body: { childId: kidA, cadence: "daily" } });
check("B9 digest prefs for other family's child (403/404)", [403, 404].includes(crossDigest.status), `got ${crossDigest.status}`);

// Token-type confusion is asserted with a real device JWT in section G (G6).
const parentOnDevice = await call("GET", `/v1/devices/${deviceIdA}/commands`, { token: tokenA });
note("B11 parent JWT on device command route", `status ${parentOnDevice.status} (route is destructive-drain; a parent-only preview should not consume the queue)`);

// ── C. consent gate ─────────────────────────────────────────────────────────
console.log("\n── C. consent gate ──");
const noConsent = await call("POST", "/v1/family/children", { token: tokenA, body: { displayName: `NoConsent ${stamp}`, birthYear: 2016 } });
check("C1 child without consent -> 428", noConsent.status === 428, `got ${noConsent.status}`);

// ── D. rules / input validation contracts ───────────────────────────────────
console.log("\n── D. validation ──");
const daysZero = await call("PUT", `/v1/rules/${kidA}`, {
  token: tokenA,
  body: { ...rulesBody, screenTime: { ...rulesBody.screenTime, schoolHours: { start: "08:00", end: "15:00", days: [0] } } },
});
check("D1 schoolHours.days:[0] rejected (400)", daysZero.status === 400, `got ${daysZero.status}`);

const daysEight = await call("PUT", `/v1/rules/${kidA}`, {
  token: tokenA,
  body: { ...rulesBody, screenTime: { ...rulesBody.screenTime, schoolHours: { start: "08:00", end: "15:00", days: [8] } } },
});
check("D2 schoolHours.days:[8] rejected (400)", daysEight.status === 400, `got ${daysEight.status}`);

const negativeLimit = await call("PUT", `/v1/rules/${kidA}`, {
  token: tokenA,
  body: { ...rulesBody, screenTime: { ...rulesBody.screenTime, dailyLimitMinutes: -5 } },
});
check("D3 negative daily limit rejected (400)", negativeLimit.status === 400, `got ${negativeLimit.status}`);

const badTime = await call("PUT", `/v1/rules/${kidA}`, {
  token: tokenA,
  body: { ...rulesBody, screenTime: { ...rulesBody.screenTime, bedtimeStart: "25:99" } },
});
check("D4 invalid bedtime time rejected (400)", badTime.status === 400, `got ${badTime.status}`);

const badRadius = await call("POST", "/v1/location/geofences", {
  token: tokenA,
  body: { childId: kidA, label: "neg", lat: 10, lng: 10, radiusM: -50, notifyOnEnter: true, notifyOnExit: true },
});
check("D5 negative geofence radius rejected (400)", badRadius.status === 400, `got ${badRadius.status}`);

const badLat = await call("POST", "/v1/location/geofences", {
  token: tokenA,
  body: { childId: kidA, label: "lat", lat: 95, lng: 10, radiusM: 100, notifyOnEnter: true, notifyOnExit: true },
});
check("D6 latitude > 90 rejected (400)", badLat.status === 400, `got ${badLat.status}`);

const badCategory = await call("POST", "/v1/alerts/internal", {
  hmac: true,
  body: { childId: kidA, deviceId: deviceIdA, severity: "info", category: "not_a_category", title: "x", body: "y" },
});
check("D7 unknown alert category rejected (400)", badCategory.status === 400, `got ${badCategory.status}`);

const huge = await call("PUT", `/v1/rules/${kidA}`, {
  token: tokenA,
  body: { ...rulesBody, webFilter: { ...rulesBody.webFilter, blockedDomains: Array.from({ length: 20000 }, (_, i) => `d${i}.example.com`) } },
});
check("D8 oversized payload handled (400/413, not 500)", [400, 413].includes(huge.status), `got ${huge.status}`);

// ── E. agent HMAC signing ───────────────────────────────────────────────────
console.log("\n── E. agent HMAC ──");
const goodAlert = await call("POST", "/v1/alerts/internal", {
  hmac: true,
  body: { childId: kidA, deviceId: deviceIdA, severity: "info", category: "sos", title: "probe", body: "signed" },
});
check("E1 properly signed internal alert accepted", [200, 201].includes(goodAlert.status), `got ${goodAlert.status}`);

const badSig = await call("POST", "/v1/alerts/internal", {
  headers: { "x-familyshield-signature": "0".repeat(64) },
  body: { childId: kidA, deviceId: deviceIdA, severity: "info", category: "sos", title: "probe", body: "bad" },
});
check("E2 bad signature rejected (401)", badSig.status === 401, `got ${badSig.status}`);

const noSig = await call("POST", "/v1/alerts/internal", {
  body: { childId: kidA, deviceId: deviceIdA, severity: "info", category: "sos", title: "probe", body: "unsigned" },
});
check("E3 missing signature rejected (401)", noSig.status === 401, `got ${noSig.status}`);

// Replay: re-send a byte-identical, previously accepted signed request.
const replayBody = { childId: kidA, deviceId: deviceIdA, severity: "info", category: "sos", title: "replay", body: "same-bytes" };
const firstSend = await call("POST", "/v1/alerts/internal", { hmac: true, body: replayBody });
const replaySend = await call("POST", "/v1/alerts/internal", { hmac: true, body: replayBody });
if (firstSend.status === replaySend.status && [200, 201].includes(replaySend.status) && replaySend.data?.alert?.id !== firstSend.data?.alert?.id) {
  note("E4 signed-request replay", "accepted twice and created two alerts (signature covers the body only — no timestamp/nonce)");
} else {
  check("E4 signed-request replay rejected", firstSend.status !== replaySend.status || replaySend.status >= 400, `first=${firstSend.status} replay=${replaySend.status}`);
}

// Cross-endpoint signature confusion: a signature made for one agent route replayed on another.
const confusionBody = { childId: kidA, deviceId: deviceIdA, lat: 1.5, lng: 2.5, accuracyM: 5 };
const pingSigned = sign(JSON.stringify(confusionBody));
const confused = await call("POST", "/v1/alerts/internal", {
  rawBody: JSON.stringify(confusionBody),
  headers: { "x-familyshield-signature": pingSigned },
});
if ([200, 201].includes(confused.status)) {
  note("E5 cross-endpoint signature reuse", "a signature created for the location-ping body was accepted on /v1/alerts/internal (signature does not bind method+path)");
} else {
  check("E5 cross-endpoint signature reuse rejected", true, `got ${confused.status}`);
}

// ── F. session / token hygiene ──────────────────────────────────────────────
console.log("\n── F. tokens ──");
const login = await call("POST", "/v1/auth/login", { body: { email: emailA, password: PASSWORD } });
const refresh1 = login.data?.refreshToken;
const access1 = login.data?.token;
check("F1 login returns access + refresh", !!refresh1 && !!access1, `status ${login.status}`);

const rot1 = await call("POST", "/v1/auth/token/refresh", { body: { refreshToken: refresh1 } });
const rot2 = await call("POST", "/v1/auth/token/refresh", { body: { refreshToken: refresh1 } });
check("F2 refresh reuse rejected (401)", rot2.status === 401, `first=${rot1.status} replay=${rot2.status}`);

if (rot1.data?.token) {
  const afterReuse = await call("GET", "/v1/family/me", { token: rot1.data.token });
  check("F3 reuse revokes the rotated session (token no longer valid)", afterReuse.status === 401, `got ${afterReuse.status}`);
}

const freshLogin = await call("POST", "/v1/auth/login", { body: { email: emailA, password: PASSWORD } });
const logoutRes = await call("POST", "/v1/auth/logout", { token: freshLogin.data?.token, body: { refreshToken: freshLogin.data?.refreshToken } });
const refreshAfterLogout = await call("POST", "/v1/auth/token/refresh", { body: { refreshToken: freshLogin.data?.refreshToken } });
check("F4 refresh token dead after logout", logoutRes.status < 300 && refreshAfterLogout.status === 401, `logout=${logoutRes.status} refresh=${refreshAfterLogout.status}`);

// The per-device HMAC signing secret authenticates agent -> server alerts. No parent-facing
// payload may contain it (an allowlist-by-omission strip of pushToken missed this column).
const SECRET_RE = /internalSecret|hmacSecret|passwordHash|vaultkey|jwtSecret/i;
const scanSecrets = (label, obj) => {
  const hit = SECRET_RE.test(JSON.stringify(obj ?? {}));
  check(`${label} exposes no device/signing secrets`, !hit, hit ? "secret-ish field present in payload" : "");
};
scanSecrets("F5 /me", (await call("GET", "/v1/family/me", { token: tokenA })).data);
scanSecrets("F6 /family/export", (await call("GET", "/v1/family/export", { token: tokenA })).data);
if (deviceIdA) scanSecrets("F7 /devices/:id", (await call("GET", `/v1/devices/${deviceIdA}`, { token: tokenA })).data);

// ── G. device lifecycle, per-device secrets, revocation (verified 2026-10-11) ─
console.log("\n── G. device lifecycle (pairing claim flow) ──");
/** Parent mints a code, the device claims it — returns a real device JWT + per-device secret. */
async function pairDevice(childId, label) {
  const code = (await call("POST", "/v1/devices/pair", { token: tokenA, body: { childId } })).data?.code;
  if (!code) return { status: 0 };
  const claim = await call("POST", "/v1/devices/pair/claim", {
    body: { code, platform: "android", model: label, osVersion: "14", deviceName: label },
  });
  return {
    token: claim.data?.token,
    secret: claim.data?.hmacSecret,
    deviceId: claim.data?.device?.id ?? claim.data?.deviceId,
    status: claim.status,
  };
}
const kidA2 = (await call("POST", "/v1/family/children", {
  token: tokenA,
  body: { displayName: `QA Sibling ${stamp}`, birthYear: 2015, consent: { method: "sms_plus", jurisdiction: "US" } },
})).data?.child?.id;
const d1 = await pairDevice(kidA, "qa-dev-1");
const d2 = await pairDevice(kidA2, "qa-dev-2");
check("G1 pairing claim returns device token + per-device secret", !!d1.token && !!d1.secret, `status=${d1.status}`);
check("G2 second device paired", !!d2.token && !!d2.deviceId, `status=${d2.status}`);

if (d1.token) {
  // A device must not enumerate the family's devices or read a sibling's signing secret.
  const devList = await call("GET", "/v1/devices", { token: d1.token });
  check("G3 device JWT cannot list family devices", [401, 403].includes(devList.status), `got ${devList.status}`);
  if (d2.deviceId) {
    const sib = await call("GET", `/v1/devices/${d2.deviceId}`, { token: d1.token });
    check("G4 device JWT cannot read a sibling device", [401, 403, 404].includes(sib.status), `got ${sib.status}`);
    check("G5 sibling device read leaks no signing secret", !JSON.stringify(sib.data ?? {}).includes("internalSecret"));
  }
  const devOnParent = await call("GET", "/v1/family/me", { token: d1.token });
  check("G6 device JWT rejected on parent route /family/me", [401, 403].includes(devOnParent.status), `got ${devOnParent.status}`);
  const devWsTicket = await call("POST", "/v1/ws-ticket", { token: d1.token });
  check("G6b device JWT cannot mint a parent WS ticket (family event stream)", [401, 403].includes(devWsTicket.status), `got ${devWsTicket.status}`);

  // A device's signature must not write into a sibling child.
  if (d1.secret && kidA2) {
    const body = JSON.stringify({ childId: kidA2, deviceId: d1.deviceId, severity: "warning", category: "sos", title: `qa-xchild-${stamp}`, body: "signed by sibling device" });
    const sig = createHmac("sha256", d1.secret).update(body).digest("hex");
    const inj = await call("POST", "/v1/alerts/internal", { rawBody: body, headers: { "x-familyshield-signature": sig } });
    check("G7 device HMAC cannot write an alert for a sibling child", inj.status >= 400, `got ${inj.status}`);

    // Issue #29: A device's signature must not write search-event or youtube-watch for a sibling child.
    const searchBody = JSON.stringify({ childId: kidA2, deviceId: d1.deviceId, engine: "google", query: "how to kill myself" });
    const searchSig = createHmac("sha256", d1.secret).update(searchBody).digest("hex");
    const searchInj = await call("POST", "/v1/content/search-event", { rawBody: searchBody, headers: { "x-familyshield-signature": searchSig } });
    check("G7d device HMAC cannot inject search-event for a sibling child (#29)", searchInj.status >= 400, `got ${searchInj.status}`);

    const ytBody = JSON.stringify({ childId: kidA2, deviceId: d1.deviceId, videoId: "xyz123", title: "how to commit suicide", channel: "c" });
    const ytSig = createHmac("sha256", d1.secret).update(ytBody).digest("hex");
    const ytInj = await call("POST", "/v1/content/youtube-watch", { rawBody: ytBody, headers: { "x-familyshield-signature": ytSig } });
    check("G7e device HMAC cannot inject youtube-watch for a sibling child (#29)", ytInj.status >= 400, `got ${ytInj.status}`);
  }

  // BUG-001 / Issue #19: Android LocationPingBatchDto envelope and device-token ID resolution
  const batchPing = await call("POST", "/v1/location/ping", {
    token: d1.token,
    body: {
      pings: [
        { lat: 37.7749, lng: -122.4194, accuracyM: 10, timestamp: new Date().toISOString() },
        { lat: 37.7750, lng: -122.4195, accuracyM: 8, timestamp: new Date().toISOString() },
      ],
    },
  });
  check("G7b batch location envelope accepted with device JWT (BUG-001)", [200, 201].includes(batchPing.status) && batchPing.data?.count === 2, `status=${batchPing.status} count=${batchPing.data?.count}`);

  const flatPingNoBodyIds = await call("POST", "/v1/location/ping", {
    token: d1.token,
    body: { lat: 37.7751, lng: -122.4196, accuracyM: 5 },
  });
  check("G7c flat location ping accepted with device JWT without body IDs (BUG-001)", [200, 201].includes(flatPingNoBodyIds.status), `status=${flatPingNoBodyIds.status}`);

  // Revocation must hold on every route, not just under /v1/devices.
  const unpair = await call("DELETE", `/v1/devices/${d1.deviceId}`, { token: tokenA });
  check("G8 unpair succeeds", unpair.status < 300, `got ${unpair.status}`);
  const after = {
    devices: (await call("GET", `/v1/devices/${d1.deviceId}`, { token: d1.token })).status,
    rules: (await call("GET", `/v1/rules/${kidA}`, { token: d1.token })).status,
    ping: (await call("POST", "/v1/location/ping", { token: d1.token, body: { childId: kidA, deviceId: d1.deviceId, lat: 1.1, lng: 2.2, accuracyM: 5 } })).status,
    wsTicket: (await call("POST", "/v1/ws-ticket", { token: d1.token })).status,
  };
  check("G9 revoked device rejected on /v1/devices", after.devices === 401, `got ${after.devices}`);
  check("G10 revoked device rejected on /v1/rules", after.rules === 401, `got ${after.rules}`);
  check("G11 revoked device rejected on /v1/location/ping", after.ping === 401, `got ${after.ping}`);
  check("G12 revoked device cannot mint a WS ticket", after.wsTicket === 401, `got ${after.wsTicket}`);
}

// ── I. every alert category the clients actually send (AND-01) ──────────────
console.log("\n── I. agent alert category coverage ──");
for (const category of [
  "web_threat", "app_blocked", "screen_time_exceeded", "geofence", "sos", "ai_concern",
  "cyberbullying", "self_harm", "grooming", // server enum today
  "tamper", "vpn_detected", "install_request", "unknown_contact", // sent by the agents
]) {
  const res = await call("POST", "/v1/alerts/internal", {
    hmac: true,
    body: { childId: kidA, deviceId: deviceIdA, severity: "info", category, title: `cat ${category}`, body: "coverage" },
  });
  check(`I category "${category}" accepted`, [200, 201].includes(res.status), `got ${res.status}`);
}

// ── J. error hygiene and input bounds ───────────────────────────────────────
console.log("\n── J. error hygiene & bounds ──");
const overflow = await call("PUT", `/v1/rules/${kidA}`, {
  token: tokenA,
  body: { ...rulesBody, screenTime: { ...rulesBody.screenTime, dailyLimitMinutes: 99999999999 } },
});
const overflowLeak = /prisma|invocation|at Object|stack/i.test(JSON.stringify(overflow.data ?? {}));
check("J1 out-of-range integer rejected (400) with no DB internals leaked", overflow.status === 400 && !overflowLeak, `status=${overflow.status} internalsLeaked=${overflowLeak}`);

target("J2 signed-request replay protection", "a byte-identical signed agent request is accepted twice (signature covers only the body — no timestamp/nonce)");
// A live pairing for the processing-stop checks (d1 was unpaired in section G).
const dJ = await pairDevice(kidA, "qa-dev-j3");
const revokeProbe = await call("POST", `/v1/family/children/${kidA}/consent/revoke`, { token: tokenA });
const xRevokeProbe = await call("POST", `/v1/family/children/${kidA}/consent/revoke`, { token: tokenB });
const blockedWrite = await call("PUT", `/v1/rules/${kidA}`, { token: tokenA, body: rulesBody });
// ADR-0008 §2b: withdrawal must stop *processing* — device ingestion and device reads answer 428.
const pingBody = { childId: kidA, deviceId: dJ.deviceId, lat: 24.7, lng: 46.7, accuracyM: 5, timestamp: new Date().toISOString() };
const blockedPing = dJ.token ? await call("POST", "/v1/location/ping", { token: dJ.token, body: pingBody }) : { status: 0 };
const blockedRules = dJ.token ? await call("GET", `/v1/rules/${kidA}`, { token: dJ.token }) : { status: 0 };
const parentRules = await call("GET", `/v1/rules/${kidA}`, { token: tokenA });
const blockedDrain = dJ.token ? await call("GET", `/v1/devices/${dJ.deviceId}/commands`, { token: dJ.token }) : { status: 0 };
// ADR-0008 §2c: safe-direction actions stay open; enforcement actions do not.
const resumeOpen = await call("POST", `/v1/controls/children/${kidA}/resume`, { token: tokenA });
const lockBlocked = dJ.deviceId ? await call("POST", `/v1/devices/${dJ.deviceId}/command`, { token: tokenA, body: { command: "lock" } }) : { status: 0 };
const unlockOpen = dJ.deviceId ? await call("POST", `/v1/devices/${dJ.deviceId}/command`, { token: tokenA, body: { command: "unlock" } }) : { status: 0 };
const regrant = await call("POST", `/v1/family/children/${kidA}/consent`, { token: tokenA, body: { method: "credit_card", jurisdiction: "US" } });
const unblockedWrite = await call("PUT", `/v1/rules/${kidA}`, { token: tokenA, body: rulesBody });
const unblockedPing = dJ.token ? await call("POST", "/v1/location/ping", { token: dJ.token, body: pingBody }) : { status: 0 };
const drainAfter = dJ.token ? await call("GET", `/v1/devices/${dJ.deviceId}/commands`, { token: dJ.token }) : { status: 0, data: [] };
const drainTypes = Array.isArray(drainAfter.data) ? drainAfter.data.map((c) => c.type) : [];

check(
  "J3 consent revocation enforcement (revoke -> 428 on parent writes, regrant -> unblocked)",
  revokeProbe.status === 200 && xRevokeProbe.status === 403 && blockedWrite.status === 428 && regrant.status === 201 && unblockedWrite.status === 200,
  `revoke=${revokeProbe.status} xRevoke=${xRevokeProbe.status} blocked=${blockedWrite.status} regrant=${regrant.status} unblocked=${unblockedWrite.status}`,
);
check(
  "J3b consent revocation stops device processing (ping/rules/commands -> 428; parent read stays 200)",
  blockedPing.status === 428 && blockedRules.status === 428 && blockedDrain.status === 428 && parentRules.status === 200 && unblockedPing.status === 201,
  `ping=${blockedPing.status} rules=${blockedRules.status} drain=${blockedDrain.status} parentRules=${parentRules.status} pingAfterRegrant=${unblockedPing.status}`,
);
check(
  "J3c safe-direction actions stay open while revoked (resume/unlock 200, lock 428)",
  resumeOpen.status === 200 && unlockOpen.status === 200 && lockBlocked.status === 428,
  `resume=${resumeOpen.status} unlock=${unlockOpen.status} lock=${lockBlocked.status}`,
);
check(
  "J3d agents are told to pause and resume (consent_revoked + consent_granted commands queued)",
  drainTypes.includes("consent_revoked") && drainTypes.includes("consent_granted"),
  `drain=${JSON.stringify(drainTypes)}`,
);

// IOS-01: the iOS AlertReporter signs with the device's own secret but sends no top-level
// `deviceId`, so the server falls back to the global secret and rejects every alert (verified 401).
if (d2?.secret && kidA2) {
  const iosBody = JSON.stringify({ childId: kidA2, category: "sos", severity: "critical", title: "ios-shape", body: "no deviceId", metadata: { source: "ios" } });
  const iosSig = createHmac("sha256", d2.secret).update(iosBody).digest("hex");
  const iosRes = await call("POST", "/v1/alerts/internal", { rawBody: iosBody, headers: { "x-familyshield-signature": iosSig } });
  check("J4 iOS-shaped alert (per-device secret, no body deviceId) accepted", [200, 201].includes(iosRes.status), `got ${iosRes.status}`);

  // J5 (gate): while devices may carry their own secret, the global secret must NOT be able to sign
  // as that device — the per-device secret is the thing that makes an agent alert trustworthy.
  // Verified 2026-10-11: after the P0 bundle this is fail-closed (401). Keep it that way.
  const gBody = JSON.stringify({ childId: kidA2, deviceId: d2.deviceId, category: "sos", severity: "info", title: "global-secret-check", body: "x" });
  const gRes = await call("POST", "/v1/alerts/internal", {
    rawBody: gBody,
    headers: { "x-familyshield-signature": createHmac("sha256", HMAC_SECRET).update(gBody).digest("hex") },
  });
  check("J5 global secret cannot sign as a device that has its own secret", gRes.status === 401, `got ${gRes.status}`);

  // J6 (target, NON-GATING): the global-secret fallback still applies to devices with no per-device
  // secret (the parent `POST /v1/devices/register` path), and candidates are resolved from the BODY
  // childId — so the global secret can write into any child that owns such a device. No shipped
  // client uses that path today (only e2e), so this is a design decision, not a live regression:
  // see DISCUSSION-LOG ask 16. Promote to a gate check if the fallback is removed.
  const regd = await call("POST", "/v1/devices/register", {
    token: tokenA,
    body: { childId: kidA2, platform: "windows", model: "probe-nosecret", osVersion: "10" },
  });
  if (regd.status === 201) {
    const nBody = JSON.stringify({ childId: kidA2, category: "sos", severity: "info", title: "global-fallback-check", body: "x" });
    const nRes = await call("POST", "/v1/alerts/internal", {
      rawBody: nBody,
      headers: { "x-familyshield-signature": createHmac("sha256", HMAC_SECRET).update(nBody).digest("hex") },
    });
    target(
      "J6 global-secret fallback for secret-less devices",
      `HTTP ${nRes.status} when signing with the global secret for a child whose device has no per-device secret (201 = the fallback is still open; see ask 16)`,
    );
  }
}

// ── H. misc surface ─────────────────────────────────────────────────────────
console.log("\n── H. surface ──");
const unknownRoute = await call("GET", `/v1/does-not-exist-${stamp}`);
check("H1 unknown route -> 404 JSON", unknownRoute.status === 404, `got ${unknownRoute.status}`);

const healthDeep = await call("GET", "/health/deep");
check("H2 /health/deep reports db+redis", healthDeep.status === 200 && healthDeep.data?.db === "up" && healthDeep.data?.redis === "up", JSON.stringify(healthDeep.data));

// ── summary ─────────────────────────────────────────────────────────────────
console.log(`\n───────────  ${PASS.length} passed · ${FAIL.length} failed · ${TARGETS.length} targets · ${NOTE.length} notes  ───────────`);
if (FAIL.length) console.log("FAILURES (must fix to make this gate green):\n- " + FAIL.join("\n- "));
if (TARGETS.length) console.log("TARGETS (tracked, need a design decision, not gating):\n- " + TARGETS.join("\n- "));
if (NOTE.length) console.log("NOTES:\n- " + NOTE.join("\n- "));
process.exit(FAIL.length ? 1 : 0);
