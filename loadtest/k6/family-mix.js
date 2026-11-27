// OSRA load test: simulated families against the LOAD-TEST stack only (loadtest/README.md).
//
//   k6 run -e BASE_URL=http://<loadtest ALB> -e JWT_SECRET=... -e FAMILIES=10000 -e SCENARIO=steady k6/family-mix.js
//
// SCENARIO: smoke | steady | push_outage | storm | parent_rush | signup | sockets
// FAMILIES: how many seeded families to spread the load over (the seed must have written at least this many).
// HEADROOM: multiplier on the expected peak (default 1.5 = the plan's test target of 0.15 req/s per family).
// DURATION: steady phase length (default 20m); RAMP: ramp-up length (default 5m).
import http from "k6/http";
import ws from "k6/ws";
import { check, sleep } from "k6";
import { Counter, Trend } from "k6/metrics";
import { ltDevices, ltParent } from "./lib/ids.js";
import { deviceCalls, parentReads, parentActions, MIX_PER_FAMILY } from "./lib/calls.js";
import { deviceToken, parentToken, deviceSignature } from "./lib/auth.js";

const BASE = (__ENV.BASE_URL || "").replace(/\/$/, "");
if (!BASE || /staging\.osratech|api\.osratech\.com|osratech\.com/.test(BASE)) {
  throw new Error(`BASE_URL must be the load-test stack's own address, never staging or production (got "${BASE}")`);
}
const FAMILIES = Number(__ENV.FAMILIES || 1000);
const HEADROOM = Number(__ENV.HEADROOM || 1.5);
const SCENARIO = __ENV.SCENARIO || "smoke";
const DURATION = __ENV.DURATION || "20m";
const RAMP = __ENV.RAMP || "5m";
// Several generator tasks split one test: each sends SHARE of the load (loadtest.sh run sets 1/N).
const SHARE = Number(__ENV.SHARE || 1);
const CLIENT = "loadtest/1.0.0 (1; android; loadtest)";

const actionLatency = new Trend("parent_action_to_ws_frame_ms", true);
const wsFrames = new Counter("ws_frames");

// --- request plumbing ----------------------------------------------------------------------------------------
function send(call, who) {
  const raw = call.body === undefined ? null : JSON.stringify(call.body);
  const headers = { "x-osra-client": CLIENT };
  if (raw) headers["content-type"] = "application/json";
  if (call.auth === "device") headers.authorization = `Bearer ${deviceToken(who)}`;
  else if (call.auth === "parent") headers.authorization = `Bearer ${parentToken(who)}`;
  else if (call.auth === "device-hmac") Object.assign(headers, deviceSignature(who.deviceId, raw || ""));
  const res = http.request(call.method, `${BASE}${call.path}`, raw, { headers, tags: { name: call.name, who: call.auth === "parent" ? "parent" : "device" } });
  check(res, { [`${call.name} 2xx`]: (r) => r.status >= 200 && r.status < 300 });
  return res;
}
const randomFamily = () => Math.floor(Math.random() * FAMILIES);
const randomDevice = () => { const list = ltDevices(randomFamily()); return list[Math.floor(Math.random() * list.length)]; };
const randomParent = () => { const f = randomFamily(); return ltParent(f, Math.random() < 0.6 ? 0 : 1); };

// --- the steady mix: one arrival-rate scenario per call type --------------------------------------------------
const perMinute = (perFamilyPerSecond, mult = 1) => Math.max(1, Math.round(FAMILIES * perFamilyPerSecond * HEADROOM * mult * SHARE * 60));
function arrival(exec, ratePerFamily, mult = 1) {
  const target = perMinute(ratePerFamily, mult);
  return {
    executor: "ramping-arrival-rate", exec, timeUnit: "1m", startRate: 0,
    preAllocatedVUs: Math.max(5, Math.ceil(target / 60 / 4)), maxVUs: Math.max(20, Math.ceil(target / 60) * 2),
    stages: [{ target, duration: RAMP }, { target, duration: DURATION }],
  };
}
function steadyScenarios(pollMult = 1) {
  const m = MIX_PER_FAMILY;
  return {
    command_poll: arrival("commandPoll", m.commandPoll, pollMult),
    activity: arrival("activity", m.activity),
    location_ping: arrival("locationPing", m.locationPing),
    telemetry: arrival("telemetry", m.telemetry),
    rule_sync: arrival("ruleSync", m.ruleSync),
    social_scan: arrival("socialScan", m.socialScan),
    search_event: arrival("searchEvent", m.searchEvent),
    blocklists: arrival("blocklists", m.blocklists),
    parent_read: arrival("parentRead", m.parentRead),
    parent_action: arrival("parentAction", m.parentAction),
  };
}

