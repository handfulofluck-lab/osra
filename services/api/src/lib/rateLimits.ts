import type { FastifyInstance } from "fastify";
import rateLimit from "@fastify/rate-limit";
import type { Redis } from "ioredis";

/**
 * Rate limits for the whole API, in one place so `server.ts`, the routes and the tests agree (plan 2.7).
 *
 * Every bucket keys on `req.ip`, so behind a load balancer the client address must come from
 * `X-Forwarded-For` (`trustProxyFromEnv`), and every API task must count in the same place (Redis),
 * or two tasks each allow the full limit.
 *
 * Failure mode when Redis is unreachable:
 * - the global bucket fails **open** (`skipOnError: true`): a short Redis outage must not turn every
 *   request into an error. It opens nothing a parent could use, because since #349 an authenticated
 *   parent request needs Redis for the revocation checks anyway;
 * - the auth bucket and the pairing-claim bucket fail **closed** (`skipOnError: false`): they are the
 *   brakes on password and pairing-code guessing, so without a count they refuse.
 */

/** Every route that names no bucket of its own. */
export const GLOBAL_RATE_LIMIT = { max: 200, timeWindow: "1 minute", skipOnError: true } as const;

/** register, login, MFA and MFA reset (`routes/auth.ts`): the password- and code-guessing brake. */
export const AUTH_RATE_LIMIT = { max: 20, timeWindow: "1 minute", skipOnError: false } as const;

/** `POST /v1/devices/pair/claim`: unauthenticated, and the only place a pairing code is tried. */
export const PAIR_CLAIM_RATE_LIMIT = { max: 10, timeWindow: "1 minute", skipOnError: false } as const;

/** Redis key prefix for the limiter's counters; each key expires with its window. */
export const RATE_LIMIT_KEY_PREFIX = "rl:";

/**
 * Fastify's `trustProxy` from `TRUST_PROXY`: the number of proxy hops in front of the API.
 *
 * Only a hop count is accepted. Fastify then takes the client address from the entry that many hops
 * from the right of `X-Forwarded-For`, which the nearest proxy wrote itself, so a caller cannot pick
 * its own bucket by sending the header. `true` would trust the leftmost entry, which the caller
 * controls, and is refused. Unset or empty trusts nothing (the API is reached directly, as in local
 * development and the test suites).
 */
export function trustProxyFromEnv(value: string | undefined = process.env.TRUST_PROXY): number | false {
  const raw = value?.trim();
  if (!raw) return false;
  if (!/^\d+$/.test(raw)) {
    throw new Error(`TRUST_PROXY must be a hop count (for example 1 behind the ALB), got "${raw}"`);
  }
  return Number(raw);
}

/** Register the limiter with its counters in Redis; the routes add their own buckets via `config`. */
export async function registerRateLimits(app: FastifyInstance, redis: Redis): Promise<void> {
  await app.register(rateLimit, { ...GLOBAL_RATE_LIMIT, redis, nameSpace: RATE_LIMIT_KEY_PREFIX });
}
