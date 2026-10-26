#!/usr/bin/env node
/**
 * The server half of the iOS live API test (roadmap 5.5 PR A2, #372). It runs against an API started on
 * the macOS runner from this checkout, never against a shared or deployed server.
 *
 *   node scripts/live-api.mjs setup    # seeded parent logs in, adds a child with consent, sets its rules, mints a code
 *   node scripts/live-api.mjs verify   # after the XCTest run: the parent sees the agent's alert and location
 *
 * `setup` seeds through the API itself, as services/api/scripts/e2e.mjs does, and hands the tests their
 * inputs through $GITHUB_ENV as TEST_RUNNER_* variables (xcodebuild strips the prefix for the test
 * process). The pairing code is masked in the log. `verify` exits 1 unless the parent's alert list holds
 * the `screen_time_exceeded` alert the tests sent for that child, tagged with this run's marker.
 */
import { appendFileSync } from "node:fs";

const API = process.env.API_BASE ?? "http://127.0.0.1:3000";
// The seed's development credentials (services/api/scripts/seed.ts, used when SEED_DEMO_PASSWORD is
// unset outside production); the same pair services/api/scripts/e2e.mjs logs in with.
const PARENT = { email: "demo@familyshield.dev", password: "CorrectHorseBatteryStaple!" };
const RUN_MARKER = process.env.OSRA_TEST_RUN_MARKER ?? "";
// What IntegrationTests/LiveAPITests.swift case 6 expects to sync. Keep the two in step.
const LIVE_RULES = {
  screenTime: {
    dailyLimitMinutes: 120, weekendLimitMinutes: 240, bedtimeStart: "21:30", bedtimeEnd: "06:45",
    schoolHours: { start: "08:00", end: "15:00", days: [1, 2, 3, 4, 5] },
  },
  webFilter: { blockedCategories: ["gambling"], allowedDomains: [], blockedDomains: ["blocked.example"], safeSearchEnforced: true },
  appRules: [
    { packageId: "com.example.blocked", appName: "Blocked", action: "block" },
    { packageId: "com.example.allowed", appName: "Allowed", action: "allow" },
  ],
  routines: [
    { name: "Homework", startTime: "16:00", endTime: "18:00", days: [1, 7], blockedApps: ["com.example.game"], allowedApps: [] },
  ],
  alwaysAllowedApps: [],
};

