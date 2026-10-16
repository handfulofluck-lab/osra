import type { FastifyReply, FastifyRequest } from "fastify";
import { prisma } from "../db.js";
import { checkActiveConsent } from "../lib/consent.js";

interface RequireConsentOptions {
  /** Request param name holding the childId (default "childId"). */
  param?: string;
  /** Where the id comes from: route params (default), the JSON body, or the query string. */
  source?: "params" | "body" | "query";
}

/**
 * Fastify preHandler that enforces the active parental consent gate (HTTP 428).
 * Checks that the target child has a non-revoked, non-expired ConsentRecord matching
 * the family jurisdiction (spec §12.5, ADR-0002).
 */
export function requireConsent({ param = "childId", source = "params" }: RequireConsentOptions = {}) {
  return async (req: FastifyRequest, reply: FastifyReply): Promise<void> => {
    const childId =
      source === "params"
        ? (req.params as Record<string, string>)[param]
        : source === "query"
          ? ((req.query as Record<string, unknown>)?.[param] as string)
          : ((req.body as Record<string, unknown>)?.[param] as string);

    if (!childId) {
      await reply.code(400).send({ error: `missing_${param}` });
      return;
    }

    let familyRegion: string | undefined;
    const reqChild = (req as unknown as { child?: { familyId?: string; family?: { region?: string } } }).child;
    if (reqChild?.family?.region) {
      familyRegion = reqChild.family.region;
    } else {
      const familyId = reqChild?.familyId ?? (req.user as { familyId?: string } | undefined)?.familyId;
      if (familyId) {
        const family = await prisma.family.findUnique({ where: { id: familyId } });
        familyRegion = family?.region;
      } else {
        const child = await prisma.child.findUnique({
          where: { id: childId },
          include: { family: true },
        });
        familyRegion = child?.family?.region;
      }
    }

    const result = await checkActiveConsent(childId, familyRegion);
    if (!result.active) {
      await reply.code(428).send({
        error: result.reason ?? "parental_consent_required",
        ...(result.jurisdiction ? { jurisdiction: result.jurisdiction } : {}),
      });
      return;
    }
  };
}
