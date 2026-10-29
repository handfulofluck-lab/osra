import { vi } from "vitest";
import Fastify, { type FastifyInstance } from "fastify";
import fastifyJwt from "@fastify/jwt";
import { registerErrorHandler } from "../src/lib/errorHandler.js";

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

/** Every model the mocked client has; a test that must prove "no write" walks this list. */
export const MOCKED_MODELS = [
  "family",
  "parent",
  "revokedToken",
  "parentMfaRecoveryCode",
  "mfaResetRequest",
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
  "digestRecipient",
  "digestSend",
  "familyInvite",
  "parentPushToken",
  "deviceCommand",
  "deviceApp",
  "pairingDecision",
  "installRequest",
  "appUsageDaily",
  "webVisit",
] as const;

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
  for (const model of MOCKED_MODELS) {
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
  /**
   * The shared test server runs Redis 5.0.14, which has no GETDEL: calling it is an error there, and
   * this mock says so instead of pretending. Production code must use the Lua GET+DEL consume
   * (devices.ts:217, auth.ts /reset/confirm) and tests mock `eval` for the same job.
   */
  getdel = vi.fn(async (_key: string): Promise<string | null> => {
    throw new Error("ERR unknown command 'getdel'");
  });
  set = vi.fn(async (..._args: unknown[]): Promise<string | null> => "OK");
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
  /** Hash storage for the idle-request counters (roadmap 5.8) and anything else that counts in a hash. */
  readonly hashes = new Map<string, Record<string, string>>();
  hincrby = vi.fn(async (key: string, field: string, increment: number) => {
    const hash = this.hashes.get(key) ?? {};
    hash[field] = String(Number(hash[field] ?? 0) + increment);
    this.hashes.set(key, hash);
    return Number(hash[field]);
  });
  hgetall = vi.fn(async (key: string) => this.hashes.get(key) ?? {});
  /**
   * A MULTI that behaves like the one `recordDeviceRequest` uses: `multi().hincrby(...).expire(...).exec()`
   * queues both commands and applies them on `exec`, in order, through the same `hincrby`/`expire` mocks. A
   * fake inside the test would assert the fake; this one means a broken chain (a missing `exec`, a dropped
   * `expire`) actually fails the test.
   */
  multi = vi.fn(() => {
    const queued: Array<() => Promise<unknown>> = [];
    const chain = {
      hincrby: (key: string, field: string, increment: number) => {
        queued.push(() => this.hincrby(key, field, increment));
        return chain;
      },
      expire: (key: string, seconds: number) => {
        queued.push(() => this.expire(key, seconds));
        return chain;
      },
      exec: async () => Promise.all(queued.map((run) => run())),
    };
    return chain;
  });
  /** Seed a hash as if a previous process had written it. */
  seedHash(key: string, values: Record<string, string>): void {
    this.hashes.set(key, { ...values });
  }
  constructor() {
    MockRedis.instances.push(this);
  }
}

/**
 * Build a Fastify instance with jwt + the given route plugin mounted at prefix, and the production
 * error handler installed, so a route's status is what the server would send (a rethrow through the
 * handler is a 400 for anything Prisma-shaped, which is exactly what #167 had to stop doing).
 *
 * `opts.sessionGuard` mounts the production global auth gate (`middleware/sessionGuard.ts`, the
 * preHandler `server.ts` installs) for an app whose routes are registered after it. Without it a
 * test exercises a route without the gate in front of it, which is how the device-revocation rule
 * came to be tested only through the one router that re-implemented it (ADR-0032). The import is
 * dynamic so the files that never ask for the guard still do not load `src/db.ts`.
 */
export async function buildApp(
  routes: (app: FastifyInstance) => Promise<void>,
  prefix: string,
  opts: { sessionGuard?: boolean } = {},
): Promise<FastifyInstance> {
  const app = Fastify({ logger: false });
  await app.register(fastifyJwt, { secret: "test-secret" });
  registerErrorHandler(app);
  if (opts.sessionGuard) {
    const { sessionGuardHook } = await import("../src/middleware/sessionGuard.js");
    app.addHook("preHandler", sessionGuardHook);
  }
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
  // ADR-0032: the durable revocation records. A parent with no row and no logout has nothing to
  // restore, which is what almost every route test means; the tests that care set these explicitly.
  prismaMock.revokedToken.findMany.mockResolvedValue([]);
  prismaMock.revokedToken.deleteMany.mockResolvedValue({ count: 0 });
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

/** The counting half of @fastify/rate-limit's Redis store script (INCR, then PEXPIRE a new key). */
export class FakeRateLimitRedis {
  readonly counts = new Map<string, number>();
  down = false;
  defineCommand(): void {
    /* the store defines `rateLimit` only when it is missing; this class supplies it */
  }
  rateLimit(
    key: string,
    timeWindow: number,
    _max: number,
    _ban: number,
    _continueExceeding: boolean,
    cb: (err: Error | null, res: [number, number, boolean] | null) => void,
  ): void {
    if (this.down) {
      // What ioredis raises once `maxRetriesPerRequest` (2, src/redis.ts) is spent on a dead connection.
      const err = new Error("Reached the max retries per request limit (which is 2).");
      err.name = "MaxRetriesPerRequestError";
      return cb(err, null);
    }
    const current = (this.counts.get(key) ?? 0) + 1;
    this.counts.set(key, current);
    cb(null, [current, timeWindow, false]);
  }
}
