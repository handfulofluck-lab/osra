import { beforeEach, describe, expect, it, vi } from "vitest";
import { generateKeyPairSync } from "node:crypto";
import { prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", () => ({ prisma: prismaMock }));
vi.mock("../src/realtime/gateway.js", () => ({ publishFamilyEvent: vi.fn(async () => undefined) }));

import { FcmProvider, buildAssertion } from "../src/lib/push/fcm.js";
import { ApnsProvider, buildProviderToken } from "../src/lib/push/apns.js";
import {
  buildAlertMessage,
  buildDeviceWakeMessage,
  notifyDeviceWake,
  notifyParentsOfAlert,
  setDeviceWakeSender,
  setPushProviders,
  shouldPush,
} from "../src/lib/push/notify.js";
import { enqueueDeviceCommand } from "../src/lib/deviceCommands.js";
import { raiseAlert } from "../src/lib/alerts.js";
import { publishFamilyEvent } from "../src/realtime/gateway.js";
import type { PushMessage, PushProvider, PushResult } from "../src/lib/push/types.js";

const rsa = generateKeyPairSync("rsa", { modulusLength: 2048, privateKeyEncoding: { type: "pkcs8", format: "pem" }, publicKeyEncoding: { type: "spki", format: "pem" } });
const ec = generateKeyPairSync("ec", { namedCurve: "P-256", privateKeyEncoding: { type: "pkcs8", format: "pem" }, publicKeyEncoding: { type: "spki", format: "pem" } });

const sa = { project_id: "osra-test", client_email: "push@osra-test.iam.gserviceaccount.com", private_key: rsa.privateKey };

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

const alert = { id: "alert-1", childId: "child-1", severity: "critical", category: "sos", title: "SOS", body: "Alex pressed SOS" };

class FakeProvider implements PushProvider {
  readonly platform = "android" as const;
  sent: Array<{ token: string; message: PushMessage }> = [];
  constructor(private readonly outcome: (token: string) => PushResult = () => ({ ok: true })) {}
  async send(token: string, message: PushMessage): Promise<PushResult> {
    this.sent.push({ token, message });
    return this.outcome(token);
  }
}

describe("FCM provider", () => {
  it("signs an RS256 assertion whose claims target the messaging scope", () => {
    const jwt = buildAssertion(sa, 1_700_000_000);
    const [h, c, s] = jwt.split(".");
    expect(JSON.parse(Buffer.from(h, "base64url").toString())).toEqual({ alg: "RS256", typ: "JWT" });
    const claims = JSON.parse(Buffer.from(c, "base64url").toString());
    expect(claims).toMatchObject({ iss: sa.client_email, scope: "https://www.googleapis.com/auth/firebase.messaging", iat: 1_700_000_000, exp: 1_700_003_600 });
    expect(s.length).toBeGreaterThan(300);
  });

  it("exchanges the assertion once, then sends a v1 message with high priority for critical alerts", async () => {
    const fetchMock = vi.fn(async (url: string) => {
      if (url.endsWith("/token")) return jsonResponse(200, { access_token: "ya29.test", expires_in: 3600 });
      return jsonResponse(200, { name: "projects/osra-test/messages/1" });
    });
    const provider = new FcmProvider(sa, fetchMock as never);
    const message = buildAlertMessage(alert, "Alex");
    expect(await provider.send("tok-1", message)).toEqual({ ok: true });
    expect(await provider.send("tok-2", message)).toEqual({ ok: true });
    const tokenCalls = fetchMock.mock.calls.filter(([u]) => (u as string).endsWith("/token"));
    expect(tokenCalls).toHaveLength(1);
    const sendCall = fetchMock.mock.calls.find(([u]) => (u as string).includes("messages:send"))!;
    expect(sendCall[0]).toBe("https://fcm.googleapis.com/v1/projects/osra-test/messages:send");
    const body = JSON.parse((sendCall[1] as RequestInit).body as string);
    expect(body.message.token).toBe("tok-1");
    expect(body.message.notification).toEqual({ title: "Alex: SOS", body: "Alex pressed SOS" });
    expect(body.message.data).toEqual({ type: "alert", alertId: "alert-1", childId: "child-1", category: "sos", severity: "critical" });
    expect(body.message.android.priority).toBe("HIGH");
    expect(body.message.android.collapse_key).toBe("child-child-1");
    expect((sendCall[1] as RequestInit).headers).toMatchObject({ authorization: "Bearer ya29.test" });
  });

  it("reports UNREGISTERED tokens as invalid and transient errors as retained", async () => {
    const outcomes = [
      jsonResponse(404, { error: { status: "NOT_FOUND", details: [{ errorCode: "UNREGISTERED" }] } }),
      jsonResponse(503, { error: { status: "UNAVAILABLE" } }),
    ];
    const fetchMock = vi.fn(async (url: string) => (url.endsWith("/token") ? jsonResponse(200, { access_token: "t", expires_in: 3600 }) : outcomes.shift()!));
    const provider = new FcmProvider(sa, fetchMock as never);
    const m = buildAlertMessage(alert);
    expect(await provider.send("dead", m)).toMatchObject({ ok: false, invalidToken: true });
    expect(await provider.send("flaky", m)).toMatchObject({ ok: false, invalidToken: false });
  });
});

describe("APNs provider", () => {
  it("builds an ES256 provider token with the key id and team", () => {
    const jwt = buildProviderToken({ keyP8: ec.privateKey, keyId: "ABC123", teamId: "TEAM42" }, 1_700_000_000);
    const [h, c, s] = jwt.split(".");
    expect(JSON.parse(Buffer.from(h, "base64url").toString())).toEqual({ alg: "ES256", kid: "ABC123" });
    expect(JSON.parse(Buffer.from(c, "base64url").toString())).toEqual({ iss: "TEAM42", iat: 1_700_000_000 });
    expect(Buffer.from(s, "base64url")).toHaveLength(64); // raw r||s, not DER
  });

  it("sends to /3/device/<token> with topic and collapse id, and prunes on 410", async () => {
    const calls: Array<{ path: string; headers: Record<string, string>; body: string }> = [];
    let status = 200;
    const transport = async (_host: string, path: string, headers: Record<string, string>, body: string) => {
      calls.push({ path, headers, body });
      return { status, body: status === 200 ? "" : JSON.stringify({ reason: "Unregistered" }) };
    };
    const provider = new ApnsProvider({ keyP8: ec.privateKey, keyId: "K", teamId: "T", bundleId: "com.osra.parent", host: "https://api.sandbox.push.apple.com" }, transport);
    expect(await provider.send("abc", buildAlertMessage(alert))).toEqual({ ok: true });
    expect(calls[0].path).toBe("/3/device/abc");
    expect(calls[0].headers["apns-topic"]).toBe("com.osra.parent");
    expect(calls[0].headers["apns-priority"]).toBe("10");
    expect(calls[0].headers["apns-collapse-id"]).toBe("child-child-1");
    expect(JSON.parse(calls[0].body).aps.alert).toEqual({ title: "SOS", body: "Alex pressed SOS" });
    status = 410;
    expect(await provider.send("gone", buildAlertMessage(alert))).toMatchObject({ ok: false, invalidToken: true });
  });

  // 5.5 PR D: the child device wake is a background push to the child agent's topic. Mutants: push-type
  // "alert" or priority 10 for the wake, or the parent topic, each fail here.
  it("sends the device wake as a background push at priority 5 to the child agent's topic", async () => {
    const calls: Array<{ headers: Record<string, string>; body: string }> = [];
    const transport = async (_host: string, _path: string, headers: Record<string, string>, body: string) => {
      calls.push({ headers, body });
      return { status: 200, body: "" };
    };
    const cfg = { keyP8: ec.privateKey, keyId: "K", teamId: "T", bundleId: "com.osra.parent", host: "https://api.sandbox.push.apple.com" };
    const provider = new ApnsProvider({ ...cfg, deviceBundleId: "dev.familyshield.agent" }, transport);
    expect(await provider.send("child-token", buildDeviceWakeMessage())).toEqual({ ok: true });
    expect(calls[0].headers["apns-push-type"]).toBe("background");
    expect(calls[0].headers["apns-priority"]).toBe("5");
    expect(calls[0].headers["apns-topic"]).toBe("dev.familyshield.agent");
    expect(JSON.parse(calls[0].body).aps).toEqual({ "content-available": 1 });
    // The alert path is unchanged: parent topic, alert type.
    await provider.send("parent-token", buildAlertMessage(alert));
    expect(calls[1].headers["apns-push-type"]).toBe("alert");
    expect(calls[1].headers["apns-topic"]).toBe("com.osra.parent");
  });

  it("does not send a device wake without APNS_DEVICE_BUNDLE_ID, and does not call the token dead", async () => {
    const calls: unknown[] = [];
    const transport = async () => {
      calls.push(1);
      return { status: 400, body: JSON.stringify({ reason: "DeviceTokenNotForTopic" }) };
    };
    const provider = new ApnsProvider({ keyP8: ec.privateKey, keyId: "K", teamId: "T", bundleId: "com.osra.parent", host: "https://api.sandbox.push.apple.com" }, transport);
    // Sent under the parent topic, Apple would answer DeviceTokenNotForTopic and the token would be cleared.
    expect(await provider.send("child-token", buildDeviceWakeMessage())).toMatchObject({ ok: false, invalidToken: false });
    expect(calls).toHaveLength(0);
  });
});

describe("notification policy", () => {
  beforeEach(() => {
    resetPrismaMock();
    setPushProviders(null);
    delete process.env.PUSH_MIN_SEVERITY;
  });

  it("treats a missing alert as nothing to push (no TypeError in the fire-and-forget path)", async () => {
    expect(shouldPush(undefined, "info")).toBe(false);
    const err = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const out = await notifyParentsOfAlert("fam-1", undefined as unknown as typeof alert);
    expect(out.skipped).toBe("severity");
    expect(err).not.toHaveBeenCalled();
    err.mockRestore();
  });

  it("applies the severity floor but always pushes SOS and tamper", () => {
    expect(shouldPush({ severity: "info", category: "geofence" }, "warning")).toBe(false);
    expect(shouldPush({ severity: "warning", category: "ai_concern" }, "warning")).toBe(true);
    expect(shouldPush({ severity: "info", category: "sos" }, "critical")).toBe(true);
    expect(shouldPush({ severity: "info", category: "tamper" }, "critical")).toBe(true);
  });

  it("fans out to every parent token in the family and prunes dead ones", async () => {
    const provider = new FakeProvider((token) => (token === "dead" ? { ok: false, invalidToken: true, reason: "UNREGISTERED" } : { ok: true }));
    setPushProviders([provider]);
    prismaMock.digestPrefs.findUnique.mockResolvedValue(null);
    prismaMock.parent.findMany.mockResolvedValue([{ id: "parent-1" }, { id: "parent-2" }]);
    prismaMock.parentPushToken.findMany.mockResolvedValue([
      { id: "t1", parentId: "parent-1", token: "live-1", platform: "android" },
      { id: "t2", parentId: "parent-2", token: "dead", platform: "web" },
    ]);
    prismaMock.parentPushToken.deleteMany.mockResolvedValue({ count: 1 });

    const outcome = await notifyParentsOfAlert("fam-1", alert, "Alex");
    expect(outcome).toEqual({ recipients: 2, delivered: 1, pruned: 1, skipped: null });
    expect(provider.sent.map((s) => s.token).sort()).toEqual(["dead", "live-1"]);
    expect(prismaMock.parentPushToken.findMany).toHaveBeenCalledWith({ where: { parentId: { in: ["parent-1", "parent-2"] } } });
    expect(prismaMock.parentPushToken.deleteMany).toHaveBeenCalledWith({ where: { id: { in: ["t2"] } } });
  });

  it("respects the family's pushEnabled=false preference", async () => {
    const provider = new FakeProvider();
    setPushProviders([provider]);
    prismaMock.digestPrefs.findUnique.mockResolvedValue({ familyId: "fam-1", pushEnabled: false, dailyEmail: true, weeklyEmail: true, emails: [] });
    const outcome = await notifyParentsOfAlert("fam-1", alert);
    expect(outcome.skipped).toBe("prefs");
    expect(provider.sent).toHaveLength(0);
  });

  it("is a no-op with no providers configured and never throws", async () => {
    setPushProviders([]);
    const outcome = await notifyParentsOfAlert("fam-1", alert);
    expect(outcome.skipped).toBe("no_providers");
  });

  it("raiseAlert creates the row, publishes the family event and pushes once", async () => {
    const provider = new FakeProvider();
    setPushProviders([provider]);
    prismaMock.alert.create.mockImplementation(async ({ data }: { data: Record<string, unknown> }) => ({ id: "alert-9", createdAt: new Date(), acknowledged: false, ...data }));
    prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", displayName: "Alex" });
    prismaMock.digestPrefs.findUnique.mockResolvedValue(null);
    prismaMock.parent.findMany.mockResolvedValue([{ id: "parent-1" }]);
    prismaMock.parentPushToken.findMany.mockResolvedValue([{ id: "t1", parentId: "parent-1", token: "tok", platform: "android" }]);

    const created = await raiseAlert({ childId: "child-1", familyId: "fam-1", severity: "warning", category: "ai_concern", title: "T", body: "B", metadata: { a: 1 } });
    expect(created.id).toBe("alert-9");
    expect(prismaMock.alert.create).toHaveBeenCalledTimes(1);
    expect(publishFamilyEvent).toHaveBeenCalledWith("fam-1", expect.objectContaining({ type: "alert", payload: expect.objectContaining({ id: "alert-9" }) }));
    expect(provider.sent).toHaveLength(1);
    expect(provider.sent[0].message.title).toBe("Alex: T");
    expect(provider.sent[0].message.priority).toBe("normal");
  });
});

describe("the child device wake (#319)", () => {
  beforeEach(() => {
    resetPrismaMock();
    setPushProviders(null);
    setDeviceWakeSender(null);
  });

  it("builds a data-only message: the literal word wake, high priority, a collapse key, no title, body or command field", () => {
    const message = buildDeviceWakeMessage();
    // Claude's ruling (2026-10-23): `{ "w": "1" }`, never a `type` field — a pre-#322 agent reads
    // `msg.data["type"] ?: return` and would otherwise hand "wake" to the dispatcher as an unknown
    // command. This assertion is the mutant for that: swap in `type: "wake"` and it goes red.
    expect(message).toEqual({ data: { w: "1" }, threadId: "wake", priority: "high", dataOnly: true });
    // The whole point: nothing about a command travels in the payload.
    expect(Object.keys(message.data)).toEqual(["w"]);
    expect(message.data).not.toHaveProperty("type");
    expect(message.title).toBeUndefined();
    expect(message.body).toBeUndefined();
  });

  it("FCM: a data-only message carries no notification block and collapses on the wake key", () => {
    const body = FcmProvider.buildMessage("tok", buildDeviceWakeMessage());
    expect(body.message).not.toHaveProperty("notification");
    expect(body.message.android).toEqual({ priority: "HIGH", collapse_key: "wake" });
    expect(body.message.android).not.toHaveProperty("notification");
    expect(body.message.data).toEqual({ w: "1" });
    expect(body.message.apns.headers["apns-priority"]).toBe("10");
    expect(body.message.apns.payload.aps).toEqual({ "content-available": 1 });
  });

  it("FCM: an ordinary alert still renders a notification (the data-only branch must not leak)", () => {
    const body = FcmProvider.buildMessage("tok", buildAlertMessage(alert, "Alex"));
    expect(body.message.notification).toEqual({ title: "Alex: SOS", body: "Alex pressed SOS" });
    expect(body.message.android.notification.channel_id).toBe("osra_alerts");
  });

  it("APNs: a data-only payload has no alert, an alert payload still does", () => {
    expect(ApnsProvider.buildPayload(buildDeviceWakeMessage()).aps).toEqual({ "content-available": 1 });
    expect(ApnsProvider.buildPayload(buildAlertMessage(alert, "Alex")).aps.alert).toEqual({ title: "Alex: SOS", body: "Alex pressed SOS" });
  });

  it("wakes the device row's own token, and a dead token is cleared from the row", async () => {
    const provider = new FakeProvider((token) => (token === "dead" ? { ok: false, invalidToken: true, reason: "UNREGISTERED" } : { ok: true }));
    setPushProviders([provider]);

    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-1", pushToken: "live", platform: "android" });
    expect(await notifyDeviceWake("dev-1")).toEqual({ delivered: 1, clearedToken: false, skipped: null });
    expect(provider.sent).toHaveLength(1);
    expect(provider.sent[0].token).toBe("live");
    expect(provider.sent[0].message.data).toEqual({ w: "1" });

    // Compare-and-clear (#323 review): the clear must name the token that failed. Without the
    // `pushToken` condition a token that rotated mid-flight would be erased — the agent then never
    // re-uploads, because stored == uploaded, and push stays dead with no error anywhere.
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-2", pushToken: "dead", platform: "android" });
    prismaMock.device.updateMany.mockResolvedValue({ count: 1 });
    expect(await notifyDeviceWake("dev-2")).toEqual({ delivered: 0, clearedToken: true, skipped: null });
    expect(prismaMock.device.updateMany).toHaveBeenCalledWith({ where: { id: "dev-2", pushToken: "dead" }, data: { pushToken: null } });

    // W10 (Claude's #323 review): a compare-and-clear that matches nothing must report
    // clearedToken: false, not a hard-coded true. The row already holds a rotated token, so the
    // `pushToken` condition finds no row.
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-3", pushToken: "dead", platform: "android" });
    prismaMock.device.updateMany.mockResolvedValue({ count: 0 });
    expect(await notifyDeviceWake("dev-3")).toEqual({ delivered: 0, clearedToken: false, skipped: null });
  });

  it("skips cleanly with no token, no provider, or a provider that throws — never throwing itself", async () => {
    setPushProviders([]);
    expect((await notifyDeviceWake("dev-1")).skipped).toBe("no_providers");

    const provider = new FakeProvider();
    setPushProviders([provider]);
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-1", pushToken: null, platform: "android" });
    expect((await notifyDeviceWake("dev-1")).skipped).toBe("no_token");
    expect(provider.sent).toHaveLength(0);

    const err = vi.spyOn(console, "error").mockImplementation(() => undefined);
    prismaMock.device.findUnique.mockRejectedValue(new Error("db down"));
    expect(await notifyDeviceWake("dev-1")).toEqual({ delivered: 0, clearedToken: false, skipped: null });
    expect(err).toHaveBeenCalled();
    err.mockRestore();
  });

  it("a transient send failure keeps the token (only an invalid token clears it)", async () => {
    const provider = new FakeProvider(() => ({ ok: false, invalidToken: false, reason: "HTTP 503" }));
    setPushProviders([provider]);
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-1", pushToken: "live", platform: "android" });
    const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    expect(await notifyDeviceWake("dev-1")).toEqual({ delivered: 0, clearedToken: false, skipped: null });
    expect(prismaMock.device.updateMany).not.toHaveBeenCalled();
    warn.mockRestore();
  });

  it("enqueueDeviceCommand wakes the device exactly once, and a wake that fails does not fail the command", async () => {
    const wakes: string[] = [];
    setDeviceWakeSender(async (id) => {
      wakes.push(id);
      return { delivered: 1, clearedToken: false, skipped: null };
    });
    prismaMock.deviceCommand.create.mockImplementation(async ({ data }: { data: Record<string, unknown> }) => ({
      id: "cmd-1", createdAt: new Date(), status: "pending", attempts: 0, ...data,
    }));

    const message = await enqueueDeviceCommand("dev-1", "lock", {}, { requestedBy: "parent-1" });
    expect(message.type).toBe("lock");
    expect(wakes).toEqual(["dev-1"]);

    // The route's guarantee: a wake that throws synchronously or rejects is invisible to the caller.
    setDeviceWakeSender(() => {
      throw new Error("boom");
    });
    expect((await enqueueDeviceCommand("dev-1", "unlock", {}, { requestedBy: "parent-1" })).type).toBe("unlock");
    setDeviceWakeSender(async () => {
      throw new Error("network");
    });
    expect((await enqueueDeviceCommand("dev-1", "ring", {}, { requestedBy: "parent-1" })).type).toBe("ring");
  });
});
