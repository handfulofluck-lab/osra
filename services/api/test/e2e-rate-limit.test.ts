import { createServer } from "node:http";
import type { IncomingMessage, ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { describe, expect, it } from "vitest";

/**
 * Issue #126: e2e must speak the same language as `qa-probe` when the API rate-limits the run
 * (#112/#114), and a missing `/me` envelope must be one recorded failure plus a summary — not a
 * TypeError that truncates the run. These tests point the real harness at a stub API.
 *
 * `E2E_SCRIPT` exists so the same assertions can be run against an older `e2e.mjs` (proof that the
 * tests fail before the fix, e.g. `E2E_SCRIPT=…/e2e-main.mjs vitest run e2e-rate-limit`). It is not
 * set by the normal suite.
 */
const E2E =
  process.env.E2E_SCRIPT ?? resolve(dirname(fileURLToPath(import.meta.url)), "../scripts/e2e.mjs");

type HarnessRun = { code: number | null; stdout: string; stderr: string };

const json = (res: ServerResponse, status: number, body: unknown) => {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
};

async function runE2E(handler: (req: IncomingMessage, res: ServerResponse) => void): Promise<HarnessRun> {
  const server = createServer(handler);
  await new Promise<void>((ready) => server.listen(0, "127.0.0.1", ready));
  const { port } = server.address() as AddressInfo;

  const child = spawn(process.execPath, [E2E], {
    env: {
      ...process.env,
      API_BASE: `http://127.0.0.1:${port}`,
      INTERNAL_HMAC_SECRET: "e2e-rate-limit-test-secret",
      FS_WS_FLAGGED: "1",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (chunk) => { stdout += chunk; });
  child.stderr.on("data", (chunk) => { stderr += chunk; });

  const code = await new Promise<number | null>((settle, fail) => {
    const timeout = setTimeout(() => {
      child.kill();
      fail(new Error(`e2e did not exit within 15 s\nstdout:\n${stdout}\nstderr:\n${stderr}`));
    }, 15000);
    child.on("exit", (exitCode) => {
      clearTimeout(timeout);
      settle(exitCode);
    });
  });

  server.closeAllConnections();
  await new Promise<void>((closed) => server.close(() => closed()));
  return { code, stdout, stderr };
}

const rate = (res: ServerResponse, retryAfterSeconds = "0") => {
  res.writeHead(429, { "content-type": "application/json", "retry-after": retryAfterSeconds });
  res.end(JSON.stringify({ error: "rate_limited" }));
};

const all429 = (retryAfterSeconds: string) => (_req: IncomingMessage, res: ServerResponse) => rate(res, retryAfterSeconds);

describe("e2e 429 handling (issue #126)", () => {
  it("aborts before any check when Retry-After is longer than the retry cap", async () => {
    const run = await runE2E(all429("60"));
    expect(run.code).toBe(2);
    expect(run.stdout).toContain("ABORT: rate limited by the API (1 x 429) - wait 60 s and re-run");
    expect(run.stdout).toContain("Retry-After 60 s exceeds the 3 s retry cap");
    expect(run.stdout).not.toMatch(/^FAIL /m);
    expect(run.stdout).not.toContain("=== E2E:");
  });

  it("retries once on a short Retry-After, then aborts instead of failing the check", async () => {
    const run = await runE2E(all429("0"));
    expect(run.code).toBe(2);
    expect(run.stdout).toContain("ABORT: rate limited by the API (2 x 429) - wait 60 s and re-run");
    expect(run.stdout).toContain("the single retry after 0 ms was also 429");
    expect(run.stdout).not.toMatch(/^FAIL /m);
  });

  it("aborts once the run has seen more than five 429s, even when every retry succeeded", async () => {
    // One 429 per call, retried successfully, until the sixth call crosses the counter. The abort
    // must happen before the retry and without turning the earlier throttled calls into failures.
    const attempts = new Map<string, number>();
    const bump = (key: string) => {
      const n = (attempts.get(key) ?? 0) + 1;
      attempts.set(key, n);
      return n;
    };
    const run = await runE2E((req, res) => {
      let raw = "";
      req.on("data", (chunk) => { raw += chunk; });
      req.on("end", () => {
        const url = new URL(req.url ?? "/", "http://127.0.0.1");
        const body = raw ? JSON.parse(raw) : {};
        if (url.pathname === "/v1/auth/login") return bump("login") === 1 ? rate(res) : json(res, 200, { token: "stub-token" });
        if (url.pathname === "/v1/family/me") {
          return bump("me") === 1
            ? rate(res)
            : json(res, 200, {
                family: { id: "stub-family" },
                devices: [],
                children: [{ displayName: "Alex", devices: [{ id: "seed-device" }], ruleSet: { id: "rules" } }],
              });
        }
        if (url.pathname === "/v1/family/children") {
          const n = bump(`child:${body.displayName}`);
          if (n === 1) return rate(res);
          return body.displayName === "Sam"
            ? json(res, 201, { child: { id: "sam" }, consent: { method: "sms_plus" } })
            : json(res, 428, {});
        }
        if (url.pathname === "/v1/devices/register") return bump("register") === 1 ? rate(res) : json(res, 201, { device: { id: "device" } });
        if (url.pathname === "/v1/devices/pair") return rate(res);
        return json(res, 200, {});
      });
    });

    expect(run.code).toBe(2);
    expect(run.stdout).toContain("ABORT: rate limited by the API (6 x 429) - wait 60 s and re-run");
    expect(run.stdout).toContain("more than 5 x 429 in one run");
    expect(run.stdout).not.toMatch(/^FAIL /m);
    expect(run.stdout).toContain("PASS  child with inline consent -> 201");
  });

  it("a missing /me envelope is one recorded failure with the body and a printed summary, not a crash", async () => {
    const run = await runE2E((req, res) => {
      req.resume();
      const url = new URL(req.url ?? "/", "http://127.0.0.1");
      if (req.method === "POST" && url.pathname === "/v1/auth/login") return json(res, 200, { token: "stub-token" });
      if (req.method === "GET" && url.pathname === "/v1/family/me") return json(res, 200, { family: { id: "stub-family" } });
      return json(res, 200, {});
    });

    expect(run.code).toBe(1);
    expect(run.stdout.match(/^FAIL /gm) ?? []).toHaveLength(1);
    expect(run.stdout).toContain("FAIL  GET /me returns family envelope");
    expect(run.stdout).toContain('STOP  GET /family/me status 200 returned no family envelope — body: {"family":{"id":"stub-family"}}');
    expect(run.stdout).toMatch(/=== E2E: \d+ passed, 1 failed ===/);
    expect(run.stdout).not.toContain("TypeError");
    expect(run.stdout).not.toMatch(/^\s+at /m);
    expect(run.stderr).not.toContain("TypeError");
  });
});
