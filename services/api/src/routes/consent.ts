import type { FastifyInstance } from "fastify";
import { prisma } from "../db.js";
import { requireParent, requireFamily } from "../middleware/requireFamily.js";
import { checkActiveConsent } from "../lib/consent.js";

export async function consentRoutes(app: FastifyInstance) {
  /** Revoke active parental consent for a child (Issue #43 route). */
  app.post(
    "/:childId/revoke",
    { preHandler: [requireParent, requireFamily({ param: "childId", model: "child" })] },
    async (req, reply) => {
      const { childId } = req.params as { childId: string };
      const now = new Date();
      const updated = await prisma.consentRecord.updateMany({
        where: { childId, revokedAt: null },
        data: { revokedAt: now },
      });
      return reply.code(200).send({
        revoked: true,
        childId,
        count: updated.count,
        revokedAt: now.toISOString(),
      });
    },
  );

  /** Check active consent status for a child. */
  app.get(
    "/:childId/status",
    { preHandler: [requireParent, requireFamily({ param: "childId", model: "child" })] },
    async (req) => {
      const { childId } = req.params as { childId: string };
      const reqChild = (req as unknown as { child?: { family?: { region?: string } } }).child;
      const status = await checkActiveConsent(childId, reqChild?.family?.region);
      return status;
    },
  );
}
