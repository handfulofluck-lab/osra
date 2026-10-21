/**
 * OSRA QA probe suite — adversarial checks against a LIVE API (Postgres + Redis required).
 *
 * Companion to `e2e.mjs`: e2e proves the happy paths work; this file tries to BREAK the
 * documented security invariants and validation contracts. Every probe prints PASS when the
 * system behaves correctly (i.e. it REJECTS the bad input) and FAIL when it accepts it.
 *
 * Usage:  node scripts/qa-probe.mjs          (see QA-KIMI docs; needs INTERNAL_HMAC_SECRET)
 * Env:    API_BASE, INTERNAL_HMAC_SECRET
 *
 * Exit code is non-zero when any probe fails (1), or (2) when the API rate-limited the run — a 429
 * burst is stopped before it can be recorded as product failures (issue #112).
 */
import { createHmac, randomUUID } from "node:crypto";
import { spawn } from "node:child_process";

// Node 20 hides the global WebSocket behind a flag — re-exec ourselves with it (same shim as e2e.mjs).
if (typeof globalThis.WebSocket === "undefined" && !process.env.FS_WS_FLAGGED) {
  const child = spawn(process.execPath, ["--experimental-websocket", process.argv[1]], {
    stdio: "inherit",
    env: { ...process.env, FS_WS_FLAGGED: "1" },
  });
  child.on("exit", (code) => process.exit(code ?? 1));
  await new Promise(() => {});
}

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

/**
 * v2 internal signing (ADR-0014): HMAC over `${ts}.${nonce}.${body}` + timestamp/nonce headers.
 * `hmac: true` signs as the ai-engine SERVICE (global secret + caller header); `secret: <device>`
 * signs as that device. `signV1()` is the legacy body-only format, kept here only to prove the
 * server treats it as it should.
 */
const signV2 = (secret, body, { caller, nonce, ts } = {}) => {
  const timestamp = String(ts ?? Math.floor(Date.now() / 1000));
  const n = nonce ?? randomUUID().replace(/-/g, "");
  return {
    "x-familyshield-signature": createHmac("sha256", secret).update(`${timestamp}.${n}.${body}`).digest("hex"),
    "x-familyshield-timestamp": timestamp,
    "x-familyshield-nonce": n,
    ...(caller ? { "x-familyshield-caller": caller } : {}),
  };
};
const signV1 = (secret, body) => ({ "x-familyshield-signature": createHmac("sha256", secret).update(body).digest("hex") });
const sign = (body) => signV2(HMAC_SECRET, body, { caller: "ai-engine" });
/**
 * Mint an HS256 JWT with the server's own secret. The probe runs with the stack's env, so it can
 * produce a *signature-valid* token that is not an access token — the only way to test that
 * `/location/ping` distinguishes "signed by us" from "may write location data" (a reset token).
 */
const signHs256Jwt = (payload, secret) => {
  const enc = (obj) => Buffer.from(JSON.stringify(obj)).toString("base64url");
  const head = enc({ alg: "HS256", typ: "JWT" });
  const body = enc(payload);
  const sig = createHmac("sha256", secret).update(`${head}.${body}`).digest("base64url");
  return `${head}.${body}.${sig}`;
};

/**
 * Issue #112: a burst of 429s is the API's own rate limiter, not a product defect. One run of this
 * probe makes ~109 calls, and the shared :3000 instance is also used by other agents, so an isolated
 * 429 can be an unlucky overlap. More than five in one run is the measured burst shape (run 2 of the
 * #112 report saw 66) — at that point the limiter is shaping the run and its results are not
 * independent of the throttle. Stop instead of manufacturing failures.
 */
const RATE_LIMIT_ABORT_AFTER = 5;
/** Honour Retry-After only when it is shorter than this; the API asks for up to 60 s. */
const RATE_LIMIT_RETRY_CAP_MS = 3000;
let rateLimited429 = 0;

class RateLimitAbort extends Error {}
/** Sockets opened in section L, so the abort path can close them and let the process exit. */
const OPEN_SOCKETS = new Set();

process.on("uncaughtException", (err) => {
  if (err instanceof RateLimitAbort) {
    for (const ws of OPEN_SOCKETS) { try { ws.close(); } catch { /* already closing */ } }
    process.exitCode = 2;
    return; // let the loop drain: process.exit() after several fetches trips a Node 24/Windows libuv assertion
  }
  console.error(err);
  process.exit(1);
});

const abortRateLimited = (why) => {
  console.log(`\nABORT: rate limited by the API (${rateLimited429} x 429) - wait 60 s and re-run`);
  if (why) console.log(`       ${why}`);
  console.log("       No 429-induced check was recorded as a failure; the run stopped first.");
  process.exitCode = 2;
  throw new RateLimitAbort("rate limited by the API");
};

/** Count one observed 429 and abort once the run is clearly being throttled. */
const count429 = (where) => {
  rateLimited429 += 1;
  if (rateLimited429 > RATE_LIMIT_ABORT_AFTER) {
    abortRateLimited(`${where} — more than ${RATE_LIMIT_ABORT_AFTER} x 429 in one run`);
  }
};

/** Retry-After is seconds per RFC 9110; absent or unparseable = one short default wait. */
const retryAfterMs = (res) => {
  const header = res.headers.get("retry-after");
  const seconds = header === null ? NaN : Number(header);
  return Number.isFinite(seconds) && seconds >= 0 ? seconds * 1000 : 1000;
};

async function call(method, path, { token, body, hmac, secret, rawBody, headers } = {}) {
  const raw = rawBody !== undefined ? rawBody : body === undefined ? undefined : JSON.stringify(body);
  const send = () => fetch(`${API}${path}`, {
    method,
    headers: {
      ...(raw !== undefined ? { "content-type": "application/json" } : {}),
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(secret ? signV2(secret, raw ?? "") : hmac ? sign(raw ?? "") : {}),
      ...headers,
    },
    body: raw,
  });
  let res = await send();
  if (res.status === 429) {
    count429(`${method} ${path}`);
    const waitMs = retryAfterMs(res);
    // A 60 s window would stretch this gate by a minute per hit; the issue allows a retry only when
    // it does not extend the run meaningfully, so a long Retry-After means stop, not sleep.
    if (waitMs > RATE_LIMIT_RETRY_CAP_MS) {
      abortRateLimited(`Retry-After ${Math.round(waitMs / 1000)} s exceeds the ${RATE_LIMIT_RETRY_CAP_MS / 1000} s retry cap (${method} ${path})`);
    }
    await new Promise((r) => setTimeout(r, waitMs));
    res = await send();
    if (res.status === 429) {
      count429(`${method} ${path} (retry)`);
      abortRateLimited(`the single retry after ${waitMs} ms was also 429 (${method} ${path})`);
    }
  }
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
let tokenA = regA.data?.token;
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
  body: { childId: kidA, platform: "windows", model: "QA-PC", osVersion: "10", pushToken: "probe-register-token" },
});
const deviceIdA = devA.data?.device?.id ?? devA.data?.deviceId ?? devA.data?.id;
check("setup: device A registered", devA.status === 201 && !!deviceIdA, `got ${devA.status}`);
// Issue #138: /register returned the raw Prisma row — the per-device HMAC field and the push token
// must not appear in a parent-facing enrollment response (sanitizeDevice).
check("setup: register response exposes no internalSecret or pushToken", devA.status === 201 && !("internalSecret" in (devA.data?.device ?? {})) && !("pushToken" in (devA.data?.device ?? {})), `keys=${Object.keys(devA.data?.device ?? {}).join(",")}`);

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

const crossReports = await call("GET", `/v1/reports/usage?childId=${kidA}&days=7`, { token: tokenB });
check("B5 usage report for other family's child (403/404)", [403, 404].includes(crossReports.status), `got ${crossReports.status}`);
const crossWeb = await call("GET", `/v1/reports/web?childId=${kidA}&days=7`, { token: tokenB });
check("B5b browsing history for other family's child (403/404)", [403, 404].includes(crossWeb.status), `got ${crossWeb.status}`);

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
check("B11 parent JWT cannot drain the device command queue (403; parents use /commands/history)", parentOnDevice.status === 403, `got ${parentOnDevice.status}`);
const parentHistory = await call("GET", `/v1/devices/${deviceIdA}/commands/history`, { token: tokenA });
check("B11b parent reads command history non-destructively (200 {items})", parentHistory.status === 200 && Array.isArray(parentHistory.data?.items), `got ${parentHistory.status}`);

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

