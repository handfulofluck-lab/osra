import { beforeEach, describe, expect, it, vi } from "vitest";
import { locationRoutes } from "../src/routes/location.js";
import { publishFamilyEvent } from "../src/realtime/gateway.js";
import { authHeader, buildApp, deviceHeader, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});
vi.mock("../src/realtime/gateway.js", () => ({ publishFamilyEvent: vi.fn(async () => undefined) }));

const CHILD_ID = "child-1";
const DEVICE_ID = "device-1";

/** Plan 2.7 F4: a location ping comes from the child's device (a parent JWT is 403), so the ping
 * tests sign a device JWT for the fixture device. */
function pingHeader(app: Parameters<typeof deviceHeader>[0]) {
  return deviceHeader(app, { deviceId: DEVICE_ID, childId: CHILD_ID, familyId: "fam-1" });
}

const PING_TS = "2026-10-21T09:15:00.000Z";
const PING = {
  childId: CHILD_ID,
  deviceId: DEVICE_ID,
  lat: 40.7128,
  lng: -74.006,
  accuracyM: 5,
  timestamp: PING_TS,
};

describe("POST /v1/location/ping — realtime fan-out (issue #253)", () => {
  beforeEach(() => {
    resetPrismaMock();
    vi.mocked(publishFamilyEvent).mockClear();
    prismaMock.child.findUnique.mockResolvedValue({ id: CHILD_ID, familyId: "fam-1" });
    prismaMock.device.findUnique.mockResolvedValue({ id: DEVICE_ID, childId: CHILD_ID });
    prismaMock.device.update.mockResolvedValue({});
    prismaMock.geofence.findMany.mockResolvedValue([]);
    prismaMock.locationPing.create.mockImplementation(async ({ data }: { data: Record<string, unknown> }) => ({
      id: "ping-1",
      ...data,
    }));
  });

  it("publishes exactly one `location` event per upload, with the child id and no coordinates", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");

    const res = await app.inject({
      method: "POST",
      url: "/v1/location/ping",
      headers: pingHeader(app),
      payload: PING,
    });

    expect(res.statusCode).toBe(201);
    expect(publishFamilyEvent).toHaveBeenCalledTimes(1);
    expect(publishFamilyEvent).toHaveBeenCalledWith("fam-1", {
      type: "location",
      payload: { childId: CHILD_ID, ts: new Date(PING_TS) },
      ts: expect.any(String),
    });

    const [, event] = vi.mocked(publishFamilyEvent).mock.calls[0] as [string, Record<string, unknown>];
    const payload = event.payload as Record<string, unknown>;
    // #242: coordinates live only in LocationPing. The client refetches through the authorised
    // GET /v1/location/:childId/latest, so the bus must never carry a position.
    expect(payload).not.toHaveProperty("lat");
    expect(payload).not.toHaveProperty("lng");
    expect(JSON.stringify(event)).not.toContain("40.7128");
    await app.close();
  });

  it("publishes once for a batch, not once per ping", async () => {
    const app = await buildApp(locationRoutes, "/v1/location");

    const res = await app.inject({
      method: "POST",
      url: "/v1/location/ping",
      headers: pingHeader(app),
      payload: { childId: CHILD_ID, deviceId: DEVICE_ID, pings: [PING, PING, PING] },
    });

    expect(res.statusCode).toBe(201);
    expect(prismaMock.locationPing.create).toHaveBeenCalledTimes(3);
    expect(publishFamilyEvent).toHaveBeenCalledTimes(1);
    await app.close();
  });

  it("publishes nothing when the consent gate refuses the upload (428)", async () => {
    prismaMock.consentRecord.findFirst.mockResolvedValue(null);
    const app = await buildApp(locationRoutes, "/v1/location");

    const res = await app.inject({
      method: "POST",
      url: "/v1/location/ping",
      headers: pingHeader(app),
      payload: PING,
    });

    expect(res.statusCode).toBe(428);
    expect(prismaMock.locationPing.create).not.toHaveBeenCalled();
    expect(publishFamilyEvent).not.toHaveBeenCalled();
    await app.close();
  });

  it("returns the stored pings even when the publish fails (best-effort)", async () => {
    vi.mocked(publishFamilyEvent).mockRejectedValueOnce(new Error("redis down"));
    const app = await buildApp(locationRoutes, "/v1/location");

    const res = await app.inject({
      method: "POST",
      url: "/v1/location/ping",
      headers: pingHeader(app),
      payload: PING,
    });

    expect(res.statusCode).toBe(201);
    expect(res.json().count).toBe(1);
    await app.close();
  });
});
