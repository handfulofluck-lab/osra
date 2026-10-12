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
import { registerRealtime } from "./realtime/gateway.js";
import { healthRoutes } from "./routes/health.js";

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
  if (user?.jti) {
    const redis = getRedis();
    const revoked = await redis.get(`revoked:token:${user.jti}`).catch(() => null);
    if (revoked) {
      return reply.code(401).send({ error: "session_revoked" });
    }
  }
});

// Global error handler: sanitize database / Prisma internal errors to avoid leaking stack traces or schema internals
app.setErrorHandler((error, req, reply) => {
  const errStr = String(error?.message ?? "") + String(error?.stack ?? "");
  if (/prisma|invocation|P2020|P2002|P2003/i.test(errStr) || error.name === "PrismaClientKnownRequestError") {
    req.log.error(error);
    return reply.code(400).send({ error: "invalid_input" });
  }
  return reply.send(error);
});

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

registerRealtime(app);

const port = Number(process.env.PORT ?? 3000);
await app.listen({ port, host: "0.0.0.0" });