// Replay (ADR-0014 / target J2 → gate): the SAME v2-signed bytes a second time must be refused —
// the nonce was consumed on first presentment. Sent as the ai-engine service (global secret + caller).
const replayBody = JSON.stringify({ childId: kidA, deviceId: deviceIdA, severity: "info", category: "sos", title: "replay", body: "same-bytes" });
const replayHeaders = sign(replayBody);
const firstSend = await call("POST", "/v1/alerts/internal", { rawBody: replayBody, headers: replayHeaders });
const replaySend = await call("POST", "/v1/alerts/internal", { rawBody: replayBody, headers: replayHeaders });
check("E4/J2 byte-identical signed request replayed -> 401 replay (nonce consumed)", [200, 201].includes(firstSend.status) && replaySend.status === 401 && replaySend.data?.reason === "replay", `first=${firstSend.status} replay=${replaySend.status} ${JSON.stringify(replaySend.data)}`);
const staleSend = await call("POST", "/v1/alerts/internal", { rawBody: replayBody, headers: signV2(HMAC_SECRET, replayBody, { caller: "ai-engine", ts: Math.floor(Date.now() / 1000) - 301 }) });
check("E4b signature with a timestamp 301 s old -> 401 stale_timestamp", staleSend.status === 401 && staleSend.data?.reason === "stale_timestamp", `got ${staleSend.status} ${JSON.stringify(staleSend.data)}`);
const noCaller = await call("POST", "/v1/alerts/internal", { rawBody: replayBody, headers: signV2(HMAC_SECRET, replayBody) });
check("E4c global secret without the service caller header -> 401", noCaller.status === 401 && noCaller.data?.reason === "global_secret_requires_service_caller", `got ${noCaller.status} ${JSON.stringify(noCaller.data)}`);

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
// Kept for L6 (#120): this access token was revoked by the F4 logout, so presenting it on the
// legacy WebSocket `?token=` path proves the bypass accepted a dead parent session.
const revokedParentToken = freshLogin.data?.token;
// ADR-0014: the theft response in F2/F3 revoked EVERY session of parent A, including the
// registration token this probe has been using — exactly as a real theft should. Prove it, then log
// in again for the rest of the run.
const stolenEra = await call("GET", "/v1/family/me", { token: tokenA });
// #117: revocation is a monotonic sessions version (`sv`) read when a token is minted, not a
// second-grained `iat` epoch, so a login issued in the SAME second as the theft response is live and
// the old token is dead. No clock boundary to wait for (that wait was #110's workaround); the check
// still asserts the CAUSE - the fresh token actually works - rather than trusting the login status.
const relogin = await call("POST", "/v1/auth/login", { body: { email: emailA, password: PASSWORD } });
const freshTokenWorks = relogin.data?.token
  ? (await call("GET", "/v1/family/me", { token: relogin.data.token })).status === 200
  : false;
check("F8 theft response killed the owner's other live access token too (401); a fresh login works", stolenEra.status === 401 && stolenEra.data?.error === "session_revoked" && relogin.status === 200 && !!relogin.data?.token && freshTokenWorks, `old=${stolenEra.status} relogin=${relogin.status} freshTokenUsable=${freshTokenWorks}`);
if (relogin.data?.token) tokenA = relogin.data.token;

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
    const inj = await call("POST", "/v1/alerts/internal", { rawBody: body, headers: signV2(d1.secret, body) });
    check("G7 device HMAC cannot write an alert for a sibling child", inj.status >= 400, `got ${inj.status}`);

    // Issue #29: A device's signature must not write search-event or youtube-watch for a sibling child.
    const searchBody = JSON.stringify({ childId: kidA2, deviceId: d1.deviceId, engine: "google", query: "how to kill myself" });
    const searchInj = await call("POST", "/v1/content/search-event", { rawBody: searchBody, headers: signV2(d1.secret, searchBody) });
    check("G7d device HMAC cannot inject search-event for a sibling child (#29)", searchInj.status >= 400, `got ${searchInj.status}`);

    const ytBody = JSON.stringify({ childId: kidA2, deviceId: d1.deviceId, videoId: "xyz123", title: "how to commit suicide", channel: "c" });
    const ytInj = await call("POST", "/v1/content/youtube-watch", { rawBody: ytBody, headers: signV2(d1.secret, ytBody) });
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

