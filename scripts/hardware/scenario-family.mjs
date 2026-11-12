#!/usr/bin/env node
/**
 * A throwaway family for the real-device scenario suite (issue #668; `docs/QA/SCENARIO-SUITE.md` §4 step 3).
 *
 *   node scripts/hardware/scenario-family.mjs create --base-url http://localhost:3000
 *   node scripts/hardware/scenario-family.mjs delete --base-url http://localhost:3000 --token-file <path>
 *
 * `create` signs a parent up, adds a child, neutralises the child's screen-time windows through the API,
 * mints a pairing code, and prints **one** JSON object: `{ familyId, childId, pairingCode, parentTokenFile }`.
 * The access token — and the password the deletion needs for re-authentication — go to that file and
 * nowhere else: never to stdout, never to a log line. A terminal scrollback and a screenshot of one are how
 * a token leaves a test host, and `docs/TESTING.md` §7 says so in the tester's own words.
 *
 * `delete` erases the family with `DELETE /v1/family` (the owner's account deletion, `routes/family.ts:388`)
 * and then proves it: every child-scoped table TR-06 counted in Postgres is read through its own parent
 * route afterwards, and every one must refuse. It prints one JSON object of its own, `counts` included.
 *
 * **Everything is the public API.** No SQL, no Prisma client, no database URL: what the seed creates and
 * erases is what a parent could create and erase from the app.
 *
 * **The base URL guard** (`resolveBaseUrl`) refuses anything that is not `localhost`, `127.0.0.1` or a
 * `*.staging.osratech.com` host, before the first network call. This script creates accounts and erases
 * them; a typo that points it at production is not a mistake worth surviving.
 *
 * Exit codes, matching the other gates: `0` done · `1` a step failed or residue was found · `2` refused to
 * run (usage, base URL, token file).
 */
