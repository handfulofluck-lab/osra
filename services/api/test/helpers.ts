import { vi } from "vitest";
import Fastify, { type FastifyInstance } from "fastify";
import fastifyJwt from "@fastify/jwt";

/** Proxy-based auto-mock: every property access returns a stable vi.fn(). */
const allMocks: Array<ReturnType<typeof vi.fn>> = [];

function autoMockModel(): Record<string, ReturnType<typeof vi.fn>> {
  const fns = new Map<string, ReturnType<typeof vi.fn>>();
  return new Proxy({}, {
    get(_target, prop: string) {
      if (!fns.has(prop)) {
        const fn = vi.fn();
        fns.set(prop, fn);
        allMocks.push(fn);
      }
      return fns.get(prop)!;
    },
  }) as Record<string, ReturnType<typeof vi.fn>>;
}

/** Build the mocked PrismaClient shape used by all route tests. */
function makePrismaMock() {
  const root: Record<string, unknown> = {
    $transaction: vi.fn(),
    $queryRaw: vi.fn(async () => [{}]),
    $executeRaw: vi.fn(async () => 0),
  };
  allMocks.push(root.$transaction as ReturnType<typeof vi.fn>);
  allMocks.push(root.$queryRaw as ReturnType<typeof vi.fn>);
  allMocks.push(root.$executeRaw as ReturnType<typeof vi.fn>);
  for (const model of [
    "family",
    "parent",
    "child",
    "device",
    "ruleSet",
    "geofence",
    "alert",
    "consentRecord",
    "locationPing",
    "activityEvent",
    "socialEvent",
    "digestPrefs",
    "digestSend",
    "familyInvite",
    "parentPushToken",
    "deviceCommand",
    "installRequest",
    "appUsageDaily",
    "webVisit",
  ]) {
    root[model] = autoMockModel();
  }
  const mock = root as unknown as {
    [k: string]: Record<string, ReturnType<typeof vi.fn>>;
  } & { $transaction: ReturnType<typeof vi.fn>; $queryRaw: ReturnType<typeof vi.fn>; $executeRaw: ReturnType<typeof vi.fn> };
  // Default: run callback transactions against the mock itself, resolve promise arrays.
  mock.$transaction.mockImplementation((arg: unknown) =>
    typeof arg === "function"
      ? (arg as (tx: unknown) => unknown)(mock)
      : Promise.all(arg as Promise<unknown>[]),
  );
  return mock;
}

/** Mocked PrismaClient; wire it in test files with vi.mock("../src/db.js", () => ({ prisma: prismaMock })). */
export const prismaMock = makePrismaMock();

/** In-memory stand-in for ioredis so no live Redis is needed. */
export class MockRedis {
  static instances: MockRedis[] = [];
  publish = vi.fn(async (_channel: string, _message: string) => 1);
  ping = vi.fn(async () => "PONG");
  psubscribe = vi.fn(async (_pattern: string) => undefined);
  on = vi.fn();
  get = vi.fn(async (_key: string) => null as string | null);
  set = vi.fn(async (..._args: unknown[]) => "OK");
  quit = vi.fn(async () => "OK");
  lpush = vi.fn(async (_key: string, _value: string) => 1);
  ltrim = vi.fn(async (..._args: unknown[]) => "OK");
  eval = vi.fn(async (..._args: unknown[]) => null as unknown);
  lrange = vi.fn(async (_key: string, _start: number, _stop: number) => [] as string[]);
  del = vi.fn(async (..._keys: string[]) => 0);
  sadd = vi.fn(async (_key: string, ..._members: string[]) => 1);
  srem = vi.fn(async (..._args: unknown[]) => 1);
  smembers = vi.fn(async (_key: string) => [] as string[]);
  incrby = vi.fn(async (_key: string, _increment: number) => 1);
  expire = vi.fn(async (_key: string, _seconds: number) => 1);
  constructor() {
    MockRedis.instances.push(this);
  }
}