const scenarios = {
  smoke: { smoke: { executor: "constant-arrival-rate", exec: "smokeAll", rate: 2, timeUnit: "1s", duration: __ENV.DURATION || "5m", preAllocatedVUs: 5, maxVUs: 20 } },
  steady: steadyScenarios(),
  // FCM/APNs down: every phone falls back to the 60 s poll. 2.5 devices / 60 s = +0.042 req/s per family.
  push_outage: steadyScenarios(1 + 0.042 / MIX_PER_FAMILY.commandPoll),
  // Every device comes back within 60 s after an outage: rules + poll + location backlog, once each.
  storm: { storm: { executor: "shared-iterations", exec: "reconnect", vus: Math.min(2000, Math.ceil(FAMILIES * SHARE / 5)), iterations: Math.ceil(FAMILIES * SHARE), maxDuration: "10m" } },
  // 2% of families' parents press pause/bonus within 2 minutes while another parent's socket listens.
  parent_rush: Object.assign(steadyScenarios(), {
    rush: { executor: "shared-iterations", exec: "rush", vus: Math.max(1, Math.ceil(FAMILIES * SHARE * 0.02 / 10)), iterations: Math.ceil(FAMILIES * SHARE * 0.02), startTime: RAMP, maxDuration: "4m" },
  }),
  // New families pairing alongside the steady mix: register -> child -> pair code -> claim -> polls -> approve.
  signup: Object.assign(steadyScenarios(), {
    signup: { executor: "constant-arrival-rate", exec: "signup", rate: Math.max(1, Math.round(Number(__ENV.SIGNUPS_PER_HOUR || 500) * SHARE)), timeUnit: "1h", duration: DURATION, startTime: RAMP, preAllocatedVUs: 5, maxVUs: 50 },
  }),
  // 10% of parents with the app open: one WebSocket each for SOCKET_SECONDS.
  sockets: { sockets: { executor: "constant-vus", exec: "socket", vus: Math.ceil(FAMILIES * 1.5 * 0.1 * SHARE), duration: DURATION } },
};

export const options = {
  scenarios: scenarios[SCENARIO],
  discardResponseBodies: true,
  thresholds: {
    http_req_failed: ["rate<0.001"],
    "http_req_duration{who:device}": ["p(95)<300", "p(99)<1000"],
    "http_req_duration{who:parent}": ["p(95)<500"],
    parent_action_to_ws_frame_ms: ["p(95)<2000"],
  },
  summaryTrendStats: ["avg", "p(50)", "p(95)", "p(99)", "max"],
};
if (!options.scenarios) throw new Error(`unknown SCENARIO "${SCENARIO}"`);

// --- executors ------------------------------------------------------------------------------------------------
const dev = (build) => () => { const d = randomDevice(); send(build(d), d); };
export const commandPoll = dev(deviceCalls.commandPoll);
export const activity = dev(deviceCalls.activity);
export const locationPing = dev(deviceCalls.locationPing);
export const telemetry = dev(deviceCalls.telemetry);
export const ruleSync = dev(deviceCalls.ruleSync);
export const socialScan = dev(deviceCalls.socialScan);
export const searchEvent = dev(deviceCalls.searchEvent);
export const blocklists = dev(deviceCalls.blocklists);

const READS = Object.values(parentReads);
export function parentRead() { const p = randomParent(); send(READS[Math.floor(Math.random() * READS.length)](p), p); }
export function parentAction() {
  const p = randomParent();
  const r = Math.random();
  if (r < 0.4) send(parentActions.bonus(p), p);
  else if (r < 0.7) { send(parentActions.pause(p), p); send(parentActions.resume(p), p); }
  else send(parentActions.rulesPatch(p), p);
}

export function smokeAll() {
  const f = randomFamily();
  const d = ltDevices(f)[0];
  for (const build of Object.values(deviceCalls)) send(build(d), d);
  const p = ltParent(f, 1);
  for (const build of READS) send(build(p), p);
  send(parentActions.bonus(p), p);
}

export function reconnect() {
  const f = Math.floor(Math.random() * FAMILIES); // each iteration is one family coming back
  for (const d of ltDevices(f)) {
    send(deviceCalls.ruleSync(d), d);
    send(deviceCalls.commandPoll(d), d);
    send(deviceCalls.locationPing(d), d);
  }
}