// ── G2. location & rules authorization (audit findings 1 and 2) ─────────────
// A device token is family-scoped, so `requireFamily` alone lets it read a sibling child. And a
// verified JWT used to be enough for `/location/ping`: a password-reset token (no role/family) or a
// parent-supplied `deviceId` for another child reached the write. These checks pin both shut.
console.log("\n── G2. location & rules authorization ──");
{
  const ownRules = await call("GET", `/v1/rules/${kidA2}`, { token: d2.token });
  const ownLoc = await call("GET", `/v1/location/${kidA2}/history`, { token: d2.token });
  check("G13 device JWT reads its own child's rules and location (200)", ownRules.status === 200 && ownLoc.status === 200, `rules=${ownRules.status} location=${ownLoc.status}`);

  const sibRules = await call("GET", `/v1/rules/${kidA}`, { token: d2.token });
  const sibLoc = await call("GET", `/v1/location/${kidA}/history`, { token: d2.token });
  check("G14 device JWT cannot read a sibling child's rules or location (403 cross_child_forbidden)", sibRules.status === 403 && sibRules.data?.error === "cross_child_forbidden" && sibLoc.status === 403 && sibLoc.data?.error === "cross_child_forbidden", `rules=${sibRules.status}/${sibRules.data?.error} location=${sibLoc.status}/${sibLoc.data?.error}`);

  const ownPing = await call("POST", "/v1/location/ping", {
    token: tokenA,
    body: { childId: kidA2, deviceId: d2.deviceId, lat: 37.7749, lng: -122.4194, accuracyM: 5 },
  });
  check("G15 parent ping for its own child's device still succeeds (201)", ownPing.status === 201, `got ${ownPing.status}`);

  const crossDevPing = await call("POST", "/v1/location/ping", {
    token: tokenA,
    body: { childId: kidA2, deviceId: deviceIdA, lat: 37.7749, lng: -122.4194, accuracyM: 5 },
  });
  check("G16 parent-supplied deviceId belonging to another child is refused (403 device_mismatch)", crossDevPing.status === 403 && crossDevPing.data?.error === "device_mismatch", `got ${crossDevPing.status} ${JSON.stringify(crossDevPing.data)}`);

  const crossFamPing = await call("POST", "/v1/location/ping", {
    token: tokenB,
    body: { childId: kidA, deviceId: deviceIdA, lat: 37.7749, lng: -122.4194, accuracyM: 5 },
  });
  check("G17 parent ping for another family's child is still forbidden (403)", crossFamPing.status === 403, `got ${crossFamPing.status}`);

  // #124 (audit finding 5): family scoping is not device identity. Device A could post telemetry for
  // sibling B in the same family, refreshing B's lastSeen/battery and B's child's day totals, because
  // `requireFamily` only proves the target shares the caller's familyId — every device in a family
  // does. Agent-write routes therefore compose `requireOwnDevice` after it
  // (`services/api/src/middleware/requireFamily.ts`); parents stay family-scoped (G15).
  const sibTelemetry = await call("POST", `/v1/devices/${deviceIdA}/telemetry`, { token: d2.token, body: { batteryPct: 11 } });
  check("G20 a device token cannot post telemetry for a sibling device in the same family (403 forbidden)", sibTelemetry.status === 403 && sibTelemetry.data?.error === "forbidden", `got ${sibTelemetry.status} ${JSON.stringify(sibTelemetry.data)}`);
  const ownTelemetry = await call("POST", `/v1/devices/${d2.deviceId}/telemetry`, { token: d2.token, body: { batteryPct: 57 } });
  check("G21 a device token CAN post telemetry for its own device (202 accepted)", ownTelemetry.status === 202 && ownTelemetry.data?.accepted === true, `got ${ownTelemetry.status} ${JSON.stringify(ownTelemetry.data)}`);

  // #124 (audit finding 4): the device-silence watch matches `online`, so the writers must write
  // `online`. The watch used to match `active` — a status no writer produces — and never fired. The
  // alert-timing half (one critical tamper/device_silent alert per episode, flip to `offline`) needs a
  // backdated row plus a job trigger that the probe cannot reach over HTTP and that a 5-minute tick
  // makes unsuitable for a merge gate, so it stays a unit test (`test/device-silence.test.ts`). What
  // the probe can pin live is the other half of the contract: the status a real write produces.
  const reported = await call("GET", `/v1/devices/${d2.deviceId}`, { token: tokenA });
  const reportedStatus = reported.data?.device?.status;
  const reportedSeen = Date.parse(reported.data?.device?.lastSeen ?? "");
  check("G22 telemetry writes the status the silence watch matches (`online`), never `active`", reported.status === 200 && reportedStatus === "online" && Number.isFinite(reportedSeen) && Date.now() - reportedSeen < 120_000, `get=${reported.status} device.status=${reportedStatus} lastSeen=${reported.data?.device?.lastSeen ?? "none"}`);
  const familyDevices = await call("GET", "/v1/devices", { token: tokenA });
  const writtenStatuses = (familyDevices.data?.devices ?? []).map((dev) => dev.status);
  check("G23 every device status written in this run is in the shared vocabulary (no `active`)", familyDevices.status === 200 && writtenStatuses.length > 0 && writtenStatuses.every((s) => ["online", "offline", "locked", "sos"].includes(s)), `statuses=${JSON.stringify(writtenStatuses)}`);

  // Roadmap 3.4: the installed-launchable-app inventory. d2 is paired and live; the parent token
  // reads it, another family cannot, and the agent cannot write a sibling device's list.
  const appsWrite = await call("POST", `/v1/devices/${d2.deviceId}/apps`, {
    token: d2.token,
    body: {
      version: 1,
      apps: [
        { packageId: "com.example.game", label: "Game", isSystem: false },
        { packageId: "com.android.settings", label: "Settings", isSystem: true },
        { packageId: "com.example.game", label: "Game duplicate", isSystem: false },
      ],
    },
  });
  check("G24 installed apps: the device uploads its own inventory (202) and duplicates collapse", appsWrite.status === 202 && appsWrite.data?.accepted === true && appsWrite.data?.count === 2, `got ${appsWrite.status} ${JSON.stringify(appsWrite.data)}`);
  const appsRead = await call("GET", `/v1/devices/${d2.deviceId}/apps`, { token: tokenA });
  const appInventory = appsRead.data?.apps ?? [];
  const appKeys = appInventory.length ? Object.keys(appInventory[0]).sort().join(",") : "";
  check("G25 installed apps: the parent reads version 1 with package+label+system only", appsRead.status === 200 && appsRead.data?.version === 1 && appsRead.data?.count === 2 && appInventory.length === 2 && appKeys === "isSystem,label,packageId" && appInventory.some((a) => a.packageId === "com.android.settings" && a.isSystem === true), `status=${appsRead.status} version=${appsRead.data?.version} count=${appsRead.data?.count} keys=${appKeys}`);
  const appsOtherFamily = await call("GET", `/v1/devices/${d2.deviceId}/apps`, { token: tokenB });
  check("G26 installed apps: another family cannot read the inventory (403)", appsOtherFamily.status === 403, `got ${appsOtherFamily.status}`);
  const appsSibling = await call("POST", `/v1/devices/${deviceIdA}/apps`, { token: d2.token, body: { version: 1, apps: [] } });
  check("G27 installed apps: a device cannot write a sibling device's inventory (403)", appsSibling.status === 403, `got ${appsSibling.status} ${JSON.stringify(appsSibling.data)}`);
  const appsTooMany = await call("POST", `/v1/devices/${d2.deviceId}/apps`, {
    token: d2.token,
    body: { version: 1, apps: Array.from({ length: 501 }, (_, i) => ({ packageId: `com.example.app${i}`, label: `App ${i}`, isSystem: false })) },
  });
  const appsLongLabel = await call("POST", `/v1/devices/${d2.deviceId}/apps`, {
    token: d2.token,
    body: { version: 1, apps: [{ packageId: "com.example.long", label: "x".repeat(101), isSystem: false }] },
  });
  const appsBadVersion = await call("POST", `/v1/devices/${d2.deviceId}/apps`, { token: d2.token, body: { version: 2, apps: [] } });
  check("G28 installed apps: 501 apps, a 101-character label and version 2 are rejected (400)", appsTooMany.status === 400 && appsLongLabel.status === 400 && appsBadVersion.status === 400, `many=${appsTooMany.status} label=${appsLongLabel.status} version=${appsBadVersion.status}`);
  const appsReplace = await call("POST", `/v1/devices/${d2.deviceId}/apps`, {
    token: d2.token,
    body: { version: 1, apps: [{ packageId: "com.example.only", label: "Only", isSystem: false }] },
  });
  const appsAfterReplace = await call("GET", `/v1/devices/${d2.deviceId}/apps`, { token: tokenA });
  const appsClear = await call("POST", `/v1/devices/${d2.deviceId}/apps`, { token: d2.token, body: { version: 1, apps: [] } });
  const appsAfterClear = await call("GET", `/v1/devices/${d2.deviceId}/apps`, { token: tokenA });
  check("G29 installed apps: a later report replaces the list and an empty report clears it", appsReplace.status === 202 && appsAfterReplace.data?.count === 1 && appsAfterReplace.data?.apps?.[0]?.packageId === "com.example.only" && appsClear.status === 202 && appsAfterClear.data?.count === 0, `replace=${appsReplace.status} count=${appsAfterReplace.data?.count} clear=${appsClear.status} after=${appsAfterClear.data?.count}`);

  if (process.env.JWT_SECRET) {
    const parentId = JSON.parse(Buffer.from(tokenA.split(".")[1], "base64url").toString()).sub;
    const now = Math.floor(Date.now() / 1000);
    const resetToken = signHs256Jwt({ sub: parentId, purpose: "password_reset", iat: now, exp: now + 900 }, process.env.JWT_SECRET);
    const resetPing = await call("POST", "/v1/location/ping", {
      token: resetToken,
      body: { childId: kidA, deviceId: deviceIdA, lat: 37.7749, lng: -122.4194, accuracyM: 5 },
    });
    check("G18 password-reset purpose token cannot post a location ping (401)", resetPing.status === 401, `got ${resetPing.status}`);

    // #146: the reset token was also a general bearer credential. Replay the exploit shape on a
    // disposable account: reset the password, then present a freshly minted reset token to routes
    // guarded by requireJwt. Before the fix /mfa/enroll returned 200 (no secret yet) and
    // /logout-all revoked the account's sessions.
    const resetEmail = `qa-reset-${stamp}@example.com`;
    const resetReg = await call("POST", "/v1/auth/register", {
      body: { email: resetEmail, password: PASSWORD, displayName: "QA Reset", familyName: "QA Reset Family", region: "US" },
    });
    const resetSub = resetReg.data?.token
      ? JSON.parse(Buffer.from(resetReg.data.token.split(".")[1], "base64url").toString()).sub
      : null;
    const mintReset = () => {
      const mintedAt = Math.floor(Date.now() / 1000);
      return signHs256Jwt({ sub: resetSub, purpose: "password_reset", iat: mintedAt, exp: mintedAt + 900 }, process.env.JWT_SECRET);
    };
    const resetNewPassword = "QaProbeResetPassw0rd!";
    const forgedReset = mintReset();
    // #167: a reset token is single-use and only exists if /reset/request stored its `jti`. This
    // hand-signed token has no store record, so it is refused at confirm too — the old check
    // expected 200 here and can no longer be produced by a probe that cannot read the emailed link.
    const confirmReset = resetSub
      ? await call("POST", "/v1/auth/reset/confirm", { body: { token: forgedReset, password: resetNewPassword } })
      : { status: 0 };
    // The same shape must still be refused as a bearer credential: a reset token is never a session.
    const resetEnroll = await call("POST", "/v1/auth/mfa/enroll", { token: forgedReset, body: { password: resetNewPassword } });
    const resetLogoutAll = await call("POST", "/v1/auth/logout-all", { token: forgedReset });
    check("G19 a password-reset purpose token is refused as a reset (no store record) and as a bearer credential (/mfa/enroll and /logout-all -> 401)", resetReg.status === 201 && confirmReset.status === 401 && resetEnroll.status === 401 && resetLogoutAll.status === 401, `register=${resetReg.status} confirm=${confirmReset.status} enroll=${resetEnroll.status} logoutAll=${resetLogoutAll.status}`);
  } else {
    target("G18 password-reset purpose token rejected on /location/ping", "JWT_SECRET not present in the probe environment, so a reset-purpose token cannot be minted here");
  }
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
const blockedApps = dJ.token ? await call("POST", `/v1/devices/${dJ.deviceId}/apps`, { token: dJ.token, body: { version: 1, apps: [{ packageId: "com.example.game", label: "Game", isSystem: false }] } }) : { status: 0 };
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
check(
  "J3e consent revocation stops the installed-app upload too (POST /devices/:id/apps -> 428)",
  blockedApps.status === 428,
  `apps=${blockedApps.status}`,
);

// Issue #53 (found by Kimi/Antigravity verification of PR #52): the probe never asserted that a
// device actually receives a fresh command, so a queue that expired every row on a non-UTC
// database stayed green. These checks fail if the drain is empty, if delivery is not recorded,
// or if the ack transition does not happen. Run them against a non-UTC database (docs/TESTING.md).
const freshCmd = dJ.deviceId ? await call("POST", `/v1/devices/${dJ.deviceId}/command`, { token: tokenA, body: { command: "ring" } }) : { status: 0, data: {} };
const freshDrain = dJ.token ? await call("GET", `/v1/devices/${dJ.deviceId}/commands?ack=1`, { token: dJ.token }) : { status: 0, data: [] };
const freshHit = Array.isArray(freshDrain.data) ? freshDrain.data.find((c) => c.id === freshCmd.data?.id) : undefined;
check(
  "K1 device drains a fresh command within seconds (not expired on arrival — issue #53)",
  freshCmd.status === 200 && freshCmd.data?.status === "pending" && freshDrain.status === 200 && !!freshHit && freshHit.type === "ring",
  `post=${freshCmd.status} drain=${freshDrain.status} ids=${JSON.stringify((freshDrain.data || []).map((c) => c.type))}`,
);
const freshHistory = dJ.deviceId ? await call("GET", `/v1/devices/${dJ.deviceId}/commands/history?limit=5`, { token: tokenA }) : { status: 0, data: {} };
const freshRow = freshHistory.data?.items?.find((c) => c.id === freshCmd.data?.id);
check("K2 history records the drained command as delivered", freshRow?.status === "delivered", `status=${freshRow?.status}`);
const freshAck = freshCmd.data?.id && dJ.token ? await call("POST", `/v1/devices/${dJ.deviceId}/commands/${freshCmd.data.id}/ack`, { token: dJ.token, body: { status: "ok" } }) : { status: 0, data: {} };
check("K3 device ack flips the command to acked", freshAck.status === 200 && freshAck.data?.command?.status === "acked", `got ${freshAck.status} ${freshAck.data?.command?.status ?? ""}`);
const emptyDrain = dJ.token ? await call("GET", `/v1/devices/${dJ.deviceId}/commands?ack=1`, { token: dJ.token }) : { status: 0, data: [1] };
check("K4 an acked command is not re-offered", emptyDrain.status === 200 && Array.isArray(emptyDrain.data) && !emptyDrain.data.some((c) => c.id === freshCmd.data?.id), `drain=${JSON.stringify((emptyDrain.data || []).map((c) => c.type))}`);

// IOS-01: the iOS AlertReporter signs with the device's own secret but sends no top-level
// `deviceId`, so the server falls back to the global secret and rejects every alert (verified 401).
if (d2?.secret && kidA2) {
  const iosBody = JSON.stringify({ childId: kidA2, category: "sos", severity: "critical", title: "ios-shape", body: "no deviceId", metadata: { source: "ios" } });
  const iosRes = await call("POST", "/v1/alerts/internal", { rawBody: iosBody, headers: signV2(d2.secret, iosBody) });
  check("J4 iOS-shaped alert (per-device secret, no body deviceId) accepted", [200, 201].includes(iosRes.status), `got ${iosRes.status}`);

  // J5 (gate): while devices may carry their own secret, the global secret must NOT be able to sign
  // as that device — the per-device secret is the thing that makes an agent alert trustworthy.
  // Verified 2026-10-11: after the P0 bundle this is fail-closed (401). Keep it that way.
  const gBody = JSON.stringify({ childId: kidA2, deviceId: d2.deviceId, category: "sos", severity: "info", title: "global-secret-check", body: "x" });
  const gRes = await call("POST", "/v1/alerts/internal", { rawBody: gBody, headers: signV1(HMAC_SECRET, gBody) });
  const gRes2 = await call("POST", "/v1/alerts/internal", { rawBody: gBody, headers: signV2(HMAC_SECRET, gBody) });
  check("J5 bare global secret (v1, or v2 without a caller) cannot sign as a device that has its own secret", gRes.status === 401 && gRes2.status === 401, `v1=${gRes.status} v2nocaller=${gRes2.status}`);

  // J6 (gate, ADR-0014): the global-secret fallback for secret-less devices is CLOSED. A device
  // registered through the parent path has no secret; nothing body-only may act for it, and the
  // global secret authenticates only as a named service. The legitimate service path (caller header)
  // still works for child-only bodies, which is what the ai-engine sends.
  const regd = await call("POST", "/v1/devices/register", {
    token: tokenA,
    body: { childId: kidA2, platform: "windows", model: "probe-nosecret", osVersion: "10" },
  });
  if (regd.status === 201) {
    const nBody = JSON.stringify({ childId: kidA2, category: "sos", severity: "info", title: "global-fallback-check", body: "x" });
    const bare = await call("POST", "/v1/alerts/internal", { rawBody: nBody, headers: signV1(HMAC_SECRET, nBody) });
    const dBody = JSON.stringify({ childId: kidA2, deviceId: regd.data?.device?.id, category: "sos", severity: "info", title: "global-fallback-check", body: "x" });
    const bareDev = await call("POST", "/v1/alerts/internal", { rawBody: dBody, headers: signV1(HMAC_SECRET, dBody) });
    check("J6 bare global secret cannot write for a child/device with no per-device secret (401)", bare.status === 401 && bareDev.status === 401, `childOnly=${bare.status} deviceNamed=${bareDev.status}`);
    const svc = await call("POST", "/v1/alerts/internal", { rawBody: nBody, headers: sign(nBody) });
    check("J6b the ai-engine service path (global secret + caller, v2) still raises a child-only alert (201)", svc.status === 201, `got ${svc.status}`);
  }
  // J7: legacy v1 device signatures. Refused by default since 2026-10-17 (the gating check); an operator
  // who set INTERNAL_SIGNING_ALLOW_V1=1 for a rollout sees the target instead, so the state is never silent.
  if (d2?.secret) {
    const v1Body = JSON.stringify({ childId: kidA2, deviceId: d2.deviceId, category: "sos", severity: "info", title: "legacy-v1", body: "x" });
    const v1Res = await call("POST", "/v1/alerts/internal", { rawBody: v1Body, headers: signV1(d2.secret, v1Body) });
    if ([200, 201].includes(v1Res.status)) {
      target("J7 legacy v1 (body-only) device signatures", `HTTP ${v1Res.status} — accepted because INTERNAL_SIGNING_ALLOW_V1=1 is set; unset it once every agent signs v2 (ADR-0014)`);
    } else {
      check("J7 legacy v1 device signatures refused by default (opt in with INTERNAL_SIGNING_ALLOW_V1=1)", v1Res.status === 401 && v1Res.data?.reason === "legacy_signature_disabled", `got ${v1Res.status} ${JSON.stringify(v1Res.data)}`);
    }
  }
}

// ── L. realtime contract — `ready` frame (TR-05) ────────────────────────────
console.log("\n── L. realtime ──");
{
  // Contract: the gateway sends `{type:"ready", familyId, ts}` as the FIRST frame after it has
  // registered the socket, and no event frame precedes it. A client that has not seen `ready`
  // cannot know whether a published event reached it; a client that has can treat a missing event
  // as a delivery failure, not a race. Checked end-to-end here: real ticket, real socket, real alert.
  const openSocket = async (ticket) => {
    const ws = new WebSocket(`${API.replace(/^http/, "ws")}/v1/ws?ticket=${encodeURIComponent(ticket)}`);
    OPEN_SOCKETS.add(ws);
    const frames = [];
    let close = null;
    ws.addEventListener("message", (ev) => frames.push(JSON.parse(ev.data)));
    ws.addEventListener("close", (ev) => { OPEN_SOCKETS.delete(ws); close = ev?.code ?? -1; });
    ws.addEventListener("error", () => {});
    const until = async (pred, ms) => {
      const deadline = Date.now() + ms;
      for (;;) {
        if (pred()) return true;
        if (Date.now() > deadline) return false;
        await new Promise((r) => setTimeout(r, 50));
      }
    };
    return { ws, frames, close: () => close, until };
  };
  const meA = await call("GET", "/v1/family/me", { token: tokenA });
  const familyIdA = meA.data?.family?.id;
  const ticketA = (await call("POST", "/v1/ws-ticket", { token: tokenA })).data?.ticket;
  const sock = await openSocket(ticketA ?? "missing");
  const gotReady = await sock.until(() => sock.frames.some((f) => f.type === "ready"), 5000);
  const first = sock.frames[0];
  check(
    "L1 parent socket receives {type:ready} as the FIRST frame, bound to its own familyId",
    gotReady && first?.type === "ready" && first?.familyId === familyIdA && typeof first?.ts === "string",
    `first=${JSON.stringify(first ?? null)} expectedFamily=${familyIdA} close=${sock.close()}`,
  );
  const readyIdx = sock.frames.findIndex((f) => f.type === "ready");
  const alertBody = { childId: kidA, deviceId: deviceIdA, severity: "info", category: "sos", title: `ready-order-${stamp}`, body: "after ready" };
  const posted = await call("POST", "/v1/alerts/internal", { hmac: true, body: alertBody });
  const gotAlert = await sock.until(() => sock.frames.some((f) => f.type === "alert" && f.payload?.title === alertBody.title), 10000);
  const alertIdx = sock.frames.findIndex((f) => f.type === "alert" && f.payload?.title === alertBody.title);
  check(
    "L2 an alert published after ready is delivered on that socket, after ready",
    [200, 201].includes(posted.status) && gotAlert && readyIdx === 0 && alertIdx > readyIdx,
    `post=${posted.status} readyIdx=${readyIdx} alertIdx=${alertIdx} frames=${sock.frames.length} close=${sock.close()}`,
  );
  check("L3 no event frame precedes ready", !sock.frames.slice(0, Math.max(readyIdx, 0)).some((f) => f.type !== "ready"), `frames=${JSON.stringify(sock.frames.map((f) => f.type))}`);
  sock.ws.close();

  // A bad ticket must close 4001 and must NOT leak a ready frame (ready = "you are subscribed").
  const bad = await openSocket(`bogus-${stamp}`);
  const closed = await bad.until(() => bad.close() !== null, 5000);
  check("L4 invalid ticket -> close 4001 and no ready frame", closed && bad.close() === 4001 && bad.frames.length === 0, `close=${bad.close()} frames=${bad.frames.length}`);

  // A ticket is single-use: the second presentment of the same ticket is refused, no ready frame.
  const reuse = await openSocket(ticketA ?? "missing");
  const reuseClosed = await reuse.until(() => reuse.close() !== null, 5000);
  check("L5 a consumed ticket cannot open a second socket (4001, no ready)", reuseClosed && reuse.close() === 4001 && reuse.frames.length === 0, `close=${reuse.close()} frames=${reuse.frames.length}`);

  // Issue #120: the legacy `?token=<jwt>` handshake is removed. A stale client must fail loudly with
  // a JSON 401 that names the reason — the websocket plugin would otherwise answer a non-upgrade
  // request with 404, which reads as "wrong route" rather than "your handshake is no longer accepted".
  const revokedQuery = revokedParentToken
    ? await call("GET", `/v1/ws?token=${encodeURIComponent(revokedParentToken)}`)
    : { status: 0, data: null };
  check("L6 revoked parent JWT in ?token= is refused with 401 ticket_required (#120)", revokedQuery.status === 401 && revokedQuery.data?.error === "ticket_required", `got ${revokedQuery.status} ${JSON.stringify(revokedQuery.data)}`);

  const deviceQuery = d2.token
    ? await call("GET", `/v1/ws?token=${encodeURIComponent(d2.token)}`)
    : { status: 0, data: null };
  check("L7 device JWT in ?token= is refused with 401 ticket_required (#120)", deviceQuery.status === 401 && deviceQuery.data?.error === "ticket_required", `got ${deviceQuery.status} ${JSON.stringify(deviceQuery.data)}`);

  const revokedDeviceQuery = d1.token
    ? await call("GET", `/v1/ws?token=${encodeURIComponent(d1.token)}`)
    : { status: 0, data: null };
  check("L7b revoked device JWT in ?token= is refused with 401 ticket_required (#120)", revokedDeviceQuery.status === 401 && revokedDeviceQuery.data?.error === "ticket_required", `got ${revokedDeviceQuery.status} ${JSON.stringify(revokedDeviceQuery.data)}`);

  const noTicket = await call("GET", "/v1/ws");
  check("L8 /v1/ws without a ticket is a JSON 401 ticket_required, not a 404 (#120)", noTicket.status === 401 && noTicket.data?.error === "ticket_required", `got ${noTicket.status} ${JSON.stringify(noTicket.data)}`);

  // ...and the replacement still works: a fresh ticket opens the stream and delivers `ready`.
  const ticketOnly = (await call("POST", "/v1/ws-ticket", { token: tokenA })).data?.ticket;
  const ticketOnlySock = await openSocket(ticketOnly ?? "missing");
  const ticketOnlyReady = await ticketOnlySock.until(() => ticketOnlySock.frames.some((f) => f.type === "ready"), 5000);
  check("L9 a fresh single-use ticket still opens the stream (ready is the first frame)", ticketOnlyReady && ticketOnlySock.close() === null && ticketOnlySock.frames[0]?.type === "ready", `ready=${ticketOnlyReady} close=${ticketOnlySock.close()} first=${ticketOnlySock.frames[0]?.type}`);
  ticketOnlySock.ws.close();
}

// ── M. usage model + erasure cascade (Phase 2c, ADR-0013) ───────────────────
console.log("\n── M. usage model & erasure ──");
{
  // Bounds on the new report routes.
  const tooMany = await call("GET", `/v1/reports/usage?childId=${kidA}&days=400`, { token: tokenA });
  const zero = await call("GET", `/v1/reports/usage?childId=${kidA}&days=0`, { token: tokenA });
  const webBig = await call("GET", `/v1/reports/web?childId=${kidA}&limit=5000`, { token: tokenA });
  const webDays = await call("GET", `/v1/reports/web?childId=${kidA}&days=91`, { token: tokenA });
  check("M1 /reports/usage and /reports/web reject out-of-range days/limit (400)", [tooMany, zero, webBig, webDays].every((r) => r.status === 400), `got ${[tooMany, zero, webBig, webDays].map((r) => r.status).join("/")}`);
  const own = await call("GET", `/v1/reports/usage?childId=${kidA}&days=3`, { token: tokenA });
  check("M2 /reports/usage returns a 3-entry series for the owning parent", own.status === 200 && Array.isArray(own.data?.series) && own.data.series.length === 3 && own.data.series.every((d) => typeof d.minutes === "number"), `got ${own.status} len=${own.data?.series?.length}`);

  // Erasure: a scratch child with a real paired device and ingested data, erased by its own parent.
  const kidC = (await call("POST", "/v1/family/children", {
    token: tokenA,
    body: { displayName: `QA Erase ${stamp}`, birthYear: 2016, consent: { method: "sms_plus", jurisdiction: "US" } },
  })).data?.child?.id;
  const dC = kidC ? await pairDevice(kidC, "qa-erase-dev") : { status: 0 };
  if (kidC && dC.token && dC.deviceId) {
    await call("POST", `/v1/devices/${dC.deviceId}/activity`, { token: dC.token, body: { events: [
      { type: "app_usage", payload: { app: "YouTube", minutes: 3 } },
      { type: "url", payload: { url: "https://erase.example/p", blocked: false } },
    ] } });
    await call("POST", `/v1/devices/${dC.deviceId}/telemetry`, { token: dC.token, body: { totalMinutes: 3 } });
    const crossErase = await call("DELETE", `/v1/family/children/${kidC}`, { token: tokenB });
    check("M3 other family cannot erase a child (403/404), child still readable by its parent", [403, 404].includes(crossErase.status) && (await call("GET", `/v1/family/children/${kidC}`, { token: tokenA })).status === 200, `got ${crossErase.status}`);
    const erase = await call("DELETE", `/v1/family/children/${kidC}`, { token: tokenA });
    check("M4 own erasure returns deleted devices + per-table counts incl. activity/web/usage rows", erase.status === 200 && erase.data?.deletedDevices?.includes(dC.deviceId) && erase.data?.rows?.activityEvent >= 2 && erase.data?.rows?.webVisit >= 1 && erase.data?.rows?.appUsageDaily >= 2 && erase.data?.rows?.device >= 1, `got ${erase.status} ${JSON.stringify(erase.data?.rows ?? null)}`);
    const afterDevice = await call("GET", `/v1/devices/${dC.deviceId}/commands`, { token: dC.token });
    const afterPing = await call("POST", "/v1/location/ping", { token: dC.token, body: { childId: kidC, deviceId: dC.deviceId, lat: 1, lng: 2, accuracyM: 5 } });
    check("M5 an erased child's device JWT is revoked on every route (401), not merely orphaned", afterDevice.status === 401 && afterPing.status === 401, `commands=${afterDevice.status} ping=${afterPing.status}`);
    const gone = await call("GET", `/v1/family/children/${kidC}`, { token: tokenA });
    const usageGone = await call("GET", `/v1/reports/usage?childId=${kidC}&days=1`, { token: tokenA });
    check("M6 erased child is gone for its parent too (404 on child and on its reports)", gone.status === 404 && usageGone.status === 404, `child=${gone.status} usage=${usageGone.status}`);
  } else {
    check("M3-M6 erasure scratch child + device could not be created", false, `kidC=${kidC} claim=${dC.status}`);
  }
}

// ── N. parent sessions and family roles (ADR-0014) ──────────────────────────
console.log("\n── N. sessions & roles ──");
{
  // N1: logout-all kills the live access token immediately (it used to stay valid for 7 days).
  const loginA = await call("POST", "/v1/auth/login", { body: { email: emailA, password: PASSWORD } });
  const liveTok = loginA.data?.token;
  const claims = liveTok ? JSON.parse(Buffer.from(liveTok.split(".")[1], "base64url").toString()) : {};
  check("N1 every parent access token carries a jti and a familyRole", typeof claims.jti === "string" && claims.jti.length === 32 && claims.role === "parent" && typeof claims.familyRole === "string", JSON.stringify({ jti: claims.jti, role: claims.role, familyRole: claims.familyRole }));
  // #117: the revocation bumps the parent's sessions version, so this token dies even when it was
  // minted in the same wall-clock second - no sleep needed (the old 1100 ms wait is gone on purpose).
  const killAll = await call("POST", "/v1/auth/logout-all", { token: liveTok });
  const afterKill = await call("GET", "/v1/family/me", { token: liveTok });
  check("N2 logout-all revokes the live access token (401 session_revoked), not only the refresh token", killAll.status === 200 && afterKill.status === 401 && afterKill.data?.error === "session_revoked", `logoutAll=${killAll.status} then=${afterKill.status} ${JSON.stringify(afterKill.data)}`);
  // N3: single logout with the refresh token also kills the access token issued with it.
  const loginA2 = await call("POST", "/v1/auth/login", { body: { email: emailA, password: PASSWORD } });
  const out = await call("POST", "/v1/auth/logout", { body: { refreshToken: loginA2.data?.refreshToken } });
  const afterOut = await call("GET", "/v1/family/me", { token: loginA2.data?.token });
  check("N3 single logout (refresh token) also revokes its access token (401)", out.status === 200 && afterOut.status === 401, `logout=${out.status} then=${afterOut.status}`);
  // Fresh token for family A for the rest of this section.
  const tokenA3 = (await call("POST", "/v1/auth/login", { body: { email: emailA, password: PASSWORD } })).data?.token;

  // N4–N6: invite family B's parent into family A as a co-parent with only the "alerts" permission.
  const invite = await call("POST", "/v1/family/invites", { token: tokenA3, body: { email: emailB, role: "co-parent", permissions: ["alerts"] } });
  const inviteId = invite.data?.invite?.id;
  check("N4 owner can invite a co-parent (201 with id)", invite.status === 201 && !!inviteId, `got ${invite.status}`);
  const accept = inviteId ? await call("POST", `/v1/family/invites/${inviteId}/accept`, { token: tokenB }) : { status: 0 };
  const coTok = accept.data?.token;
  const coClaims = coTok ? JSON.parse(Buffer.from(coTok.split(".")[1], "base64url").toString()) : {};
  const coMe = coTok ? await call("GET", "/v1/family/me", { token: coTok }) : { status: 0 };
  check("N5 accepted invite mints a token the parent surface ACCEPTS (role=parent, familyRole=co-parent) — was 403 before", accept.status === 200 && coClaims.role === "parent" && coClaims.familyRole === "co-parent" && coMe.status === 200 && coMe.data?.family?.id && coMe.data.family.id !== undefined, `accept=${accept.status} me=${coMe.status} claims=${JSON.stringify({ role: coClaims.role, familyRole: coClaims.familyRole })}`);
  if (coTok) {
    const coRules = await call("PATCH", `/v1/rules/${kidA}`, { token: coTok, body: { dailyLimitMinutes: 45 } });
    const coCmd = await call("POST", `/v1/devices/${deviceIdA}/command`, { token: coTok, body: { command: "lock" } });
    const coErase = await call("DELETE", `/v1/family/children/${kidA}`, { token: coTok });
    const coRead = await call("GET", `/v1/rules/${kidA}`, { token: coTok });
    check("N6 co-parent without 'rules'/'devices' cannot write rules or command a device (403 permission_required); erasure is owner-only (403); reads work", coRules.status === 403 && coRules.data?.error === "permission_required" && coCmd.status === 403 && coErase.status === 403 && coErase.data?.error === "owner_role_required" && coRead.status === 200, `rules=${coRules.status} cmd=${coCmd.status} erase=${coErase.status} read=${coRead.status}`);
    // Issue #138: enrollment issued credentials outside the `devices` surface. Both routes must now
    // fail closed for a co-parent whose invite granted only `alerts` (ADR-0014 amendment).
    const coRegister = await call("POST", "/v1/devices/register", { token: coTok, body: { childId: kidA, platform: "android", model: "co-probe", osVersion: "14" } });
    check("N6b co-parent without 'devices' cannot register a device (403 permission_required)", coRegister.status === 403 && coRegister.data?.error === "permission_required" && coRegister.data?.permission === "devices", `got ${coRegister.status} ${JSON.stringify(coRegister.data)}`);
    const coPair = await call("POST", "/v1/devices/pair", { token: coTok, body: { childId: kidA } });
    check("N6c co-parent without 'devices' cannot mint a pairing code (403 permission_required)", coPair.status === 403 && coPair.data?.error === "permission_required" && coPair.data?.permission === "devices", `got ${coPair.status} ${JSON.stringify(coPair.data)}`);
    // #124 (audit finding 6): push-token is a parent-side device mutation, so it names the same
    // `devices` permission as command, unpair and enrollment. Without it, a co-parent admitted for
    // `alerts` could repoint the child's notifications to a device they control.
    const coPush = await call("POST", `/v1/devices/${deviceIdA}/push-token`, { token: coTok, body: { pushToken: `co-probe-${stamp}` } });
    check("N6d co-parent without 'devices' cannot set a device push token (403 permission_required)", coPush.status === 403 && coPush.data?.error === "permission_required" && coPush.data?.permission === "devices", `got ${coPush.status} ${JSON.stringify(coPush.data)}`);
    // Roadmap 3.4: the installed-app inventory is a `rules` surface (it feeds the Rules editor).
    const coApps = await call("GET", `/v1/devices/${d2.deviceId}/apps`, { token: coTok });
    check("N6f co-parent without 'rules' cannot read the installed-app inventory (403 permission_required)", coApps.status === 403 && coApps.data?.error === "permission_required" && coApps.data?.permission === "rules", `got ${coApps.status} ${JSON.stringify(coApps.data)}`);
    // ...and the owner's success response is an allowlist, not the raw Prisma row: `internalSecret` is
    // the device's signing key and `pushToken` is another user's FCM handle, so neither may leave the
    // server (the pre-fix response carried both).
    const ownerPush = await call("POST", `/v1/devices/${deviceIdA}/push-token`, { token: tokenA3, body: { pushToken: `fcm-probe-${stamp}` } });
    const ownerPushBody = JSON.stringify(ownerPush.data ?? {});
    check("N6e owner push-token update (200) returns neither internalSecret nor pushToken", ownerPush.status === 200 && ownerPush.data?.device?.id === deviceIdA && !ownerPushBody.includes("internalSecret") && !ownerPushBody.includes("pushToken"), `got ${ownerPush.status} ${ownerPushBody.slice(0, 200)}`);
    // N7: the permission the invite DID grant works — ack an alert of family A.
    const alertsA = await call("GET", "/v1/alerts?limit=1", { token: coTok });
    const alertId = alertsA.data?.items?.[0]?.id ?? alertsA.data?.alerts?.[0]?.id;
    const ack = alertId ? await call("POST", `/v1/alerts/${alertId}/ack`, { token: coTok }) : { status: 0 };
    check("N7 co-parent WITH the 'alerts' permission can acknowledge an alert (200)", ack.status === 200, `alerts=${alertsA.status} ack=${ack.status} id=${alertId ?? "none"}`);
  }
}

// ── O. one-time MFA recovery codes (ADR-0023 Option A) ──────────────────────
// The unit suite proves the state machine against a mock; these checks prove the *live* contract on
// a disposable account: ten codes shown once, a code works exactly once, the batch dies with it, the
// recovery token is not a session, and it cannot outlive the recovery it served.
console.log("\n── O. MFA recovery codes (ADR-0023) ──");

/** RFC 6238 TOTP (SHA-1, 30 s, 6 digits) — the probe must compute a real code from the secret. */
const totpCode = (secretB32, at = Date.now()) => {
  const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  const key = [];
  let bits = 0;
  let value = 0;
  for (const ch of secretB32.toUpperCase()) {
    const idx = ALPHABET.indexOf(ch);
    if (idx === -1) continue;
    value = (value << 5) | idx;
    bits += 5;
    if (bits >= 8) {
      key.push((value >>> (bits - 8)) & 255);
      bits -= 8;
      value &= (1 << bits) - 1;
    }
  }
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(Math.floor(at / 1000 / 30)));
  const digest = createHmac("sha1", Buffer.from(key)).update(counter).digest();
  const offset = digest[digest.length - 1] & 0x0f;
  const bin = ((digest[offset] & 0x7f) << 24) | (digest[offset + 1] << 16) | (digest[offset + 2] << 8) | digest[offset + 3];
  return String(bin % 1_000_000).padStart(6, "0");
};
/** The next window's code: replay protection refused a second use of an earlier step's counter. */
const nextTotp = (secret) => totpCode(secret, Date.now() + 30_000);
/** Sleep past the current 30-second window so a code for the following one is unambiguously newer. */
const waitForNextTotpWindow = async () => {
  await new Promise((resolve) => setTimeout(resolve, 30_000 - (Date.now() % 30_000) + 1_000));
};

