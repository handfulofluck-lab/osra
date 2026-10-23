import Fastify from "fastify";
import cors from "@fastify/cors";
import jwt from "@fastify/jwt";
import rateLimit from "@fastify/rate-limit";
import websocket from "@fastify/websocket";
import { authRoutes } from "./routes/auth.js";
import { blocklistRoutes } from "./routes/blocklists.js";
import { familyRoutes } from "./routes/family.js";
import { deviceRoutes } from "./routes/devices.js";
import { rulesRoutes } from "./routes/rules.js";
import { controlsRoutes } from "./routes/controls.js";
import { alertsRoutes } from "./routes/alerts.js";
import { locationRoutes } from "./routes/location.js";
import { reportsRoutes } from "./routes/reports.js";
import { digestRoutes } from "./routes/digests.js";
import { socialRoutes } from "./routes/social.js";
import { contentRoutes } from "./routes/content.js";
import { inviteRoutes } from "./routes/invites.js";
import { insightsRoutes } from "./routes/insights.js";
import { meRoutes } from "./routes/me.js";
import { startDigestScheduler } from "./jobs/digestScheduler.js";
import { registerRealtime } from "./realtime/gateway.js";
import { startUsageRollupScheduler } from "./jobs/usageRollup.js";
import { startDeviceSilenceScheduler } from "./jobs/deviceSilence.js";
import { startMfaResetExpiryScheduler } from "./jobs/mfaResetExpiry.js";
import { isParentSessionLive } from "./lib/sessions.js";
import { healthRoutes } from "./routes/health.js";
import { registerErrorHandler } from "./lib/errorHandler.js";
import { registerIdleBudgetHook } from "./lib/idleBudget.js";

// Review 3.7: fail fast on missing/known-dev secrets instead of booting insecurely.
const JWT_SECRET = process.env.JWT_SECRET;
if (!JWT_SECRET || JWT_SECRET === "dev-secret-change-me" || JWT_SECRET === "e2e-dev-secret") {
  if (process.env.NODE_ENV === "production") {
    throw new Error("JWT_SECRET must be set to a non-dev value in production");
  }
  console.warn("[security] JWT_SECRET is unset or a known dev value — set a strong secret before exposing this server");
}
if (!process.env.VAULT_KEY && process.env.NODE_ENV === "production") {
  throw new Error("VAULT_KEY must be set in production (snippet vault encryption key)");
}

import { getRedis } from "./redis.js";
import { prisma } from "./db.js";
import { assertPrismaClientInSync } from "./lib/schemaSync.js";

// Issue #47: fail fast on boot if database schema and generated Prisma client drifted.
try {
  await assertPrismaClientInSync(prisma);
} catch (err: any) {
  if (err.message?.includes("[SchemaDrift]")) {
    console.error(`\n======================================================\n${err.message}\n======================================================\n`);
    process.exit(1);
  }
  console.warn(`[schema-sync] Database check skipped due to connectivity issue: ${err.message}`);
}

const app = Fastify({ logger: { level: process.env.LOG_LEVEL ?? "info" } });

// Review API-1: CORS allowlist via env (comma-separated); unset = reflect (dev/test only, NOTE).
const corsOrigins = process.env.CORS_ORIGIN?.split(",").map((o) => o.trim()).filter(Boolean);
await app.register(cors, {
  origin: corsOrigins && corsOrigins.length > 0 ? corsOrigins : true,
  credentials: true,
});
await app.register(jwt, { secret: JWT_SECRET ?? "dev-insecure-jwt-secret" });
await app.register(rateLimit, { max: 200, timeWindow: "1 minute" });
await app.register(websocket);

// Global device revocation hook: any authenticated device whose token was revoked gets 401 across all routes.
app.addHook("preHandler", async (req, reply) => {
  try {
    await req.jwtVerify();
  } catch {
    return; // unauthenticated requests fall through to route-specific handlers
  }
  const user = req.user as { role?: string; deviceId?: string; jti?: string } | undefined;
  if (user?.role === "device" && user.deviceId) {
    const redis = getRedis();
    const revoked = await redis.get(`revoked:device:${user.deviceId}`).catch(() => null);
    if (revoked) {
      return reply.code(401).send({ error: "device_revoked" });
    }
  }
  if (user?.role === "parent" && !(await isParentSessionLive(user as { sub?: string; jti?: string; iat?: number; sv?: number }))) {
    return reply.code(401).send({ error: "session_revoked" });
  }
});

/**
 * Idle-request budget (roadmap 5.8): count authenticated device requests, per device per minute per route,
 * so the acceptance's "idle child phone ≤ 3 requests per 10 min" becomes a number instead of an impression.
 * Counts only — no bodies, no query strings, no addresses — and onResponse, so a handler's own failures and
 * timings cannot change what is counted. It never throws, and it records nothing unless
 * `IDLE_BUDGET_COUNTING=1`: the instrument is on in tests and staging, off in production (#346 review).
 */
registerIdleBudgetHook(app);

// Global error handler: sanitize database / Prisma internal errors to avoid leaking stack traces or
// schema internals. Shared with the test harness so a route's status is the one production sends.
registerErrorHandler(app);

await app.register(healthRoutes);


// Auth routes get a stricter bucket (review API-11): brute-force protection on register/login/reset.
await app.register(authRoutes, {
  prefix: "/v1/auth",
  config: { rateLimit: { max: 20, timeWindow: "1 minute" } },
});
await app.register(blocklistRoutes, { prefix: "/v1/blocklists" });
await app.register(familyRoutes, { prefix: "/v1/family" });
await app.register(inviteRoutes, { prefix: "/v1/family" });
await app.register(deviceRoutes, { prefix: "/v1/devices" });
await app.register(rulesRoutes, { prefix: "/v1/rules" });
await app.register(controlsRoutes, { prefix: "/v1/controls" });
await app.register(alertsRoutes, { prefix: "/v1/alerts" });
await app.register(locationRoutes, { prefix: "/v1/location" });
await app.register(reportsRoutes, { prefix: "/v1/reports" });
await app.register(digestRoutes, { prefix: "/v1/digests" });
await app.register(socialRoutes, { prefix: "/v1/social" });
await app.register(contentRoutes, { prefix: "/v1/content" });
await app.register(insightsRoutes, { prefix: "/v1/insights" });
await app.register(meRoutes, { prefix: "/v1/me" });

registerRealtime(app);

const port = Number(process.env.PORT ?? 3000);
await app.listen({ port, host: "0.0.0.0" });
// Phase 2a: in-process digest scheduler (hourly tick; JOBS_ENABLED=0 disables, e.g. behind an external cron).
startDigestScheduler();
// Phase 2c: nightly usage rollup + retention (ADR-0013); same JOBS_ENABLED switch.
startUsageRollupScheduler();
// Plan 1.9 finding: a wiped or removed agent cannot alert; the server notices the silence instead.
startDeviceSilenceScheduler();
// ADR-0031: the 24-hour witness deadline and the 12-month retention of MFA reset rows.
startMfaResetExpiryScheduler();
