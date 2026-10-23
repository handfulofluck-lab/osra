import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { describe, expect, it } from "vitest";

/**
 * Issue #112: a 429 burst is the API's own rate limiter. The probe must stop and say so, not record
 * the throttled calls as product failures. These tests point the real probe at a stub API that only
 * answers 429 and assert the abort contract. The exception is a 429 the API answers as a product
 * decision (`reset_limit_reached`, ADR-0031 decision 7): that one goes back to the check (#309).
 */
const PROBE = resolve(dirname(fileURLToPath(import.meta.url)), "../scripts/qa-probe.mjs");

type ProbeRun = { code: number | null; stdout: string; stderr: string };

async function runProbeAgainstAll429(retryAfterSeconds: string | null, body: object = { error: "rate_limited" }): Promise<ProbeRun> {
  const server = createServer((req, res) => {
    req.resume();
    res.writeHead(429, { "content-type": "application/json", ...(retryAfterSeconds === null ? {} : { "retry-after": retryAfterSeconds }) });
    res.end(JSON.stringify(body));
  });
  await new Promise<void>((ready) => server.listen(0, "127.0.0.1", ready));
  const { port } = server.address() as AddressInfo;

  const child = spawn(process.execPath, [PROBE], {
    env: {
      ...process.env,
      API_BASE: `http://127.0.0.1:${port}`,
      INTERNAL_HMAC_SECRET: "qa-probe-rate-limit-test-secret",
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
      fail(new Error(`probe did not exit within 10 s\nstdout:\n${stdout}\nstderr:\n${stderr}`));
    }, 10000);
    child.on("exit", (exitCode) => {
      clearTimeout(timeout);
      settle(exitCode);
    });
  });

  server.closeAllConnections();
  await new Promise<void>((closed) => server.close(() => closed()));
  return { code, stdout, stderr };
}

describe("qa-probe 429 handling (issue #112)", () => {
  it("aborts before any check when Retry-After is longer than the retry cap", async () => {
    const run = await runProbeAgainstAll429("60");
    expect(run.code).toBe(2);
    expect(run.stdout).toContain("ABORT: rate limited by the API (1 x 429) - wait 60 s and re-run");
    expect(run.stdout).toContain("Retry-After 60 s exceeds the 3 s retry cap");
    expect(run.stdout).not.toMatch(/^FAIL /m);
    expect(run.stdout).not.toContain("passed ·");
  });

  it("retries once on a short Retry-After, then aborts instead of failing the check", async () => {
    const run = await runProbeAgainstAll429("0");
    expect(run.code).toBe(2);
    expect(run.stdout).toContain("ABORT: rate limited by the API (2 x 429) - wait 60 s and re-run");
    expect(run.stdout).toContain("the single retry after 0 ms was also 429");
    expect(run.stdout).not.toMatch(/^FAIL /m);
  });

  it("treats @fastify/rate-limit's real body as throttling too", async () => {
    const run = await runProbeAgainstAll429("60", { statusCode: 429, error: "Too Many Requests", message: "Rate limit exceeded, retry in 1 minute" });
    expect(run.code).toBe(2);
    expect(run.stdout).toContain("ABORT: rate limited by the API (1 x 429) - wait 60 s and re-run");
    expect(run.stdout).not.toMatch(/^FAIL /m);
  });

  it("hands the API's own 429 answer (ADR-0031 decision 7) back to the check instead of aborting (#309)", async () => {
    const run = await runProbeAgainstAll429(null, { error: "reset_limit_reached" });
    expect(run.code).toBe(1);
    expect(run.stdout).toMatch(/^FAIL  setup: two families registered — 429\/429$/m);
    expect(run.stdout).not.toContain("ABORT");
  });
});
