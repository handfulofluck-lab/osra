import { generateKeyPairSync } from "node:crypto";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { prismaMock, resetPrismaMock } from "./helpers.js";
import { ApnsProvider } from "../src/lib/push/apns.js";
import { FcmProvider } from "../src/lib/push/fcm.js";
import {
  buildParentAlertMessage,
  notifyParentsOfAlert,
  setPushProviders,
} from "../src/lib/push/notify.js";

vi.mock("../src/db.js", () => ({ prisma: prismaMock }));

const deliveryOne = "f12ec7d3-135d-4665-993b-9ea1126a92f6";
const deliveryTwo = "b9950c80-94ab-4a25-8d54-a7de51984683";
const syntheticAlert = {
  id: "fixture-card",
  childId: "fixture-child",
  severity: "critical",
  category: "social_concern",
  title: "Sample private title",
  body: "Sample private body",
};

function delivery(id: string, sequence: number) {
  return { pushDeliveryId: id, pushDeliverySeq: sequence };
}

const genericKeys = {
  "title-loc-key": "PUSH_ALERT_TITLE",
  "loc-key": "PUSH_ALERT_BODY",
};

describe("#1139 grouped Parent push transport", () => {
  beforeEach(resetPrismaMock);
  afterEach(() => setPushProviders(null));

  it("uses distinct APNs collapse IDs for native deliveries with one stable thread", async () => {
    const wire: ReturnType<typeof FcmProvider.buildMessage>["message"][] = [];
    setPushProviders([{
      platform: "android",
      async send(recipient, message) {
        wire.push(FcmProvider.buildMessage(recipient, message).message);
        return { ok: true };
      },
    }]);
    prismaMock.parent.findMany.mockResolvedValue([{ id: "fixture-parent" }]);
    prismaMock.parentPushToken.findMany.mockResolvedValue([
      { id: "fixture-ios", parentId: "fixture-parent", platform: "ios", token: "synthetic-ios" },
      { id: "fixture-android", parentId: "fixture-parent", platform: "android", token: "synthetic-android" },
    ]);

    await notifyParentsOfAlert("fixture-family", { ...syntheticAlert, metadata: delivery(deliveryOne, 1) });
    await notifyParentsOfAlert("fixture-family", { ...syntheticAlert, metadata: delivery(deliveryTwo, 2) });

    const ios = wire.filter((row) => row.token === "synthetic-ios");
    expect(ios.map((row) => row.apns.headers)).toEqual([
      { "apns-priority": "10", "apns-collapse-id": deliveryOne },
      { "apns-priority": "10", "apns-collapse-id": deliveryTwo },
    ]);
    for (const row of ios) {
      expect(row.data).toEqual({ w: "1", g: "1" });
      expect(row.apns.payload.aps).toMatchObject({
        alert: genericKeys,
        "content-available": 1,
        "thread-id": "osra-wake",
      });
      expect(row).not.toHaveProperty("notification");
      const serialized = JSON.stringify(row);
      expect(serialized).not.toContain(syntheticAlert.id);
      expect(serialized).not.toContain(syntheticAlert.childId);
      expect(serialized).not.toContain(syntheticAlert.title);
      expect(serialized).not.toContain(syntheticAlert.body);
    }

    const android = wire.filter((row) => row.token === "synthetic-android");
    expect(android).toHaveLength(2);
    for (const row of android) {
      expect(row.data).toEqual({ w: "1" });
      expect(row.android).toEqual({ priority: "HIGH", collapse_key: "osra-wake" });
      expect(row.apns.headers).toEqual({ "apns-priority": "10" });
      expect(row).not.toHaveProperty("notification");
    }
  });

  it.each([
    { category: "social_concern", metadata: delivery(deliveryOne, 0) },
    { category: "gaming_chat", metadata: delivery("not-an-opaque-id", 1) },
    { category: "gaming_chat", metadata: delivery("0".repeat(65), 1) },
    { category: "gaming_chat", metadata: delivery(deliveryOne + "\n", 1) },
    { category: "tamper", metadata: delivery(deliveryOne, 1) },
  ])("keeps the legacy iOS wake when the grouped identity is ineligible", (alert) => {
    const message = buildParentAlertMessage("ios", alert);
    const { message: wire } = FcmProvider.buildMessage("synthetic-ios", message);
    expect(wire.data).toEqual({ w: "1" });
    expect(wire.apns.headers).toEqual({ "apns-priority": "10" });
    expect(wire.apns.payload.aps).toMatchObject({ alert: genericKeys, "thread-id": "osra-wake" });
  });

  it("uses the explicit APNs identity for direct sends without changing legacy collapse", async () => {
    const { privateKey } = generateKeyPairSync("ec", {
      namedCurve: "P-256",
      privateKeyEncoding: { type: "pkcs8", format: "pem" },
      publicKeyEncoding: { type: "spki", format: "pem" },
    });
    const requests: Array<{ collapse: string; body: unknown }> = [];
    const provider = new ApnsProvider({
      keyP8: privateKey,
      keyId: "fixture-signing",
      teamId: "fixture-team",
      bundleId: "com.example.fixture",
      host: "https://example.invalid",
    }, async (_host, _path, headers, body) => {
      requests.push({ collapse: headers["apns-collapse-id"]!, body: JSON.parse(body) });
      return { status: 200, body: "" };
    });

    const grouped = buildParentAlertMessage("ios", {
      category: "gaming_chat", metadata: delivery(deliveryOne, 1),
    });
    expect(await provider.send("synthetic-ios", grouped)).toEqual({ ok: true });
    expect(await provider.send("synthetic-ios", buildParentAlertMessage("ios"))).toEqual({ ok: true });

    expect(requests.map((request) => request.collapse)).toEqual([deliveryOne, "osra-wake"]);
    expect(requests[0]?.body).toMatchObject({
      w: "1",
      g: "1",
      aps: { alert: genericKeys, "thread-id": "osra-wake" },
    });
    expect(requests[1]?.body).not.toHaveProperty("g");
  });
});