/** Build a Fastify instance with jwt + the given route plugin mounted at prefix. */
export async function buildApp(
  routes: (app: FastifyInstance) => Promise<void>,
  prefix: string,
): Promise<FastifyInstance> {
  const app = Fastify({ logger: false });
  await app.register(fastifyJwt, { secret: "test-secret" });
  await app.register(routes, { prefix });
  await app.ready();
  return app;
}

/** Sign a parent JWT and return an authorization header. */
export function authHeader(app: FastifyInstance, familyId = "fam-1", sub = "parent-1") {
  const token = app.jwt.sign({ sub, familyId, role: "parent" });
  return { authorization: `Bearer ${token}` };
}

/** Sign a device JWT (spec §14.1 claims) and return an authorization header. */
export function deviceHeader(
  app: FastifyInstance,
  claims = { deviceId: "dev-1", childId: "child-1", familyId: "fam-1" },
) {
  const token = app.jwt.sign({ sub: claims.deviceId, ...claims, role: "device" });
  return { authorization: `Bearer ${token}` };
}

/** Reset all prisma mock call history and implementations. */
export function resetPrismaMock(): void {
  for (const fn of allMocks) fn.mockReset();
  prismaMock.$transaction.mockImplementation((arg: unknown) =>
    typeof arg === "function"
      ? (arg as (tx: unknown) => unknown)(prismaMock)
      : Promise.all(arg as Promise<unknown>[]),
  );
  // Default caller for tests: `authHeader()` signs as parent-1 of fam-1, an owner (ADR-0014 role gates).
  prismaMock.parent.findUnique.mockResolvedValue({
    id: "parent-1", familyId: "fam-1", email: "parent-1@example.com", displayName: "Parent One",
    role: "owner", permissions: [], passwordHash: "argon2$stub", mfaEnabled: false, mfaSecret: null,
  });
  // Default active consent for tests: non-revoked, non-expired, US jurisdiction.
  prismaMock.consentRecord.findFirst.mockResolvedValue({
    id: "consent-default",
    childId: "child-1",
    parentId: "parent-1",
    method: "sms_plus",
    jurisdiction: "US",
    grantedAt: new Date(),
    expiresAt: null,
    revokedAt: null,
    thirdPartySharing: false,
  });
  prismaMock.consentRecord.findMany.mockResolvedValue([{
    id: "consent-default",
    childId: "child-1",
    parentId: "parent-1",
    method: "sms_plus",
    jurisdiction: "US",
    grantedAt: new Date(),
    expiresAt: null,
    revokedAt: null,
    thirdPartySharing: false,
  }]);
  prismaMock.consentRecord.updateMany.mockResolvedValue({ count: 1 });
  // Child-scoped fan-outs (rules_updated, consent_revoked) iterate the child's devices.
  prismaMock.device.findMany.mockResolvedValue([]);
  // Phase 2a: alert push fan-out reads parents + tokens; default to none so route tests stay quiet.
  prismaMock.parent.findMany.mockResolvedValue([]);
  prismaMock.parentPushToken.findMany.mockResolvedValue([]);
  prismaMock.parentPushToken.deleteMany.mockResolvedValue({ count: 0 });
  // Phase 2b: commands are rows. Default create echoes a pending row so enqueue callers work.
  prismaMock.deviceCommand.findFirst.mockResolvedValue(null);
  prismaMock.deviceCommand.create.mockImplementation(async ({ data }: { data: Record<string, unknown> }) => ({
    id: `cmd-${Math.random().toString(36).slice(2, 8)}`,
    status: "pending",
    attempts: 0,
    createdAt: new Date(),
    deliveredAt: null,
    ackedAt: null,
    result: null,
    ...data,
  }));
  prismaMock.$queryRaw.mockResolvedValue([{}]);
  prismaMock.$executeRaw.mockResolvedValue(0);
  prismaMock.family.findUnique.mockResolvedValue({
    id: "fam-1",
    name: "Demo Family",
    region: "US",
  });
}