const RECOVERY_CODE_FORMAT = /^[0-9A-HJKMNP-TV-Z]{4}(-[0-9A-HJKMNP-TV-Z]{4}){3}$/;
const recEmail = `qa-recovery-${stamp}@example.com`;
const recReg = await call("POST", "/v1/auth/register", {
  body: { email: recEmail, password: PASSWORD, displayName: "QA Recovery", familyName: "QA Recovery Family", region: "US" },
});
let recToken = recReg.data?.token;
const recEnroll = await call("POST", "/v1/auth/mfa/enroll", { token: recToken, body: {} });
const recSecret = recEnroll.data?.secret ?? "";
const recVerify = await call("POST", "/v1/auth/mfa/verify", {
  token: recToken,
  // One window back: three TOTP-consuming steps follow (login, re-verify, second login), and the
  // replay guard only accepts a counter above the last one it saw.
  body: { code: recSecret ? totpCode(recSecret, Date.now() - 30_000) : "000000" },
});
let recCodes = Array.isArray(recVerify.data?.recoveryCodes) ? recVerify.data.recoveryCodes : [];
check("O1 MFA verification returns ten distinct one-time codes in XXXX-XXXX-XXXX-XXXX form", recReg.status === 201 && recEnroll.status === 200 && recVerify.status === 200 && recVerify.data?.mfaEnabled === true && recCodes.length === 10 && new Set(recCodes).size === 10 && recCodes.every((c) => RECOVERY_CODE_FORMAT.test(c)), `register=${recReg.status} enroll=${recEnroll.status} verify=${recVerify.status} codes=${recCodes.length} distinct=${new Set(recCodes).size}`);

