import type { FastifyInstance } from "fastify";
import { prisma } from "../db.js";
import { getRedis } from "../redis.js";

/** Liveness + readiness probes. */
export async function healthRoutes(app: FastifyInstance): Promise<void> {
  // Liveness: process is up. Intentionally skips dependency checks so a database
  // outage doesn't take the probe down with it — use /health/deep for the truth.
  app.get("/health", async () => ({ ok: true, version: "0.1.0" }));

  // Deep health: verifies the dependencies /health skips (Postgres, Redis).
  // When apps error while /health looks fine, a "db":"down" here means the API is
  // up but every data route will fail with 500 until the database comes back.
  app.get("/health/deep", async (_req, reply) => {
    const checks: Record<string, "up" | "down"> = {};
    try {
      await prisma.$queryRaw`SELECT 1`;
      checks.db = "up";
    } catch {
      checks.db = "down";
    }
    try {
      await getRedis().ping();
      checks.redis = "up";
    } catch {
      checks.redis = "down";
    }
    const ok = checks.db === "up" && checks.redis === "up";
    return reply.code(ok ? 200 : 503).send({ ok, version: "0.1.0", ...checks });
  });
}
