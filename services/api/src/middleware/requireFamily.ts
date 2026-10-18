import type { FastifyReply, FastifyRequest } from "fastify";
import { prisma } from "../db.js";

/** Models that can be family-scoped via requireFamily, with their familyId resolution. */
type FamilyScopedModel = "child" | "device" | "geofence" | "alert";

type FamilyScopedResource = {
  id?: string;
  childId?: string;
  familyId?: string;
  child?: { familyId: string } | null;
};

interface RequireFamilyOptions {
  /** Request param name holding the resource id (default "id"). */
  param?: string;
  /** Where the id comes from: route params (default), the JSON body, or the query string. */
  source?: "params" | "body" | "query";
  /** Prisma model to load and scope-check. */
  model: FamilyScopedModel;
  /**
   * `"own-child"` (default `"family"`) additionally confines a **device** token to the child its
   * Device row belongs to. Family isolation alone is not enough for a child-scoped read: every
   * device in a family shares the familyId, so `requireFamily` alone lets a device read a sibling
   * child (ADR-0002, ADR-0003). Parent tokens stay family-scoped.
   */
  deviceAccess?: "family" | "own-child";
}

const loaders: Record<
  FamilyScopedModel,
  (id: string) => Promise<FamilyScopedResource | null>
> = {
  child: async (id) => prisma.child.findUnique({ where: { id } }),
  device: async (id) => prisma.device.findUnique({ where: { id }, include: { child: true } }),
  geofence: async (id) => prisma.geofence.findUnique({ where: { id }, include: { child: true } }),
  alert: async (id) => prisma.alert.findUnique({ where: { id }, include: { child: true } }),
};

function resourceFamilyId(resource: FamilyScopedResource): string | undefined {
  return resource.familyId ?? resource.child?.familyId;
}

/** The child a resource belongs to; for a child row that is the row itself. */
function resourceChildId(resource: FamilyScopedResource, model: FamilyScopedModel, id: string): string | undefined {
  return model === "child" ? resource.id ?? id : resource.childId;
}

import { getRedis } from "../redis.js";
import { isParentSessionLive } from "../lib/sessions.js";

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
  // ADR-0014: per-token revocation (`jti`) and the parent's sessions-invalid-before instant.
  if (user && !(await isParentSessionLive(user))) {
    await reply.code(401).send({ error: "session_revoked" });
    return;
  }
}

/** The permission names an invite may grant; the owner implicitly holds all of them. */
export const PERMISSIONS = ["rules", "alerts", "location", "social", "devices"] as const;
export type Permission = (typeof PERMISSIONS)[number];

type ParentRoleRow = { id: string; role: string; permissions: string[] };

async function loadParentRole(req: FastifyRequest): Promise<ParentRoleRow | null> {
  const cached = (req as unknown as { parentRole?: ParentRoleRow | null }).parentRole;
  if (cached !== undefined) return cached;
  const user = req.user as { sub?: string } | undefined;
  const row = user?.sub ? await prisma.parent.findUnique({ where: { id: user.sub }, select: { id: true, role: true, permissions: true } }) : null;
  (req as unknown as { parentRole?: ParentRoleRow | null }).parentRole = row;
  return row;
}

/** preHandler (after requireParent): the caller's Parent row must carry the owner role. */
export async function requireOwner(req: FastifyRequest, reply: FastifyReply): Promise<void> {
  const parent = await loadParentRole(req);
  if (!parent) {
    await reply.code(404).send({ error: "parent_not_found" });
    return;
  }
  if (parent.role !== "owner") {
    await reply.code(403).send({ error: "owner_role_required" });
  }
}

/**
 * preHandler factory (after requireParent): owners pass; a co-parent or guardian passes only when
 * the invite that admitted them granted `permission` (ADR-0014 — `permissions` were stored and
 * never enforced). Reads are never gated by this; only the mutating routes name a permission.
 */
export function requirePermission(permission: Permission) {
  return async (req: FastifyRequest, reply: FastifyReply): Promise<void> => {
    const parent = await loadParentRole(req);
    if (!parent) {
      await reply.code(404).send({ error: "parent_not_found" });
      return;
    }
    if (parent.role === "owner" || parent.permissions.includes(permission)) return;
    await reply.code(403).send({ error: "permission_required", permission });
  };
}


/**
 * preHandler factory: loads a family-scoped resource, verifies it belongs to the
 * authenticated parent's family (403 otherwise, 401 without a JWT), and attaches
 * the resource to the request as `req.<model>`. With `deviceAccess: "own-child"` a device
 * token is also confined to the child its Device row belongs to (403 `cross_child_forbidden`).
 */
export function requireFamily({ param = "id", source = "params", model, deviceAccess = "family" }: RequireFamilyOptions) {
  return async (req: FastifyRequest, reply: FastifyReply): Promise<void> => {
    let user = req.user as { familyId?: string; role?: string; childId?: string } | undefined;
    if (!user?.familyId) {
      try {
        await req.jwtVerify();
        user = req.user as { familyId?: string; role?: string; childId?: string };
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
    if (deviceAccess === "own-child" && user.role === "device") {
      const ownChildId = user.childId;
      const targetChildId = resourceChildId(resource, model, id);
      if (!ownChildId || targetChildId !== ownChildId) {
        await reply.code(403).send({ error: "cross_child_forbidden" });
        return;
      }
    }
    (req as unknown as Record<string, unknown>)[model] = resource;
  };
}

/**
 * preHandler (after `requireFamily`): a device JWT may act only on its own device id.
 *
 * `requireFamily` proves the target belongs to the caller's *family*; it does not prove the caller
 * *is* that device. Family membership is not enough for a device write (audit finding 5: device A
 * could write sibling B's telemetry/activity), so agent-write routes compose this after the family
 * check. Parent tokens pass untouched — for them, family scoping is the whole rule.
 */
export function requireOwnDevice(param = "id") {
  return async (req: FastifyRequest, reply: FastifyReply): Promise<void> => {
    const user = req.user as { role?: string; deviceId?: string } | undefined;
    if (user?.role !== "device") return;
    const id = (req.params as Record<string, string>)[param];
    if (user.deviceId !== id) {
      await reply.code(403).send({ error: "forbidden" });
    }
  };
}
