#!/usr/bin/env node
/**
 * Tests for `scripts/hardware/scenario-family.mjs` (issue #668). Node's built-in runner, no dependencies:
 *
 *   node --test scripts/hardware/scenario-family.test.mjs
 *
 * Three kinds of case:
 *
 * 1. **The base URL guard**, one case per refused shape with the reason it must be refused. This is the
 *    check that matters most: the script creates accounts and erases them, so a host it should not talk
 *    to is a run that must not start. `resolveBaseUrl` is called directly, and one case runs the CLI to
 *    prove the refusal is a named error and exit 2 (not a `fetch` failure).
 * 2. **The mechanics of `create`/`delete` against a stub API** on 127.0.0.1 — the script only ever talks
 *    to a host this guard allows, so a local stub is a legal target. It pins the one JSON object on stdout,
 *    the token file's mode and the fact that the token never reaches stdout, the exact payloads the real
 *    routes take, and that `create` refuses a ruleset that does not read back neutral.
 * 3. **`delete` after `create` leaves nothing** — the whole point of the helper. It needs a live API, so
 *    it is skipped with a reason unless `SCENARIO_API_BASE` is set (the precedent is `e2e.mjs`'s
 *    `DATABASE_URL` gate, `services/api/scripts/e2e.mjs:477-499`, which skips its row-count check with a
 *    NOTE rather than pretending). When the variable *is* set, non-zero counts **fail** the test.
 */
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { BaseUrlRefused, brief, redact, resolveBaseUrl, writeTokenFile } from "./scenario-family.mjs";

const SCRIPT = join(dirname(fileURLToPath(import.meta.url)), "scenario-family.mjs");
const LIVE_BASE = process.env.SCENARIO_API_BASE;

/**
 * Run the script as a child process, exactly as a tester does. Asynchronous on purpose: `spawnSync` blocks
 * this process's event loop, and the stub API these cases talk to lives in it — a synchronous spawn would
 * deadlock against its own fixture.
 */
