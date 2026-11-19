import type { FastifyInstance } from "fastify";
import { consentCopyFor } from "../lib/consentCopy.js";

/**
 * `GET /v1/consent-copy?locale=` (ADR-0043 D3, #846 part A).
 *
 * Public on purpose: the sign-up screen asks before anyone has a session, and the copy is the text the
 * person is being asked to accept — putting it behind a login would be the wrong way round. The route
 * reads no database and writes nothing.
 */
export async function consentCopyRoutes(app: FastifyInstance) {
  app.get("/consent-copy", async (req, reply) => {
    const raw = (req.query as { locale?: unknown } | undefined)?.locale;
    // A `textVersion` bump changes the body, so a cached copy must not outlive the change.
    reply.header("cache-control", "no-store");
    return consentCopyFor(typeof raw === "string" ? raw : undefined);
  });
}