// Enrolment verification revoked every session, so a fresh login needs the next TOTP window.
const recLogin = await call("POST", "/v1/auth/login", {
  body: { email: recEmail, password: PASSWORD, code: recSecret ? totpCode(recSecret) : "000000" },
});
let recSession = recLogin.data?.token;
const genNoAuth = await call("POST", "/v1/auth/mfa/recovery-codes", { token: recSession, body: {} });
const genWrongPw = await call("POST", "/v1/auth/mfa/recovery-codes", { token: recSession, body: { password: "WrongPassw0rd!" } });
check("O2 generating recovery codes needs the password or a current TOTP, never the session alone (401 reauth_required)", recLogin.status === 200 && genNoAuth.status === 401 && genNoAuth.data?.error === "reauth_required" && genWrongPw.status === 401 && genWrongPw.data?.error === "reauth_required", `login=${recLogin.status} noBody=${genNoAuth.status}/${genNoAuth.data?.error} wrongPw=${genWrongPw.status}/${genWrongPw.data?.error}`);

const recWrongCode = await call("POST", "/v1/auth/mfa/recover", { body: { email: recEmail, password: PASSWORD, code: "0000-0000-0000-0000" } });
const recWrongPassword = await call("POST", "/v1/auth/mfa/recover", { body: { email: recEmail, password: "WrongPassw0rd!", code: recCodes[0] } });
const recUnknownEmail = await call("POST", "/v1/auth/mfa/recover", { body: { email: `nobody-recovery-${stamp}@example.com`, password: PASSWORD, code: recCodes[0] } });
check("O3 a wrong code, a wrong password and an unknown address answer the same 401 invalid_recovery (no oracle, batch untouched)", [recWrongCode, recWrongPassword, recUnknownEmail].every((r) => r.status === 401 && r.data?.error === "invalid_recovery"), `wrongCode=${recWrongCode.status}/${recWrongCode.data?.error} wrongPw=${recWrongPassword.status}/${recWrongPassword.data?.error} unknown=${recUnknownEmail.status}/${recUnknownEmail.data?.error}`);

