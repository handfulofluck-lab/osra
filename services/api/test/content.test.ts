import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createHmac } from "node:crypto";
import { contentRoutes } from "../src/routes/content.js";
import { MockRedis, authHeader, buildApp, deviceHeader, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

const SECRET = "test-internal-secret";
const CHILD = { id: "child-1", familyId: "fam-1", birthYear: 2012 };

const sign = (raw: string) => createHmac("sha256", SECRET).update(raw).digest("hex");

function postSearchEvent(app: Awaited<ReturnType<typeof buildApp>>, body: Record<string, unknown>, sig?: string) {
  const raw = JSON.stringify(body);
  return app.inject({
    method: "POST",
    url: "/v1/content/search-event",
    headers: {
      "content-type": "application/json",
      "x-familyshield-signature": sig ?? sign(raw),
    },
    payload: raw,
  });
}

function postYouTubeWatch(app: Awaited<ReturnType<typeof buildApp>>, body: Record<string, unknown>, sig?: string) {
  const raw = JSON.stringify(body);
  return app.inject({
    method: "POST",
    url: "/v1/content/youtube-watch",
    headers: {
      "content-type": "application/json",
      "x-familyshield-signature": sig ?? sign(raw),
    },
    payload: raw,
  });
}

describe("Track 1: Content Safety & Search Monitoring routes", () => {
  let app: Awaited<ReturnType<typeof buildApp>>;
  const originalFetch = globalThis.fetch;

  beforeEach(async () => {
    resetPrismaMock();
    process.env.INTERNAL_HMAC_SECRET = SECRET;
    process.env.VAULT_KEY = Buffer.alloc(32, 7).toString("base64");
    prismaMock.child.findUnique.mockResolvedValue(CHILD);

    app = await buildApp(async (instance) => {
      await instance.register(contentRoutes, { prefix: "/v1/content" });
    });
  });

  afterEach(async () => {
    globalThis.fetch = originalFetch;
    await app.close();
  });

  it("rejects search-event when HMAC signature is invalid or missing (401)", async () => {
    const resNoSig = await app.inject({
      method: "POST",
      url: "/v1/content/search-event",
      headers: { "content-type": "application/json" },
      payload: JSON.stringify({ childId: CHILD.id, engine: "google", query: "minecraft mods" }),
    });
    expect(resNoSig.statusCode).toBe(401);

    const resBadSig = await postSearchEvent(app, { childId: CHILD.id, engine: "google", query: "minecraft mods" }, "bad-sig");
    expect(resBadSig.statusCode).toBe(401);
  });

  it("accepts safe search query and returns flagged: false (200)", async () => {
    const res = await postSearchEvent(app, {
      childId: CHILD.id,
      engine: "google",
      query: "how to bake sourdough bread",
    });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.flagged).toBe(false);
    expect(body.severity).toBe("info");
    expect(prismaMock.alert.create).not.toHaveBeenCalled();
  });

  it("flags self-harm search query via local fallback and persists encrypted vault event (201)", async () => {
    prismaMock.alert.create.mockResolvedValue({ id: "alert-1", childId: CHILD.id });
    prismaMock.socialEvent.create.mockResolvedValue({ id: "event-1" });

    const res = await postSearchEvent(app, {
      childId: CHILD.id,
      engine: "youtube",
      query: "how to commit suicide painlessly",
    });

    expect(res.statusCode).toBe(201);
    const body = res.json();
    expect(body.flagged).toBe(true);
    expect(body.severity).toBe("critical");
    expect(body.concernTypes).toContain("self_harm");

    // Snippet encrypted and written to vault
    expect(prismaMock.socialEvent.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({
          childId: CHILD.id,
          app: "search:youtube",
          severity: "critical",
          concernTypes: expect.arrayContaining(["self_harm"]),
        }),
      }),
    );

    // Alert created
    expect(prismaMock.alert.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({
          childId: CHILD.id,
          category: "self_harm",
          severity: "critical",
        }),
      }),
    );
  });

  it("analyzes YouTube watch event and flags dangerous title (201)", async () => {
    prismaMock.alert.create.mockResolvedValue({ id: "alert-yt", childId: CHILD.id });
    prismaMock.socialEvent.create.mockResolvedValue({ id: "event-yt" });

    const res = await postYouTubeWatch(app, {
      childId: CHILD.id,
      videoId: "abc12345678",
      title: "how to commit suicide compilation",
      channel: "bad_channel",
    });

    expect(res.statusCode).toBe(201);
    const body = res.json();
    expect(body.flagged).toBe(true);
    expect(body.severity).toBe("critical");
    expect(prismaMock.alert.create).toHaveBeenCalled();
  });

  it("parent endpoint GET /v1/content/searches requires parent role and returns decrypted history", async () => {
    const parentHeader = authHeader(app, CHILD.familyId);
    const deviceHead = deviceHeader(app, { deviceId: "dev-1", childId: CHILD.id, familyId: CHILD.familyId });

    // Device JWT rejected (403)
    const resDev = await app.inject({
      method: "GET",
      url: `/v1/content/searches?childId=${CHILD.id}`,
      headers: deviceHead,
    });
    expect(resDev.statusCode).toBe(403);

    // Parent accepted and decrypted
    prismaMock.socialEvent.findMany.mockResolvedValue([
      {
        id: "ev-1",
        childId: CHILD.id,
        app: "search:google",
        contact: "google",
        severity: "critical",
        previewCipher: "test-cipher",
        concernTypes: ["self_harm"],
        createdAt: new Date("2026-10-12T12:00:00Z"),
      },
    ]);

    const resParent = await app.inject({
      method: "GET",
      url: `/v1/content/searches?childId=${CHILD.id}`,
      headers: parentHeader,
    });
    expect(resParent.statusCode).toBe(200);
    const body = resParent.json();
    expect(body.items).toHaveLength(1);
    expect(body.items[0].engine).toBe("google");
    expect(body.items[0].severity).toBe("critical");
  });

  it("issue #29: rejects search-event when signing device belongs to another child (400)", async () => {
    const devSecret = "device-secret-1";
    prismaMock.device.findUnique.mockResolvedValue({
      id: "dev-a",
      childId: "child-a",
      internalSecret: devSecret,
      revokedAt: null,
    });

    const body = {
      deviceId: "dev-a",
      childId: "child-b", // mismatched target child
      engine: "google",
      query: "how to kill myself",
    };
    const raw = JSON.stringify(body);
    const sig = createHmac("sha256", devSecret).update(raw).digest("hex");

    const res = await app.inject({
      method: "POST",
      url: "/v1/content/search-event",
      headers: {
        "content-type": "application/json",
        "x-familyshield-signature": sig,
      },
      payload: raw,
    });

    expect(res.statusCode).toBe(400);
    expect(res.json()).toEqual({ error: "cross_child_content_forbidden" });
  });

  it("issue #29: rejects youtube-watch when signing device belongs to another child (400)", async () => {
    const devSecret = "device-secret-1";
    prismaMock.device.findUnique.mockResolvedValue({
      id: "dev-a",
      childId: "child-a",
      internalSecret: devSecret,
      revokedAt: null,
    });

    const body = {
      deviceId: "dev-a",
      childId: "child-b", // mismatched target child
      videoId: "xyz987",
      title: "bad video",
      channel: "bad channel",
    };
    const raw = JSON.stringify(body);
    const sig = createHmac("sha256", devSecret).update(raw).digest("hex");

    const res = await app.inject({
      method: "POST",
      url: "/v1/content/youtube-watch",
      headers: {
        "content-type": "application/json",
        "x-familyshield-signature": sig,
      },
      payload: raw,
    });

    expect(res.statusCode).toBe(400);
    expect(res.json()).toEqual({ error: "cross_child_content_forbidden" });
  });

  it("issue #30: flags 'how can I kill myself tonight' via expanded self-harm regex (201)", async () => {
    prismaMock.alert.create.mockResolvedValue({ id: "alert-sh", childId: CHILD.id });
    prismaMock.socialEvent.create.mockResolvedValue({ id: "event-sh" });

    const res = await postSearchEvent(app, {
      childId: CHILD.id,
      engine: "google",
      query: "how can I kill myself tonight",
    });

    expect(res.statusCode).toBe(201);
    const body = res.json();
    expect(body.flagged).toBe(true);
    expect(body.severity).toBe("critical");
    expect(body.concernTypes).toContain("self_harm");
  });
});

