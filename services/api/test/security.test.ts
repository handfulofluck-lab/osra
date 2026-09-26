import { describe, expect, it } from "vitest";
import Fastify from "fastify";
import cors from "@fastify/cors";
import rateLimit from "@fastify/rate-limit";

// Plugin-level checks mirroring the server.ts wiring:
//   cors       { origin: true, credentials: true }
//   rateLimit  { max: 200, timeWindow: "1 minute" }
// These build bare Fastify instances (no routes under test) so no prisma/redis mocks
// are needed. Token-level security checks (refresh rotation, purpose-scoped reset
// tokens, expired TOTP) live in auth.test.ts beside the routes they exercise.

describe("server hardening (server.ts plugin parity)", () => {
  it("rate-limits to 429 after 200 requests within the one-minute window", async () => {
    const app = Fastify({ logger: false });
    await app.register(rateLimit, { max: 200, timeWindow: "1 minute" });
    app.get("/probe", async () => ({ ok: true }));
    await app.ready();

    for (let i = 0; i < 200; i++) {
      const res = await app.inject({ method: "GET", url: "/probe" });
      expect(res.statusCode).toBe(200);
    }
    const limited = await app.inject({ method: "GET", url: "/probe" });
    expect(limited.statusCode).toBe(429);
    expect(limited.json().error).toBe("Too Many Requests");
    await app.close();
  }, 30000);

  it("CORS preflight reflects the request origin and allows credentials", async () => {
    const app = Fastify({ logger: false });
    await app.register(cors, { origin: true, credentials: true });
    app.get("/probe", async () => ({ ok: true }));
    await app.ready();

    const res = await app.inject({
      method: "OPTIONS",
      url: "/probe",
      headers: {
        origin: "https://parent-app.example.com",
        "access-control-request-method": "GET",
      },
    });
    expect(res.statusCode).toBe(204);
    expect(res.headers["access-control-allow-origin"]).toBe("https://parent-app.example.com");
    expect(res.headers["access-control-allow-credentials"]).toBe("true");

    // Simple (non-preflight) requests also carry the reflected origin.
    const simple = await app.inject({
      method: "GET",
      url: "/probe",
      headers: { origin: "https://parent-app.example.com" },
    });
    expect(simple.headers["access-control-allow-origin"]).toBe("https://parent-app.example.com");
    await app.close();
  });
});
