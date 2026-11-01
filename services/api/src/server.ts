import Fastify from "fastify";
import cors from "@fastify/cors";
import jwt from "@fastify/jwt";
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
import { accountRoutes } from "./routes/account.js";
import { startDigestScheduler } from "./jobs/digestScheduler.js";
import { registerRealtime } from "./realtime/gateway.js";
import { startUsageRollupScheduler } from "./jobs/usageRollup.js";
import { startDeviceSilenceScheduler } from "./jobs/deviceSilence.js";
import { startMfaResetExpiryScheduler } from "./jobs/mfaResetExpiry.js";
import { startRevokedTokenPruneScheduler } from "./jobs/revokedTokenPrune.js";
import { sessionGuardHook } from "./middleware/sessionGuard.js";
import { healthRoutes } from "./routes/health.js";
import { registerErrorHandler } from "./lib/errorHandler.js";
import { registerIdleBudgetHook } from "./lib/idleBudget.js";
import { registerClientHeader } from "./middleware/clientHeader.js";
import { AUTH_RATE_LIMIT, registerRateLimits, trustProxyFromEnv } from "./lib/rateLimits.js";
import { getRedis } from "./redis.js";
import { LOGGER_SERIALIZERS } from "./lib/logRedaction.js";

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

// Behind the ALB every request arrives from the balancer, so the client address comes from
// X-Forwarded-For, trusted for TRUST_PROXY hops (1 in infra/terraform/env/ecs.tf). Unset trusts nothing.
// #442 PR 3: the request log keeps the URL but not the credential some links carry in it (`?token=`,
// `?ticket=`), so a mailed deletion or digest link never lands in log aggregation (`lib/logRedaction.ts`).
const app = Fastify({
  logger: { level: process.env.LOG_LEVEL ?? "info", serializers: LOGGER_SERIALIZERS },
  trustProxy: trustProxyFromEnv(),
});

// Review API-1: CORS allowlist via env (comma-separated); unset = reflect (dev/test only, NOTE).
const corsOrigins = process.env.CORS_ORIGIN?.split(",").map((o) => o.trim()).filter(Boolean);
await app.register(cors, {
  origin: corsOrigins && corsOrigins.length > 0 ? corsOrigins : true,
  credentials: true,
});
await app.register(jwt, { secret: JWT_SECRET ?? "dev-insecure-jwt-secret" });
await registerRateLimits(app, getRedis());
await app.register(websocket);

// Global auth gate for every route: a revoked device token and a revoked parent session answer 401
// here, before any route sees the request. The rule itself lives in `middleware/sessionGuard.ts`
// (`sessionGuardHook`) so a test can mount the production hook — `server.ts` listens on import and
// cannot be imported by a test. ADR-0032: the `Device` row and `Parent.sessionVersion` are the
// records; the Redis keys are caches they rebuild on a miss.
app.addHook("preHandler", sessionGuardHook);

// ADR-0034 1b: X-OSRA-Client is parsed before the body is read (a 426 must not depend on a request
// shape the server might not understand), every response carries X-OSRA-Update, and a device's own
// request records its build. CLIENT_POLICY ships empty, so nothing is refused.
registerClientHeader(app);

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
  config: { rateLimit: AUTH_RATE_LIMIT },
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
// #442 PR 3: the public account-deletion pages (Play's web link). No session; the two POSTs carry
// AUTH_RATE_LIMIT themselves.
await app.register(accountRoutes, { prefix: "/v1/account" });

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
// ADR-0032: single-logout records are pruned once the token they revoked could no longer be shown.
startRevokedTokenPruneScheduler();
