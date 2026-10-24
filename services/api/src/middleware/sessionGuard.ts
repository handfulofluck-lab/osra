import type { FastifyReply, FastifyRequest } from "fastify";
import { deviceVerdict } from "../lib/deviceRevocation.js";
import { isParentSessionLive } from "../lib/sessions.js";

/**
 * The global auth gate that runs before every route (ADR-0032, ADR-0025, handoff item 4).
 *
 * It lives here rather than inline in `server.ts` because `server.ts` listens, opens Prisma and
 * starts schedulers on import — so no test can mount the production hook, and the device-revocation
 * rule was exercised only through the routes that re-implemented it (the `deviceRoutes` hook, the
 * location ping, the private ws-ticket route). A rule that only one of seven call sites implements
 * is a rule with six places to regress. `test/durable-revocation.test.ts` registers this function
 * itself, on an app that has routes but no listener.
 *
 * Unauthenticated requests fall through untouched: authentication is each route's own business
 * (some routes accept HMAC instead of a JWT), and this hook only *adds* refusals for a token that
 * verified. Two of them:
 *
 *  - a device whose row is gone (or whose tombstone is present) → `401 device_revoked`, decided by
 *    `deviceVerdict`: tombstone, then the 5-minute positive cache, then the `Device` row itself.
 *  - a parent whose session was revoked → `401 session_revoked`, decided by `isParentSessionLive`:
 *    the sessions version in Postgres (Redis is its cache) and the single-logout record.
 */
export async function sessionGuardHook(req: FastifyRequest, reply: FastifyReply): Promise<void> {
  try {
    await req.jwtVerify();
  } catch {
    return; // unauthenticated requests fall through to route-specific handlers
  }
  const user = req.user as
    | { role?: string; deviceId?: string; jti?: string; sub?: string; iat?: number; sv?: number }
    | undefined;
  if (user?.role === "device" && user.deviceId) {
    if ((await deviceVerdict(user.deviceId)) === "revoked") {
      await reply.code(401).send({ error: "device_revoked" });
      return;
    }
  }
  if (user?.role === "parent" && !(await isParentSessionLive(user))) {
    await reply.code(401).send({ error: "session_revoked" });
  }
}
