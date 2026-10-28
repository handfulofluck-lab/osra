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

/**
 * Issue #126: e2e is the second gate a runner hits in the same sitting as `qa-probe`, against the
 * shared `:3000` instance that rate-limits 200 requests/min per IP (auth routes 20/min). A 429 burst
 * is the API's own limiter, not a product defect. This is the contract `qa-probe` already uses
 * (#112/#114): count every 429 once, retry once when `Retry-After` is short, and above a small
 * threshold stop with one ABORT line and exit **2** — never manufacture a `FAIL` from a throttled
 * response. Exit 1 keeps its meaning: a real assertion failed.
 */
const RATE_LIMIT_ABORT_AFTER = 5;
/** Honour Retry-After only when it is shorter than this; the API asks for up to 60 s. */
const RATE_LIMIT_RETRY_CAP_MS = 3000;
let rateLimited429 = 0;

class RateLimitAbort extends Error {}
/** Thrown by `stop()` so module evaluation ends without a stack trace or a second summary. */
class HarnessStop extends Error {}
/** Socket opened in section 7, so a mid-run abort can close it and let the process exit. */
const OPEN_SOCKETS = new Set();

/** Print the summary once, close Redis, and set the exit code from what was recorded. */
const finish = () => {
  console.log(`\n=== E2E: ${PASS.length} passed, ${FAIL.length} failed ===`);
  if (FAIL.length) console.log(`failures: ${FAIL.join("; ")}`);
  process.exitCode = FAIL.length ? 1 : 0;
  redis.disconnect();
};

/**
 * End the run at a point the remaining checks cannot get past (e.g. `/me` returned no envelope).
 * The failure that caused it is already recorded; printing the summary and stopping is the whole
 * contract — the old code threw a TypeError here and the run died with no summary (issue #126).
 */
const stop = (reason) => {
  console.log(`\nSTOP  ${reason}`);
  finish();
  throw new HarnessStop(reason);
};

