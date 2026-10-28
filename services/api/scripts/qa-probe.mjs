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

/** Stops the run from the top level without `process.exit()` — see the note in the handler below. */
class StopRun extends Error {
  constructor(code) {
    super("stop");
    this.code = code;
  }
}

process.on("uncaughtException", (err) => {
  if (err instanceof RateLimitAbort) {
    for (const ws of OPEN_SOCKETS) { try { ws.close(); } catch { /* already closing */ } }
    process.exitCode = 2;
    return; // let the loop drain: process.exit() after several fetches trips a Node 24/Windows libuv assertion
  }
  // #309: the same assertion, on a different path. When a `setup:` check fails, the early exit used to
  // call `process.exit(1)` while a `fetch` keep-alive socket was closing, and on Node 24/Windows the
  // process died with 0xC0000409 instead of 1 — so the stub test in `test/qa-probe-rate-limit.test.ts`
  // read a crash, not a FAIL. Setting the code and letting the loop drain is what the aborts do above.
  if (err instanceof StopRun) {
    for (const ws of OPEN_SOCKETS) { try { ws.close(); } catch { /* already closing */ } }
    process.exitCode = err.code;
    return;
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

// 429s the API itself answers, as product decisions; every other 429 is throttling (see call()).
const APP_429_ERRORS = new Set(["reset_limit_reached"]);

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

/**
 * The global limiter's window as the last response reported it (200 a minute per address, server.ts).
 * Before Q, the run sends close to 200 requests inside one minute, so `call` waits out the window when
 * it is nearly spent, as section Q's `qcall` does, instead of tripping the 429 abort. Only the global
 * bucket is read (x-ratelimit-limit 200): the auth and pairing buckets are what some checks test.
 */
const globalWindow = { remaining: Infinity, resetAt: 0 };
const GLOBAL_LIMIT = "200";

async function call(method, path, { token, body, hmac, secret, rawBody, headers } = {}) {
  if (globalWindow.remaining <= 3 && globalWindow.resetAt > Date.now()) {
    await new Promise((r) => setTimeout(r, globalWindow.resetAt - Date.now() + 300));
    globalWindow.remaining = Infinity;
  }
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
  if (res.headers.get("x-ratelimit-limit") === GLOBAL_LIMIT) {
    const remaining = Number(res.headers.get("x-ratelimit-remaining"));
    const reset = Number(res.headers.get("x-ratelimit-reset"));
    if (Number.isFinite(remaining)) globalWindow.remaining = remaining;
    if (Number.isFinite(reset)) globalWindow.resetAt = Date.now() + reset * 1000;
  }
  // The API's own 429s are answers, not throttling: ADR-0031 decision 7 refuses a fourth reset request
  // in 30 days with `429 reset_limit_reached`. Only the codes in APP_429_ERRORS go back to the check that
  // asked; any other 429 (the rate limiter's "Too Many Requests", a proxy's) is throttling, as before (#112).
  if (res.status === 429) {
    const peek = await res.clone().json().catch(() => null);
    if (APP_429_ERRORS.has(peek?.error)) return { status: 429, data: peek };
  }
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
  throw new StopRun(1);
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

// Plan 2.7 F1 (Claude, #329): the old B7 called GET /v1/insights/:childId, a route that was never
// registered, so the router's 404 passed it whatever the guards did. It now targets a child-scoped
// read the B group did not cover, and asserts the exact refusal. Mutant: drop requireFamily from
// content.ts:266 -> 200, and this fails.
const crossSearches = await call("GET", `/v1/content/searches?childId=${kidA}`, { token: tokenB });
check("B7 flagged searches of another family's child are refused (403 forbidden)", crossSearches.status === 403 && crossSearches.data?.error === "forbidden", `got ${crossSearches.status} ${JSON.stringify(crossSearches.data)}`);

const crossDevRegister = await call("POST", "/v1/devices/register", {
  token: tokenB,
  body: { childId: kidA, platform: "android", model: "evil", osVersion: "1" },
});
check("B8 register device against other family's child (403/404)", [403, 404].includes(crossDevRegister.status), `got ${crossDevRegister.status}`);

// Plan 2.7 F1 (Claude, #329): the old B9 called PUT /v1/digests, a route that was never registered
// (digests live at /prefs and /send-now), so it could not fail. Mutant: drop requireFamily from
// social.ts:166 -> 200, and this fails.
const crossSocial = await call("GET", `/v1/social/events?childId=${kidA}`, { token: tokenB });
check("B9 social events of another family's child are refused (403 forbidden)", crossSocial.status === 403 && crossSocial.data?.error === "forbidden", `got ${crossSocial.status} ${JSON.stringify(crossSocial.data)}`);

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
/**
 * The device claims `code` and the family's parent (`parentToken`) taps Allow; the device's poll then
 * gets the token (plan 2.7, osra-security#3 PR 2). Answers with the poll's response, which has the body
 * `/pair/claim` used to return. A claim that is not 202 comes back as it is.
 */
async function claimApproved(code, body, parentToken) {
  const claim = await call("POST", "/v1/devices/pair/claim", { body: { code, ...body } });
  if (claim.status !== 202) return claim;
  const approve = await call("POST", `/v1/devices/pair/claims/${claim.data.claimId}/approve`, { token: parentToken });
  if (approve.status !== 200) return approve;
  return call("POST", `/v1/devices/pair/claims/${claim.data.claimId}/poll`, { body: { pollSecret: claim.data.pollSecret } });
}

/** Parent mints a code, the device claims it and the parent allows it — a real device JWT + per-device secret. */
async function pairDevice(childId, label) {
  const code = (await call("POST", "/v1/devices/pair", { token: tokenA, body: { childId } })).data?.code;
  if (!code) return { status: 0 };
  const claim = await claimApproved(code, { platform: "android", model: label, osVersion: "14", deviceName: label }, tokenA);
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

// G2b–G2g: the parent approves each new device (plan 2.7, osra-security#3 PR 2). One code, three claims
// (the /pair/claim bucket is 10 a minute and the whole run uses nine). Mutants, run against a live API:
// mint the token in the claim handler again -> G2b fails (201, a token before anyone allowed it); drop
// the SET NX on `pair:<code>:claim` -> G2c (202); skip pollSecretMatches -> G2d (201); drop the family
// comparison in the approve route -> G2e (200); leave the code in place on Deny -> G2g (409).
{
  const code = (await call("POST", "/v1/devices/pair", { token: tokenA, body: { childId: kidA } })).data?.code;
  const claim = code ? await call("POST", "/v1/devices/pair/claim", { body: { code, platform: "android", model: "qa-unapproved", osVersion: "14" } }) : { status: 0, data: null };
  const { claimId, pollSecret } = claim.data ?? {};
  if (claim.status === 202 && claimId && pollSecret) {
    const poll = await call("POST", `/v1/devices/pair/claims/${claimId}/poll`, { body: { pollSecret } });
    check("G2b a pairing claim the parent has not allowed gets no token (claim 202, poll 202 pending)", poll.status === 202 && !poll.data?.token && !claim.data?.token, `claim=${claim.status} poll=${poll.status} token=${!!(poll.data?.token ?? claim.data?.token)}`);
    const second = await call("POST", "/v1/devices/pair/claim", { body: { code, platform: "android", model: "qa-second", osVersion: "14" } });
    check("G2c a second claim on a code with a pending claim is refused (409 claim_pending)", second.status === 409 && second.data?.error === "claim_pending", `got ${second.status} ${second.data?.error ?? ""}`);
    // Family B tries while the claim is still pending, so a missing family check would let it through.
    const view = await call("GET", `/v1/devices/pair/${code}/claim`, { token: tokenB });
    const otherAllow = await call("POST", `/v1/devices/pair/claims/${claimId}/approve`, { token: tokenB });
    await call("POST", `/v1/devices/pair/claims/${claimId}/approve`, { token: tokenA });
    const wrong = await call("POST", `/v1/devices/pair/claims/${claimId}/poll`, { body: { pollSecret: "x".repeat(43) } });
    check("G2d an approved claim polled with the wrong secret gets no token (404)", wrong.status === 404 && !wrong.data?.token, `got ${wrong.status}`);
    check("G2e another family's parent can neither see nor decide the claim (404, 404)", view.status === 404 && otherAllow.status === 404, `view=${view.status} approve=${otherAllow.status}`);
  } else {
    target("G2b–G2e a pending claim (no 202 claim here)", `pair code=${!!code} claim=${claim.status}`);
  }
  // Deny on a fresh claim: the phone is told, and the code is burned (a second try on it is 404).
  const code2 = (await call("POST", "/v1/devices/pair", { token: tokenA, body: { childId: kidA } })).data?.code;
  const claim2 = code2 ? await call("POST", "/v1/devices/pair/claim", { body: { code: code2, platform: "android", model: "qa-denied", osVersion: "14" } }) : { status: 0, data: null };
  if (claim2.status === 202) {
    const deny = await call("POST", `/v1/devices/pair/claims/${claim2.data.claimId}/deny`, { token: tokenA });
    const poll = await call("POST", `/v1/devices/pair/claims/${claim2.data.claimId}/poll`, { body: { pollSecret: claim2.data.pollSecret } });
    check("G2f a denied claim gets no token (deny 200, poll 410 claim_denied)", deny.status === 200 && poll.status === 410 && poll.data?.error === "claim_denied", `deny=${deny.status} poll=${poll.status} ${poll.data?.error ?? ""}`);
    const again = await call("POST", "/v1/devices/pair/claim", { body: { code: code2, platform: "android", model: "qa-denied", osVersion: "14" } });
    check("G2g Deny burns the code: claiming it again is 404", again.status === 404, `got ${again.status} ${again.data?.error ?? ""}`);
  } else {
    target("G2f–G2g a denied claim (no 202 claim here)", `pair code=${!!code2} claim=${claim2.status}`);
  }
}

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

  // Plan 2.7 F4 (Claude, #329, 2026-10-23): a location ping comes from the child's device. A parent
  // JWT is refused with 403 device_role_required before the body is read — the former G15 ("parent
  // ping … still succeeds (201)") and G16 (a parent-supplied deviceId of another child) are superseded,
  // see scripts/probe-gate-acks.json. Mutant: restore `if (user?.role === "parent" && user.familyId) return;`
  // in pingAuth (location.ts) -> G15 gets 201 and fails.
  const ownPing = await call("POST", "/v1/location/ping", {
    token: tokenA,
    body: { childId: kidA2, deviceId: d2.deviceId, lat: 37.7749, lng: -122.4194, accuracyM: 5 },
  });
  check("G15 a parent location ping is refused even for its own child's device (403 device_role_required)", ownPing.status === 403 && ownPing.data?.error === "device_role_required", `got ${ownPing.status} ${JSON.stringify(ownPing.data)}`);

  // The device-token identity check stays (location.ts, the `user.role === "device"` branch): a device
  // may not file a ping under another device's id. Mutant: drop the topDeviceId comparison -> 201.
  const crossDevPing = await call("POST", "/v1/location/ping", {
    token: d2.token,
    body: { childId: kidA2, deviceId: deviceIdA, lat: 37.7749, lng: -122.4194, accuracyM: 5 },
  });
  check("G16 a device token whose body names another device is refused (403 device_mismatch)", crossDevPing.status === 403 && crossDevPing.data?.error === "device_mismatch", `got ${crossDevPing.status} ${JSON.stringify(crossDevPing.data)}`);

  const crossFamPing = await call("POST", "/v1/location/ping", {
    token: tokenB,
    body: { childId: kidA, deviceId: deviceIdA, lat: 37.7749, lng: -122.4194, accuracyM: 5 },
  });
  // Since plan 2.7 F4 the parent refusal comes before the family check, so the error is named exactly.
  check("G17 parent ping for another family's child is still forbidden (403)", crossFamPing.status === 403 && crossFamPing.data?.error === "device_role_required", `got ${crossFamPing.status} ${JSON.stringify(crossFamPing.data)}`);

  // #124 (audit finding 5): family scoping is not device identity. Device A could post telemetry for
  // sibling B in the same family, refreshing B's lastSeen/battery and B's child's day totals, because
  // `requireFamily` only proves the target shares the caller's familyId — every device in a family
  // does. Agent-write routes therefore compose `requireOwnDevice` after it
  // (`services/api/src/middleware/requireFamily.ts`); since plan 2.7 F2 a parent token is refused too.
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

  // #319 (roadmap 1.5). `POST /:id/push-token` is the device's own registration path and nothing
  // else: Claude's decision (2026-10-23) keeps the path the Android client already calls and makes it
  // device-only — `requireFamily` + role `device` + `requireOwnDevice` — so the parent capability that
  // used to sit on it is gone. P1 proves the route actually accepts the caller it exists for (so the
  // two refusals below cannot pass by refusing everyone); P2/P3 are the half a later "let parents do
  // it again" edit would relax, and the parent-write case is also pinned at N6d in its permission
  // shape.
  const selfPush = await call("POST", `/v1/devices/${d2.deviceId}/push-token`, { token: d2.token, body: { token: `fcm-self-${stamp}-device-token` } });
  check("P1 a device registers its own push token (204 with no body)", selfPush.status === 204 && selfPush.data === null, `got ${selfPush.status} ${JSON.stringify(selfPush.data)}`);
  const siblingPush = await call("POST", `/v1/devices/${deviceIdA}/push-token`, { token: d2.token, body: { token: `fcm-sibling-${stamp}-device-token` } });
  check("P2 a device cannot set a sibling device's push token (403 forbidden)", siblingPush.status === 403 && siblingPush.data?.error === "forbidden", `got ${siblingPush.status} ${JSON.stringify(siblingPush.data)}`);
  const parentPush = await call("POST", `/v1/devices/${d2.deviceId}/push-token`, { token: tokenA, body: { token: `fcm-parent-${stamp}-device-token` } });
  check("P3 a parent cannot set a device's push token (403 device_role_required)", parentPush.status === 403 && parentPush.data?.error === "device_role_required", `got ${parentPush.status} ${JSON.stringify(parentPush.data)}`);

  // Roadmap 5.8's second half: "idle child phone <= 3 requests per 10 min". The rate must be COUNTED before it
  // can be a gate, so this check always reports the measurement and gates only once a threshold has been
  // measured: IDLE_BUDGET_M10 is empty until Claude measures the Flip4, and a threshold invented here would be
  // a gate that measures the author's guess.
  //
  // Counting is off unless the API runs with IDLE_BUDGET_COUNTING=1 (#346 review), so P6 must not read a zero
  // it did not measure: with the flag off the route says `counting: false` and a "0 requests" line here would
  // claim a budget from no data at all.
  const selfReq = await call("GET", `/v1/devices/${d2.deviceId}/requests`, { token: d2.token });
  check("P4 the agent does not read its own request accounting (403; the parent does)", selfReq.status === 403, `got ${selfReq.status}`);
  const parentReq = await call("GET", `/v1/devices/${d2.deviceId}/requests`, { token: tokenA });
  const reqBody = parentReq.data ?? {};
  // "Counts only" is the promise the route makes: no route key may carry an identifier, so nothing in the
  // body can say which child or which command.
  const routeKeys = Object.keys(reqBody.byRoute ?? {});
  const leaksAnId = routeKeys.some((k) => /[0-9a-f]{8}-[0-9a-f]{4}-/i.test(k) || /\d{5,}/.test(k));
  check("P5 a parent reads a device's request rate as counts only — the window is named and no route key carries an id", parentReq.status === 200 && typeof reqBody.total === "number" && typeof reqBody.windowMinutes === "number" && !leaksAnId, `got ${parentReq.status} keys=${JSON.stringify(routeKeys).slice(0, 160)} leaksAnId=${leaksAnId}`);
  const idleThreshold = process.env.IDLE_BUDGET_M10 ? Number(process.env.IDLE_BUDGET_M10) : null;
  const idleBusiest = reqBody.busiestWindow?.count ?? 0;
  if (reqBody.counting === false) {
    target(
      "P6 the idle-request budget is not measured on this run (counting disabled on the API)",
      `the API answers counting=false, so no request was recorded: "0" here would mean "nothing was written", not "the phone stayed idle"; run the API with IDLE_BUDGET_COUNTING=1 to measure`,
    );
  } else if (idleThreshold === null) {
    target(
      "P6 the idle-request budget is measured but not yet a gate (IDLE_BUDGET_M10 unset)",
      `busiest 10-minute window on this run: ${idleBusiest} request(s); the row's acceptance is <= 3, measured by Claude on the Flip4`,
    );
  } else {
    check("P6 the idle-request budget holds (busiest 10-minute window <= IDLE_BUDGET_M10)", idleBusiest <= idleThreshold, `busiest=${idleBusiest} threshold=${idleThreshold}`);
  }

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
    // #124 (audit finding 6) pinned that a co-parent without `devices` could not set a push token.
    // #319 (Claude, 2026-10-23) redefined the route as device-only, so the assertion is now stronger:
    // NO parent may set one, permission or not. The owner is the all-permissions caller, and both get
    // the same refusal. The old `403 permission_required` shape cannot occur any more —
    // `requirePermission("devices")` is no longer in the chain — so asserting it would assert a route
    // that does not exist. Superseded assertion, not a weakened one; acknowledged in
    // scripts/probe-gate-acks.json.
    const coPush = await call("POST", `/v1/devices/${deviceIdA}/push-token`, { token: coTok, body: { token: `co-probe-${stamp}-device-token` } });
    const ownerPush = await call("POST", `/v1/devices/${deviceIdA}/push-token`, { token: tokenA3, body: { token: `fcm-probe-${stamp}-device-token` } });
    check("N6d no parent may set a device push token, permission or not: the co-parent and the owner are both refused (403 device_role_required)", coPush.status === 403 && coPush.data?.error === "device_role_required" && ownerPush.status === 403 && ownerPush.data?.error === "device_role_required", `co=${coPush.status} ${JSON.stringify(coPush.data)} owner=${ownerPush.status} ${JSON.stringify(ownerPush.data)}`);
    // Roadmap 3.4: the installed-app inventory is a `rules` surface (it feeds the Rules editor).
    const coApps = await call("GET", `/v1/devices/${d2.deviceId}/apps`, { token: coTok });
    check("N6f co-parent without 'rules' cannot read the installed-app inventory (403 permission_required)", coApps.status === 403 && coApps.data?.error === "permission_required" && coApps.data?.permission === "rules", `got ${coApps.status} ${JSON.stringify(coApps.data)}`);
    // N6e ("owner push-token update (200) returns neither internalSecret nor pushToken") is retired by
    // the same decision: the owner's write is now refused, and a `204` with no body has no device
    // object that could carry `internalSecret` or `pushToken`. Both callers are covered by N6d above
    // and the device's own `204` by P1. Acknowledged in scripts/probe-gate-acks.json.
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


// ── O (cont.). MFA reset with a family witness (ADR-0031) ───────────────────
// The route for a parent who lost the authenticator AND every recovery code: password, the account's
// mailbox, a family witness (a paired child device or another owner/co-parent), then a 72-hour window,
// with no operator and no admin route (ADR-0031). `test/mfa-reset.test.ts` proves the state machine
// against a mock; these checks pin the *live* contract, including the #305 review finding that
// `GET /devices/:id/commands/history` handed the witness code itself to any parent of the family —
// O18 fails if that comes back.
//
// The mailbox: the probe has no inbox. `POST /mfa/reset/confirm` takes the link's token, and
// `/mfa/reset/request` echoes it as `confirmToken` only while no email provider is configured and
// NODE_ENV is not production (`echoResetTokens` in `services/api/src/routes/auth.ts`). On a stack with
// RESEND_API_KEY/EMAIL_FROM set, the witness half cannot be walked over HTTP; this block then reports
// one `target` naming the checks it could not run, never a silent pass. The 7-day post-window expiry
// (amendment 2026-10-22, gap 1) is a database clock the probe cannot wait for: it stays a unit test
// (`mfa-reset-expiry.test.ts`) plus `src/jobs/mfaResetExpiry.ts`, and is deliberately not asserted here.
//
// Accounts are `qa-mfa-*@example.com`, so `scripts/cleanup-test-data.sql` removes their families —
// `MfaResetRequest.parentId` cascades from `Parent`, so the reset rows go with them. No real account
// is touched, and the probe itself has no database connection (docs/TESTING.md §6).
console.log("\n── O (cont.). MFA reset with a family witness (ADR-0031) ──");
const mrEmail = `qa-mfa-reset-${stamp}@example.com`;
const mrGuardianEmail = `qa-mfa-guardian-${stamp}@example.com`;
const mrOtherEmail = `qa-mfa-other-${stamp}@example.com`;
const mrCoParentEmail = `qa-mfa-coparent-${stamp}@example.com`;
const mrReg = await call("POST", "/v1/auth/register", {
  body: { email: mrEmail, password: PASSWORD, displayName: "QA Reset Parent", familyName: "QA Reset Family", region: "US" },
});
let mrToken = mrReg.data?.token;
// The guardian: invited into the reset parent's family and moved there, so it is a real same-family
// parent whose role is deliberately partial (ADR-0031 claim 4).
const mrGuardianReg = await call("POST", "/v1/auth/register", {
  body: { email: mrGuardianEmail, password: PASSWORD, displayName: "QA Reset Guardian", familyName: "QA Guardian Family", region: "US" },
});
let mrGuardianToken = mrGuardianReg.data?.token;
// A live owner of a *different* family: section N turns parent B into a co-parent of family A, so B's
// registration token is no longer a cross-family credential by the time this block runs.
const mrOtherReg = await call("POST", "/v1/auth/register", {
  body: { email: mrOtherEmail, password: PASSWORD, displayName: "QA Other Owner", familyName: "QA Other Family", region: "US" },
});
const mrOtherToken = mrOtherReg.data?.token;
// The co-parent: a real `co-parent` of the reset family, the caller `pending` lists the requester's
// request for (amendment 2026-10-23, claim 4) and the caller whose correct credentials must not read it
// through `status` (claim 3). No second factor and no request of their own: the owner's open request
// already shows `pending` leaving the caller's own out, and a co-parent with MFA needs one more
// `/login`, which this probe cannot afford — it already makes 20, and `/login` allows 20 a minute per
// address (#313 review). Registration and the invite happen before the requester's MFA verification,
// which revokes the owner's session the invite needs.
const mrCoParentReg = await call("POST", "/v1/auth/register", {
  body: { email: mrCoParentEmail, password: PASSWORD, displayName: "QA Reset Co-Parent", familyName: "QA Co-Parent Family", region: "US" },
});
let mrCoParentToken = mrCoParentReg.data?.token;

const mrChild = await call("POST", "/v1/family/children", {
  token: mrToken,
  body: { displayName: `QA Reset Kid ${stamp}`, birthYear: 2015, consent: { method: "sms_plus", jurisdiction: "US" } },
});
const mrKid = mrChild.data?.child?.id;
// Paired, not merely registered: the witness code has to be readable from a real device queue.
const mrPair = mrKid ? await call("POST", "/v1/devices/pair", { token: mrToken, body: { childId: mrKid } }) : { status: 0 };
const mrClaim = mrPair.data?.code
  ? await claimApproved(mrPair.data.code, { platform: "android", model: "qa-mfa-reset-dev", osVersion: "14", deviceName: "qa-mfa-reset-dev" }, mrToken)
  : { status: 0 };
const mrDeviceId = mrClaim.data?.device?.id ?? mrClaim.data?.deviceId;
const mrDeviceToken = mrClaim.data?.token;

// The guardian must join while the owner's registration session is still live: verifying an MFA
// enrolment revokes every session of that parent (below), and the invite needs an owner.
const mrInvite = mrToken
  ? await call("POST", "/v1/family/invites", { token: mrToken, body: { email: mrGuardianEmail, role: "guardian", permissions: [] } })
  : { status: 0 };
const mrInviteId = mrInvite.data?.invite?.id ?? mrInvite.data?.acceptToken;
const mrGuardianAccept = mrInviteId && mrGuardianToken
  ? await call("POST", `/v1/family/invites/${mrInviteId}/accept`, { token: mrGuardianToken })
  : { status: 0 };
if (mrGuardianAccept.data?.token) mrGuardianToken = mrGuardianAccept.data.token;

// The co-parent joins the same way, as a `co-parent` — the other role `/approve` and `pending` accept.
const mrCoParentInvite = mrToken
  ? await call("POST", "/v1/family/invites", { token: mrToken, body: { email: mrCoParentEmail, role: "co-parent", permissions: [] } })
  : { status: 0 };
const mrCoParentInviteId = mrCoParentInvite.data?.invite?.id ?? mrCoParentInvite.data?.acceptToken;
const mrCoParentAccept = mrCoParentInviteId && mrCoParentToken
  ? await call("POST", `/v1/family/invites/${mrCoParentInviteId}/accept`, { token: mrCoParentToken })
  : { status: 0 };
if (mrCoParentAccept.data?.token) mrCoParentToken = mrCoParentAccept.data.token;

const mrEnroll = await call("POST", "/v1/auth/mfa/enroll", { token: mrToken, body: {} });
const mrSecret = mrEnroll.data?.secret ?? "";
// One window back, so the login below can present a strictly newer counter (the replay guard refuses
// a counter it has already seen).
const mrVerify = await call("POST", "/v1/auth/mfa/verify", { token: mrToken, body: { code: mrSecret ? totpCode(mrSecret, Date.now() - 30_000) : "000000" } });
// Verification revoked every session; this is the only session the block uses, and the witness step
// kills it (claim 2). Every session-bearing read below therefore happens before the witness passes.
const mrLogin = await call("POST", "/v1/auth/login", { body: { email: mrEmail, password: PASSWORD, code: mrSecret ? totpCode(mrSecret) : "000000" } });
const mrSession = mrLogin.data?.token;
check("setup: the MFA-reset family has MFA on, one paired device and a guardian (so the flow can be walked)", mrReg.status === 201 && mrVerify.status === 200 && mrLogin.status === 200 && !!mrKid && !!mrDeviceId && !!mrDeviceToken && mrGuardianAccept.status === 200, `register=${mrReg.status} enroll=${mrEnroll.status} verify=${mrVerify.status} login=${mrLogin.status} child=${!!mrKid} device=${!!mrDeviceId} guardian=${mrGuardianAccept.status}`);

// ADR-0031 claim 1a / decision 2.1: the request route must not become a password oracle distinct from
// `/login`. Both sides are compared — a shared wrong answer would otherwise also pass.
const mrWrongLogin = await call("POST", "/v1/auth/login", { body: { email: mrEmail, password: "WrongPassw0rd!" } });
const mrWrongRequest = await call("POST", "/v1/auth/mfa/reset/request", { body: { email: mrEmail, password: "WrongPassw0rd!" } });
const mrUnknownLogin = await call("POST", "/v1/auth/login", { body: { email: `nobody-mfa-reset-${stamp}@example.com`, password: PASSWORD } });
const mrUnknownRequest = await call("POST", "/v1/auth/mfa/reset/request", { body: { email: `nobody-mfa-reset-${stamp}@example.com`, password: PASSWORD } });
check("O14 a wrong password and an unknown address get /login's own answer from /mfa/reset/request (same status, same body)", mrWrongLogin.status === 401 && mrWrongRequest.status === mrWrongLogin.status && JSON.stringify(mrWrongRequest.data) === JSON.stringify(mrWrongLogin.data) && mrUnknownRequest.status === mrUnknownLogin.status && JSON.stringify(mrUnknownRequest.data) === JSON.stringify(mrUnknownLogin.data), `wrongPw: login=${mrWrongLogin.status}/${JSON.stringify(mrWrongLogin.data)} request=${mrWrongRequest.status}/${JSON.stringify(mrWrongRequest.data)} unknown: login=${mrUnknownLogin.status}/${JSON.stringify(mrUnknownLogin.data)} request=${mrUnknownRequest.status}/${JSON.stringify(mrUnknownRequest.data)}`);

// Claim 1b's other half / the #305 finding: `show_reset_code` has exactly one producer — the mailbox
// confirmation. A parent-issueable command of that name would let any family parent put a fake reset
// notice with a chosen code on a child's phone (`CommandSchema`, services/api/src/routes/devices.ts).
const mrParentCmd = mrDeviceId && mrSession ? await call("POST", `/v1/devices/${mrDeviceId}/command`, { token: mrSession, body: { command: "show_reset_code" } }) : { status: 0, data: {} };
const mrBaseline = mrDeviceId && mrSession ? await call("GET", `/v1/devices/${mrDeviceId}/commands/history?limit=100`, { token: mrSession }) : { status: 0, data: {} };
const mrBaselineRows = mrBaseline.data?.items ?? [];
check("O15 a parent cannot issue show_reset_code: refused 400 and nothing is queued (the reset flow is its only producer)", mrParentCmd.status === 400 && mrBaseline.status === 200 && mrBaselineRows.filter((c) => c.type === "show_reset_code").length === 0, `command=${mrParentCmd.status} history=${mrBaseline.status} queued=${JSON.stringify(mrBaselineRows.map((c) => c.type))}`);

const mrRequest = await call("POST", "/v1/auth/mfa/reset/request", { body: { email: mrEmail, password: PASSWORD } });
const mrRequestId = mrRequest.data?.requestId;
const mrConfirmToken = mrRequest.data?.confirmToken;
if (typeof mrConfirmToken !== "string") {
  target("O16-O22 the MFA reset witness half (mailbox link, show_reset_code, window, sign-in cancel)", `POST /mfa/reset/request answered ${mrRequest.status} without a confirmToken: the link is echoed only while no email provider is configured and NODE_ENV is not production (echoResetTokens, services/api/src/routes/auth.ts), so this probe cannot walk the mailbox step on this stack`);
} else {
  // Claim 1b: nothing is sent to a child device before the link is clicked.
  const mrPreConfirm = await call("GET", `/v1/devices/${mrDeviceId}/commands/history?limit=100`, { token: mrSession });
  const mrPreRows = mrPreConfirm.data?.items ?? [];
  const mrConfirm = await call("POST", "/v1/auth/mfa/reset/confirm", { body: { token: mrConfirmToken } });
  // The device's own drain — the only surface that may see the plaintext code (decision 2.3).
  const mrDrain = mrDeviceToken ? await call("GET", `/v1/devices/${mrDeviceId}/commands?ack=1`, { token: mrDeviceToken }) : { status: 0, data: [] };
  const mrDrainRows = Array.isArray(mrDrain.data) ? mrDrain.data : [];
  const mrCodeRow = mrDrainRows.find((c) => c.type === "show_reset_code");
  const mrDeviceCode = mrCodeRow?.payload?.code;
  const mrCodeKnown = /^\d{8}$/.test(String(mrDeviceCode ?? ""));
  const mrPostHistory = await call("GET", `/v1/devices/${mrDeviceId}/commands/history?limit=100`, { token: mrSession });
  const mrPostRows = mrPostHistory.data?.items ?? [];
  const mrPostCodeRows = mrPostRows.filter((c) => c.type === "show_reset_code");
  const mrPostCode = mrPostCodeRows[0] ?? {};
  const mrPostPayload = mrPostCode.payload ?? {};
  const mrPostText = JSON.stringify(mrPostHistory.data ?? {});
  const mrCodeLeak = mrCodeKnown && mrPostText.includes(String(mrDeviceCode));

  check("O16 no show_reset_code reaches the family before the mailbox link is clicked, and exactly one is sent after", mrRequest.status === 200 && !!mrRequestId && mrConfirm.status === 200 && mrPreRows.filter((c) => c.type === "show_reset_code").length === 0 && mrPostCodeRows.length === 1, `request=${mrRequest.status} confirm=${mrConfirm.status}/${mrConfirm.data?.witness} before=[${mrPreRows.map((c) => c.type).join(",")}] after=${mrPostCodeRows.length} codeExpiresAt=${mrConfirm.data?.codeExpiresAt ?? "none"}`);
  check("O17 the child's own device holds the 8-digit code, bound to this request — no parent surface does", mrDrain.status === 200 && mrCodeKnown && mrCodeRow?.payload?.requestId === mrRequestId, `drain=${mrDrain.status} rows=${JSON.stringify(mrDrainRows.map((c) => c.type))} digits=${mrCodeKnown ? 8 : 0} requestMatches=${mrCodeRow?.payload?.requestId === mrRequestId}`);
  check("O18 the parent-facing command history never carries the plaintext show_reset_code, and still shows the row with its status and expiresAt", mrPostHistory.status === 200 && mrPostCodeRows.length === 1 && !("code" in mrPostPayload) && !mrCodeLeak && typeof mrPostCode.expiresAt === "string" && Date.parse(mrPostCode.expiresAt) > Date.now() && ["pending", "delivered", "acked", "failed"].includes(mrPostCode.status), `history=${mrPostHistory.status} rows=${mrPostCodeRows.length} payloadKeys=[${Object.keys(mrPostPayload).join(",")}] status=${mrPostCode.status} expiresAt=${mrPostCode.expiresAt ?? "none"} codeInBody=${mrCodeLeak}`);

  // Claim 4: partial access is not approval. Both refusals land while the request is
  // `mailbox_confirmed`, i.e. on a request a witness could actually pass right now.
  const mrGuardianApprove = await call("POST", "/v1/auth/mfa/reset/approve", { token: mrGuardianToken, body: { requestId: mrRequestId } });
  const mrOtherApprove = await call("POST", "/v1/auth/mfa/reset/approve", { token: mrOtherToken, body: { requestId: mrRequestId } });
  check("O19 a guardian of the family and the owner of another family cannot approve a reset (403 role_not_allowed / 403 forbidden)", mrGuardianApprove.status === 403 && mrGuardianApprove.data?.error === "role_not_allowed" && mrOtherApprove.status === 403 && mrOtherApprove.data?.error === "forbidden", `guardian=${mrGuardianApprove.status}/${mrGuardianApprove.data?.error} otherFamily=${mrOtherApprove.status}/${mrOtherApprove.data?.error}`);

  // ── ADR-0031 amendment 2026-10-23 (item 1, item 2): the two read routes #311 needed ────────────
  // `POST /mfa/reset/status` is the requester's own read — they have no session — and `GET
  // /mfa/reset/pending` is another owner/co-parent's. Both are reads, and every check below names the
  // mutant that breaks it: a check that cannot fail is not a check (AGENTS.md §4).
  //
  // The owner is also the requester, so their own open request is what makes "never the caller's own
  // request" observable; the co-parent, who has none, is the caller the list is for.

  // Claim 1 (probe half): `status` writes nothing. Over HTTP that shows through four doors — the
  // request's own stage and attempt count, the parent-facing command history, `complete`'s refusal
  // (`witness_required` while the request still waits for its witness; `request_cancelled` if `status`
  // had treated itself as a sign-in) and another parent's live session (a revocation).
  // Mutants this kills: cancel/mark the row on read → complete answers request_cancelled or the stage
  // changes; an ack or an enqueue on read → the history bodies differ; a bump of the requester's or
  // another parent's session → that parent's read fails. A payload clear on read does not show here:
  // the history never shows a `show_reset_code` payload (#305), so that write, like the DB-level "rows
  // byte-identical" half, is the unit test's claim 1 — the probe deliberately has no database
  // connection (docs/TESTING.md §6).
  const mrStatusHistoryBefore = mrSession
    ? await call("GET", `/v1/devices/${mrDeviceId}/commands/history?limit=100`, { token: mrSession })
    : { status: 0, data: {} };
  const mrStatus1 = await call("POST", "/v1/auth/mfa/reset/status", { body: { email: mrEmail, password: PASSWORD, requestId: mrRequestId } });
  const mrStatus2 = await call("POST", "/v1/auth/mfa/reset/status", { body: { email: mrEmail, password: PASSWORD, requestId: mrRequestId } });
  const mrStatusHistoryAfter = mrSession
    ? await call("GET", `/v1/devices/${mrDeviceId}/commands/history?limit=100`, { token: mrSession })
    : { status: 0, data: {} };
  const mrCompleteAfterStatus = await call("POST", "/v1/auth/mfa/reset/complete", { body: { email: mrEmail, password: PASSWORD, requestId: mrRequestId } });
  const mrGuardianSessionAfter = await call("GET", "/v1/family/me", { token: mrGuardianToken });
  const mrStatusStable = mrStatus1.status === 200 && JSON.stringify(mrStatus2.data) === JSON.stringify(mrStatus1.data);
  const mrStatusHistoryStable = mrStatusHistoryBefore.status === 200 && mrStatusHistoryAfter.status === 200 && JSON.stringify(mrStatusHistoryAfter.data) === JSON.stringify(mrStatusHistoryBefore.data);
  check("O24 status writes nothing: the request stays mailbox_confirmed with five attempts, the device command history is unchanged, another parent's session still works and complete still answers witness_required", mrStatusStable && mrStatus1.data?.state === "mailbox_confirmed" && mrStatus1.data?.attemptsRemaining === 5 && typeof mrStatus1.data?.witnessDeadline === "string" && typeof mrStatus1.data?.codeExpiresAt === "string" && mrStatus1.data?.mailboxLinkExpiresAt === null && mrStatusHistoryStable && mrCompleteAfterStatus.status === 409 && mrCompleteAfterStatus.data?.error === "witness_required" && mrGuardianSessionAfter.status === 200, `status=${mrStatus1.status}/${mrStatus1.data?.state}/attempts=${mrStatus1.data?.attemptsRemaining} stable=${mrStatusStable} historyUnchanged=${mrStatusHistoryStable} complete=${mrCompleteAfterStatus.status}/${mrCompleteAfterStatus.data?.error} guardianSession=${mrGuardianSessionAfter.status}`);

  // Claim 3: another parent's valid `requestId` with the caller's own credentials is `404
  // request_not_found`, byte-identical to an id that does not exist. The caller is the co-parent, with
  // their correct email and password, asking about the requester's live request.
  // Mutants this kills: drop `request.parentId !== parent.id` (answers 200 with the other parent's
  // request — the oracle), answer 403 instead (distinguishable from "no such id"), or echo a field of
  // the other parent's request into the 404 body.
  const mrStatusOtherId = await call("POST", "/v1/auth/mfa/reset/status", { body: { email: mrCoParentEmail, password: PASSWORD, requestId: mrRequestId } });
  const mrStatusNoSuchId = await call("POST", "/v1/auth/mfa/reset/status", { body: { email: mrCoParentEmail, password: PASSWORD, requestId: randomUUID() } });
  check("O25 status on another parent's valid requestId answers 404 request_not_found, identical to an unknown id (not an oracle)", mrStatusOtherId.status === 404 && mrStatusOtherId.data?.error === "request_not_found" && mrStatusNoSuchId.status === mrStatusOtherId.status && JSON.stringify(mrStatusNoSuchId.data) === JSON.stringify(mrStatusOtherId.data) && Object.keys(mrStatusOtherId.data ?? {}).join(",") === "error", `otherId=${mrStatusOtherId.status}/${JSON.stringify(mrStatusOtherId.data)} unknownId=${mrStatusNoSuchId.status}/${JSON.stringify(mrStatusNoSuchId.data)}`);

  // Claim 4: the list is the family's, someone else's, and only what waits for a witness.
  // Mutants this kills: drop `parentId: { not: caller.id }` → the caller's own request is listed;
  // drop `familyId` → the foreign owner sees this family's request; list with no requester lookup →
  // the name and role are empty, and the prompt cannot say who is asking.
  const mrPendingAsCoParent = mrCoParentToken
    ? await call("GET", "/v1/auth/mfa/reset/pending", { token: mrCoParentToken })
    : { status: 0, data: {} };
  const mrPendingAsOwner = mrSession
    ? await call("GET", "/v1/auth/mfa/reset/pending", { token: mrSession })
    : { status: 0, data: {} };
  const mrPendingAsOtherFamily = await call("GET", "/v1/auth/mfa/reset/pending", { token: mrOtherToken });
  const mrPendingCoParentIds = (mrPendingAsCoParent.data?.requests ?? []).map((r) => r.requestId);
  const mrPendingOwnerIds = (mrPendingAsOwner.data?.requests ?? []).map((r) => r.requestId);
  const mrPendingOtherIds = (mrPendingAsOtherFamily.data?.requests ?? []).map((r) => r.requestId);
  const mrPendingEntry = (mrPendingAsCoParent.data?.requests ?? [])[0] ?? {};
  check("O26 pending lists the other parent's open request — never the caller's own, never another family's — with the requester's name and role", mrPendingAsCoParent.status === 200 && JSON.stringify(mrPendingCoParentIds) === JSON.stringify([mrRequestId]) && mrPendingEntry.state === "mailbox_confirmed" && mrPendingEntry.requester?.displayName === "QA Reset Parent" && mrPendingEntry.requester?.role === "owner" && typeof mrPendingEntry.requester?.parentId === "string" && typeof mrPendingEntry.witnessDeadline === "string" && mrPendingEntry.windowEndsAt === null && mrPendingAsOwner.status === 200 && mrPendingOwnerIds.length === 0 && mrPendingAsOtherFamily.status === 200 && mrPendingOtherIds.length === 0, `coParent=${mrPendingAsCoParent.status}/[${mrPendingCoParentIds.join(",")}] requester=${mrPendingEntry.requester?.displayName}/${mrPendingEntry.requester?.role} deadline=${mrPendingEntry.witnessDeadline ?? "none"} owner=${mrPendingAsOwner.status}/[${mrPendingOwnerIds.join(",")}] otherFamily=${mrPendingAsOtherFamily.status}/[${mrPendingOtherIds.join(",")}]`);

  // Claim 4, the refusal: a `guardian` is refused exactly as on `/approve`, and the list needs a
  // session at all. Mutants this kills: allow the guardian (200 with the family's requests), or drop
  // `preHandler: requireJwt` (an anonymous read of who is resetting their second factor).
  const mrPendingAsGuardian = await call("GET", "/v1/auth/mfa/reset/pending", { token: mrGuardianToken });
  const mrPendingAnonymous = await call("GET", "/v1/auth/mfa/reset/pending");
  check("O27 pending refuses a guardian (403 role_not_allowed) and an unauthenticated caller (401)", mrPendingAsGuardian.status === 403 && mrPendingAsGuardian.data?.error === "role_not_allowed" && mrPendingAnonymous.status === 401, `guardian=${mrPendingAsGuardian.status}/${mrPendingAsGuardian.data?.error} anonymous=${mrPendingAnonymous.status}/${mrPendingAnonymous.data?.error}`);

  // Claim 5: neither read carries a credential or another parent's data — the field lists are the
  // amendment's, exactly. Mutants this kills: return the row (`...request` → `codeHash` and
  // `witnessRef` appear, and the key list grows), return the plaintext code, or return the
  // requester's email address instead of their name.
  const mrStatusKeyList = Object.keys(mrStatus1.data ?? {}).sort().join(",");
  const mrPendingKeyList = Object.keys(mrPendingEntry).sort().join(",");
  const mrRequesterKeyList = Object.keys(mrPendingEntry.requester ?? {}).sort().join(",");
  const mrReadText = JSON.stringify(mrStatus1.data ?? {}) + JSON.stringify(mrPendingAsCoParent.data ?? {});
  const mrReadLeak = ["codeHash", "witnessRef", "failedCodeAttempts"].filter((key) => mrReadText.includes(key));
  check("O28 neither read carries codeHash, witnessRef, the plaintext code or the requester's email, and both bodies are exactly the documented field list", mrStatusKeyList === "attemptsRemaining,codeExpiresAt,createdAt,emailConfirmedAt,mailboxLinkExpiresAt,outcomeAt,requestId,state,windowEndsAt,witnessAt,witnessDeadline,witnessKind" && mrPendingKeyList === "createdAt,emailConfirmedAt,requestId,requester,state,windowEndsAt,witnessDeadline" && mrRequesterKeyList === "displayName,parentId,role" && mrReadLeak.length === 0 && mrCodeKnown && !mrReadText.includes(String(mrDeviceCode)) && !mrReadText.includes(mrEmail), `statusKeys=[${mrStatusKeyList}] pendingKeys=[${mrPendingKeyList}] requesterKeys=[${mrRequesterKeyList}] leaked=[${mrReadLeak.join(",")}] codeInBody=${mrCodeKnown ? mrReadText.includes(String(mrDeviceCode)) : "unknown"} emailInBody=${mrReadText.includes(mrEmail)}`);

  const mrWitness = mrCodeKnown ? await call("POST", "/v1/auth/mfa/reset/witness", { body: { requestId: mrRequestId, code: String(mrDeviceCode) } }) : { status: 0, data: {} };
  // Claim 1d: before the window ends nothing changes at all. The factor is still bound — a password
  // alone is answered `mfa_required`, not the `mfa_reenroll_required` an early completion would leave.
  const mrEarlyComplete = await call("POST", "/v1/auth/mfa/reset/complete", { body: { email: mrEmail, password: PASSWORD, requestId: mrRequestId } });
  const mrPasswordOnly = await call("POST", "/v1/auth/login", { body: { email: mrEmail, password: PASSWORD } });
  check("O20 complete inside the 72-hour window is refused (409 window_open) and leaves the factor bound (password-only login still 401 mfa_required)", mrWitness.status === 200 && mrWitness.data?.state === "witness_passed" && mrEarlyComplete.status === 409 && mrEarlyComplete.data?.error === "window_open" && mrPasswordOnly.status === 401 && mrPasswordOnly.data?.error === "mfa_required", `witness=${mrWitness.status}/${mrWitness.data?.state} windowEndsAt=${mrWitness.data?.windowEndsAt ?? "none"} complete=${mrEarlyComplete.status}/${mrEarlyComplete.data?.error} passwordOnly=${mrPasswordOnly.status}/${mrPasswordOnly.data?.error}`);

  // Amendment 2026-10-22, gap 3 / SPEC's state table: a window a witness has already passed is not
  // restartable, even by the parent it belongs to.
  const mrSecondRequest = await call("POST", "/v1/auth/mfa/reset/request", { body: { email: mrEmail, password: PASSWORD } });
  check("O21 a second request while the first is witness_passed is refused (409 reset_already_pending): the window is not restartable", mrSecondRequest.status === 409 && mrSecondRequest.data?.error === "reset_already_pending" && mrSecondRequest.data?.requestId === undefined, `got ${mrSecondRequest.status}/${mrSecondRequest.data?.error} newRequestId=${mrSecondRequest.data?.requestId ? "present" : "none"}`);

  // ADR-0031 decision 3, the main defence: a parent who can sign in is not locked out, so the request
  // was not theirs. `nextTotp` is the next step's code — one above the counter the login above used.
  const mrCancelLogin = await call("POST", "/v1/auth/login", { body: { email: mrEmail, password: PASSWORD, code: mrSecret ? nextTotp(mrSecret) : "000000" } });
  const mrLateComplete = await call("POST", "/v1/auth/mfa/reset/complete", { body: { email: mrEmail, password: PASSWORD, requestId: mrRequestId } });
  check("O22 a successful /login by the parent during the window cancels the request: complete answers 409 request_cancelled", mrCancelLogin.status === 200 && !!mrCancelLogin.data?.token && mrLateComplete.status === 409 && mrLateComplete.data?.error === "request_cancelled", `login=${mrCancelLogin.status} complete=${mrLateComplete.status}/${mrLateComplete.data?.error}`);
}

// Decision 6 / claim 7: no witness, no reset — and the refusal must store nothing. A stored `requested`
// row would be superseded by the second request and answer 200, so the second refusal is the proof.
const nwEmail = `qa-mfa-nowitness-${stamp}@example.com`;
const nwReg = await call("POST", "/v1/auth/register", {
  body: { email: nwEmail, password: PASSWORD, displayName: "QA No Witness", familyName: "QA No Witness Family", region: "US" },
});
const nwEnroll = await call("POST", "/v1/auth/mfa/enroll", { token: nwReg.data?.token, body: {} });
const nwSecret = nwEnroll.data?.secret ?? "";
const nwVerify = await call("POST", "/v1/auth/mfa/verify", { token: nwReg.data?.token, body: { code: nwSecret ? totpCode(nwSecret) : "000000" } });
// A second refusal alone proves nothing: `no_witness` is answered before any row is read, so it would
// come back the same even if the first refusal had stored one. Instead: three refusals, then give the
// family a witness and ask once more. A stored row per refusal would now hit decision 7's three per
// 30 days (`429 reset_limit_reached`); nothing stored means an ordinary `200` with a request id.
const nwRefusals = [];
for (let i = 0; i < 3; i++) nwRefusals.push(await call("POST", "/v1/auth/mfa/reset/request", { body: { email: nwEmail, password: PASSWORD } }));
const nwLogin = await call("POST", "/v1/auth/login", { body: { email: nwEmail, password: PASSWORD, code: nwSecret ? nextTotp(nwSecret) : "000000" } });
const nwToken = nwLogin.data?.token;
const nwChild = nwToken
  ? await call("POST", "/v1/family/children", { token: nwToken, body: { displayName: `QA No Witness Kid ${stamp}`, birthYear: 2015, consent: { method: "sms_plus", jurisdiction: "US" } } })
  : { status: 0, data: {} };
const nwPair = nwChild.data?.child?.id ? await call("POST", "/v1/devices/pair", { token: nwToken, body: { childId: nwChild.data.child.id } }) : { status: 0, data: {} };
const nwClaim = nwPair.data?.code
  ? await claimApproved(nwPair.data.code, { platform: "android", model: "qa-mfa-nowitness-dev", osVersion: "14", deviceName: "qa-mfa-nowitness-dev" }, nwToken)
  : { status: 0, data: {} };
const nwAfter = await call("POST", "/v1/auth/mfa/reset/request", { body: { email: nwEmail, password: PASSWORD } });
check("O23 a family with no paired device and no other owner/co-parent is refused 409 no_witness, and the refusals store nothing (after three refusals and a newly paired device, the next request is an ordinary 200, not 429)", nwVerify.status === 200 && nwRefusals.every((r) => r.status === 409 && r.data?.error === "no_witness" && r.data?.requestId === undefined) && !!nwClaim.data?.token && nwAfter.status === 200 && !!nwAfter.data?.requestId, `verify=${nwVerify.status} refusals=${nwRefusals.map((r) => `${r.status}/${r.data?.error}`).join(",")} login=${nwLogin.status} claim=${nwClaim.status} after=${nwAfter.status}/${nwAfter.data?.error ?? "ok"}`);


// ── Q. plan 2.7 — the authorization matrix, column by column ────────────────
// docs/QA/security/authz-matrix.md §1a lists the cells no test or check pinned. Each check below walks
// one column of that matrix across every JWT route, so a route that loses (or never had) its guard is
// named in the failure instead of averaging into a count. The ids are real where the route reads, and
// a placeholder where it writes: every expected answer here is decided before the resource is loaded,
// so a placeholder cannot make a check pass, and a regression cannot mutate real rows.
// Pacing: about 430 requests, so this section reads the global limiter's own headers and waits for the
// window instead of tripping the probe's 429 abort (200/min per address, server.ts:66).
console.log("\n── Q. plan 2.7 authorization matrix ──");
{
  const Z = "00000000-0000-0000-0000-000000000000";
  const qState = { remaining: Infinity, resetAt: 0 };
  /** `call` with pacing: same request shape, but it waits out the limiter window when it is nearly spent. */
  async function qcall(method, path, { token, body } = {}) {
    if (qState.remaining <= 3) await new Promise((r) => setTimeout(r, Math.max(0, qState.resetAt - Date.now()) + 300));
    const raw = body === undefined ? undefined : JSON.stringify(body);
    const res = await fetch(`${API}${path}`, {
      method,
      headers: { ...(raw !== undefined ? { "content-type": "application/json" } : {}), ...(token ? { authorization: `Bearer ${token}` } : {}) },
      body: raw,
    });
    const remaining = Number(res.headers.get("x-ratelimit-remaining"));
    const reset = Number(res.headers.get("x-ratelimit-reset"));
    if (Number.isFinite(remaining)) qState.remaining = remaining;
    if (Number.isFinite(reset)) qState.resetAt = Date.now() + reset * 1000;
    if (res.status === 429) {
      count429(`Q ${method} ${path}`);
      qState.remaining = 0;
      return qcall(method, path, { token, body });
    }
    let data = null;
    try { data = await res.json(); } catch { /* empty body */ }
    return { status: res.status, data };
  }
  /** Run a table of [method, path, body, expected status, expected error|null]; return the mismatches. */
  async function walk(token, rows) {
    const bad = [];
    for (const [method, path, body, status, error] of rows) {
      const r = await qcall(method, path, { token, body });
      if (r.status !== status || (error && r.data?.error !== error)) bad.push(`${method} ${path} -> ${r.status} ${r.data?.error ?? ""}`.trim());
    }
    return bad;
  }
  const kid = kidA2;
  const dev = d2.deviceId;
  // Every JWT route in matrix §1 (62): health, pair/claim, the ticket-only GET /v1/ws, the HMAC-only
  // ingest routes and the /v1/auth routes (matrix §3) are the only ones left out.
  const jwtRoutes = [
    ["GET", "/v1/alerts"], ["POST", `/v1/alerts/${Z}/ack`, {}],
    ["POST", "/v1/devices/register", { childId: Z, platform: "android", model: "q", osVersion: "1" }],
    ["POST", "/v1/devices/pair", { childId: Z }],
    ["GET", "/v1/devices"], ["GET", `/v1/devices/${dev}`], ["GET", `/v1/devices/${dev}/apps`],
    ["POST", `/v1/devices/${Z}/apps`, { version: 1, apps: [] }],
    ["POST", `/v1/devices/${Z}/command`, { command: "unlock" }],
    ["GET", `/v1/devices/${dev}/commands`], ["POST", `/v1/devices/${Z}/commands/${Z}/ack`, { status: "acked" }],
    ["GET", `/v1/devices/${dev}/commands/history`],
    ["POST", `/v1/devices/${Z}/push-token`, { token: "q".repeat(24) }],
    ["POST", `/v1/devices/${Z}/telemetry`, { batteryPct: 50 }], ["POST", `/v1/devices/${Z}/activity`, { events: [] }],
    ["DELETE", `/v1/devices/${Z}`],
    ["GET", "/v1/family/me"], ["PATCH", "/v1/family/me", { timezone: "UTC" }],
    ["POST", "/v1/family/children", { displayName: "q", birthYear: 2015 }],
    ["GET", `/v1/family/children/${kid}`], ["PATCH", `/v1/family/children/${Z}`, { displayName: "q" }],
    ["DELETE", `/v1/family/children/${Z}`],
    ["POST", `/v1/family/children/${Z}/consent`, { method: "sms_plus", jurisdiction: "US" }],
    ["GET", `/v1/family/children/${kid}/consent`], ["POST", `/v1/family/children/${Z}/consent/revoke`, {}],
    ["GET", "/v1/family/export"],
    ["POST", "/v1/family/invites", { email: "q@example.invalid", role: "guardian", permissions: [] }],
    ["GET", "/v1/family/invites"], ["POST", `/v1/family/invites/${Z}/accept`, {}], ["DELETE", `/v1/family/invites/${Z}`],
    ["POST", "/v1/location/ping", { lat: 1, lng: 2, accuracyM: 5 }],
    ["GET", `/v1/location/${kid}/latest`], ["GET", `/v1/location/${kid}/history`], ["GET", `/v1/location/geofences/${kid}`],
    ["POST", "/v1/location/geofences", { childId: Z, label: "q", lat: 1, lng: 2, radiusM: 100 }],
    ["DELETE", `/v1/location/geofences/${Z}`],
    ["GET", `/v1/rules/${kid}`], ["PUT", `/v1/rules/${Z}`, {}], ["PATCH", `/v1/rules/${Z}`, {}],
    ...["pause-internet", "pause", "resume-internet", "resume", "wind-down"].map((a) => ["POST", `/v1/controls/children/${Z}/${a}`, { minutes: 5 }]),
    ["POST", `/v1/controls/children/${Z}/bonus`, { minutes: 5 }], ["GET", `/v1/controls/children/${kid}/status`],
    ["GET", `/v1/reports/activity?childId=${kid}`], ["GET", `/v1/reports/summary?childId=${kid}`],
    ["GET", `/v1/reports/usage?childId=${kid}&days=1`], ["GET", `/v1/reports/web?childId=${kid}&days=1`],
    ["GET", `/v1/reports/wellbeing/${kid}`],
    ["GET", `/v1/social/events?childId=${kid}`], ["GET", `/v1/content/searches?childId=${kid}`],
    ["GET", "/v1/digests/prefs"], ["PUT", "/v1/digests/prefs", { dailyEmail: false, weeklyEmail: false, pushEnabled: false, emails: ["q@example.invalid"] }],
    ["POST", "/v1/digests/send-now", {}],
    ["POST", "/v1/me/push-token", { token: "q".repeat(24), platform: "android" }], ["DELETE", "/v1/me/push-token", { token: "q".repeat(24) }],
    ["GET", "/v1/me/push-tokens"],
    ["GET", "/v1/blocklists"], ["GET", "/v1/insights/apps?packageId=com.spotify.music"],
    ["POST", "/v1/ws-ticket"],
  ];
  const as = (status, error) => jwtRoutes.map(([m, p, b]) => [m, p, b, status, error]);

  // Q1: a revoked device token (d1, unpaired at G8) is 401 device_revoked on every route — the global
  // hook (server.ts:77-82) is the only guard on most of them, and no unit test reaches it.
  // Mutant: drop the device branch of the server.ts hook -> most rows answer 403/200/404 and are named.
  if (d1.token) {
    const bad = await walk(d1.token, as(401, "device_revoked"));
    check("Q1 a revoked device token is refused on every JWT route (401 device_revoked)", bad.length === 0, bad.slice(0, 8).join("; ") + (bad.length > 8 ? ` … +${bad.length - 8}` : ""));
  } else {
    target("Q1 a revoked device token is refused on every JWT route", "the G-section device was not paired, so there is no revoked device token");
  }

  // Q2: tokenA was minted before N2's logout-all for account A, so its session is revoked. Every route
  // must say so, including the three requireAuth routes, where the hook (server.ts:84-86) is the only
  // `sv` check (requireAuth reads the jti only). Mutant: drop the parent branch of the hook -> the
  // requireAuth rows answer 200 and are named.
  {
    const bad = await walk(tokenA, as(401, "session_revoked"));
    check("Q2 a revoked parent session is refused on every JWT route (401 session_revoked)", bad.length === 0, bad.slice(0, 8).join("; ") + (bad.length > 8 ? ` … +${bad.length - 8}` : ""));
  }

  // Q3/Q4 mint tokens, so they need the API's signing secret (as G18/G19 do).
  if (process.env.JWT_SECRET) {
    const nowSec = Math.floor(Date.now() / 1000);
    const aClaims = JSON.parse(Buffer.from(tokenA.split(".")[1], "base64url").toString());
    // Q3: the same claims as a real owner token, expired a minute ago. Mutant: verify with
    // `ignoreExpiration` in any guard -> that route answers 200/403 and is named.
    const expired = signHs256Jwt({ ...aClaims, iat: nowSec - 3600, exp: nowSec - 60 }, process.env.JWT_SECRET);
    const badExp = await walk(expired, as(401, null));
    check("Q3 an expired parent token is refused on every JWT route (401)", badExp.length === 0, badExp.slice(0, 8).join("; ") + (badExp.length > 8 ? ` … +${badExp.length - 8}` : ""));
    // Q4: a password-reset token for the same parent, the shape /reset/request mints (no role, no
    // family). #146 was this token reaching /mfa/enroll. Mutant: drop isBearerSession from a guard ->
    // its routes are named.
    const purpose = signHs256Jwt({ sub: aClaims.sub, purpose: "password_reset", jti: "q".repeat(32), iat: nowSec, exp: nowSec + 900 }, process.env.JWT_SECRET);
    const badPurpose = await walk(purpose, as(401, null));
    check("Q4 a password-reset purpose token is refused on every JWT route (401)", badPurpose.length === 0, badPurpose.slice(0, 8).join("; ") + (badPurpose.length > 8 ? ` … +${badPurpose.length - 8}` : ""));
  } else {
    target("Q3 an expired parent token is refused on every JWT route", "JWT_SECRET not present in the probe environment, so an expired token cannot be minted here");
    target("Q4 a password-reset purpose token is refused on every JWT route", "JWT_SECRET not present in the probe environment, so a purpose token cannot be minted here");
  }

  // Q5: no token at all. Mutant: delete a route's preHandler -> that route answers 200/400/404.
  {
    const bad = await walk(undefined, as(401, null));
    check("Q5 a request with no token is refused on every JWT route (401)", bad.length === 0, bad.slice(0, 8).join("; ") + (bad.length > 8 ? ` … +${bad.length - 8}` : ""));
  }

  // Q6: a guardian and a co-parent invited with NO permissions (the O-section family). Every route that
  // names a permission or the owner refuses them before any row is read; the device-only routes refuse
  // them as parents. Mutant: drop any one requirePermission/requireOwner/requireDeviceRole -> its row
  // is named. The device-only rows use the family's own device, because requireFamily runs first there.
  const roleRows = [
    ["POST", `/v1/alerts/${Z}/ack`, {}, 403, "permission_required"],
    ["POST", "/v1/devices/register", { childId: Z, platform: "android", model: "q", osVersion: "1" }, 403, "permission_required"],
    ["POST", "/v1/devices/pair", { childId: Z }, 403, "permission_required"],
    ["GET", `/v1/devices/${Z}/apps`, undefined, 403, "permission_required"],
    ["POST", `/v1/devices/${Z}/command`, { command: "unlock" }, 403, "permission_required"],
    ["DELETE", `/v1/devices/${Z}`, undefined, 403, "permission_required"],
    ["PATCH", `/v1/family/children/${Z}`, { displayName: "q" }, 403, "permission_required"],
    ["POST", "/v1/location/geofences", { childId: Z, label: "q", lat: 1, lng: 2, radiusM: 100 }, 403, "permission_required"],
    ["DELETE", `/v1/location/geofences/${Z}`, undefined, 403, "permission_required"],
    ["PUT", `/v1/rules/${Z}`, {}, 403, "permission_required"], ["PATCH", `/v1/rules/${Z}`, {}, 403, "permission_required"],
    ...["pause-internet", "pause", "resume-internet", "resume", "bonus", "wind-down"].map((a) => ["POST", `/v1/controls/children/${Z}/${a}`, { minutes: 5 }, 403, "permission_required"]),
    ["GET", `/v1/controls/children/${Z}/status`, undefined, 403, "permission_required"],
    ["PATCH", "/v1/family/me", { timezone: "UTC" }, 403, "owner_role_required"],
    ["POST", "/v1/family/children", { displayName: "q", birthYear: 2015 }, 403, "owner_role_required"],
    ["DELETE", `/v1/family/children/${Z}`, undefined, 403, "owner_role_required"],
    ["POST", `/v1/family/children/${Z}/consent`, { method: "sms_plus", jurisdiction: "US" }, 403, "owner_role_required"],
    ["POST", `/v1/family/children/${Z}/consent/revoke`, {}, 403, "owner_role_required"],
    ["POST", "/v1/family/invites", { email: "q@example.invalid", role: "guardian", permissions: [] }, 403, "owner_role_required"],
    ["DELETE", `/v1/family/invites/${Z}`, undefined, 403, "owner_role_required"],
    // #326 (26 Oct): the export is the GDPR Art. 15/20 request, so it is owner-only like consent revoke and
    // child delete. It moved here from Q6c/Q6d's admitted reads.
    ["GET", "/v1/family/export", undefined, 403, "owner_role_required"],
    // #354: where the family's digest goes, and sending it, are owner actions.
    ["PUT", "/v1/digests/prefs", { dailyEmail: false, weeklyEmail: false, pushEnabled: false, emails: ["q@example.invalid"] }, 403, "owner_role_required"],
    ["POST", "/v1/digests/send-now", {}, 403, "owner_role_required"],
    ...(mrDeviceId ? [
      ["POST", `/v1/devices/${mrDeviceId}/telemetry`, { batteryPct: 50 }, 403, "device_role_required"],
      ["POST", `/v1/devices/${mrDeviceId}/activity`, { events: [] }, 403, "device_role_required"],
      ["POST", `/v1/devices/${mrDeviceId}/apps`, { version: 1, apps: [] }, 403, "device_role_required"],
      ["POST", `/v1/devices/${mrDeviceId}/push-token`, { token: "q".repeat(24) }, 403, "device_role_required"],
      ["GET", `/v1/devices/${mrDeviceId}/commands`, undefined, 403, "device_role_required"],
    ] : []),
    ["POST", "/v1/location/ping", { lat: 1, lng: 2, accuracyM: 5 }, 403, "device_role_required"],
  ];
  /** Walk roleRows with one no-permission role; null when that role has no live session here. */
  async function roleWalk(tok) {
    const live = tok ? (await qcall("GET", "/v1/family/me", { token: tok })).status === 200 : false;
    return live ? walk(tok, roleRows) : null;
  }
  const badGuardian = await roleWalk(mrGuardianToken);
  if (badGuardian) {
    check("Q6 a guardian with no permissions is refused on every permission-, owner- and device-only route", badGuardian.length === 0, badGuardian.slice(0, 8).join("; ") + (badGuardian.length > 8 ? ` … +${badGuardian.length - 8}` : ""));
  } else {
    // A target never shares a check's exact name: check-probe-integrity keys names per severity, so a
    // shared name reads as both promoted and demoted and fails the gate on every PR (found on #338).
    target("Q6 a guardian with no permissions is refused (no live guardian session)", "the O-section guardian has no live session here");
  }
  const badCoParent = await roleWalk(mrCoParentToken);
  if (badCoParent) {
    check("Q6b a co-parent with no permissions is refused on every permission-, owner- and device-only route", badCoParent.length === 0, badCoParent.slice(0, 8).join("; ") + (badCoParent.length > 8 ? ` … +${badCoParent.length - 8}` : ""));
  } else {
    target("Q6b a co-parent with no permissions is refused (no live co-parent session)", "the O-section co-parent has no live session here");
  }

  // Q6c/Q6d: the positive half (matrix §6, "co-parent and guardian → 2xx"). A guardian and a co-parent invited
  // with NONE must be admitted to the reads their role keeps: their own family, by its real ids. Same tokens as
  // Q6/Q6b, so no extra logins. `404 no_pings` on `/location/:childId/latest` is an admission: the guards passed
  // and the family has no ping. The family export is owner-only for both (#326), so it is in Q6/Q6b instead.
  // Since the ADR-0014 amendment (2026-10-26, #399/#401) a guardian also needs `alerts`, `location` or `social`
  // for the reads in `gatedReads`: a co-parent keeps them (Q6d), a guardian is refused them (Q6e).
  // Mutant: requireOwner (or any requirePermission) on GET /v1/digests/prefs -> both Q6c and Q6d name it.
  const openReads = mrKid && mrDeviceId ? [
    ["GET", "/v1/devices", undefined, 200],
    ["GET", `/v1/devices/${mrDeviceId}`, undefined, 200], ["GET", `/v1/devices/${mrDeviceId}/commands/history`, undefined, 200],
    ["GET", "/v1/family/me", undefined, 200], ["GET", `/v1/family/children/${mrKid}`, undefined, 200],
    ["GET", `/v1/family/children/${mrKid}/consent`, undefined, 200], ["GET", "/v1/family/invites", undefined, 200],
    ["GET", `/v1/rules/${mrKid}`, undefined, 200],
    ["GET", `/v1/reports/summary?childId=${mrKid}`, undefined, 200],
    ["GET", `/v1/reports/usage?childId=${mrKid}&days=1`, undefined, 200], ["GET", `/v1/reports/wellbeing/${mrKid}`, undefined, 200],
    ["GET", "/v1/digests/prefs", undefined, 200], ["GET", "/v1/me/push-tokens", undefined, 200],
    ["GET", "/v1/blocklists", undefined, 200], ["POST", "/v1/ws-ticket", undefined, 200],
  ] : null;
  // [method, path, the permission a guardian needs, the co-parent's status, its error]
  const gatedReads = mrKid ? [
    ["GET", "/v1/alerts", "alerts", 200],
    ["GET", `/v1/location/${mrKid}/latest`, "location", 404, "no_pings"], ["GET", `/v1/location/${mrKid}/history`, "location", 200],
    ["GET", `/v1/location/geofences/${mrKid}`, "location", 200],
    ["GET", `/v1/social/events?childId=${mrKid}`, "social", 200], ["GET", `/v1/content/searches?childId=${mrKid}`, "social", 200],
    ["GET", `/v1/reports/web?childId=${mrKid}&days=1`, "social", 200], ["GET", `/v1/reports/activity?childId=${mrKid}`, "social", 200],
  ] : null;
  const coParentReads = openReads && gatedReads ? [...openReads, ...gatedReads.map(([m, p, , st, err]) => [m, p, undefined, st, err])] : null;
  for (const [label, tok, rows] of [["Q6c a guardian", mrGuardianToken, openReads], ["Q6d a co-parent", mrCoParentToken, coParentReads]]) {
    const live = rows && tok ? (await qcall("GET", "/v1/family/me", { token: tok })).status === 200 : false;
    if (live) {
      const bad = await walk(tok, rows);
      check(`${label} with no permissions is admitted to every route that names no permission`, bad.length === 0, bad.slice(0, 8).join("; ") + (bad.length > 8 ? ` … +${bad.length - 8}` : ""));
    } else {
      target(`${label} with no permissions is admitted (no live session or no family ids here)`, "the O-section family has no live session or no child/device here");
    }
  }
  // Q6e: the ADR-0014 amendment's refusals. A guardian with no permissions is refused each gated read with
  // `403 permission_required` naming the permission, and the broad reads hold back what the narrow ones refuse
  // (decision 2): no `geofences` on `/v1/family/me`, no `topBlockedDomains` on `/v1/reports/summary`.
  // Mutant: drop requireGuardianRead from any gated route, or the geofence omission -> Q6e names it.
  {
    const live = gatedReads && mrGuardianToken ? (await qcall("GET", "/v1/family/me", { token: mrGuardianToken })) : null;
    if (live?.status === 200) {
      const bad = [];
      for (const [m, p, perm] of gatedReads) {
        const r = await qcall(m, p, { token: mrGuardianToken });
        if (r.status !== 403 || r.data?.error !== "permission_required" || r.data?.permission !== perm) {
          bad.push(`${m} ${p} -> ${r.status} ${r.data?.error ?? ""} ${r.data?.permission ?? ""}`.trim());
        }
      }
      const kids = live.data?.children ?? live.data?.family?.children ?? [];
      if (kids.some((c) => c && "geofences" in c)) bad.push("GET /v1/family/me -> children carry geofences");
      const summary = await qcall("GET", `/v1/reports/summary?childId=${mrKid}`, { token: mrGuardianToken });
      if (summary.status !== 200 || (summary.data && "topBlockedDomains" in summary.data)) bad.push(`GET /v1/reports/summary -> ${summary.status}${summary.data && "topBlockedDomains" in summary.data ? " with topBlockedDomains" : ""}`);
      check("Q6e a guardian with no permissions is refused the alert, location and social reads, and the broad reads withhold them", bad.length === 0, bad.slice(0, 8).join("; ") + (bad.length > 8 ? ` … +${bad.length - 8}` : ""));
    } else {
      target("Q6e a guardian with no permissions is refused the gated reads (no live guardian session or no family ids here)", "the O-section guardian has no live session or no child here");
    }
  }

  // Q6f: the ADR-0014 amendment, decision 3 (#402). An `alert` frame carries the whole alert row, title and body
  // (lib/alerts.ts), so the live socket must skip a guardian without `alerts` exactly as `GET /v1/alerts` does,
  // and a `location` frame must skip one without `location`. The co-parent, whose reads are unchanged, is the
  // control: its socket must receive both frames, or "the guardian saw nothing" proves nothing.
  // Mutant: publish to every family socket again (drop the per-socket filter) -> the guardian's socket gets them.
  if (mrKid && mrDeviceId && mrDeviceToken && mrGuardianToken && mrCoParentToken) {
    const live = async (ticket) => {
      const ws = new WebSocket(`${API.replace(/^http/, "ws")}/v1/ws?ticket=${encodeURIComponent(ticket)}`);
      OPEN_SOCKETS.add(ws);
      const frames = [];
      ws.addEventListener("message", (ev) => { try { frames.push(JSON.parse(ev.data)); } catch { /* not JSON */ } });
      ws.addEventListener("close", () => OPEN_SOCKETS.delete(ws));
      ws.addEventListener("error", () => {});
      return { ws, frames };
    };
    const waitFor = async (pred, ms) => {
      const deadline = Date.now() + ms;
      while (!pred() && Date.now() < deadline) await new Promise((r) => setTimeout(r, 50));
      return pred();
    };
    const gTicket = (await qcall("POST", "/v1/ws-ticket", { token: mrGuardianToken })).data?.ticket;
    const cTicket = (await qcall("POST", "/v1/ws-ticket", { token: mrCoParentToken })).data?.ticket;
    if (gTicket && cTicket) {
      const g = await live(gTicket);
      const c = await live(cTicket);
      const ready = await waitFor(() => g.frames.some((f) => f.type === "ready") && c.frames.some((f) => f.type === "ready"), 5000);
      const title = `q6f-guardian-socket-${Date.now()}`;
      const posted = await call("POST", "/v1/alerts/internal", { hmac: true, body: { childId: mrKid, deviceId: mrDeviceId, severity: "info", category: "sos", title, body: "q6f" } });
      const pinged = await call("POST", "/v1/location/ping", { token: mrDeviceToken, body: { lat: 25.2854, lng: 51.531, accuracyM: 10 } });
      const isAlert = (f) => f.type === "alert" && f.payload?.title === title;
      const isLocation = (f) => f.type === "location" && f.payload?.childId === mrKid;
      const control = await waitFor(() => c.frames.some(isAlert) && c.frames.some(isLocation), 10000);
      await new Promise((r) => setTimeout(r, 500)); // the guardian's socket gets the same window after the control's frames land
      const leaked = g.frames.filter((f) => isAlert(f) || isLocation(f)).map((f) => f.type);
      check(
        "Q6f a guardian with no permissions receives no alert or location frame on the live socket, while a co-parent does",
        ready && [200, 201].includes(posted.status) && [200, 201].includes(pinged.status) && control && leaked.length === 0,
        `ready=${ready} alert=${posted.status} ping=${pinged.status} coParentGotBoth=${control} guardianGot=${JSON.stringify(leaked)}`,
      );
      g.ws.close();
      c.ws.close();
    } else {
      target("Q6f a guardian receives no alert or location frame (no ws-ticket here)", `guardianTicket=${!!gTicket} coParentTicket=${!!cTicket}`);
    }
  } else {
    target("Q6f a guardian receives no alert or location frame (no live O-section family here)", "the O-section family has no live guardian, co-parent or device here");
  }

  // Q2c: Q2 for the live socket (#414). The socket re-checks its session before every family frame, so after
  // logout-all, a socket that session opened earlier gets no further frame and is closed with 4001. It runs
  // here, after Q6f, because it ends the co-parent's sessions and nothing after this reads them. The owner's
  // socket is the control: it must receive the alert, or "the co-parent saw nothing" proves nothing. The
  // alert is raised after the gateway's 5 s session cache (SESSION_RECHECK_MS) has run out.
  // Mutant: skip the `sessionLive` check in the gateway's fan-out -> the co-parent's socket stays open and
  // receives the alert.
  // The owner's earlier sessions are spent by the MFA reset block, so the control logs in afresh.
  const q2cOwner = mrKid && mrDeviceId && mrCoParentToken && mrSecret
    ? (await call("POST", "/v1/auth/login", { body: { email: mrEmail, password: PASSWORD, code: totpCode(mrSecret) } })).data?.token
    : undefined;
  if (mrKid && mrDeviceId && mrCoParentToken && q2cOwner) {
    const live = async (ticket) => {
      const ws = new WebSocket(`${API.replace(/^http/, "ws")}/v1/ws?ticket=${encodeURIComponent(ticket)}`);
      OPEN_SOCKETS.add(ws);
      const sock = { ws, frames: [], closeCode: null, closedAt: null };
      ws.addEventListener("message", (ev) => { try { sock.frames.push(JSON.parse(ev.data)); } catch { /* not JSON */ } });
      ws.addEventListener("close", (ev) => { OPEN_SOCKETS.delete(ws); sock.closeCode = ev?.code ?? -1; sock.closedAt = Date.now(); });
      ws.addEventListener("error", () => {});
      return sock;
    };
    const waitFor = async (pred, ms) => {
      const deadline = Date.now() + ms;
      while (!pred() && Date.now() < deadline) await new Promise((r) => setTimeout(r, 50));
      return pred();
    };
    const vTicket = (await qcall("POST", "/v1/ws-ticket", { token: mrCoParentToken })).data?.ticket;
    const oTicket = (await qcall("POST", "/v1/ws-ticket", { token: q2cOwner })).data?.ticket;
    if (vTicket && oTicket) {
      const v = await live(vTicket);
      const o = await live(oTicket);
      const ready = await waitFor(() => v.frames.some((f) => f.type === "ready") && o.frames.some((f) => f.type === "ready"), 5000);
      const revokedAt = Date.now();
      const logoutAll = await call("POST", "/v1/auth/logout-all", { token: mrCoParentToken });
      const after = await call("GET", "/v1/family/me", { token: mrCoParentToken });
      await waitFor(() => v.closeCode !== null, 6000);
      // Q2d (#417), read here, before Q2c's alert: every session revocation also closes that parent's sockets at
      // once, so the socket is closed before any family frame is raised, not on the first frame after the 5 s cache.
      const earlyClose = v.closeCode;
      const closeMs = v.closedAt ? v.closedAt - revokedAt : null;
      const framesBeforeAlert = v.frames.map((f) => f.type);
      const wait = revokedAt + 5500 - Date.now();
      if (wait > 0) await new Promise((r) => setTimeout(r, wait));
      const title = `q2c-revoked-socket-${Date.now()}`;
      const posted = await call("POST", "/v1/alerts/internal", { hmac: true, body: { childId: mrKid, deviceId: mrDeviceId, severity: "info", category: "sos", title, body: "q2c" } });
      const isAlert = (f) => f.type === "alert" && f.payload?.title === title;
      const control = await waitFor(() => o.frames.some(isAlert), 10000);
      await new Promise((r) => setTimeout(r, 500)); // the revoked socket gets the same window after the control's frame lands
      await waitFor(() => v.closeCode !== null, 1000);
      const leaked = v.frames.some(isAlert);
      check(
        "Q2c a socket opened before logout-all gets no further family frame and is closed with 4001",
        ready && logoutAll.status === 200 && after.status === 401 && [200, 201].includes(posted.status) && control && !leaked && v.closeCode === 4001,
        `ready=${ready} logoutAll=${logoutAll.status} tokenAfter=${after.status} alert=${posted.status} ownerGotAlert=${control} revokedSocketGotAlert=${leaked} close=${v.closeCode}`,
      );
      // Q2d's second half: the revoke signal is a control message naming a parent id, never family data, so no
      // socket receives it, the owner's (still live) included. Mutants: drop the publish in revokeAllRefreshTokens
      // -> no close until a frame arrives (`close=null` here); forward the signal instead of handling it -> the
      // owner's socket receives `session_revoked` (the per-frame check still closes the revoked socket, so only
      // this half sees it).
      const signalLeaked = o.frames.some((f) => f.type === "session_revoked");
      check(
        "Q2d logout-all closes the parent's open socket with 4001 within 2 s, before any family frame, and no socket receives the revoke signal",
        logoutAll.status === 200 && earlyClose === 4001 && closeMs !== null && closeMs <= 2000 && framesBeforeAlert.every((t) => t === "ready") && !signalLeaked,
        `logoutAll=${logoutAll.status} closedBeforeAnyFrame=${earlyClose !== null} close=${earlyClose} afterMs=${closeMs} revokedFrames=${JSON.stringify(framesBeforeAlert)} ownerGotSignal=${signalLeaked}`,
      );
      v.ws.close();
      o.ws.close();
    } else {
      target("Q2c a socket opened before logout-all is closed (no ws-ticket here)", `coParentTicket=${!!vTicket} ownerTicket=${!!oTicket}`);
      target("Q2d logout-all closes the parent's open socket at once (no ws-ticket here)", `coParentTicket=${!!vTicket} ownerTicket=${!!oTicket}`);
    }
  } else {
    target("Q2c a socket opened before logout-all is closed (no live O-section family here)", "the O-section family has no live co-parent or device here, or the owner could not log in again");
    target("Q2d logout-all closes the parent's open socket at once (no live O-section family here)", "the O-section family has no live co-parent or device here, or the owner could not log in again");
  }

  // Q7: a live device token on every parent-only route is 403 parent_role_required (requireParent, or
  // the ws-ticket role check). Mutant: requireParent that skips the role test -> the reads answer 200.
  if (d2.token) {
    // The routes a device token may call (matrix §1, own-device column not 403r); every other JWT route
    // is parent-only. Listed by hand, so a route added later without a decision shows up here as a diff.
    const deviceAllowed = new Set([
      `GET /v1/devices/${dev}`, `POST /v1/devices/${Z}/apps`, `GET /v1/devices/${dev}/commands`,
      `POST /v1/devices/${Z}/commands/${Z}/ack`, `POST /v1/devices/${Z}/push-token`,
      `POST /v1/devices/${Z}/telemetry`, `POST /v1/devices/${Z}/activity`,
      `POST /v1/family/invites/${Z}/accept`,
      "POST /v1/location/ping", `GET /v1/location/${kid}/latest`, `GET /v1/location/${kid}/history`,
      `GET /v1/location/geofences/${kid}`, `GET /v1/rules/${kid}`,
      "GET /v1/blocklists", "GET /v1/insights/apps?packageId=com.spotify.music",
    ]);
    const parentOnly = jwtRoutes.filter(([m, p]) => !deviceAllowed.has(`${m} ${p}`));
    const bad = await walk(d2.token, parentOnly.map(([m, p, b]) => [m, p, b, 403, "parent_role_required"]));
    check("Q7 a device token is refused on every parent-only route (403 parent_role_required)", bad.length === 0, bad.slice(0, 8).join("; ") + (bad.length > 8 ? ` … +${bad.length - 8}` : ""));
  } else {
    target("Q7 a device token is refused on every parent-only route", "the G-section device was not paired");
  }

  // Q8: the owner of ANOTHER family (the no-witness family above) against this family's real ids, on
  // the family-scoped routes that name no permission — reads, plus the safe-direction writes. Mutant:
  // drop requireFamily from any of them -> it answers 200 and is named.
  if (nwToken) {
    const bad = await walk(nwToken, [
      ["GET", `/v1/devices/${dev}`], ["GET", `/v1/devices/${dev}/commands/history`],
      ["GET", `/v1/family/children/${kid}`], ["GET", `/v1/family/children/${kid}/consent`],
      ["GET", `/v1/location/${kid}/latest`], ["GET", `/v1/location/${kid}/history`], ["GET", `/v1/location/geofences/${kid}`],
      ["GET", `/v1/rules/${kid}`], ["GET", `/v1/controls/children/${kid}/status`],
      ["GET", `/v1/reports/activity?childId=${kid}`], ["GET", `/v1/reports/summary?childId=${kid}`],
      ["GET", `/v1/reports/usage?childId=${kid}&days=1`], ["GET", `/v1/reports/web?childId=${kid}&days=1`],
      ["GET", `/v1/reports/wellbeing/${kid}`],
      ["POST", `/v1/devices/${dev}/command`, { command: "unlock" }],
      ["POST", `/v1/controls/children/${kid}/resume`, {}],
    ].map(([m, p, b]) => [m, p, b, 403, "forbidden"]));
    check("Q8 another family's owner is refused on this family's scoped routes (403 forbidden)", bad.length === 0, bad.slice(0, 8).join("; ") + (bad.length > 8 ? ` … +${bad.length - 8}` : ""));
  } else {
    target("Q8 another family's owner is refused on this family's scoped routes", "the no-witness family above has no live session");
  }

  // Q9: outbound email cannot be steered by a family (plan 2.7, #354). Text that lands in
  // a subject is bounded, the digest list is capped, and an address that isn't a parent of the family
  // gets nothing until it confirms. Mutants: drop `.max(80)` on familyName -> Q9a 201; drop `.max(5)`
  // -> Q9b 200; drop the confirmation filter in send-now -> Q9c lists the stranger. The 21st-invite 429
  // is not probed: reaching it sends 20 real invites on a deployed API (test/invites.test.ts pins it).
  const longName = await qcall("POST", "/v1/auth/register", {
    body: { email: `qa-longname-${stamp}@example.com`, password: PASSWORD, displayName: "QA", familyName: "q".repeat(81), region: "US" },
  });
  check("Q9a an 81-character familyName is refused at registration (400)", longName.status === 400 && !!longName.data?.error?.fieldErrors?.familyName, `got ${longName.status} ${JSON.stringify(longName.data?.error?.fieldErrors ?? null)}`);
  if (nwToken) {
    const digestPrefs = (emails) => ({ dailyEmail: true, weeklyEmail: false, pushEnabled: false, emails });
    const six = await qcall("PUT", "/v1/digests/prefs", { token: nwToken, body: digestPrefs(Array.from({ length: 6 }, (_, i) => `q${i}@example.invalid`)) });
    check("Q9b a digest list of six addresses is refused (400)", six.status === 400 && !!six.data?.error?.fieldErrors?.emails, `got ${six.status}`);
    const stranger = `qa-digest-stranger-${stamp}@example.invalid`;
    const set = await qcall("PUT", "/v1/digests/prefs", { token: nwToken, body: digestPrefs([nwEmail, stranger]) });
    const byEmail = Object.fromEntries((set.data?.recipients ?? []).map((r) => [r.email, r.status]));
    const sent = await qcall("POST", "/v1/digests/send-now", { token: nwToken, body: {} });
    const sentTo = Array.isArray(sent.data?.recipients) ? sent.data.recipients : null;
    check(
      "Q9c a non-parent digest address stays pending and send-now leaves it out; the parent's own address is confirmed",
      set.status === 200 && byEmail[stranger] === "pending" && byEmail[nwEmail.toLowerCase()] === "confirmed" && sent.status === 200 && !!sentTo && !sentTo.includes(stranger),
      `prefs=${set.status} statuses=${JSON.stringify(byEmail)} sendNow=${sent.status} recipients=${JSON.stringify(sentTo)}`,
    );
    // Leave the family's digest as it was: off, with only its own address.
    await qcall("PUT", "/v1/digests/prefs", { token: nwToken, body: { dailyEmail: false, weeklyEmail: false, pushEnabled: false, emails: [nwEmail] } });
  } else {
    target("Q9b-c the digest list is capped and unconfirmed addresses get nothing", "the no-witness family above has no live session");
  }
}

// ── R. digest confirmation page: the request a browser actually sends (#354) ────────────────────
// The confirmation link is the one route a stranger reaches, from a mail client, with no session. On
// #354 the button answered 415 for every press because Fastify has no form-body parser, and the unit
// test missed it by posting without a content type. These rows send what a browser sends. The probe
// has no mailbox and no DATABASE_URL (TESTING.md, device-silence row), so it never holds a live token:
// a well-formed unknown token reaches the same handler and must get the 404 page, not a 415. The
// confirmed case stays a unit test (test/digests-abuse.test.ts). Mutants, run against a live API:
// delete the addContentTypeParser call in routes/digests.ts -> R2 fails (415); register that parser in
// server.ts instead -> R5 fails (200 path, not 415); drop no-store from the GET page -> R1 fails;
// raise its bodyLimit to 1 MB -> R6 fails.
console.log("\n── R. digest confirmation page (#354) ──");
/**
 * A browser-shaped request: raw text back, no JSON assumed. Section Q above leaves the global limiter
 * nearly spent by design, so this paces on the same headers qcall reads and waits out one window on a
 * 429 rather than retrying inside it; a second 429 is throttling and aborts, as call() does.
 */
const rState = { remaining: Infinity, resetAt: 0 };
async function browserRequest(method, path, { contentType, body } = {}, retried = false) {
  if (rState.remaining <= 3) await new Promise((r) => setTimeout(r, Math.max(0, rState.resetAt - Date.now()) + 300));
  const res = await fetch(`${API}${path}`, { method, headers: contentType ? { "content-type": contentType } : {}, body });
  const remaining = Number(res.headers.get("x-ratelimit-remaining"));
  const reset = Number(res.headers.get("x-ratelimit-reset"));
  if (Number.isFinite(remaining)) rState.remaining = remaining;
  if (Number.isFinite(reset)) rState.resetAt = Date.now() + reset * 1000;
  if (res.status === 429) {
    count429(`R ${method} ${path}`);
    if (retried) abortRateLimited(`the retry after one limiter window was also 429 (${method} ${path})`);
    rState.remaining = 0;
    return browserRequest(method, path, { contentType, body }, true);
  }
  return { status: res.status, type: res.headers.get("content-type") ?? "", cache: res.headers.get("cache-control") ?? "", text: await res.text() };
}
const FORM = "application/x-www-form-urlencoded";
const unknownToken = createHmac("sha256", `probe-${stamp}`).update("unknown-confirm-token").digest("hex");
const confirmPath = `/v1/digests/confirm?token=${unknownToken}`;

const confirmPage = await browserRequest("GET", confirmPath);
const pageForms = confirmPage.text.match(/<form\b[^>]*>/g) ?? [];
const formsPostBack = pageForms.length > 0 && pageForms.every((f) => /method="post"/i.test(f) && f.includes(`action="${confirmPath}"`));
check(
  "R1 GET of the mailed link is a page whose button posts the token back, and no cache keeps it (text/html, cache-control no-store)",
  confirmPage.status === 200 && confirmPage.type.startsWith("text/html") && /no-store/.test(confirmPage.cache) && formsPostBack,
  `got ${confirmPage.status} ${confirmPage.type} cache="${confirmPage.cache}" forms=${pageForms.length} postBack=${formsPostBack}`,
);

const pressed = await browserRequest("POST", confirmPath, { contentType: FORM, body: "" });
check(
  "R2 pressing the button (form POST, empty body, token in the URL) reaches the handler: an unknown token gets the 404 page, not 415",
  pressed.status === 404 && pressed.type.startsWith("text/html") && /no-store/.test(pressed.cache),
  `got ${pressed.status} ${pressed.type} cache="${pressed.cache}"`,
);

const malformedPress = await browserRequest("POST", "/v1/digests/confirm?token=not-a-token", { contentType: FORM, body: "" });
check(
  "R3 a form POST with a malformed token gets the 400 page",
  malformedPress.status === 400 && malformedPress.type.startsWith("text/html"),
  `got ${malformedPress.status} ${malformedPress.type}`,
);

const jsonPress = await browserRequest("POST", "/v1/digests/confirm", { contentType: "application/json", body: JSON.stringify({ token: unknownToken }) });
let jsonPressBody = null;
try { jsonPressBody = JSON.parse(jsonPress.text); } catch { /* not JSON: the check below says so */ }
check(
  "R4 a JSON caller keeps JSON: an unknown token is 404 confirmation_not_found_or_expired",
  jsonPress.status === 404 && jsonPress.type.startsWith("application/json") && jsonPressBody?.error === "confirmation_not_found_or_expired",
  `got ${jsonPress.status} ${jsonPress.type} ${jsonPress.text.slice(0, 80)}`,
);

const formElsewhere = await browserRequest("POST", "/v1/family/children", { contentType: FORM, body: "name=x" });
check(
  "R5 only /v1/digests reads form bodies: a form POST to another route is still 415",
  formElsewhere.status === 415,
  `POST /v1/family/children got ${formElsewhere.status}`,
);

const bigPress = await browserRequest("POST", confirmPath, { contentType: FORM, body: "a".repeat(4096) });
check(
  "R6 the confirmation form's body is bounded: a 4 KB form body is 413",
  bigPress.status === 413,
  `got ${bigPress.status}`,
);

// ── S. the real routes keep their own rate-limit buckets (plan 2.7, #376) ─────────────────────────
// test/rate-limits.test.ts proves the bucket configs on stand-in routes; only a live server shows that
// /pair/claim and /login still carry them. Each row sends requests until the limiter answers 429 and
// reads the bucket's size from x-ratelimit-limit. Malformed bodies on purpose: the limiter counts before
// validation, so no pairing code is ever tried and no session is created. These 429s are the answer
// under test, not throttling, so they are not counted toward the probe's 429 abort. They run last
// because they spend those two buckets for a minute: a re-run inside that minute waits, as always.
// Mutants, run against a live API: drop `{ config: { rateLimit: PAIR_CLAIM_RATE_LIMIT } }` from
// /pair/claim in routes/devices.ts -> S1 fails (limit 200, no 429 in 12); give /login a 40-a-minute
// bucket instead of RL in routes/auth.ts -> S2 fails (limit 40). Dropping /login's bucket entirely moves
// it onto the global one, which the earlier sections then spend: the run aborts at an O-section login
// (exit 2) before S2 is reached, so that mutant fails the probe too, just not by name.
console.log("\n── S. per-route rate limits (plan 2.7) ──");
/** POST until 429 (at most `cap` requests); the bucket size the route reports and when it refused. */
async function bucketOf(path, body, cap) {
  let limit = null;
  for (let i = 1; i <= cap; i++) {
    const res = await fetch(`${API}${path}`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
    limit ??= res.headers.get("x-ratelimit-limit");
    await res.arrayBuffer();
    if (res.status === 429) return { limit, refusedAt: i };
  }
  return { limit, refusedAt: null };
}
const claimBucket = await bucketOf("/v1/devices/pair/claim", { code: "not-a-code" }, 12);
check(
  "S1 /pair/claim has its own bucket of 10 a minute per address (x-ratelimit-limit 10, refused by the 11th request)",
  claimBucket.limit === "10" && claimBucket.refusedAt !== null && claimBucket.refusedAt <= 11,
  `x-ratelimit-limit=${claimBucket.limit} first 429 at request ${claimBucket.refusedAt ?? "none of 12"}`,
);
const loginBucket = await bucketOf("/v1/auth/login", { email: "not-an-email" }, 22);
check(
  "S2 /login has the auth bucket of 20 a minute per address (x-ratelimit-limit 20, refused by the 21st request)",
  loginBucket.limit === "20" && loginBucket.refusedAt !== null && loginBucket.refusedAt <= 21,
  `x-ratelimit-limit=${loginBucket.limit} first 429 at request ${loginBucket.refusedAt ?? "none of 22"}`,
);

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
process.exitCode = FAIL.length ? 1 : 0;
