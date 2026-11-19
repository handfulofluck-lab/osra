import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { prisma } from "../db.js";

/**
 * Issue #790 / R2: a device stops being pending on its first ACCEPTED request, in one place.
 *
 * `POST /v1/devices/pair/claims/:claimId/poll` creates a Device row the moment the parent's Allow is
 * taken, and that row is the phone's whole identity: `middleware/requireFamily.ts` resolves every
 * device route from it, the command queue hangs off it, and the parent app draws it. But the phone has
 * not proven anything at that point — it holds a token and a per-device HMAC secret it has never used.
 * A client that pairs and then fails its first proof (a wrong key, a planted fault, a bug in a new
 * agent) owns a row it cannot ask the server to remove, so the server decides instead: the row is
 * created pending (`Device.pairedAt` null) and becomes the family's device only when a request from it
 * is accepted.
 *
 * **Why this point.** The alternatives, and why each is wrong:
 *  - `sessionGuardHook`'s preHandler, right after `jwtVerify()` — this is the tempting one, and it is
 *    too early. At that point the request has proven the *token* verifies and nothing else. The route's
 *    own gates run after it: `requireFamily` answers 403 `cross_child_forbidden`/`forbidden` for a
 *    sibling's device, `requireOwnDevice` 403 for another device's id, `requireDeviceRole` 403 for a
 *    parent token, `requireConsent`/`assertProcessingAllowed` 428, `TelemetrySchema` 400. A device that
 *    is refused there — the wrong-device case the issue calls out by name — would have cleared its own
 *    pending flag on a request that did nothing, which is the bug in a new costume.
 *  - Each successful handler — that is one call site per route, and the rule would be missing from the
 *    next device route somebody adds. The chain it belongs to is global, so the hook is too.
 *  - `authenticateInternalRequest`'s device branch (the HMAC-signed `/internal` writes) — an *accepted*
 *    signature there is a real proof, but the route may still refuse the body afterwards (consent 428, a
 *    child outside the family), so it is not yet "acted on", and a refusal there must not count. The
 *    agent's command poll (its heartbeat, ≤ 600 s, `lib/pollCadence.ts`) is the request that clears a
 *    pending row in practice; see the note at the bottom of this comment.
 *
 * So the trigger is `onResponse` with the status the route actually sent: any 2xx/3xx answer is a
 * request the API acted on (a poll drained, telemetry stored, a rule read served), and every refusal is
 * 4xx/5xx, whatever produced it. Two properties come free from `onResponse` and both matter here:
 *  - the decision is the one the client already received, so this write cannot change a response — a
 *    bookkeeping failure must never turn a served request into a 500 (same reasoning as
 *    `middleware/clientHeader.ts` and `lib/idleBudget.ts`);
 *  - it is the last gate in the chain, so no route can forget to call it.
 *
 * **Idempotent by predicate, not by reading.** `where: { id, pairedAt: null }` makes the write a
 * zero-row no-op from the second accepted request on — `pairedAt` is never rewritten, so it stays the
 * first-proof time the parent's "added" line and the 30-minute sweep both read. A read-then-write pair
 * would cost two round trips and still race the sweep.
 *
 * **Not a gate.** Nothing reads `pairedAt` to authorise anything: a pending device may use every device
 * route it could use before (that is how it stops being pending). The column only decides whether
 * parents see the row (`routes/devices.ts`, `routes/family.ts`), whether it counts as a family device
 * (`routes/auth.ts`) and when `jobs/pendingDevices.ts` removes it.
 */

/** 2xx or 3xx: the route answered instead of refusing. Exported so the rule is readable in a test. */
export function requestAccepted(statusCode: number): boolean {
  return statusCode >= 200 && statusCode < 400;
}

/**
 * Record that this device proved itself. Best-effort by contract: the caller has already answered the
 * request, so a database failure here is logged and the next accepted request tries again.
 */
export async function markDevicePaired(deviceId: string, now: Date = new Date(), log?: FastifyRequest["log"]): Promise<void> {
  try {
    await prisma.device.updateMany({ where: { id: deviceId, pairedAt: null }, data: { pairedAt: now } });
  } catch (err) {
    log?.warn({ err, deviceId }, "pairedAt write failed");
  }
}

/**
 * The hook `server.ts` registers. Device-JWT callers only: a parent's or an unauthenticated request
 * decodes no `req.user.role === "device"`, and a pending device is exactly one whose device JWT is the
 * only credential it has.
 *
 * A device request that carries no JWT at all — an HMAC-signed `POST /v1/alerts/internal`, refused or
 * accepted — never reaches here, because nothing decodes a device from it (`lib/internalAuth.ts`
 * authenticates the body, not the request). Those calls are unaffected either way: a refused one
 * leaves the row pending, which is what the issue asks for, and an accepted one is followed by the
 * agent's next command poll, which clears pending within one poll interval.
 */
export function registerPairedAtHook(app: FastifyInstance): void {
  app.addHook("onResponse", async (req: FastifyRequest, reply: FastifyReply) => {
    const user = req.user as { role?: string; deviceId?: string; sub?: string } | undefined;
    if (user?.role !== "device") return;
    const deviceId = user.deviceId ?? user.sub;
    if (!deviceId || !requestAccepted(reply.statusCode)) return;
    await markDevicePaired(deviceId, new Date(), req.log);
  });
}