function runCli(args, env = process.env) {
  return new Promise((resolveRun, reject) => {
    const child = spawn(process.execPath, [SCRIPT, ...args], { env, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    const timer = setTimeout(() => child.kill("SIGKILL"), 60_000);
    child.on("error", reject);
    child.on("close", (status, signal) => {
      clearTimeout(timer);
      resolveRun({ status, signal, stdout, stderr });
    });
  });
}

// ── 1. The base URL guard ────────────────────────────────────────────────────────────────────────────

/**
 * Each case names the reason. The two lookalikes are why the check is an exact or dotted-suffix match and
 * never `includes`: both hosts *contain* our domain and neither is ours.
 */
const REFUSED = [
  ["https://evil.example.com", "only localhost, 127.0.0.1 and *.staging.osratech.com are allowed — this is neither"],
  ["http://osratech.com.evil.com", "the domain is on the right of nothing: the host ENDS in evil.com, so the dot-suffix test must refuse it"],
  ["http://staging.osratech.com.evil.net", "`.staging.osratech.com` is a prefix here, not the suffix — a `startsWith`/`includes` check would allow an attacker's host"],
  ["ftp://localhost", "the protocol is ftp: an allowed host does not make an allowed scheme, and a wrong scheme is a wrong client"],
];

const ACCEPTED = [
  ["http://localhost:3000", "the local API the scenario suite runs against"],
  ["http://127.0.0.1:3000", "the same stack by IP, which is what a container/port-forward path uses"],
  ["https://x.staging.osratech.com", "a subdomain of the staging zone: the HTTPS pair-B/C backend"],
];

for (const [url, reason] of REFUSED) {
  test(`refuses ${url} — ${reason}`, () => {
    assert.throws(
      () => resolveBaseUrl(url),
      (error) => {
        assert.ok(error instanceof BaseUrlRefused, `expected a named BaseUrlRefused, got ${error?.name}: ${error?.message}`);
        assert.equal(error.name, "BaseUrlRefused");
        return true;
      },
    );
  });
}

for (const [url, reason] of ACCEPTED) {
  test(`accepts ${url} — ${reason}`, () => {
    assert.equal(resolveBaseUrl(url), url);
  });
}

test("refuses plain http to a staging host, where the parent's password would cross in clear text", () => {
  // Ahmed's R1 on #674: the host check alone let http through, and registration, login and deletion each
  // carry a password or a bearer token. Loopback is the one place cleartext is allowed, and it is tested.
  assert.throws(() => resolveBaseUrl("http://api.staging.osratech.com"), BaseUrlRefused);
  assert.throws(() => resolveBaseUrl("http://x.staging.osratech.com"), BaseUrlRefused);
  assert.equal(resolveBaseUrl("http://localhost:3000"), "http://localhost:3000");
  assert.equal(resolveBaseUrl("http://127.0.0.1:3000"), "http://127.0.0.1:3000");
  assert.equal(resolveBaseUrl("https://api.staging.osratech.com"), "https://api.staging.osratech.com");
});

test("redacts token-shaped keys before a body reaches stderr", () => {
  // Ahmed's R2: `brief` printed the whole body, so a route that renamed its token field would put it in the
  // scrollback the file header warns about. Nested, array and sibling keys are covered because a rename can
  // move the secret anywhere in the shape.
  const redacted = redact({
    // The password is the credential this script actually sends (register and login), so it is in the
    // fixture at the top level and nested — Claude's f4 survived because the row had no `password` at all.
    password: "top-level-password",
    accessToken: "secret-value",
    parent: { id: "p1", refreshToken: "another", password: "nested-password", name: "Sam" },
    items: [{ apiKey: "k", hmacSecret: "h", safe: "ok" }],
    status: "ok",
  });
  assert.deepEqual(redacted, {
    password: "[redacted]",
    accessToken: "[redacted]",
    parent: { id: "p1", refreshToken: "[redacted]", password: "[redacted]", name: "Sam" },
    items: [{ apiKey: "[redacted]", hmacSecret: "[redacted]", safe: "ok" }],
    status: "ok",
  });
  assert.equal(redacted.password, "[redacted]");
  // The keys stay — a reader needs to see that a password was there — and only the values are replaced.
  assert.ok(!JSON.stringify(redacted).includes("another"));
  assert.ok(!JSON.stringify(redacted).includes("top-level-password"));
  assert.ok(!JSON.stringify(redacted).includes("nested-password"));
  assert.ok(!JSON.stringify(redacted).includes("secret-value"));
});

test("refuses the staging apex, which the wildcard does not cover", () => {
  // `*.staging.osratech.com` excludes the apex; the staging API is api.staging.osratech.com. Fail closed.
  assert.throws(() => resolveBaseUrl("https://staging.osratech.com"), BaseUrlRefused);
});

test("refuses a base URL that smuggles its host in userinfo", () => {
  // `new URL("http://localhost@evil.example.com").hostname` is evil.example.com, so the guard reads the
  // host that will actually be contacted — and refuses the credential-in-URL form outright.
  assert.throws(() => resolveBaseUrl("http://localhost@evil.example.com"), BaseUrlRefused);
});

test("refuses $SCENARIO_API_BASE when it names a host the guard does not allow", () => {
  assert.throws(() => resolveBaseUrl(undefined, { SCENARIO_API_BASE: "http://evil.example.com" }), BaseUrlRefused);
});

test("the CLI refuses a forbidden host as a named error with exit 2, before any request", async () => {
  const run = await runCli(["create", "--base-url", "https://evil.example.com"]);
  assert.equal(run.status, 2, `expected exit 2, got ${run.status}: ${run.stderr}`);
  assert.match(run.stderr, /BaseUrlRefused:/);
  assert.equal(run.stdout, "", "a refused run prints nothing on stdout");
  assert.doesNotMatch(run.stderr, /fetch failed/, "the refusal must come before the first network call, not from one");
});

// ── 2. Usage, token file and the payload shapes, against a stub API ─────────────────────────────────

/**
 * A stand-in for the routes `create` calls, with the shapes read from the real handlers:
 * `POST /v1/auth/register` (`routes/auth.ts:168,192`), `GET /v1/family/me` (`routes/family.ts:52,136`),
 * `POST /v1/family/children` (`routes/family.ts:156,193`), `PATCH`/`GET /v1/rules/:childId`
 * (`routes/rules.ts:183,169`) and `POST /v1/devices/pair` (`routes/devices.ts:310,329`).
 *
 * `neutral: false` drops the PATCH — it answers what a ruleset nobody patched reads like — so the test can
 * show that `create` refuses to mint a pairing code for a family whose windows were not neutralised.
 */
async function stubApi({ neutral = true } = {}) {
  const calls = [];
  const state = {
    token: "stub-token-8d1f2c3a",
    code: "424242",
    familyId: "fam-1",
    childId: "child-1",
    // The defaults a new child really gets (`lib/defaultRules.ts:4`).
    rules: {
      screenTime: {
        dailyLimitMinutes: 180,
        weekendLimitMinutes: 300,
        bedtimeStart: "21:00",
        bedtimeEnd: "07:00",
        schoolHours: { start: "08:00", end: "15:00", days: [1, 2, 3, 4, 5] },
      },
      webFilter: { blockedCategories: ["gambling"], allowedDomains: [], blockedDomains: [], safeSearchEnforced: true },
      appRules: [],
      routines: [],
      alwaysAllowedApps: [],
    },
  };
  const server = createServer((req, res) => {
    let raw = "";
    req.on("data", (chunk) => {
      raw += chunk;
    });
    req.on("end", () => {
      const body = raw === "" ? null : JSON.parse(raw);
      calls.push({ method: req.method, url: req.url, authorization: req.headers.authorization ?? null, body });
      const send = (status, payload) => {
        res.writeHead(status, { "content-type": "application/json" });
        res.end(JSON.stringify(payload));
      };
      if (req.method === "POST" && req.url === "/v1/auth/register") {
        return send(201, { token: state.token, refreshToken: "stub-refresh", parent: { id: "parent-1", email: body.email, displayName: body.displayName } });
      }
      if (req.method === "GET" && req.url === "/v1/family/me") {
        return send(200, {
          family: { id: state.familyId },
          parent: { id: "parent-1" },
          parents: [{ id: "parent-1" }],
          children: [{ id: state.childId, devices: [], rulesVersion: 2 }],
          devices: [],
        });
      }
      if (req.method === "POST" && req.url === "/v1/family/children") {
        return send(201, { child: { id: state.childId, displayName: body.displayName }, consent: { id: "consent-1", method: body.consent?.method } });
      }
      if (req.method === "PATCH" && req.url === `/v1/rules/${state.childId}`) {
        // The route deep-merges screenTime onto what is stored (`routes/rules.ts:212`).
        if (neutral) state.rules = { ...state.rules, screenTime: { ...state.rules.screenTime, ...body.screenTime } };
        return send(200, state.rules);
      }
      if (req.method === "GET" && req.url === `/v1/rules/${state.childId}`) {
        return send(200, state.rules);
      }
      if (req.method === "POST" && req.url === "/v1/devices/pair") {
        return send(201, { code: state.code, expiresAt: new Date(Date.now() + 600_000).toISOString() });
      }
      return send(404, { error: "not_found" });
    });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  return {
    baseUrl: `http://127.0.0.1:${port}`,
    calls,
    state,
    close: () => new Promise((resolve) => server.close(resolve)),
  };
}

function tempDir() {
  return mkdtempSync(join(tmpdir(), "scenario-family-test-"));
}

test("--help prints the usage and exits 0", async () => {
  const run = await runCli(["--help"]);
  assert.equal(run.status, 0);
  assert.match(run.stdout, /usage: node scripts\/hardware\/scenario-family\.mjs <create\|delete>/);
  assert.match(run.stdout, /--base-url/);
  assert.equal(run.stderr, "");
});

const USAGE_FAILURES = [
  [[], "no subcommand"],
  [["--frobnicate"], "an unknown first argument"],
  [["create", "--bogus"], "an unknown option on a known subcommand"],
  [["delete"], "delete without --token-file"],
  [["create", "--base-url"], "--base-url without a value"],
];

for (const [args, why] of USAGE_FAILURES) {
  test(`usage: ${why} exits 2`, async () => {
    const run = await runCli(args);
    assert.equal(run.status, 2, `expected exit 2 for ${JSON.stringify(args)}, got ${run.status}: ${run.stderr}`);
    assert.match(run.stderr, /UsageError:/);
    assert.match(run.stderr, /usage:/);
    assert.equal(run.stdout, "", "a refused run prints nothing on stdout");
  });
}

test("create sends the shapes the real routes take and prints one JSON object", async (t) => {
  const stub = await stubApi();
  const dir = tempDir();
  t.after(async () => {
    await stub.close();
    rmSync(dir, { recursive: true, force: true });
  });
  const tokenFile = join(dir, "parent.json");
  const run = await runCli(["create", "--base-url", stub.baseUrl, "--token-file", tokenFile]);
  assert.equal(run.status, 0, run.stderr);

  const printed = JSON.parse(run.stdout); // exactly one JSON object, or this throws
  assert.deepEqual(Object.keys(printed).sort(), ["childId", "familyId", "pairingCode", "parentTokenFile"]);
  assert.equal(printed.familyId, "fam-1");
  assert.equal(printed.childId, "child-1");
  assert.equal(printed.pairingCode, "424242");
  assert.equal(printed.parentTokenFile, tokenFile);
  assert.equal(run.stdout.trim().split("\n").length, 1, "stdout carries the object and nothing else");

  const register = stub.calls.find((c) => c.url === "/v1/auth/register");
  assert.equal(register.method, "POST");
  assert.ok(register.body.email.endsWith("@osratech.test"));
  assert.ok(register.body.password.length >= 12, "the route requires 12+ characters (routes/auth.ts:45)");
  assert.equal(register.body.region, "US");

  const child = stub.calls.find((c) => c.url === "/v1/family/children");
  assert.equal(child.body.consent.jurisdiction, register.body.region, "the inline consent jurisdiction must equal the family region (routes/family.ts:170)");
  assert.equal(child.authorization, "Bearer stub-token-8d1f2c3a");

  const patch = stub.calls.find((c) => c.method === "PATCH" && c.url === "/v1/rules/child-1");
  assert.equal(patch.body.screenTime.dailyLimitMinutes, 0);
  assert.equal(patch.body.screenTime.weekendLimitMinutes, 0);
  assert.equal(patch.body.screenTime.bedtimeStart, patch.body.screenTime.bedtimeEnd);
  assert.deepEqual(patch.body.screenTime.schoolHours.days, []);
  assert.equal(patch.body.allowOverlap, true, "equal bedtime times cover the day to routes/rules.ts:116, so the opt-out is required");

  // The pairing code exists only after the neutral read-back.
  const order = stub.calls.map((c) => `${c.method} ${c.url}`);
  assert.ok(order.indexOf("GET /v1/rules/child-1") < order.indexOf("POST /v1/devices/pair"), "the code is minted after the rules were verified");
});

test("the line a failed step writes to stderr carries no secret", () => {
  // Claude's f8: the row above proves `redact` works, not that the failure path uses it. `brief` is what
  // every StepFailed interpolates, so its own output is the thing that must be clean.
  const line = brief({ status: 200, data: { accessToken: "leaked-token", nested: { password: "leaked-password" } } });
  assert.ok(line.includes("[redacted]"), line);
  assert.ok(!line.includes("leaked-token"), line);
  assert.ok(!line.includes("leaked-password"), line);
  assert.ok(line.startsWith("200 "), line);
});

test("refuses to write over an existing file or follow a planted symlink", () => {
  // Ahmed's H1: the default path is in the shared temp directory, and a pre-existing file there would have
  // been followed. Exclusive create turns that into a refusal instead of a silent overwrite.
  const dir = mkdtempSync(join(tmpdir(), "scenario-h1-"));
  try {
    const path = join(dir, "token.json");
    writeTokenFile(path, { token: "one" });
    assert.throws(() => writeTokenFile(path, { token: "two" }), /EEXIST/);
    assert.equal(JSON.parse(readFileSync(path, "utf8")).token, "one");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("the token file holds the token, and stdout does not", async (t) => {
  const stub = await stubApi();
  const dir = tempDir();
  t.after(async () => {
    await stub.close();
    rmSync(dir, { recursive: true, force: true });
  });
  const tokenFile = join(dir, "parent.json");
  const run = await runCli(["create", "--base-url", stub.baseUrl, "--token-file", tokenFile]);
  assert.equal(run.status, 0, run.stderr);

  const stored = JSON.parse(readFileSync(tokenFile, "utf8"));
  assert.equal(stored.token, stub.state.token);
  assert.equal(stored.baseUrl, stub.baseUrl);
  assert.ok(stored.password.length >= 12, "the deletion re-authenticates with this password (routes/family.ts:388)");

  // The two secrets a screenshot of the terminal must not carry.
  assert.ok(!run.stdout.includes(stub.state.token), "the access token must never reach stdout");
  assert.ok(!run.stdout.includes(stored.password), "the password must never reach stdout");
  assert.ok(!run.stderr.includes(stub.state.token), "the access token must never reach stderr either");

  const mode = statSync(tokenFile).mode & 0o777;
  if (process.platform === "win32") {
    // NTFS has no POSIX mode bits: Node accepts `mode: 0o600` and the filesystem keeps 0o666. The script
    // says so on stderr rather than staying silent, and that warning is what this case pins.
    assert.match(run.stderr, /mode 0o666, not 0o600/, "on Windows the script must warn that 0600 could not be applied");
  } else {
    assert.equal(mode.toString(8), "600", "the token file must be 0600 on a POSIX filesystem");
    assert.doesNotMatch(run.stderr, /not 0o600/);
  }
});

test("create refuses a ruleset that reads back with the default bedtime (it would ambush a run)", async (t) => {
  const stub = await stubApi({ neutral: false });
  const dir = tempDir();
  t.after(async () => {
    await stub.close();
    rmSync(dir, { recursive: true, force: true });
  });
  const run = await runCli(["create", "--base-url", stub.baseUrl, "--token-file", join(dir, "parent.json")]);
  assert.equal(run.status, 1, `expected exit 1, got ${run.status}: ${run.stdout}`);
  assert.match(run.stderr, /StepFailed:.*not the neutral one/);
  assert.match(run.stderr, /bedtime is 21:00-07:00/);
  assert.equal(run.stdout, "", "no family JSON for a family nobody neutralised");
  assert.ok(!stub.calls.some((c) => c.url === "/v1/devices/pair"), "no pairing code is minted for an ambushing ruleset");
});

test("delete refuses a token file written for another host, before any request", async (t) => {
  const stub = await stubApi();
  const dir = tempDir();
  t.after(async () => {
    await stub.close();
    rmSync(dir, { recursive: true, force: true });
  });
  const tokenFile = join(dir, "parent.json");
  const foreign = {
    baseUrl: "http://localhost:59999",
    familyId: "fam-1",
    childId: "child-1",
    email: "x@osratech.test",
    password: "0123456789ab",
    token: "stub-token-8d1f2c3a",
  };
  const { writeFileSync } = await import("node:fs");
  writeFileSync(tokenFile, JSON.stringify(foreign));

  const run = await runCli(["delete", "--base-url", stub.baseUrl, "--token-file", tokenFile]);
  assert.equal(run.status, 2, `expected exit 2, got ${run.status}: ${run.stderr}`);
  assert.match(run.stderr, /TokenFileRefused:.*written for http:\/\/localhost:59999/);
  assert.equal(stub.calls.length, 0, "the stored token and password never left the file");
});

// ── 3. The live case: delete after create leaves nothing ────────────────────────────────────────────

test(
  "delete after create leaves nothing",
  {
    skip: LIVE_BASE
      ? false
      : "SCENARIO_API_BASE is not set: this case needs a running API it may create and erase an account on " +
        "(e.g. SCENARIO_API_BASE=http://localhost:3000 node --test scripts/hardware/scenario-family.test.mjs)",
  },
  async (t) => {
    const dir = tempDir();
    t.after(() => rmSync(dir, { recursive: true, force: true }));
    const tokenFile = join(dir, "parent.json");

    const created = await runCli(["create", "--base-url", LIVE_BASE, "--token-file", tokenFile]);
    assert.equal(created.status, 0, `create failed: ${created.stderr}`);
    const family = JSON.parse(created.stdout);

    const deleted = await runCli(["delete", "--base-url", LIVE_BASE, "--token-file", tokenFile]);
    assert.equal(deleted.status, 0, `delete failed: ${deleted.stderr}`);
    const report = JSON.parse(deleted.stdout);

    // Not a skip and not a warning: residue after an erasure means the erase route or the cascade is
    // broken, and the scenario would run inside a family nobody can clean up.
    const residue = Object.entries(report.counts).filter(([, served]) => served !== 0);
    assert.deepEqual(
      residue,
      [],
      `after erasing family ${family.familyId} these tables were still served: ${JSON.stringify(report.counts)}`,
    );
    assert.equal(report.eraseRows.child, 1, `the erasure must report the child row: ${JSON.stringify(report.eraseRows)}`);
    assert.equal(report.eraseRows.ruleSet, 1, `and its ruleset: ${JSON.stringify(report.eraseRows)}`);
    assert.equal(report.before?.child, 1, "the family was live before the erasure, or the zeros prove nothing");
  },
);
