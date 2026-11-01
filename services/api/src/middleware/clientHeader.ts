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

/** The columns each table stores, and where the value comes from on the parsed client. */
const DEVICE_BUILD_FIELDS = [
  ["clientApp", (c: ClientIdentity) => c.app],
  ["clientVersion", (c: ClientIdentity) => c.version],
  ["clientBuild", (c: ClientIdentity) => c.build],
  ["clientFlavour", (c: ClientIdentity) => c.flavour],
] as const;

const PUSH_TOKEN_BUILD_FIELDS = [
  ["clientApp", (c: ClientIdentity) => c.app],
  ["clientBuild", (c: ClientIdentity) => c.build],
  ["clientFlavour", (c: ClientIdentity) => c.flavour],
] as const;

/**
 * "Any of these columns differs" as a where clause, null-safe on purpose.
 *
 * `{ column: { not: value } }` does not match a NULL column in SQL, so a device reporting its build for the
 * first time would never satisfy it and the write would silently not happen. Each field therefore reads
 * `column IS NULL OR column != value` (#528 review advisory 1).
 */
function changes(
  fields: ReadonlyArray<readonly [string, (c: ClientIdentity) => string | number]>,
  client: ClientIdentity,
): Array<Record<string, unknown>> {
  return fields.map(([column, value]) => ({
    OR: [{ [column]: null }, { [column]: { not: value(client) } }],
  }));
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
        //
        // Written only when it changes (#528 review advisory 1): the agent polls every 15 minutes, and a
        // row write per poll is the load roadmap 5.8 is trying to cut. Each field is compared
        // null-safely — Prisma's `{ not: x }` EXCLUDES nulls, so `{ clientBuild: { not: 7 } }` would skip
        // a device that has never reported, and the write would silently never happen.
        await prisma.device.updateMany({
          where: { id: user.deviceId, OR: changes(DEVICE_BUILD_FIELDS, client) },
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
          where: { parentId: user.sub, OR: changes(PUSH_TOKEN_BUILD_FIELDS, client) },
          data: { clientApp: client.app, clientBuild: client.build, clientFlavour: client.flavour },
        });
      }
    } catch (err) {
      // A bookkeeping write must never turn a served request into a 500. The 426 decision never reads it.
      req.log.warn({ err }, "client build update failed");
    }
  });
}