/** Parent A pauses a child while parent B (same family) listens on the WebSocket: time to B's frame. */
export function rush() {
  const f = Math.floor(Math.random() * FAMILIES / 2) * 2; // even families have two parents
  const a = ltParent(f, 0), b = ltParent(f, 1);
  const t = http.post(`${BASE}/v1/ws-ticket`, null, { headers: { authorization: `Bearer ${parentToken(b)}`, "x-osra-client": CLIENT }, tags: { name: "parent_ws_ticket", who: "parent" }, responseType: "text" });
  if (t.status !== 200 && t.status !== 201) return;
  const ticket = t.json("ticket");
  let sentAt = 0;
  ws.connect(`${BASE.replace(/^http/, "ws")}/v1/ws?ticket=${encodeURIComponent(ticket)}`, {}, (socket) => {
    socket.on("open", () => {
      socket.setTimeout(() => {
        sentAt = Date.now();
        send(parentActions.pause(a), a);
        // The child's phone polls, gets the pause and acks it; the ack is the frame parents see (command_acked).
        const d = ltDevices(f).filter((x) => x.childId === a.children[1])[0];
        const res = http.get(`${BASE}/v1/devices/${d.deviceId}/commands`, { headers: { authorization: `Bearer ${deviceToken(d)}`, "x-osra-client": CLIENT }, tags: { name: "device_command_poll", who: "device" }, responseType: "text" });
        const cmds = res.status === 200 ? res.json() : [];
        for (const c of cmds) send({ name: "device_command_ack", method: "POST", path: `/v1/devices/${d.deviceId}/commands/${c.id}/ack`, auth: "device", body: { status: "ok" } }, d);
      }, 500);
      socket.setTimeout(() => socket.close(), 10000);
    });
    socket.on("message", () => {
      wsFrames.add(1);
      if (sentAt) { actionLatency.add(Date.now() - sentAt); sentAt = 0; socket.close(); }
    });
  });
  send(parentActions.resume(a), a);
}

export function socket() {
  const p = randomParent();
  const t = http.post(`${BASE}/v1/ws-ticket`, null, { headers: { authorization: `Bearer ${parentToken(p)}`, "x-osra-client": CLIENT }, tags: { name: "parent_ws_ticket", who: "parent" }, responseType: "text" });
  if (t.status !== 200 && t.status !== 201) { sleep(5); return; }
  ws.connect(`${BASE.replace(/^http/, "ws")}/v1/ws?ticket=${encodeURIComponent(t.json("ticket"))}`, {}, (s) => {
    s.on("message", () => wsFrames.add(1));
    s.setTimeout(() => s.close(), Number(__ENV.SOCKET_SECONDS || 120) * 1000);
  });
}

/** A brand-new synthetic family: the whole pairing flow, as the parent app and the child phone do it. */
export function signup() {
  const tag = `${Date.now()}-${__VU}-${__ITER}`;
  const json = (method, path, body, token) => http.request(method, `${BASE}${path}`, body === null ? null : JSON.stringify(body), {
    headers: Object.assign({ "x-osra-client": CLIENT }, body === null ? {} : { "content-type": "application/json" }, token ? { authorization: `Bearer ${token}` } : {}),
    tags: { name: `signup_${path.split("/")[3] || "x"}`, who: "parent" }, responseType: "text",
  });
  const reg = json("POST", "/v1/auth/register", { email: `lt-signup-${tag}@loadtest.invalid`, password: `Lt-${tag}-CorrectHorse!`, displayName: "LT Signup", familyName: `LT Signup ${tag}`, region: "US", consents: { termsPrivacy: true, textVersion: "signup-v1", locale: "en" } });
  if (!check(reg, { "signup register 201": (r) => r.status === 201 })) return;
  const token = reg.json("token");
  const child = json("POST", "/v1/family/children", { displayName: "LT Kid", birthYear: 2014, consent: { method: "sms_plus", jurisdiction: "US" } }, token);
  if (!check(child, { "signup child 201": (r) => r.status === 201 || r.status === 200 })) return;
  const childId = child.json("child.id");
  const pair = json("POST", "/v1/devices/pair", { childId }, token);
  if (!check(pair, { "signup pair code": (r) => r.status === 200 || r.status === 201 })) return;
  const claim = json("POST", "/v1/devices/pair/claim", { code: pair.json("code"), platform: "android", model: "LT Synthetic", osVersion: "14" });
  if (!check(claim, { "signup claim 202": (r) => r.status === 202 })) return;
  const claimId = claim.json("claimId"), pollSecret = claim.json("pollSecret");
  for (let i = 0; i < 3; i++) { json("POST", `/v1/devices/pair/claims/${claimId}/poll`, { pollSecret }); sleep(2); }
  json("POST", `/v1/devices/pair/claims/${claimId}/approve`, null, token);
  const done = json("POST", `/v1/devices/pair/claims/${claimId}/poll`, { pollSecret });
  check(done, { "signup device token": (r) => r.status === 201 || r.status === 200 });
}
