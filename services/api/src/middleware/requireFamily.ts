import type { FastifyReply, FastifyRequest } from "fastify";
import { prisma } from "../db.js";

/** Models that can be family-scoped via requireFamily, with their familyId resolution. */
type FamilyScopedModel = "child" | "device" | "geofence" | "alert";

interface RequireFamilyOptions {
  /** Request param name holding the resource id (default "id"). */
  param?: string;
  /** Where the id comes from: route params (default), the JSON body, or the query string. */
  source?: "params" | "body" | "query";
  /** Prisma model to load and scope-check. */
  model: FamilyScopedModel;
}

const loaders: Record<
  FamilyScopedModel,
  (id: string) => Promise<{ familyId?: string; child?: { familyId: string } | null } | null>
> = {
  child: async (id) => prisma.child.findUnique({ where: { id } }),
  device: async (id) => prisma.device.findUnique({ where: { id }, include: { child: true } }),
  geofence: async (id) => prisma.geofence.findUnique({ where: { id }, include: { child: true } }),
  alert: async (id) => prisma.alert.findUnique({ where: { id }, include: { child: true } }),
};

function resourceFamilyId(resource: { familyId?: string; child?: { familyId: string } | null }): string | undefined {
  return resource.familyId ?? resource.child?.familyId;
}

import { getRedis } from "../redis.js";

export function sanitizeDevice<T extends Record<string, any>>(device: T): Omit<T, "internalSecret" | "pushToken"> {
  if (!device) return device;
  const { internalSecret: _s, pushToken: _t, ...rest } = device;
  return rest as any;
}

/** Fastify preHandler that only requires a valid parent JWT (no resource scoping). */
export async function requireAuth(req: FastifyRequest, reply: FastifyReply): Promise<void> {
  try {
    await req.jwtVerify();
  } catch {
    await reply.code(401).send({ error: "unauthorized" });
    return;
  }
  const user = req.user as { sub?: string; role?: string; iat?: number; jti?: string } | undefined;
  if (user?.jti) {
    const redis = getRedis();
    const revokedToken = await redis.get(`revoked:token:${user.jti}`).catch(() => null);
    if (revokedToken) {
      await reply.code(401).send({ error: "session_revoked" });
      return;
    }
  }
}

/** preHandler for parent-only mutations: verified JWT plus role "parent" (403 otherwise). */
// NOTE: requireAuth/requireFamily stay role-agnostic so device JWTs keep working on agent
// reads (rules GET, device GETs, telemetry); parent-only routes compose requireParent first.
export async function requireParent(req: FastifyRequest, reply: FastifyReply): Promise<void> {
  try {
    await req.jwtVerify();
  } catch {
    await reply.code(401).send({ error: "unauthorized" });
    return;
  }
  const user = req.user as { sub?: string; role?: string; iat?: number; jti?: string } | undefined;
  if (user?.role !== "parent") {
    await reply.code(403).send({ error: "parent_role_required" });
    return;
  }
  if (user?.jti) {
    const redis = getRedis();
    const revokedToken = await redis.get(`revoked:token:${user.jti}`).catch(() => null);
    if (revokedToken) {
      await reply.code(401).send({ error: "session_revoked" });
      return;
    }
  }
}


/**
 * preHandler factory: loads a family-scoped resource, verifies it belongs to the
 * authenticated parent's family (403 otherwise, 401 without a JWT), and attaches
 * the resource to the request as `req.<model>`.
 */
export function requireFamily({ param = "id", source = "params", model }: RequireFamilyOptions) {
  return async (req: FastifyRequest, reply: FastifyReply): Promise<void> => {
    let user = req.user as { familyId?: string } | undefined;
    if (!user?.familyId) {
      try {
        await req.jwtVerify();
        user = req.user as { familyId?: string };
      } catch {
        await reply.code(401).send({ error: "unauthorized" });
        return;
      }
    }
    const id =
      source === "params"
        ? (req.params as Record<string, string>)[param]
        : source === "query"
          ? (req.query as Record<string, unknown>)?.[param] as string
          : (req.body as Record<string, unknown>)?.[param] as string;
    if (!id) {
      await reply.code(400).send({ error: `missing_${param}` });
      return;
    }
    const resource = await loaders[model](id);
    if (!resource) {
      await reply.code(404).send({ error: "not_found" });
      return;
    }
    if (resourceFamilyId(resource) !== user.familyId) {
      await reply.code(403).send({ error: "forbidden" });
      return;
    }
    (req as unknown as Record<string, unknown>)[model] = resource;
  };
}