const recovered = await call("POST", "/v1/auth/mfa/recover", { body: { email: recEmail, password: PASSWORD, code: recCodes[0] } });
const recoveryToken = recovered.data?.recoveryToken;
const recoveryClaims = recoveryToken ? JSON.parse(Buffer.from(recoveryToken.split(".")[1], "base64url").toString()) : {};
check("O4 a valid code recovers the account and returns only a purpose-scoped token (no role, no familyId)", recovered.status === 200 && typeof recoveryToken === "string" && Object.keys(recovered.data ?? {}).length === 1 && recoveryClaims.purpose === "mfa_recovery" && recoveryClaims.role === undefined && recoveryClaims.familyId === undefined, `status=${recovered.status} keys=${Object.keys(recovered.data ?? {}).join(",")} claims=${JSON.stringify({ purpose: recoveryClaims.purpose, role: recoveryClaims.role, familyId: recoveryClaims.familyId })}`);

const replayCode = await call("POST", "/v1/auth/mfa/recover", { body: { email: recEmail, password: PASSWORD, code: recCodes[0] } });
check("O5 the same recovery code is refused once spent (401 invalid_recovery)", replayCode.status === 401 && replayCode.data?.error === "invalid_recovery", `got ${replayCode.status}/${replayCode.data?.error}`);