async function call(method, path, { token, body } = {}) {
  const res = await fetch(`${API}${path}`, {
    method,
    headers: { ...(body ? { "content-type": "application/json" } : {}), ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  let data = null;
  try { data = await res.json(); } catch { /* empty body */ }
  return { status: res.status, data };
}

function fail(message) {
  console.error(`live-api: ${message}`);
  process.exit(1);
}

async function login() {
  const res = await call("POST", "/v1/auth/login", { body: PARENT });
  if (res.status !== 200 || !res.data?.token) fail(`seeded parent login answered ${res.status}`);
  return res.data.token;
}

function exportEnv(name, value, { secret = false } = {}) {
  if (secret) console.log(`::add-mask::${value}`);
  if (process.env.GITHUB_ENV) appendFileSync(process.env.GITHUB_ENV, `${name}=${value}\n`);
  console.log(`${name}=${secret ? "***" : value}`);
}

async function setup() {
  const token = await login();
  const child = await call("POST", "/v1/family/children", {
    token,
    body: { displayName: "iOS Live", birthYear: 2014, consent: { method: "sms_plus", jurisdiction: "US" } },
  });
  const childId = child.data?.child?.id ?? child.data?.id;
  if (child.status !== 201 || !childId) fail(`creating the child answered ${child.status}`);
  // The rules case (6) reads these back as the iPhone (5.5 PR C): one blocked app, one routine on Mon and Sun.
  const rules = await call("PUT", `/v1/rules/${childId}`, { token, body: LIVE_RULES });
  if (rules.status !== 200) fail(`setting the child's rules answered ${rules.status}`);
  const pair = await call("POST", "/v1/devices/pair", { token, body: { childId } });
  if (pair.status !== 201 || !/^\d{6}$/.test(pair.data?.code ?? "")) fail(`minting a pairing code answered ${pair.status}`);
  exportEnv("TEST_RUNNER_OSRA_TEST_API_BASE", API);
  exportEnv("TEST_RUNNER_OSRA_TEST_CHILD_ID", childId);
  exportEnv("TEST_RUNNER_OSRA_TEST_PAIR_CODE", pair.data.code, { secret: true });
  exportEnv("OSRA_TEST_CHILD_ID", childId);
}

async function verify() {
  const childId = process.env.OSRA_TEST_CHILD_ID;
  if (!childId) fail("OSRA_TEST_CHILD_ID is not set (run setup first)");
  if (!RUN_MARKER) fail("OSRA_TEST_RUN_MARKER is not set");
  const token = await login();
  const list = await call("GET", `/v1/alerts?childId=${encodeURIComponent(childId)}&category=screen_time_exceeded`, { token });
  if (list.status !== 200 || !Array.isArray(list.data?.items)) fail(`GET /v1/alerts answered ${list.status}`);
  const mine = list.data.items.filter((a) => a.childId === childId && a.category === "screen_time_exceeded" && a.metadata?.run === RUN_MARKER);
  console.log(`alerts for the child: ${list.data.items.length}; from this run (metadata.run=${RUN_MARKER}): ${mine.length}`);
  for (const a of mine) console.log(`  ${a.category} severity=${a.severity} device=${a.deviceId ?? "none"} title="${a.title}"`);
  // The replay and the tampered and stale requests were refused, so exactly one alert landed.
  if (mine.length !== 1) fail(`expected exactly 1 alert from this run, found ${mine.length}`);
  if (!mine[0].deviceId) fail("the alert carries no deviceId: it was not attributed to the paired iPhone");
  // The claim said `platform: "ios"`: the device the parent sees must say so too.
  const devices = await call("GET", "/v1/devices", { token });
  const device = (devices.data?.devices ?? []).find((d) => d.id === mine[0].deviceId);
  console.log(`paired device as the parent sees it: platform=${device?.platform ?? "missing"}`);
  if (device?.platform !== "ios") fail(`the paired device's platform is ${JSON.stringify(device?.platform)}, expected "ios"`);
  // Case 9 (5.5 PR E): the point the locate_now uploaded, from the coordinate the job gave the simulator, and
  // the grant the telemetry upload reported.
  const lat = Number(process.env.OSRA_TEST_LAT);
  const lng = Number(process.env.OSRA_TEST_LNG);
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) fail("OSRA_TEST_LAT/OSRA_TEST_LNG are not set");
  const latest = await call("GET", `/v1/location/${encodeURIComponent(childId)}/latest`, { token });
  const point = latest.data?.latest;
  console.log(`latest location as the parent sees it: status=${latest.status} device=${point?.deviceId ?? "none"} lat=${point?.lat} lng=${point?.lng} accuracyM=${point?.accuracyM}`);
  if (latest.status !== 200 || !point) fail(`GET /v1/location/:childId/latest answered ${latest.status}`);
  if (point.deviceId !== mine[0].deviceId) fail("the point is not attributed to the paired iPhone");
  if (Math.abs(point.lat - lat) > 0.001 || Math.abs(point.lng - lng) > 0.001) {
    fail(`the point is ${point.lat},${point.lng}, expected the simulator's ${lat},${lng}`);
  }
  console.log(`paired device's location grant as the parent sees it: ${device?.locationGrant ?? "missing"}`);
  if (device?.locationGrant !== "background") fail(`locationGrant is ${JSON.stringify(device?.locationGrant)}, expected "background"`);
  console.log("live-api: the parent sees the iOS agent's alert and location");
}

const mode = process.argv[2];
if (mode === "setup") await setup();
else if (mode === "verify") await verify();
else fail("usage: live-api.mjs setup|verify");