import { randomBytes } from "node:crypto";
import { chmodSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const LOCAL_HOSTS = new Set(["localhost", "127.0.0.1"]);
const STAGING_SUFFIX = ".staging.osratech.com";
const DEFAULT_BASE_URL = "http://localhost:3000";
const TOKEN_FILE_MODE = 0o600;

/**
 * The registration region. The inline consent's jurisdiction must equal the family's region or the
 * child creation answers `428 consent_jurisdiction_mismatch` (`routes/family.ts:170`). `US` is what the
 * iOS live helper uses too (`apps/child-ios/scripts/live-api.mjs:71`), so a scenario family looks like
 * the one the agents' own live tests build.
 */
const REGION = "US";

const USAGE = `usage: node scripts/hardware/scenario-family.mjs <create|delete> [options]

  create   sign a throwaway parent up, add a child, neutralise its screen-time windows, mint a pairing
           code; prints { familyId, childId, pairingCode, parentTokenFile }
  delete   erase the family the token file names, then prove the child-scoped tables are gone

options:
  --base-url <url>     localhost, 127.0.0.1 or *.staging.osratech.com (default: $SCENARIO_API_BASE,
                       else ${DEFAULT_BASE_URL}). Any other host is refused before the first request.
  --token-file <path>  create: where to write the parent's token (mode 0600); delete: the path create printed
  --help               this text

exit: 0 done · 1 a step failed or residue was found · 2 refused to run (usage, base URL, token file)
`;

/** A subcommand or option the script does not understand. Exits 2. */
export class UsageError extends Error {
  constructor(message) {
    super(message);
    this.name = "UsageError";
  }
}

/** A base URL this script will not talk to. Thrown before the first network call. Exits 2. */
export class BaseUrlRefused extends Error {
  constructor(message) {
    super(message);
    this.name = "BaseUrlRefused";
  }
}

/** The token file is unreadable, malformed, or belongs to another host/family. Exits 2. */
export class TokenFileRefused extends Error {
  constructor(message) {
    super(message);
    this.name = "TokenFileRefused";
  }
}

/** The API refused a step, or a read-back contradicts what the step just wrote. Exits 1. */
export class StepFailed extends Error {
  constructor(message) {
    super(message);
    this.name = "StepFailed";
  }
}

/**
 * What `create` writes: the only changes to the default ruleset that would otherwise ambush a run.
 *
 * The defaults a new child gets are `lib/defaultRules.ts:4`: a 180/300-minute daily limit, bedtime
 * 21:00–07:00 and school hours 08:00–15:00 on Mon–Fri. A scenario that starts at 19:50 and runs for two
 * hours meets all three. Neutralised through `PATCH /v1/rules/:childId` (`routes/rules.ts:203`), which
 * deep-merges onto the stored ruleset, so the web filter, app rules and routines stay at the product
 * default a real family has — a scenario that measures filtering needs them to exist.
 *
 * - `dailyLimitMinutes`/`weekendLimitMinutes` `0`: both agents skip the global limit at 0
 *   (`apps/child-android/.../RuleEngine.kt:102`).
 * - `bedtimeStart === bedtimeEnd`: an empty window. `RuleEngine.inWindow` returns false for every time
 *   when start equals end, and the parent app documents the same reading
 *   (`apps/parent-app/lib/features/rules/active_window.dart:118`). Not a 23:59–00:00 window that blocks
 *   for a minute at midnight — an actual no-window.
 * - `schoolHours.days: []`: the day test comes first (`RuleEngine.kt:152`), so school hours are never
 *   consulted.
 * - `allowOverlap: true`: the bedtime above covers the whole day to the server's own overlap check
 *   (`routes/rules.ts:116`, where equal times answer "covers everything"), so the input needs the opt-out
 *   the route reads (`routes/rules.ts:84`). It is an input flag; the route does not store it.
 */
export const NEUTRAL_RULES_PATCH = {
  screenTime: {
    dailyLimitMinutes: 0,
    weekendLimitMinutes: 0,
    bedtimeStart: "00:00",
    bedtimeEnd: "00:00",
    schoolHours: { start: "00:00", end: "00:00", days: [] },
  },
  allowOverlap: true,
};

/**
 * The child-scoped tables TR-06 counts in Postgres (`services/api/scripts/e2e.mjs:478-494`), plus the two
 * account rows. `delete` reads each one through its parent route after the erasure; a row that is still
 * served means the erasure left residue.
 */
export const TR06_TABLES = [
  "child",
  "ruleSet",
  "device",
  "deviceCommand",
  "deviceApp",
  "alert",
  "activityEvent",
  "webVisit",
  "appUsageDaily",
  "socialEvent",
  "installRequest",
  "locationPing",
  "geofence",
  "consentRecord",
  "pairingDecision",
];

/** The two account rows. Not TR-06's tables: they are what makes the family an account at all. */
const ACCOUNT_ROWS = ["family", "parent"];

/**
 * Resolve `--base-url` (or `$SCENARIO_API_BASE`, else localhost) and refuse anything else.
 *
 * The host test is a suffix test with the dot, not `includes`, because both refused lookalikes in the
 * test below are hosts that *look* like the real one: `osratech.com.evil.com` contains our domain and
 * `staging.osratech.com.evil.net` starts with it. An exact match or a dotted suffix is the only safe
 * comparison; `staging.osratech.com` itself (the apex) is refused too — the wildcard does not cover it,
 * and the staging API is `api.staging.osratech.com` (`docs/ROADMAP.md:150`).
 */
export function resolveBaseUrl(raw, env = process.env) {
  const value = raw ?? env.SCENARIO_API_BASE ?? DEFAULT_BASE_URL;
  let url;
  try {
    url = new URL(value);
  } catch {
    throw new BaseUrlRefused(`"${value}" is not a URL`);
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new BaseUrlRefused(`${url.protocol}// is not an http or https scheme`);
  }
  if (url.username !== "" || url.password !== "") {
    throw new BaseUrlRefused(`credentials in the URL ("${url.username}@…") — an address the script cannot check is not one it talks to`);
  }
  const host = url.hostname.toLowerCase();
  if (!LOCAL_HOSTS.has(host) && !host.endsWith(STAGING_SUFFIX)) {
    throw new BaseUrlRefused(
      `host "${host}" is not localhost, 127.0.0.1 or a *.staging.osratech.com host (the staging API is api.staging.osratech.com)`,
    );
  }
  return url.href.replace(/\/+$/, "");
}

/** `http://localhost:3000` from any URL string, for comparing a token file with `--base-url`. */
export function originOf(raw) {
  try {
    return new URL(String(raw)).origin;
  } catch {
    return String(raw);
  }
}

/**
 * Write the credentials file at mode 0600 and report the mode the filesystem actually kept.
 *
 * On Windows `writeFileSync`'s `mode` is accepted and ignored — NTFS has no POSIX mode bits — so the
 * caller warns when the group/other bits survive instead of pretending they did not. Measured on this
 * host (Node 24, Windows 11): a file written with `mode: 0o600` stats as `0o666`.
 */
export function writeTokenFile(path, payload) {
  writeFileSync(path, `${JSON.stringify(payload, null, 2)}\n`, { mode: TOKEN_FILE_MODE });
  try {
    chmodSync(path, TOKEN_FILE_MODE);
  } catch {
    /* the write above already asked for 0600; a refusal here is a warning, not a lost file */
  }
  return statSync(path).mode & 0o777;
}

/** Read the file `create` printed. Every field `delete` needs is checked here, before any request. */
export function readTokenFile(path) {
  let raw;
  try {
    raw = readFileSync(path, "utf8");
  } catch (error) {
    throw new TokenFileRefused(
      `cannot read ${path} (${error.code ?? error.message}) — pass the parentTokenFile that create printed`,
    );
  }
  let data;
  try {
    data = JSON.parse(raw);
  } catch {
    throw new TokenFileRefused(`${path} is not JSON — it is not a file create wrote`);
  }
  const required = ["baseUrl", "familyId", "childId", "email", "password", "token"];
  const missing = required.filter((key) => typeof data?.[key] !== "string" || data[key] === "");
  if (missing.length > 0) throw new TokenFileRefused(`${path} is missing ${missing.join(", ")}`);
  return data;
}

async function api(baseUrl, method, path, { token, body } = {}) {
  const res = await fetch(`${baseUrl}${path}`, {
    method,
    headers: {
      ...(body === undefined ? {} : { "content-type": "application/json" }),
      ...(token === undefined ? {} : { authorization: `Bearer ${token}` }),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  let data = null;
  try {
    data = await res.json();
  } catch {
    /* 204, or an empty body */
  }
  return { status: res.status, data };
}

const brief = (response) => `${response.status} ${JSON.stringify(response.data ?? null)}`;

/**
 * The ruleset a scenario needs: no limit that expires mid-run, no bedtime window, no school days.
 * The read-back is the check, not the write: `create` must not mint a pairing code for a family whose
 * rules it has only asked for.
 */
export function assertNeutralRules(rules) {
  const screenTime = rules?.screenTime;
  if (!screenTime) throw new StepFailed(`GET /v1/rules answered no screenTime (${JSON.stringify(rules ?? null)})`);
  const problems = [];
  if (screenTime.dailyLimitMinutes !== 0) problems.push(`dailyLimitMinutes is ${screenTime.dailyLimitMinutes}, not 0`);
  if (screenTime.weekendLimitMinutes !== 0) problems.push(`weekendLimitMinutes is ${screenTime.weekendLimitMinutes}, not 0`);
  if (screenTime.bedtimeStart !== screenTime.bedtimeEnd) {
    problems.push(`bedtime is ${screenTime.bedtimeStart}-${screenTime.bedtimeEnd}, not an empty window`);
  }
  const days = screenTime.schoolHours?.days;
  if (!Array.isArray(days) || days.length !== 0) problems.push(`schoolHours.days is ${JSON.stringify(days)}, not []`);
  if (problems.length > 0) {
    throw new StepFailed(`the ruleset read back is not the neutral one — ${problems.join("; ")}`);
  }
}

const runTag = () => `${new Date().toISOString().replace(/[-:.]/g, "").slice(0, 15)}-${randomBytes(3).toString("hex")}`;

/**
 * Create the family through the API, in the order that keeps a run un-ambushed: the rules are neutral
 * before a pairing code exists, so the phone never applies the defaults even once.
 */
export async function createFamily({ baseUrl, tokenFile, log = console.error }) {
  const tag = runTag();
  // Absolute, because the printed path is what `delete` is given, possibly from another directory.
  const target = resolve(tokenFile);
  const email = `scenario-${tag}@osratech.test`;
  const password = randomBytes(24).toString("base64url");
  let token;
  let familyId;
  try {
    const registration = await api(baseUrl, "POST", "/v1/auth/register", {
      body: { email, password, displayName: `Scenario ${tag}`, familyName: `Scenario ${tag}`, region: REGION },
    });
    if (registration.status !== 201 || typeof registration.data?.token !== "string") {
      throw new StepFailed(`POST /v1/auth/register answered ${brief(registration)}`);
    }
    token = registration.data.token;

    const me = await api(baseUrl, "GET", "/v1/family/me", { token });
    familyId = me.data?.family?.id;
    if (me.status !== 200 || typeof familyId !== "string") {
      throw new StepFailed(`GET /v1/family/me answered ${brief(me)}`);
    }

    const child = await api(baseUrl, "POST", "/v1/family/children", {
      token,
      body: { displayName: `Scenario child ${tag}`, birthYear: 2015, consent: { method: "sms_plus", jurisdiction: REGION } },
    });
    const childId = child.data?.child?.id;
    if (child.status !== 201 || typeof childId !== "string") {
      throw new StepFailed(`POST /v1/family/children answered ${brief(child)}`);
    }

    const patched = await api(baseUrl, "PATCH", `/v1/rules/${childId}`, { token, body: NEUTRAL_RULES_PATCH });
    if (patched.status !== 200) throw new StepFailed(`PATCH /v1/rules/${childId} answered ${brief(patched)}`);
    const readBack = await api(baseUrl, "GET", `/v1/rules/${childId}`, { token });
    if (readBack.status !== 200) throw new StepFailed(`GET /v1/rules/${childId} answered ${brief(readBack)}`);
    assertNeutralRules(readBack.data);

    const pair = await api(baseUrl, "POST", "/v1/devices/pair", { token, body: { childId } });
    const pairingCode = pair.data?.code;
    if (pair.status !== 201 || !/^\d{6}$/.test(pairingCode ?? "")) {
      throw new StepFailed(`POST /v1/devices/pair answered ${brief(pair)}`);
    }

    const mode = writeTokenFile(target, {
      baseUrl,
      familyId,
      childId,
      email,
      password,
      token,
      createdAt: new Date().toISOString(),
    });
    if ((mode & 0o077) !== 0) {
      log(
        `scenario-family: the token file is mode 0o${mode.toString(8)}, not 0o600 — this OS ignores POSIX mode bits. ` +
          `It holds the parent's token and password; keep it under your own user profile and delete it after the run.`,
      );
    }
    return { familyId, childId, pairingCode, parentTokenFile: target };
  } catch (error) {
    await erasePartial({ baseUrl, token, familyId, password, log });
    throw error;
  }
}

/**
 * Best effort: a `create` that fails after the sign-up would otherwise leave a real account behind, which
 * is exactly the residue `AGENTS.md` §7 forbids. It cannot throw — the original failure is the message.
 */
async function erasePartial({ baseUrl, token, familyId, password, log }) {
  if (!token || !familyId) return;
  try {
    const erased = await api(baseUrl, "DELETE", "/v1/family", { token, body: { password } });
    if (erased.status === 200) log(`scenario-family: create failed; erased the partial family ${familyId}`);
    else log(`scenario-family: create failed AND the partial family ${familyId} could not be erased (${erased.status})`);
  } catch (error) {
    log(`scenario-family: create failed AND erasing the partial family ${familyId} threw (${error.message})`);
  }
}

/**
 * The family the token file names, read through the parent routes, before anything is deleted. A deletion
 * proved against an empty family is a tautology: these numbers are what make the zeros after it mean
 * something. Every read is a route that serves the table it counts.
 */
async function liveFamily(baseUrl, token) {
  const me = await api(baseUrl, "GET", "/v1/family/me", { token });
  if (me.status !== 200) throw new StepFailed(`GET /v1/family/me answered ${brief(me)}`);
  const children = Array.isArray(me.data?.children) ? me.data.children : [];
  return { familyId: me.data?.family?.id, children };
}

async function liveCounts(baseUrl, token, creds) {
  const { familyId, children } = await liveFamily(baseUrl, token);
  if (familyId !== creds.familyId) {
    throw new TokenFileRefused(`the token opens family ${familyId}, but ${creds.familyId} is what the token file says — refusing to erase either`);
  }
  const child = children.find((c) => c.id === creds.childId);
  if (!child) {
    throw new StepFailed(
      `GET /v1/family/me does not hold child ${creds.childId}: the family is already erased, or the token file belongs to another family`,
    );
  }
  const rules = await api(baseUrl, "GET", `/v1/rules/${creds.childId}`, { token });
  const consent = await api(baseUrl, "GET", `/v1/family/children/${creds.childId}/consent`, { token });
  const alerts = await api(baseUrl, "GET", `/v1/alerts?childId=${encodeURIComponent(creds.childId)}&limit=1`, { token });
  const deviceIds = (child.devices ?? []).map((d) => d.id);
  return {
    child: 1,
    ruleSet: rules.status === 200 ? 1 : 0,
    consentRecord: Array.isArray(consent.data?.records) ? consent.data.records.length : 0,
    device: deviceIds.length,
    deviceIds,
    alert: typeof alerts.data?.meta?.total === "number" ? alerts.data.meta.total : 0,
    rulesVersion: child.rulesVersion ?? null,
  };
}

/**
 * One parent route per table TR-06 counts, plus the export (the only parent read that carries
 * `pairingDecision`, `routes/family.ts:361`) and the login that proves the `parent` row itself is gone.
 * Each must refuse after the erasure; one that answers 200 is residue and the table keeps a 1.
 */
function probesFor(childId, deviceIds) {
  const q = encodeURIComponent(childId);
  const probes = [
    { table: "family", method: "GET", path: "/v1/family/me" },
    { table: "child", method: "GET", path: `/v1/family/children/${q}` },
    { table: "ruleSet", method: "GET", path: `/v1/rules/${q}` },
    { table: "device", method: "GET", path: "/v1/devices" },
    { table: "alert", method: "GET", path: `/v1/alerts?childId=${q}&limit=1` },
    { table: "geofence", method: "GET", path: `/v1/location/geofences/${q}` },
    { table: "consentRecord", method: "GET", path: `/v1/family/children/${q}/consent` },
    { table: "appUsageDaily", method: "GET", path: `/v1/reports/usage?childId=${q}&days=7` },
    { table: "webVisit", method: "GET", path: `/v1/reports/web?childId=${q}&days=7` },
    { table: "activityEvent", method: "GET", path: `/v1/reports/activity?childId=${q}&days=7` },
    { table: "socialEvent", method: "GET", path: `/v1/social/events?childId=${q}` },
    { table: "locationPing", method: "GET", path: `/v1/location/${q}/history` },
    { table: "pairingDecision", method: "GET", path: "/v1/family/export" },
    ...deviceIds.flatMap((id) => [
      { table: "installRequest", method: "GET", path: `/v1/devices/${id}/requests` },
      { table: "deviceCommand", method: "GET", path: `/v1/devices/${id}/commands/history` },
      { table: "deviceApp", method: "GET", path: `/v1/devices/${id}/apps` },
    ]),
  ];
  return probes;
}

function countsFrom(probes) {
  const counts = {};
  for (const table of [...ACCOUNT_ROWS, ...TR06_TABLES]) counts[table] = 0;
  for (const probe of probes) {
    if (probe.status === 200) counts[probe.table] = (counts[probe.table] ?? 0) + 1;
  }
  return counts;
}

/**
 * Erase the family with the real route, then prove it. `DELETE /v1/family` is the owner's escape hatch
 * (`routes/family.ts:388`, `lib/accountDeletion.ts:152`): it re-authenticates with the password, runs every
 * child through the ADR-0013 cascade, then deletes the family-scoped rows, every parent and the family in
 * one transaction, and answers with the row counts it removed. Those counts are the server's own evidence
 * that each table's rows for this child were deleted in that transaction.
 *
 * The HTTP side of the proof is what follows: the same token and the same credentials must now be refused,
 * and every route that would serve one of TR-06's tables must refuse with them. The row-level count itself
 * stays where it was — `e2e.mjs` with `DATABASE_URL` — because no public route counts rows.
 */
export async function deleteFamily({ baseUrl, tokenFile, log = console.error }) {
  const creds = readTokenFile(tokenFile);
  if (originOf(creds.baseUrl) !== originOf(baseUrl)) {
    throw new TokenFileRefused(
      `the token file was written for ${originOf(creds.baseUrl)}; refusing to send its token and password to ${originOf(baseUrl)}`,
    );
  }

  const login = await api(baseUrl, "POST", "/v1/auth/login", { body: { email: creds.email, password: creds.password } });
  if (login.status === 401) {
    log("scenario-family: the parent's credentials are already refused — the account is gone, nothing to erase");
    return { deleted: "already-erased", familyId: creds.familyId, counts: countsFrom([]), eraseRows: {}, before: null, probes: [] };
  }
  if (login.status !== 200 || typeof login.data?.token !== "string") {
    throw new StepFailed(`POST /v1/auth/login answered ${brief(login)}`);
  }
  const token = login.data.token;

  const before = await liveCounts(baseUrl, token, creds);
  if (before.child !== 1 || before.ruleSet < 1 || before.consentRecord < 1) {
    throw new StepFailed(
      `refusing to prove a deletion on a family that is not live: child=${before.child} ruleSet=${before.ruleSet} consentRecord=${before.consentRecord}`,
    );
  }
  log(`scenario-family: family ${creds.familyId} is live — ${JSON.stringify({ ...before, deviceIds: undefined })}`);

  const erase = await api(baseUrl, "DELETE", "/v1/family", { token, body: { password: creds.password } });
  if (erase.status !== 200) throw new StepFailed(`DELETE /v1/family answered ${brief(erase)}`);
  const erasedFamily = erase.data?.familyId;
  if (erase.data?.deleted !== "family" || erasedFamily !== creds.familyId) {
    throw new StepFailed(`DELETE /v1/family erased ${JSON.stringify(erase.data?.familyId)}, not ${creds.familyId}`);
  }
  const rows = erase.data?.rows ?? {};
  // The cascade ran in the same transaction the counts come from: the child row, its ruleset, its consent
  // and the parents were all deleted, so nothing serves them any more (every child-scoped delete is
  // filtered by this id).
  if (!(rows.child >= 1) || !(rows.ruleSet >= 1) || !(rows.consentRecord >= 1) || !(rows.parent >= 1) || rows.family !== 1) {
    throw new StepFailed(
      `the erasure report does not name the child, its ruleset, its consent, its parents and the family — rows=${JSON.stringify(rows)}`,
    );
  }

  const probes = [];
  for (const probe of probesFor(creds.childId, before.deviceIds)) {
    const response = await api(baseUrl, probe.method, probe.path, { token });
    probes.push({ table: probe.table, path: probe.path, status: response.status });
  }
  const afterLogin = await api(baseUrl, "POST", "/v1/auth/login", { body: { email: creds.email, password: creds.password } });
  probes.push({ table: "parent", path: "/v1/auth/login", status: afterLogin.status });

  const counts = countsFrom(probes);
  const notes = [];
  if (before.deviceIds.length === 0) {
    notes.push("no device was ever paired, so installRequest/deviceCommand/deviceApp had no route to read — their 0 is the erase report's, not a served page");
  }
  const residue = Object.entries(counts).filter(([, n]) => n !== 0);
  const deleted = residue.length === 0 ? "family" : "residue";
  if (residue.length > 0) {
    log(`scenario-family: RESIDUE — ${residue.map(([table, n]) => `${table}=${n}`).join(" ")} still answered 200 after the erasure`);
  }
  return { deleted, familyId: creds.familyId, counts, eraseRows: rows, before, probes, notes };
}

function parseArgs(argv) {
  const [command, ...rest] = argv;
  if (command === undefined) throw new UsageError("a subcommand is required");
  if (["--help", "-h", "help"].includes(command)) return { command: "help" };
  if (command !== "create" && command !== "delete") throw new UsageError(`unknown subcommand "${command}"`);

  const options = { command, baseUrl: undefined, tokenFile: undefined };
  for (let i = 0; i < rest.length; i++) {
    const arg = rest[i];
    if (arg === "--help" || arg === "-h") return { command: "help" };
    if (arg === "--base-url") {
      options.baseUrl = rest[++i];
      if (options.baseUrl === undefined) throw new UsageError("--base-url needs a value");
      continue;
    }
    if (arg.startsWith("--base-url=")) {
      options.baseUrl = arg.slice("--base-url=".length);
      continue;
    }
    if (arg === "--token-file") {
      options.tokenFile = rest[++i];
      if (options.tokenFile === undefined) throw new UsageError("--token-file needs a value");
      continue;
    }
    if (arg.startsWith("--token-file=")) {
      options.tokenFile = arg.slice("--token-file=".length);
      continue;
    }
    throw new UsageError(`unknown argument "${arg}"`);
  }
  if (options.command === "delete" && !options.tokenFile) {
    throw new UsageError("delete needs --token-file (the parentTokenFile create printed)");
  }
  return options;
}

async function cli(argv, { stdout = process.stdout, stderr = process.stderr } = {}) {
  const options = parseArgs(argv);
  if (options.command === "help") {
    stdout.write(USAGE);
    return 0;
  }
  const baseUrl = resolveBaseUrl(options.baseUrl);
  if (options.command === "create") {
    const tokenFile = options.tokenFile ?? join(tmpdir(), `osra-scenario-family-${runTag()}.json`);
    const result = await createFamily({ baseUrl, tokenFile, log: (line) => stderr.write(`${line}\n`) });
    // One JSON object on stdout, and it is the only thing on stdout: the token is in the file.
    stdout.write(`${JSON.stringify(result)}\n`);
    return 0;
  }
  const result = await deleteFamily({ baseUrl, tokenFile: options.tokenFile, log: (line) => stderr.write(`${line}\n`) });
  stdout.write(`${JSON.stringify(result)}\n`);
  const residue = Object.values(result.counts).some((n) => n !== 0);
  return residue ? 1 : 0;
}

export async function run(argv, streams) {
  try {
    process.exitCode = await cli(argv, streams);
  } catch (error) {
    if (error instanceof UsageError) {
      process.stderr.write(`scenario-family: UsageError: ${error.message}\n\n${USAGE}`);
      process.exitCode = 2;
    } else if (error instanceof BaseUrlRefused || error instanceof TokenFileRefused) {
      process.stderr.write(`scenario-family: ${error.name}: ${error.message}\n`);
      process.exitCode = 2;
    } else if (error instanceof StepFailed) {
      process.stderr.write(`scenario-family: StepFailed: ${error.message}\n`);
      process.exitCode = 1;
    } else {
      throw error;
    }
  }
  return process.exitCode;
}

const invokedDirectly =
  process.argv[1] !== undefined && import.meta.url === pathToFileURL(resolve(process.argv[1])).href;
if (invokedDirectly) await run(process.argv.slice(2));