const siblingCode = await call("POST", "/v1/auth/mfa/recover", { body: { email: recEmail, password: PASSWORD, code: recCodes[1] } });
check("O6 another code from the same batch is dead after the first use (delete-all-on-use)", siblingCode.status === 401 && siblingCode.data?.error === "invalid_recovery", `got ${siblingCode.status}/${siblingCode.data?.error} tested=${recCodes[1] ? "batch-code-2" : "none"}`);

const recMe = await call("GET", "/v1/family/me", { token: recoveryToken });
const recLogoutAll = await call("POST", "/v1/auth/logout-all", { token: recoveryToken });
const recGen = await call("POST", "/v1/auth/mfa/recovery-codes", { token: recoveryToken, body: {} });
check("O7 the recovery token is not a session: /family/me, /logout-all and code generation refuse it (401)", recMe.status === 401 && recLogoutAll.status === 401 && recGen.status === 401, `me=${recMe.status} logoutAll=${recLogoutAll.status} recoveryCodes=${recGen.status}`);

if (process.env.JWT_SECRET) {
  const nowSec = Math.floor(Date.now() / 1000);
  const recSub = recoveryClaims.sub;
  const forgedUnknown = signHs256Jwt({ sub: recSub, purpose: "mfa_recovery", jti: "0000000000000000", iat: nowSec, exp: nowSec + 900 }, process.env.JWT_SECRET);
  const forgedExpired = recoveryToken
    ? signHs256Jwt({ ...recoveryClaims, exp: nowSec - 60 }, process.env.JWT_SECRET)
    : "x.y.z";
  const forgedOther = signHs256Jwt({ ...recoveryClaims, sub: "00000000-0000-0000-0000-000000000000" }, process.env.JWT_SECRET);
  const unknownJti = await call("POST", "/v1/auth/mfa/enroll", { token: forgedUnknown, body: {} });
  const expired = await call("POST", "/v1/auth/mfa/enroll", { token: forgedExpired, body: {} });
  const otherSub = await call("POST", "/v1/auth/mfa/enroll", { token: forgedOther, body: {} });
  check("O8 an expired, unknown-jti or wrong-subject recovery token is refused by /mfa/enroll (401)", unknownJti.status === 401 && expired.status === 401 && otherSub.status === 401, `unknownJti=${unknownJti.status} expired=${expired.status} otherSub=${otherSub.status}`);
} else {
  target("O8 an expired, unknown-jti or wrong-subject recovery token is refused by /mfa/enroll", "JWT_SECRET not present in the probe environment, so a forged recovery token cannot be minted here");
}

