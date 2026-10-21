import type { FastifyInstance } from "fastify";

/**
 * Global error handler: sanitize database / Prisma internal errors to avoid leaking stack traces or
 * schema internals.
 *
 * #167: a route must never depend on this mapping for a status that is part of a contract. It turns
 * anything Prisma-shaped into `400 invalid_input`, and a client following #162 retries a 5xx, not a
 * 400 — so a post-consume failure replies 503 `reset_unavailable` explicitly instead of rethrowing.
 *
 * Exported so tests can install the production handler (`test/helpers.ts` `buildApp`). It lives here
 * rather than in `server.ts` because importing `server.ts` boots Redis, Prisma and the listener.
 */
export function registerErrorHandler(app: FastifyInstance): void {
  app.setErrorHandler((error, req, reply) => {
    const errStr = String(error?.message ?? "") + String(error?.stack ?? "");
    if (/prisma|invocation|P2020|P2002|P2003/i.test(errStr) || error.name === "PrismaClientKnownRequestError") {
      req.log.error(error);
      return reply.code(400).send({ error: "invalid_input" });
    }
    return reply.send(error);
  });
}
