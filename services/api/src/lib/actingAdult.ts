import type { FastifyRequest } from "fastify";
import { prisma } from "../db.js";

/**
 * C-04 (#1179): the child's "what changed" feed says which adult made a change. The name is stamped by the
 * server from the signed-in request, never taken from the client body and never guessed on the phone from
 * the family's adult list. When there is no parent session (system jobs, routines, device calls) or no
 * usable name, nothing is stamped and the phone shows its "your parents" fallback.
 */
export const BY_NAME_MAX = 60;

/** Device commands whose effect a child sees as a parent's decision (rule, bonus, grant, pause, lock). */
export const ATTRIBUTED_COMMANDS: ReadonlySet<string> = new Set([
  "rules_updated",
  "bonus_time",
  "wind_down",
  "pause_internet",
  "resume_internet",
  "pause",
  "resume",
  "lock",
  "unlock",
]);

export function cleanByName(raw: unknown): string | undefined {
  if (typeof raw !== "string") return undefined;
  // Control characters and runs of whitespace would break a single feed row; the length cap keeps a
  // pasted paragraph out of a command payload. Bidi embedding/override (U+202A-202E) and isolate
  // (U+2066-2069) controls are removed outright (#1237 review): they would reorder the feed text around
  // the name on the child phone.
  const name = raw
    .replace(/[\u202a-\u202e\u2066-\u2069]/g, "")
    .replace(/[\u0000-\u001f\u007f]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  if (!name) return undefined;
  return Array.from(name).slice(0, BY_NAME_MAX).join("");
}

/** The acting adult's display name, or undefined when the request is not a parent session. */
export async function actingAdultName(req: FastifyRequest): Promise<string | undefined> {
  const user = req.user as { sub?: string; role?: string } | undefined;
  if (!user?.sub || user.role !== "parent") return undefined;
  const parent = await prisma.parent.findUnique({ where: { id: user.sub }, select: { displayName: true } });
  return cleanByName(parent?.displayName);
}

/** Copy of `payload` with any client-sent `byName` removed and the server's own stamped when known. */
export function withByName(payload: Record<string, unknown>, byName: string | undefined): Record<string, unknown> {
  const { byName: _clientValue, ...rest } = payload;
  return byName ? { ...rest, byName } : rest;
}