process.on("uncaughtException", (err) => {
  if (err instanceof RateLimitAbort) {
    for (const ws of OPEN_SOCKETS) { try { ws.close(); } catch { /* already closing */ } }
    redis.disconnect();
    process.exitCode = 2;
    return; // let the loop drain: process.exit() after several fetches trips a Node 24/Windows libuv assertion
  }
  if (err instanceof HarnessStop) return; // stop() already printed the summary and set the exit code
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

/**
 * v2 internal signing (ADR-0014): HMAC-SHA256(secret, `${ts}.${nonce}.${body}`) plus the timestamp
 * and nonce headers. The global secret is a SERVICE credential — it is accepted only with the
 * caller header (`ai-engine`), which is what this harness models; device signers pass their own
 * per-device secret and no caller.
 */
const signV2 = (secret, body, { caller, nonce, ts } = {}) => {
  const timestamp = String(ts ?? Math.floor(Date.now() / 1000));
  const n = nonce ?? randomBytes(16).toString("hex");
  return {
    "x-familyshield-signature": createHmac("sha256", secret).update(`${timestamp}.${n}.${body}`).digest("hex"),
    "x-familyshield-timestamp": timestamp,
    "x-familyshield-nonce": n,
    ...(caller ? { "x-familyshield-caller": caller } : {}),
  };
};
const sign = (body) => signV2(HMAC_SECRET, body, { caller: "ai-engine" });

async function call(method, path, { token, body, hmac, secret } = {}) {
  const raw = body === undefined ? undefined : JSON.stringify(body);
  const send = () => fetch(`${API}${path}`, {
    method,
    headers: {
      ...(raw ? { "content-type": "application/json" } : {}),
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(secret ? signV2(secret, raw ?? "") : hmac ? sign(raw ?? "") : {}),
    },
    body: raw,
  });
  let res = await send();
  if (res.status === 429) {
    count429(`${method} ${path}`);
    const waitMs = retryAfterMs(res);
    // A 60 s window would stretch this gate by a minute per hit; a retry is allowed only when it
    // does not extend the run meaningfully, so a long Retry-After means stop, not sleep.
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

/** The device claims `code`, the parent allows it, and the device's poll gets the token (plan 2.7). */
async function claimApproved(code, body, parentToken) {
  const claim = await call("POST", "/v1/devices/pair/claim", { body: { code, ...body } });
  if (claim.status !== 202) return claim;
  const approve = await call("POST", `/v1/devices/pair/claims/${claim.data.claimId}/approve`, { token: parentToken });
  if (approve.status !== 200) return approve;
  return call("POST", `/v1/devices/pair/claims/${claim.data.claimId}/poll`, { body: { pollSecret: claim.data.pollSecret } });
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
const token = login.data?.token;

const me = await call("GET", "/v1/family/me", { token });
check("GET /me returns family envelope", me.status === 200 && !!me.data?.family?.id && Array.isArray(me.data?.children) && Array.isArray(me.data?.devices));
check("/me strips passwordHash", me.status === 200 && JSON.stringify(me.data).indexOf("passwordHash") === -1 && JSON.stringify(me.data).indexOf("argon2") === -1);
// Issue #126: a missing envelope used to be dereferenced here and the TypeError truncated the run
// with no summary. The envelope check above already recorded the failure; print the body, print the
// summary and stop — the rest of the flow has no child to talk about, so guessing at it would only
// manufacture more failures.
if (!Array.isArray(me.data?.children) || typeof me.data?.family?.id !== "string") {
  stop(`GET /family/me status ${me.status} returned no family envelope — body: ${JSON.stringify(me.data ?? null).slice(0, 400)}`);
}
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
// Phase 2b: an agent-side device with its own JWT, because the command drain is device-only
// (probe note B11 — a parent token must never consume the queue).
const AGENT_CODE = (await call("POST", "/v1/devices/pair", { token, body: { childId: sam.id } })).data?.code;
const AGENT = await claimApproved(AGENT_CODE, { platform: "android", model: "E2EAgent", osVersion: "15" }, token);
const agentId = AGENT.data?.device?.id;
const agentToken = AGENT.data?.token;
check("agent device paired with a device JWT", AGENT.status === 201 && !!agentId && !!agentToken, `got ${AGENT.status}`);

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

const fanout = await call("GET", `/v1/devices/${agentId}/commands`, { token: agentToken });
check("rules write fans rules_updated out to devices", fanout.status === 200 && Array.isArray(fanout.data) && fanout.data.some((c) => c.type === "rules_updated"));
const parentDrain = await call("GET", `/v1/devices/${agentId}/commands`, { token });
check("parent token cannot drain the device queue (403, B11 closed)", parentDrain.status === 403, `got ${parentDrain.status}`);

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
// TR-04: the old harness armed a ONE-SHOT promise on the socket and aborted the entire run when it
// timed out, recording 0 FAILs — so every later check silently never ran and a flake read as a hard
// failure. That shape is gone: frames are collected, and the stimulus is made repeatable instead of
// lucky, with a bounded re-post. On the CAUSE of the single abort that started this: the plausible
// mechanism — the frame is published before the gateway registers the socket — did NOT reproduce
// (20/20 immediate-post trials delivered). The diagnostics (frames=, wsError=, wsClose=) are what
// will explain the next one.
//
// TR-05: the gateway now sends `{type:"ready", familyId, ts}` as the FIRST frame on every socket,
// after it has added the socket to the family set. The harness waits for that frame before it posts
// the alert, so the ordering is a server contract rather than a guess; the Redis ticket polling that
// stood in for it under TR-04 is gone (one mechanism, not two). If an alert is ever lost AFTER
// `ready` was received, that is a finding against the subscriber, not a harness race.
//
// The assertion is unchanged — the alert must be delivered, and a genuinely undelivered alert still
// fails after the last attempt.
const wsUrl = `${API.replace(/^http/, "ws")}/v1/ws?ticket=${encodeURIComponent(ticketRes.data.ticket)}`;
const ws = new WebSocket(wsUrl);
OPEN_SOCKETS.add(ws);
const wsFrames = [];
let wsError = "";
let wsClose = "";
ws.addEventListener("message", (ev) => wsFrames.push(JSON.parse(ev.data)));
ws.addEventListener("error", (ev) => { wsError = String(ev?.message ?? "ws error"); });
// Diagnose a future abort: a server-side close (e.g. 4001 unauthorized ticket) looks identical to a
// lost frame from the client's side, and that distinction is what a one-off failure needs to explain.
ws.addEventListener("close", (ev) => { wsClose = `${ev?.code ?? "?"} ${ev?.reason || "(no reason)"}`; OPEN_SOCKETS.delete(ws); });
await new Promise((res, rej) => { ws.addEventListener("open", res); ws.addEventListener("error", rej); });
check("parent WebSocket connected", ws.readyState === 1);

const waitUntil = async (predicate, ms) => {
  const deadline = Date.now() + ms;
  for (;;) {
    const hit = await predicate();
    if (hit) return hit;
    if (Date.now() > deadline) return null;
    await new Promise((r) => setTimeout(r, 100));
  }
};
const ready = await waitUntil(() => wsFrames.find((f) => f.type === "ready"), 5000);
check(
  "WebSocket `ready` frame is the first frame and names the family (TR-05)",
  !!ready && wsFrames[0] === ready && ready.familyId === me.data.family.id && typeof ready.ts === "string",
  [wsError && `wsError=${wsError}`, wsClose && `wsClose=${wsClose}`, `frames=${wsFrames.length}`, JSON.stringify(wsFrames[0] ?? null)].filter(Boolean).join(" ").slice(0, 160),
);

let evt = null;
for (let attempt = 1; attempt <= 3 && !evt; attempt += 1) {
  const internal = await call("POST", "/v1/alerts/internal", { hmac: true, body: { childId: sam.id, deviceId, severity: "critical", category: "grooming", title: "E2E alert", body: "simulated AI concern", metadata: { source: "e2e" } } });
  if (attempt === 1) check("HMAC internal alert -> 201", internal.status === 201, `got ${internal.status}`);
  evt = await waitUntil(() => wsFrames.find((f) => f.type === "alert" && f.payload?.title === "E2E alert"), 10000);
  if (!evt && wsClose) { console.log(`NOTE  socket closed by the server (${wsClose}) — retrying the stimulus cannot help`); break; }
  if (!evt && attempt < 3) console.log(`NOTE  no ws frame within 10s on attempt ${attempt} after ready=${Boolean(ready)} — retrying the stimulus (see the TR-04/TR-05 block comment above)`);
}
check("WebSocket delivered {type:alert}", evt?.type === "alert" && evt?.payload?.title === "E2E alert", [wsError && `wsError=${wsError}`, wsClose && `wsClose=${wsClose}`, `frames=${wsFrames.length}`, JSON.stringify(evt ?? wsFrames[0] ?? null)].filter(Boolean).join(" ").slice(0, 160));
ws.close();

const badSig = await call("POST", "/v1/alerts/internal", { body: { childId: sam.id, severity: "info", category: "sos", title: "x", body: "y" } });
check("internal alert without HMAC -> 401", badSig.status === 401, `got ${badSig.status}`);

const list = await call("GET", "/v1/alerts?ack=false&limit=5", { token });
check("alerts list uses {items,meta} envelope", list.status === 200 && Array.isArray(list.data?.items) && typeof list.data?.meta?.total === "number");
const ackTarget = list.data.items.find((a) => a.title === "E2E alert");
const ack = await call("POST", `/v1/alerts/${ackTarget.id}/ack`, { token });
check("acknowledge alert", ack.status === 200 && ack.data?.alert?.acknowledged === true);

// --- 8. Device command queue (durable rows + pub/sub wake + polled drain + acks) ---
const cmdSub = nextMessage(`device:${agentId}:commands`);
const cmd = await call("POST", `/v1/devices/${agentId}/command`, { token, body: { command: "ring" } });
check("POST command -> persisted pending row with id", cmd.status === 200 && cmd.data?.type === "ring" && cmd.data?.status === "pending" && typeof cmd.data?.id === "string");
const pubMsg = await cmdSub;
check("command on Redis pub/sub {type}", pubMsg?.type === "ring" && pubMsg?.id === cmd.data.id);
const histPending = await call("GET", `/v1/devices/${agentId}/commands/history`, { token });
check("parent history shows the command pending before the device polls", histPending.status === 200 && histPending.data?.items?.some((c) => c.id === cmd.data.id && c.status === "pending"));
const drained = await call("GET", `/v1/devices/${agentId}/commands?ack=1`, { token: agentToken });
check("GET commands drains queue [{type,payload}]", drained.status === 200 && Array.isArray(drained.data) && drained.data.some((c) => c.type === "ring" && c.id === cmd.data.id));
const drainedAgain = await call("GET", `/v1/devices/${agentId}/commands?ack=1`, { token: agentToken });
check("command queue is consumed", drainedAgain.data.length === 0);
const histDelivered = await call("GET", `/v1/devices/${agentId}/commands/history`, { token });
check("parent history shows delivered after the drain", histDelivered.data?.items?.some((c) => c.id === cmd.data.id && c.status === "delivered"));
const ackRes = await call("POST", `/v1/devices/${agentId}/commands/${cmd.data.id}/ack`, { token: agentToken, body: { status: "ok", detail: { rangMs: 60000 } } });
check("device acks the command -> acked", ackRes.status === 200 && ackRes.data?.command?.status === "acked");
const parentAck = await call("POST", `/v1/devices/${agentId}/commands/${cmd.data.id}/ack`, { token, body: { status: "ok" } });
check("parent cannot ack a device command (403)", parentAck.status === 403, `got ${parentAck.status}`);

const pauseCmd = await call("POST", `/v1/devices/${agentId}/command`, { token, body: { command: "pause" } });
const pauseDrain = await call("GET", `/v1/devices/${agentId}/commands`, { token: agentToken });
check("pause command accepted and queued", pauseCmd.status === 200 && pauseDrain.data.some((c) => c.type === "pause"));

// --- 9. Telemetry ---
// Plan 2.7 F2 (Claude, #329): telemetry is device-only, so the agent posts it and the parent reads it
// back. This used to post with the parent token as a test convenience; a parent is now refused.
const tel = await call("POST", `/v1/devices/${agentId}/telemetry`, { token: agentToken, body: { batteryPct: 77, appUsage: [{ packageId: "com.minecraft", minutes: 12 }] } });
check("POST telemetry -> 202", tel.status === 202, `got ${tel.status}`);
const parentTel = await call("POST", `/v1/devices/${agentId}/telemetry`, { token, body: { batteryPct: 5 } });
check("parent cannot post a device's telemetry (403 device_role_required)", parentTel.status === 403 && parentTel.data?.error === "device_role_required", `got ${parentTel.status} ${JSON.stringify(parentTel.data)}`);
const devGet = await call("GET", `/v1/devices/${agentId}`, { token });
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

// --- 11a. Phase 2c usage model: durable rollups survive a Redis flush (ADR-0013) ---
const todayKey = new Date().toISOString().slice(0, 10);
const actBatch = await call("POST", `/v1/devices/${agentId}/activity`, { token: agentToken, body: { events: [
  { type: "app_usage", payload: { app: "YouTube", minutes: 21 } },
  { type: "app_usage", payload: { app: "Roblox", minutes: 9 } },
  { type: "app_usage", payload: { app: "YouTube", minutes: 4, live: true } }, // heartbeat: never counted
  { type: "url", payload: { url: "https://blocked.example/x", blocked: true, category: "gambling" } },
  { type: "url", payload: { domain: "news.example" } },
] } });
check("activity batch accepted (agent JWT)", actBatch.status === 202, `got ${actBatch.status}`);
const telTotal = await call("POST", `/v1/devices/${agentId}/telemetry`, { token: agentToken, body: { totalMinutes: 30, batteryPct: 64 } });
check("telemetry day total accepted", telTotal.status === 202, `got ${telTotal.status}`);
// Roadmap 3.4: the agent reports the launcher-visible inventory; the parent reads it back.
const appsUpload = await call("POST", `/v1/devices/${agentId}/apps`, {
  token: agentToken,
  body: { version: 1, apps: [
    { packageId: "com.example.e2e", label: "E2E App", isSystem: false },
    { packageId: "com.android.settings", label: "Settings", isSystem: true },
  ] },
});
check("installed app inventory accepted (agent JWT)", appsUpload.status === 202 && appsUpload.data?.accepted === true && appsUpload.data?.count === 2, `got ${appsUpload.status} ${JSON.stringify(appsUpload.data)}`);
const appsList = await call("GET", `/v1/devices/${agentId}/apps`, { token });
check("parent reads the installed app inventory", appsList.status === 200 && appsList.data?.version === 1 && appsList.data?.count === 2 && appsList.data?.apps?.some((a) => a.packageId === "com.example.e2e" && a.isSystem === false) && appsList.data?.apps?.some((a) => a.packageId === "com.android.settings" && a.isSystem === true), `got ${appsList.status} ${JSON.stringify(appsList.data?.apps)}`);
// Flush the cache the old code depended on, then read everything back from Postgres.
const redisFlush = redis.duplicate();
const flushed = await redisFlush.del(`usage:child:${sam.id}:${todayKey}`).catch(() => -1);
redisFlush.disconnect();
const meAfterFlush = await call("GET", "/v1/family/me", { token });
const samAfter = meAfterFlush.data?.children?.find((c) => c.id === sam.id);
check("screen time today survives a Redis flush (durable day total)", flushed >= 0 && samAfter?.screenTimeTodayMinutes === 30, `flushed=${flushed} minutes=${samAfter?.screenTimeTodayMinutes}`);
// #66: a delta AFTER the flush recreates the counter from the delta alone; /me must still report
// the day total (max of cache and table), not the fresh counter.
const telDelta = await call("POST", `/v1/devices/${agentId}/telemetry`, { token: agentToken, body: { totalMinutes: 5, batteryPct: 63 } });
const meAfterDelta = await call("GET", "/v1/family/me", { token });
const samAfterDelta = meAfterDelta.data?.children?.find((c) => c.id === sam.id);
check("a delta after the flush does not make /me under-report (max of cache and durable, #66)", telDelta.status === 202 && samAfterDelta?.screenTimeTodayMinutes === 35, `minutes=${samAfterDelta?.screenTimeTodayMinutes} expected 35`);
const usage = await call("GET", `/v1/reports/usage?childId=${sam.id}&days=7`, { token });
const usageToday = usage.data?.series?.find((d) => d.day === todayKey);
check("reports/usage: per-day series with per-app split from the rollup table", usage.status === 200 && usage.data?.series?.length === 7 && usageToday?.minutes === 35 && usageToday?.apps?.find((a) => a.app === "YouTube")?.minutes === 21 && usageToday?.apps?.find((a) => a.app === "Roblox")?.minutes === 9 && !usageToday?.apps?.find((a) => a.minutes === 4), `got ${usage.status} ${JSON.stringify(usageToday ?? usage.data).slice(0, 140)}`);
const web = await call("GET", `/v1/reports/web?childId=${sam.id}&days=1`, { token });
check("reports/web: browsing history rows with domain + blocked flag", web.status === 200 && web.data?.items?.some((v) => v.domain === "blocked.example" && v.blocked === true && v.category === "gambling") && web.data.items.some((v) => v.domain === "news.example" && v.blocked === false), `got ${web.status} ${JSON.stringify(web.data?.items?.map((v) => v.domain))}`);
const webBlocked = await call("GET", `/v1/reports/web?childId=${sam.id}&days=1&blocked=true`, { token });
check("reports/web?blocked=true filters to blocked visits only", webBlocked.status === 200 && webBlocked.data?.items?.length >= 1 && webBlocked.data.items.every((v) => v.blocked === true));

const windDown = await call("POST", `/v1/controls/children/${sam.id}/wind-down`, { token, body: { minutes: 15 } });
check("wind-down command accepted", windDown.status === 200);

const wkPause = await call("POST", `/v1/controls/children/${sam.id}/pause`, { token });
const wkStatus = await call("GET", `/v1/controls/children/${sam.id}/status`, { token });
check("pause internet status reflects", wkPause.status === 200 && wkStatus.data?.paused === true);
await call("POST", `/v1/controls/children/${sam.id}/resume`, { token });

// --- 11b. Token hygiene live: per-device HMAC (item 5) + device revocation (item 4) ---
const CODE2 = (await call("POST", "/v1/devices/pair", { token, body: { childId: sam.id } })).data?.code;
const CLAIM2 = await claimApproved(CODE2, { platform: "android", model: "HygienePhone", osVersion: "14" }, token);
const devSecret = CLAIM2.data?.hmacSecret;
const dev2 = CLAIM2.data?.device?.id;
check("the approved pairing mints a per-device HMAC secret", CLAIM2.status === 201 && typeof devSecret === "string" && devSecret.length === 64);
const bodyWithDev = JSON.stringify({ childId: sam.id, deviceId: dev2, severity: "info", category: "web_threat", title: "hygiene", body: "x", metadata: {} });
const devHeaders = signV2(devSecret, bodyWithDev);
check("alert signed with the DEVICE secret (v2) -> 201", (await fetch(`${API}/v1/alerts/internal`, { method: "POST", headers: { "content-type": "application/json", ...devHeaders }, body: bodyWithDev })).status === 201);
// ADR-0014 / J2: the SAME signed request a second time is a replay — the nonce was consumed.
const replayRes = await fetch(`${API}/v1/alerts/internal`, { method: "POST", headers: { "content-type": "application/json", ...devHeaders }, body: bodyWithDev });
const replayJson = await replayRes.json().catch(() => null);
check("replaying the identical signed request -> 401 replay (J2 closed)", replayRes.status === 401 && replayJson?.reason === "replay", `got ${replayRes.status} ${JSON.stringify(replayJson)}`);
const globalSign = createHmac("sha256", HMAC_SECRET).update(bodyWithDev).digest("hex");
check("same alert with the bare GLOBAL secret (v1, no caller) -> 401 (J5/J6 closed)", (await fetch(`${API}/v1/alerts/internal`, { method: "POST", headers: { "content-type": "application/json", "x-familyshield-signature": globalSign }, body: bodyWithDev })).status === 401);
const staleHeaders = signV2(devSecret, bodyWithDev, { ts: Math.floor(Date.now() / 1000) - 600 });
check("a signature with a 10-minute-old timestamp -> 401 stale_timestamp", (await fetch(`${API}/v1/alerts/internal`, { method: "POST", headers: { "content-type": "application/json", ...staleHeaders }, body: bodyWithDev })).status === 401);
const delDev2 = await call("DELETE", `/v1/devices/${dev2}`, { token });
check("unpair device -> success", delDev2.status === 200);
const revokedUse = await call("GET", `/v1/devices/${dev2}`, { token: CLAIM2.data.token });
check("unpaired device's JWT is revoked (401)", revokedUse.status === 401);

// --- 12. GDPR export + erasure ---
const exp = await call("GET", "/v1/family/export", { token });
check("GDPR export downloads JSON", exp.status === 200 && !!exp.data?.family?.children);
const erased = await call("DELETE", `/v1/family/children/${sam.id}`, { token });
check("GDPR erasure cascade", erased.status === 200 && erased.data?.erased === true);
check("erasure reports the deleted devices and per-table row counts (ADR-0013)", Array.isArray(erased.data?.deletedDevices) && erased.data.deletedDevices.includes(agentId) && erased.data?.rows?.activityEvent >= 4 && erased.data?.rows?.webVisit >= 2 && erased.data?.rows?.appUsageDaily >= 3 && erased.data?.rows?.socialEvent >= 1, JSON.stringify(erased.data?.rows ?? null));
// The erased child's agent token is revoked like an unpair (#56): its 10-year JWT must now 401.
const erasedAgent = await call("GET", `/v1/devices/${agentId}/commands`, { token: agentToken });
check("erased child's device JWT is revoked (401)", erasedAgent.status === 401, `got ${erasedAgent.status}`);
// Zero rows left: counted in the database itself when the gate shell has DATABASE_URL (TESTING.md §3).
if (process.env.DATABASE_URL) {
  const { PrismaClient } = await import("@prisma/client");
  const db = new PrismaClient();
  try {
    const where = { where: { childId: sam.id } };
    const counts = {
      activityEvent: await db.activityEvent.count(where), socialEvent: await db.socialEvent.count(where),
      installRequest: await db.installRequest.count(where), webVisit: await db.webVisit.count(where),
      appUsageDaily: await db.appUsageDaily.count(where), locationPing: await db.locationPing.count(where),
      deviceApp: await db.deviceApp.count({ where: { deviceId: { in: erased.data?.deletedDevices ?? [] } } }),
      alert: await db.alert.count(where), device: await db.device.count(where), ruleSet: await db.ruleSet.count(where),
      geofence: await db.geofence.count(where), consentRecord: await db.consentRecord.count(where),
      deviceCommand: await db.deviceCommand.count({ where: { deviceId: { in: erased.data?.deletedDevices ?? [] } } }),
      child: await db.child.count({ where: { id: sam.id } }),
    };
    check("erasure leaves ZERO child-scoped rows in every table (counted in Postgres)", Object.values(counts).every((n) => n === 0), JSON.stringify(counts));
  } finally {
    await db.$disconnect();
  }
} else {
  console.log("NOTE  erasure row-count check skipped — set DATABASE_URL in the gate shell to count rows in Postgres (TESTING.md §3)");
}

finish();
