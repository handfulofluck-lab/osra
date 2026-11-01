import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { prisma } from "../db.js";
import {
  isGateExempt,
  parseClientHeader,
  parseClientPolicy,
  shouldRefuseWith426,
  updateVerdict,
  type ClientIdentity,
  type UpdateVerdict,
} from "../lib/clientHeader.js";

/**
 * ADR-0034 PR 1b: the header every client may send, the word every response carries, and the 426 gate.
 *
 * Three hooks, because each does exactly one thing:
 *  * `onRequest` — parse, decide, and refuse *before* the body is read (decision 5 rejects a body-parse the
 *    server might not understand);
 *  * `onSend` — `X-OSRA-Update` on **every** response, so an app that reads it can prompt and one that does
 *    not loses nothing;
 *  * `onResponse` — store the build, and only from a device-JWT request for that same device (A3).
 *
 * The policy is read once at boot. It ships empty, so the gate is off.
 */
interface WithClient {
  client?: ClientIdentity | null;
  clientVerdict?: UpdateVerdict;
}

export function registerClientHeader(app: FastifyInstance): void {
  const policy = parseClientPolicy(process.env.CLIENT_POLICY);

  app.addHook("onRequest", async (req: FastifyRequest, reply: FastifyReply) => {
    const client = parseClientHeader(req.headers["x-osra-client"]);
    const verdict = updateVerdict(client, policy);
    (req as unknown as WithClient).client = client;
    (req as unknown as WithClient).clientVerdict = verdict;
    // Only the parsed fields are ever logged — never the raw header (A3): it is client-controlled text.
    if (client) req.log.debug({ clientApp: client.app, clientBuild: client.build }, "client header");
    if (shouldRefuseWith426(client, verdict) && !isGateExempt(req.method, req.url)) {
      return reply.code(426).send({
        error: "update_required",
        app: client?.app,
        minBuild: client ? policy[client.app]?.min : undefined,
      });
    }
  });

  app.addHook("onSend", async (req, reply: FastifyReply, payload: unknown) => {
    reply.header("X-OSRA-Update", (req as unknown as WithClient).clientVerdict ?? "none");
    return payload;
  });

  app.addHook("onResponse", async (req: FastifyRequest) => {
    const client = (req as unknown as WithClient).client;
    if (!client) return; // legacy: nothing to store
    const user = req.user as { role?: string; deviceId?: string; sub?: string } | undefined;
    try {
      if (user?.role === "device" && user.deviceId) {
        // A3: the device's own build, and only when THIS device made the request. A parent's request
        // resolves the same device through `requireFamily` and must not overwrite this.
        await prisma.device.update({
          where: { id: user.deviceId },
          data: {
            clientApp: client.app,
            clientVersion: client.version,
            clientBuild: client.build,
            clientFlavour: client.flavour,
          },
        });
      } else if (user?.role === "parent" && user.sub) {
        // A parent's build belongs to that parent's install, on the push-token rows it owns.
        await prisma.parentPushToken.updateMany({
          where: { parentId: user.sub },
          data: { clientApp: client.app, clientBuild: client.build, clientFlavour: client.flavour },
        });
      }
    } catch (err) {
      // A bookkeeping write must never turn a served request into a 500. The 426 decision never reads it.
      req.log.warn({ err }, "client build update failed");
    }
  });
}