const reEnroll = await call("POST", "/v1/auth/mfa/enroll", { token: recoveryToken, body: {} });
const newSecret = reEnroll.data?.secret ?? "";
const reVerify = await call("POST", "/v1/auth/mfa/verify", { token: recoveryToken, body: { code: newSecret ? nextTotp(newSecret) : "000000" } });
const newCodes = Array.isArray(reVerify.data?.recoveryCodes) ? reVerify.data.recoveryCodes : [];
const reuseAfterEnable = await call("POST", "/v1/auth/mfa/enroll", { token: recoveryToken, body: {} });
check("O9 the recovery token re-enrols MFA, gets a fresh batch, and is refused once MFA is on again", reEnroll.status === 200 && reVerify.status === 200 && newCodes.length === 10 && newCodes.every((c) => RECOVERY_CODE_FORMAT.test(c)) && reuseAfterEnable.status === 401, `enroll=${reEnroll.status} verify=${reVerify.status} codes=${newCodes.length} reuse=${reuseAfterEnable.status}`);
check("O10 the re-enrolled account still needs the new authenticator at login (no password-only window left)", (await call("POST", "/v1/auth/login", { body: { email: recEmail, password: PASSWORD } })).status === 401, "password-only login must be 401 mfa_required");

// A window has to pass before the next TOTP is strictly above the one re-verification consumed.
await waitForNextTotpWindow();
const recLogin2 = await call("POST", "/v1/auth/login", {
  body: { email: recEmail, password: PASSWORD, code: newSecret ? nextTotp(newSecret) : "000000" },
});
recSession = recLogin2.data?.token;
const regen = await call("POST", "/v1/auth/mfa/recovery-codes", { token: recSession, body: { password: PASSWORD } });
const regenCodes = Array.isArray(regen.data?.recoveryCodes) ? regen.data.recoveryCodes : [];
const oldAfterRegen = await call("POST", "/v1/auth/mfa/recover", { body: { email: recEmail, password: PASSWORD, code: newCodes[0] } });
check("O11 regenerating with the password replaces the batch: the old set is refused, ten new codes are issued", recLogin2.status === 200 && regen.status === 200 && regenCodes.length === 10 && newCodes.every((c) => !regenCodes.includes(c)) && oldAfterRegen.status === 401, `login=${recLogin2.status} regen=${regen.status} new=${regenCodes.length} oldCode=${oldAfterRegen.status}`);

// #183: recovery clears the authenticator, not the policy. The password alone must not produce a
// session — nor the re-enrolment credential that would let it bind one — and the account must still
// be an MFA account after the token finishes the flow.
const recoveredAgain = await call("POST", "/v1/auth/mfa/recover", { body: { email: recEmail, password: PASSWORD, code: regenCodes[0] } });
const recoveryToken2 = recoveredAgain.data?.recoveryToken;
const passwordOnly = await call("POST", "/v1/auth/login", { body: { email: recEmail, password: PASSWORD } });
check("O12 after a recovery the password alone gets no session (401 mfa_reenroll_required, no token, no refreshToken, no recovery token)", recoveredAgain.status === 200 && passwordOnly.status === 401 && passwordOnly.data?.error === "mfa_reenroll_required" && passwordOnly.data?.token === undefined && passwordOnly.data?.refreshToken === undefined && passwordOnly.data?.recoveryToken === undefined && Object.keys(passwordOnly.data ?? {}).join(",") === "error", `recover=${recoveredAgain.status} login=${passwordOnly.status}/${passwordOnly.data?.error} body=${JSON.stringify(passwordOnly.data ?? {}).slice(0, 160)}`);

// The next TOTP window is needed: re-verification must present a counter above the one O10's login used.
await waitForNextTotpWindow();
const enrollAgain = await call("POST", "/v1/auth/mfa/enroll", { token: recoveryToken2, body: {} });
const secretAgain = enrollAgain.data?.secret ?? "";
const verifyAgain = await call("POST", "/v1/auth/mfa/verify", { token: recoveryToken2, body: { code: secretAgain ? nextTotp(secretAgain) : "000000" } });
const afterRecovery = await call("POST", "/v1/auth/login", { body: { email: recEmail, password: PASSWORD } });
check("O13 the recovery token still re-enrols and re-verifies, and the account is back to a normal MFA account", enrollAgain.status === 200 && verifyAgain.status === 200 && Array.isArray(verifyAgain.data?.recoveryCodes) && verifyAgain.data.recoveryCodes.length === 10 && afterRecovery.status === 401 && afterRecovery.data?.error === "mfa_required", `enroll=${enrollAgain.status} verify=${verifyAgain.status} codes=${verifyAgain.data?.recoveryCodes?.length} login=${afterRecovery.status}/${afterRecovery.data?.error}`);


console.log("\n── H. surface ──");
const unknownRoute = await call("GET", `/v1/does-not-exist-${stamp}`);
check("H1 unknown route -> 404 JSON", unknownRoute.status === 404, `got ${unknownRoute.status}`);

const healthDeep = await call("GET", "/health/deep");
check("H2 /health/deep reports db+redis", healthDeep.status === 200 && healthDeep.data?.db === "up" && healthDeep.data?.redis === "up", JSON.stringify(healthDeep.data));

// ── summary ─────────────────────────────────────────────────────────────────
console.log(`\n───────────  ${PASS.length} passed · ${FAIL.length} failed · ${TARGETS.length} targets · ${NOTE.length} notes · rate limit: ${rateLimited429} x 429  ───────────`);
if (rateLimited429) console.log(`RATE LIMIT: ${rateLimited429} x 429 observed; each was retried once and the retry succeeded, so no check above judged a throttled response.`);
if (FAIL.length) console.log("FAILURES (must fix to make this gate green):\n- " + FAIL.join("\n- "));
if (TARGETS.length) console.log("TARGETS (tracked, need a design decision, not gating):\n- " + TARGETS.join("\n- "));
if (NOTE.length) console.log("NOTES:\n- " + NOTE.join("\n- "));
process.exit(FAIL.length ? 1 : 0);
