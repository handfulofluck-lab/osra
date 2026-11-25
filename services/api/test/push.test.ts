import { beforeEach, describe, expect, it, vi } from "vitest";
import { generateKeyPairSync } from "node:crypto";
import { prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", () => ({ prisma: prismaMock }));
vi.mock("../src/realtime/gateway.js", () => ({ publishFamilyEvent: vi.fn(async () => undefined) }));

import { FcmProvider, buildAssertion } from "../src/lib/push/fcm.js";
import { ApnsProvider, buildProviderToken } from "../src/lib/push/apns.js";
import { backoffDelay, isRetryableConnectionError, withBackoff } from "../src/lib/push/retry.js";
import {
  buildParentAlertMessage,
  buildDeviceWakeMessage,
  canWakeDevice,
  classifyPushError,
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
    const message = buildParentAlertMessage("android");
    // #673: the mock answers with FCM's `name`, so the result carries the id the wake log prints.
    expect(await provider.send("tok-1", message)).toEqual({ ok: true, messageId: "projects/osra-test/messages/1" });
    expect(await provider.send("tok-2", message)).toEqual({ ok: true, messageId: "projects/osra-test/messages/1" });
    const tokenCalls = fetchMock.mock.calls.filter(([u]) => (u as string).endsWith("/token"));
    expect(tokenCalls).toHaveLength(1);
    const sendCall = fetchMock.mock.calls.find(([u]) => (u as string).includes("messages:send"))!;
    expect(sendCall[0]).toBe("https://fcm.googleapis.com/v1/projects/osra-test/messages:send");
    const body = JSON.parse((sendCall[1] as RequestInit).body as string);
    expect(body.message.token).toBe("tok-1");
    // #410: the parent payload carries the wake marker and nothing else.
    expect(body.message).not.toHaveProperty("notification");
    expect(body.message.data).toEqual({ w: "1" });
    expect(body.message.android.priority).toBe("HIGH");
    expect(body.message.android.collapse_key).toBe("osra-wake");
    expect((sendCall[1] as RequestInit).headers).toMatchObject({ authorization: "Bearer ya29.test" });
  });

  /**
   * #673: the wake log names FCM's own message id, because that id is the only handle an operator can
   * take to Google's log to see whether the push was delivered and when. Mutant: return `{ ok: true }`
   * unconditionally and the first row goes red; throw on an unreadable body and the second does.
   */
  it("reports FCM's message id, and a 200 with no readable body is still a success", async () => {
    const fetchMock = vi.fn(async (url: string) => {
      if (url.endsWith("/token")) return jsonResponse(200, { access_token: "t", expires_in: 3600 });
      return jsonResponse(200, { name: "projects/osra-test/messages/7" });
    });
    const provider = new FcmProvider(sa, fetchMock as never);
    expect(await provider.send("tok", buildDeviceWakeMessage())).toEqual({ ok: true, messageId: "projects/osra-test/messages/7" });

    // An empty 200 (a proxy, or a double in another suite) must not turn a delivered wake into a failure.
    const emptyBody = vi.fn(async (url: string) =>
      url.endsWith("/token") ? jsonResponse(200, { access_token: "t", expires_in: 3600 }) : new Response("", { status: 200 }),
    );
    expect(await new FcmProvider(sa, emptyBody as never).send("tok", buildDeviceWakeMessage())).toEqual({ ok: true });
  });

  it("reports UNREGISTERED tokens as invalid and transient errors as retained", async () => {
    const outcomes = [
      jsonResponse(404, { error: { status: "NOT_FOUND", details: [{ errorCode: "UNREGISTERED" }] } }),
      jsonResponse(503, { error: { status: "UNAVAILABLE" } }),
    ];
    const fetchMock = vi.fn(async (url: string) => (url.endsWith("/token") ? jsonResponse(200, { access_token: "t", expires_in: 3600 }) : outcomes.shift()!));
    const provider = new FcmProvider(sa, fetchMock as never);
    const m = buildParentAlertMessage("android");
    expect(await provider.send("dead", m)).toMatchObject({ ok: false, invalidToken: true });
    expect(await provider.send("flaky", m)).toMatchObject({ ok: false, invalidToken: false });
  });

  /**
   * #385: FCM v1 answers 400 INVALID_ARGUMENT for any malformed request, so the status alone cannot
   * mean "this token is dead". Only a BadRequest violation naming `message.token` does; everything else
   * keeps the token, because clearing it is how one payload bug erased every family's wake target.
   * Mutant: put back `|| detail === "INVALID_ARGUMENT"` and the data-field and no-details cases go red.
   */
  const invalidArgument = (fields?: string[]) =>
    jsonResponse(400, {
      error: {
        status: "INVALID_ARGUMENT",
        message: "Request contains an invalid argument.",
        ...(fields
          ? {
              details: [
                // FCM v1 puts its own FcmError entry first; the BadRequest naming the field comes
                // after it. Without this entry a refactor that searched only details[0] passed every
                // test and never cleared a dead token in production (Claude's F4).
                { "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError", errorCode: "INVALID_ARGUMENT" },
                {
                  "@type": "type.googleapis.com/google.rpc.BadRequest",
                  fieldViolations: fields.map((field) => ({ field, description: "bad" })),
                },
              ],
            }
          : {}),
      },
    });

  it("treats 400 INVALID_ARGUMENT as a dead token only when FCM names message.token", async () => {
    const outcomes = [
      invalidArgument(["message.token"]), // a token that was never valid (or an APNs token, #382)
      invalidArgument(["message.data"]), // a payload bug: the token is fine
      invalidArgument(), // no details at all: nothing says the token is the problem
    ];
    const fetchMock = vi.fn(async (url: string) => (url.endsWith("/token") ? jsonResponse(200, { access_token: "t", expires_in: 3600 }) : outcomes.shift()!));
    const provider = new FcmProvider(sa, fetchMock as never);
    const m = buildParentAlertMessage("android");

    expect(await provider.send("never-valid", m)).toMatchObject({ ok: false, invalidToken: true });
    const dataField = await provider.send("payload-bug", m);
    expect(dataField).toMatchObject({ ok: false, invalidToken: false });
    // The reason names what FCM objected to, so the log shows the payload bug rather than a dead token.
    expect(dataField.reason).toContain("INVALID_ARGUMENT");
    expect(await provider.send("no-details", m)).toMatchObject({ ok: false, invalidToken: false });
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
    expect(await provider.send("abc", buildParentAlertMessage("ios"))).toEqual({ ok: true });
    expect(calls[0].path).toBe("/3/device/abc");
    expect(calls[0].headers["apns-topic"]).toBe("com.osra.parent");
    expect(calls[0].headers["apns-priority"]).toBe("10");
    expect(calls[0].headers["apns-collapse-id"]).toBe("osra-wake");
    // #410: the visible iOS alert carries localization keys, never literal text.
    expect(JSON.parse(calls[0].body).aps.alert).toEqual({ "title-loc-key": "PUSH_ALERT_TITLE", "loc-key": "PUSH_ALERT_BODY" });
    status = 410;
    expect(await provider.send("gone", buildParentAlertMessage("ios"))).toMatchObject({ ok: false, invalidToken: true });
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
    const provider = new ApnsProvider({ ...cfg, deviceBundleId: "com.osratech.child" }, transport);
    expect(await provider.send("child-token", buildDeviceWakeMessage())).toEqual({ ok: true });
    expect(calls[0].headers["apns-push-type"]).toBe("background");
    expect(calls[0].headers["apns-priority"]).toBe("5");
    expect(calls[0].headers["apns-topic"]).toBe("com.osratech.child");
    expect(JSON.parse(calls[0].body).aps).toEqual({ "content-available": 1 });
    // The alert path is unchanged: parent topic, alert type.
    await provider.send("parent-token", buildParentAlertMessage("ios"));
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

  it("retries once on a connection-level APNs error so a dropped HTTP/2 session does not lose the push", async () => {
    const calls: string[] = [];
    const transport = async (_host: string, _path: string, _headers: Record<string, string>, _body: string) => {
      calls.push("attempt");
      if (calls.length === 1) throw new Error("read ECONNRESET");
      return { status: 200, body: "" };
    };
    const provider = new ApnsProvider({ keyP8: ec.privateKey, keyId: "K", teamId: "T", bundleId: "com.osra.parent", host: "https://api.sandbox.push.apple.com" }, transport);
    expect(await provider.send("abc", buildParentAlertMessage("ios"))).toEqual({ ok: true });
    expect(calls).toHaveLength(2);
  });

  it("does not retry APNs errors that are not connection-level", async () => {
    const calls: string[] = [];
    const transport = async () => {
      calls.push("attempt");
      throw new Error("some other failure");
    };
    const provider = new ApnsProvider({ keyP8: ec.privateKey, keyId: "K", teamId: "T", bundleId: "com.osra.parent", host: "https://api.sandbox.push.apple.com" }, transport);
    expect(await provider.send("abc", buildParentAlertMessage("ios"))).toEqual({ ok: false, invalidToken: false, reason: "some other failure" });
    expect(calls).toHaveLength(1);
  });

  it("stops after three attempts when the connection error persists (#842: the cap is now a backoff)", async () => {
    const calls: string[] = [];
    const transport = async () => {
      calls.push("attempt");
      throw new Error("read ECONNRESET");
    };
    const provider = new ApnsProvider({ keyP8: ec.privateKey, keyId: "K", teamId: "T", bundleId: "com.osra.parent", host: "https://api.sandbox.push.apple.com" }, transport, () => Date.now(), async () => {});
    expect(await provider.send("abc", buildParentAlertMessage("ios"))).toEqual({ ok: false, invalidToken: false, reason: "read ECONNRESET" });
    expect(calls).toHaveLength(3);
  });
});

describe("push retry policy (#842)", () => {
  it("backs off 200, 400, 800, 1600 and then stays at the 2 s cap", () => {
    expect([1, 2, 3, 4, 5, 6].map((attempt) => backoffDelay(attempt))).toEqual([200, 400, 800, 1600, 2000, 2000]);
  });

  it("reads the errno from the error itself or from fetch's cause", () => {
    expect(isRetryableConnectionError(Object.assign(new Error("read ECONNRESET"), { code: "ECONNRESET" }))).toBe(true);
    expect(
      isRetryableConnectionError(new TypeError("fetch failed", { cause: Object.assign(new Error("socket"), { code: "ECONNRESET" }) })),
    ).toBe(true);
    expect(isRetryableConnectionError(new Error("some other failure"))).toBe(false);
    expect(isRetryableConnectionError(undefined)).toBe(false);
  });

  it("APNs retries twice with 200 and 400 ms and succeeds on the third attempt", async () => {
    const delays: number[] = [];
    let calls = 0;
    const transport = async () => {
      calls += 1;
      if (calls < 3) throw Object.assign(new Error("read ECONNRESET"), { code: "ECONNRESET" });
      return { status: 200, body: "" };
    };
    const provider = new ApnsProvider({ keyP8: ec.privateKey, keyId: "K", teamId: "T", bundleId: "com.osra.parent", host: "https://api.sandbox.push.apple.com" }, transport, () => Date.now(), async (ms) => {
      delays.push(ms);
    });
    expect(await provider.send("abc", buildParentAlertMessage("ios"))).toEqual({ ok: true });
    expect(calls).toBe(3);
    expect(delays).toEqual([200, 400]);
  });

  it("FCM retries the send on a dropped connection and does not re-exchange the token", async () => {
    const delays: number[] = [];
    let sends = 0;
    const fetchMock = vi.fn(async (url: string) => {
      if (url.endsWith("/token")) return jsonResponse(200, { access_token: "t", expires_in: 3600 });
      sends += 1;
      if (sends === 1) throw new TypeError("fetch failed", { cause: Object.assign(new Error("socket"), { code: "ECONNRESET" }) });
      return jsonResponse(200, { name: "projects/osra-test/messages/9" });
    });
    const provider = new FcmProvider(sa, fetchMock as never, () => Date.now(), async (ms) => {
      delays.push(ms);
    });
    expect(await provider.send("tok", buildParentAlertMessage("android"))).toEqual({ ok: true, messageId: "projects/osra-test/messages/9" });
    expect(sends).toBe(2);
    expect(fetchMock.mock.calls.filter(([u]) => (u as string).endsWith("/token"))).toHaveLength(1);
    expect(delays).toEqual([200]);
  });

  it("FCM returns a non-connection failure at once and never sleeps", async () => {
    const delays: number[] = [];
    let sends = 0;
    const fetchMock = vi.fn(async (url: string) => {
      if (url.endsWith("/token")) return jsonResponse(200, { access_token: "t", expires_in: 3600 });
      sends += 1;
      throw new TypeError("invalid payload");
    });
    const provider = new FcmProvider(sa, fetchMock as never, () => Date.now(), async (ms) => {
      delays.push(ms);
    });
    expect(await provider.send("tok", buildParentAlertMessage("android"))).toEqual({ ok: false, invalidToken: false, reason: "invalid payload" });
    expect(sends).toBe(1);
    expect(delays).toEqual([]);
  });

  it("FCM gives up after three attempts and reports the last connection error", async () => {
    const delays: number[] = [];
    let sends = 0;
    const fetchMock = vi.fn(async (url: string) => {
      if (url.endsWith("/token")) return jsonResponse(200, { access_token: "t", expires_in: 3600 });
      sends += 1;
      throw new TypeError("fetch failed", { cause: Object.assign(new Error("socket"), { code: "ETIMEDOUT" }) });
    });
    const provider = new FcmProvider(sa, fetchMock as never, () => Date.now(), async (ms) => {
      delays.push(ms);
    });
    const result = await provider.send("tok", buildParentAlertMessage("android"));
    expect(result).toMatchObject({ ok: false, invalidToken: false, reason: "fetch failed" });
    expect(sends).toBe(3);
    expect(delays).toEqual([200, 400]);
  });

  /**
   * Fable's b8/b9/b13 at `cc3e65c2`: the retry rows all failed with messages that match a pattern, so
   * the code list and the `cause.code` read could be deleted or widened with the suite still green.
   * These three go through the code path only, with a message that matches nothing.
   */
  it("retries a code in the list whose message matches no pattern (b8, err.code)", async () => {
    const delays: number[] = [];
    let calls = 0;
    const out = await withBackoff(
      async () => {
        calls += 1;
        if (calls === 1) throw Object.assign(new Error("socket closed by peer"), { code: "ECONNREFUSED" });
        return "ok";
      },
      { sleep: async (ms) => { delays.push(ms); } },
    );
    expect(out).toBe("ok");
    expect(calls).toBe(2);
    expect(delays).toEqual([200]);
  });

  it("retries a code in the list that rides on cause.code (b8, cause)", async () => {
    const delays: number[] = [];
    let calls = 0;
    const out = await withBackoff(
      async () => {
        calls += 1;
        if (calls === 1) {
          throw new TypeError("request failed", { cause: Object.assign(new Error("refused"), { code: "ECONNREFUSED" }) });
        }
        return "ok";
      },
      { sleep: async (ms) => { delays.push(ms); } },
    );
    expect(out).toBe("ok");
    expect(calls).toBe(2);
    expect(delays).toEqual([200]);
  });

  it("does not retry a neutral error whose code is outside the list (b9, err.code and cause)", async () => {
    for (const err of [
      Object.assign(new Error("invalid argument"), { code: "ENOTFOUND" }),
      Object.assign(new Error("invalid argument"), { code: "ERR_INVALID_ARG_TYPE" }),
      new TypeError("request failed", { cause: Object.assign(new Error("dns"), { code: "ENOTFOUND" }) }),
    ]) {
      const delays: number[] = [];
      let calls = 0;
      await expect(
        withBackoff(
          async () => {
            calls += 1;
            throw err;
          },
          { sleep: async (ms) => { delays.push(ms); } },
        ),
      ).rejects.toBe(err);
      expect(calls).toBe(1);
      expect(delays).toEqual([]);
    }
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

  it("applies the severity floor, always pushes SOS and warning/critical tamper, and never pushes info restarts (#889) or info tamper", async () => {
    expect(shouldPush({ severity: "info", category: "geofence" }, "warning")).toBe(false);
    expect(shouldPush({ severity: "warning", category: "ai_concern" }, "warning")).toBe(true);
    expect(shouldPush({ severity: "info", category: "sos" }, "critical")).toBe(true);
    expect(shouldPush({ severity: "warning", category: "tamper" }, "critical")).toBe(true);
    expect(shouldPush({ severity: "critical", category: "tamper" }, "critical")).toBe(true);
    // Karim, 23 Nov: the agent's own `info` "Agent updated" tamper stays in-app and never wakes the phone.
    expect(shouldPush({ severity: "info", category: "tamper" }, "info")).toBe(false);
    expect(shouldPush({ severity: "info", category: "tamper" }, "critical")).toBe(false);
    // UI/UX Bureau ruling (#889): `info` device_restarted alerts stay in-app only; `warning` restarts push.
    expect(shouldPush({ severity: "info", category: "device_restarted" }, "info")).toBe(false);
    expect(shouldPush({ severity: "warning", category: "device_restarted" }, "info")).toBe(true);

    const provider = new FakeProvider();
    setPushProviders([provider]);
    prismaMock.digestPrefs.findUnique.mockResolvedValue(null);
    prismaMock.parent.findMany.mockResolvedValue([{ id: "parent-1" }]);
    prismaMock.parentPushToken.findMany.mockResolvedValue([{ id: "t1", parentId: "parent-1", token: "tok-1", platform: "android" }]);

    const infoOutcome = await notifyParentsOfAlert("fam-1", { ...alert, severity: "info", category: "device_restarted" }, "Alex");
    expect(infoOutcome).toEqual({ recipients: 0, delivered: 0, pruned: 0, skipped: "severity" });
    expect(provider.sent).toHaveLength(0);

    const warnOutcome = await notifyParentsOfAlert("fam-1", { ...alert, severity: "warning", category: "device_restarted" }, "Alex");
    expect(warnOutcome).toEqual({ recipients: 1, delivered: 1, pruned: 0, skipped: null });
    expect(provider.sent).toHaveLength(1);
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

  it("sends a parent iPhone's token through FCM even when APNs is configured, and keeps it (#391)", async () => {
    // The parent app's iOS token comes from firebase_messaging, so it is an FCM token. APNs answers
    // BadDeviceToken for it, which would read as dead and prune the row on every alert.
    const fcm = new FakeProvider();
    const apnsSent: string[] = [];
    const apns: PushProvider = {
      platform: "ios",
      canWakeDevices: true,
      async send(token: string): Promise<PushResult> {
        apnsSent.push(token);
        return { ok: false, invalidToken: true, reason: "HTTP 400 BadDeviceToken" };
      },
    };
    setPushProviders([fcm, apns]);
    prismaMock.digestPrefs.findUnique.mockResolvedValue(null);
    prismaMock.parent.findMany.mockResolvedValue([{ id: "parent-1" }]);
    prismaMock.parentPushToken.findMany.mockResolvedValue([{ id: "t1", parentId: "parent-1", token: "fcm-ios-token", platform: "ios" }]);

    const outcome = await notifyParentsOfAlert("fam-1", alert, "Alex");
    expect(outcome).toEqual({ recipients: 1, delivered: 1, pruned: 0, skipped: null });
    expect(fcm.sent.map((s) => s.token)).toEqual(["fcm-ios-token"]);
    // #410 on the real path: the iPhone gets loc-keys and the wake marker, never the name or the text.
    expect(fcm.sent[0].message.locKeys).toEqual({ titleKey: "PUSH_ALERT_TITLE", bodyKey: "PUSH_ALERT_BODY" });
    expect(fcm.sent[0].message.data).toEqual({ w: "1" });
    const sent = JSON.stringify(fcm.sent[0].message);
    for (const canary of ["Alex", "SOS", alert.id, alert.childId]) expect(sent).not.toContain(canary);
    expect(apnsSent).toEqual([]);
    expect(prismaMock.parentPushToken.deleteMany).not.toHaveBeenCalled();
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
    prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", displayName: "Nazarene-Child" });
    prismaMock.digestPrefs.findUnique.mockResolvedValue(null);
    prismaMock.parent.findMany.mockResolvedValue([{ id: "parent-1" }]);
    prismaMock.parentPushToken.findMany.mockResolvedValue([{ id: "t1", parentId: "parent-1", token: "tok", platform: "android" }]);

    const created = await raiseAlert({ childId: "child-1", familyId: "fam-1", severity: "warning", category: "ai_concern", title: "TitleCanary", body: "BodyCanary", metadata: { a: 1 } });
    expect(created.id).toBe("alert-9");
    expect(prismaMock.alert.create).toHaveBeenCalledTimes(1);
    expect(publishFamilyEvent).toHaveBeenCalledWith("fam-1", expect.objectContaining({ type: "alert", payload: expect.objectContaining({ id: "alert-9" }) }));
    expect(provider.sent).toHaveLength(1);
    // #410: the child's name and the alert text no longer reach a parent token at all.
    expect(provider.sent[0].message.title).toBeUndefined();
    expect(provider.sent[0].message.dataOnly).toBe(true);
    // Exact, not toMatchObject: a partial match let the child's name ride along in `data` (#413 review F2).
    expect(provider.sent[0].message.data).toEqual({ w: "1" });
    const sent = JSON.stringify(provider.sent[0].message);
    for (const canary of ["Nazarene-Child", "TitleCanary", "BodyCanary", "alert-9", "child-1"]) expect(sent).not.toContain(canary);
    // #410 decision 1: every parent alert is HIGH — the app has to wake to fetch, whatever the severity.
    expect(provider.sent[0].message.priority).toBe("high");
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

  it("FCM: an android parent alert is data-only, carries `{ w: 1 }` and nothing else, and never the child's name", () => {
    // #410 T1/T2. This replaces a row that asserted `title: "Alex: SOS"` — the assertion that let the
    // child's name and the alert text travel to Google unnoticed.
    const body = FcmProvider.buildMessage("tok", buildParentAlertMessage("android"));
    expect(body.message).not.toHaveProperty("notification");
    expect(body.message.android).not.toHaveProperty("notification");
    expect(body.message.data).toEqual({ w: "1" });
    expect(body.message.android.priority).toBe("HIGH");
    expect(body.message.android.collapse_key).toBe("osra-wake");

    const wire = JSON.stringify(body);
    for (const canary of ["Nazarene-Child", "TitleCanary", "BodyCanary", alert.id, alert.childId]) {
      expect(wire).not.toContain(canary);
    }
  });

  it("FCM: an ios parent alert is visible but built from loc-keys, with no literal text", () => {
    // #410 T3.
    // The message itself carries no literal text either, so no provider can ever send one.
    expect(buildParentAlertMessage("ios")).not.toHaveProperty("title");
    expect(buildParentAlertMessage("ios")).not.toHaveProperty("body");
    const body = FcmProvider.buildMessage("tok", buildParentAlertMessage("ios"));
    const aps = body.message.apns.payload.aps;
    // No `notification` block at all: an empty one is still a notification message to FCM, and the next
    // field anyone adds to it would travel as literal text (#413 review).
    expect(body.message).not.toHaveProperty("notification");
    expect(body.message.android).not.toHaveProperty("notification");
    expect(aps.alert).toEqual({ "title-loc-key": "PUSH_ALERT_TITLE", "loc-key": "PUSH_ALERT_BODY" });
    expect(aps["content-available"]).toBe(1);
    expect(body.message.data).toEqual({ w: "1" });
    const wire = JSON.stringify(body);
    expect(wire).not.toContain("title\"");
    for (const canary of ["Nazarene-Child", "TitleCanary", "BodyCanary"]) expect(wire).not.toContain(canary);
  });

  it("APNs: the child wake has no alert and stays unchanged (#410 T4)", () => {
    expect(ApnsProvider.buildPayload(buildDeviceWakeMessage()).aps).toEqual({ "content-available": 1 });
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

  // 5.5 PR D: a child iPhone's token is a raw APNs token, so an FCM fallback would send it to a service
  // that cannot deliver it — and since #382 FCM would answer a 400 naming `message.token`, which fcm.ts
  // reads as dead. Mutant: let an iPhone fall back to FCM (as `providerFor` does for parents) and both
  // cases fail. This test uses a fake provider, so it pins the routing, not the mapping in #385.
  it("never wakes an iPhone through FCM, and keeps its token", async () => {
    const fcm = new FakeProvider(() => ({ ok: false, invalidToken: true, reason: "HTTP 400 INVALID_ARGUMENT" }));
    setPushProviders([fcm]);
    const iphone = { id: "ios-1", pushToken: "5a".repeat(32), platform: "ios" };
    prismaMock.device.findUnique.mockResolvedValue(iphone);
    prismaMock.device.updateMany.mockResolvedValue({ count: 1 });
    expect(await notifyDeviceWake("ios-1")).toEqual({ delivered: 0, clearedToken: false, skipped: "unsupported_platform" });
    expect(fcm.sent).toHaveLength(0);
    expect(prismaMock.device.updateMany).not.toHaveBeenCalled();
    expect(canWakeDevice(iphone)).toBe(false);
  });

  it("an APNs provider without APNS_DEVICE_BUNDLE_ID cannot wake an iPhone; with it, it can", async () => {
    const transport = vi.fn(async () => ({ status: 200, body: "" }));
    const cfg = { keyP8: ec.privateKey, keyId: "K", teamId: "T", bundleId: "com.osra.parent", host: "https://api.sandbox.push.apple.com" };
    const iphone = { id: "ios-1", pushToken: "5a".repeat(32), platform: "ios" };
    prismaMock.device.findUnique.mockResolvedValue(iphone);
    setPushProviders([new ApnsProvider(cfg, transport)]);
    expect((await notifyDeviceWake("ios-1")).skipped).toBe("unsupported_platform");
    expect(canWakeDevice(iphone)).toBe(false);
    setPushProviders([new ApnsProvider({ ...cfg, deviceBundleId: "com.osratech.child" }, transport)]);
    expect(await notifyDeviceWake("ios-1")).toEqual({ delivered: 1, clearedToken: false, skipped: null });
    expect(canWakeDevice(iphone)).toBe(true);
    expect(transport).toHaveBeenCalledTimes(1);
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

  /**
   * #673 (Flip4, 12 Nov, scenario run 1): `resume_internet` took 52.4 s and the API log carried no line
   * for any wake it sent, so a push that was never sent could not be told from one FCM delivered late.
   * Every attempt is now one info line naming the command, the device, FCM's message id and the
   * priority that was used. Mutant: delete the `console.info` in `notifyDeviceWake` and this row goes
   * red with no line at all.
   */
  it("logs a sent wake at info level with the command id, FCM's message id and the priority", async () => {
    setPushProviders([new FakeProvider(() => ({ ok: true, messageId: "projects/osra-test/messages/42" }))]);
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-1", pushToken: "live", platform: "android" });
    const info = vi.spyOn(console, "info").mockImplementation(() => undefined);
    const outcome = await notifyDeviceWake("dev-1", "cmd-9");
    const lines = info.mock.calls.map((c) => String(c[0]));
    info.mockRestore();

    expect(outcome).toEqual({ delivered: 1, clearedToken: false, skipped: null });
    expect(lines).toHaveLength(1);
    expect(lines[0]).toContain("command=cmd-9");
    expect(lines[0]).toContain("device=dev-1");
    expect(lines[0]).toContain("messageId=projects/osra-test/messages/42");
    expect(lines[0]).toContain("priority=high");
  });

  /** Same line, same level: a wake FCM refused names the error, and there is no message id to print. */
  it("logs a refused wake with the provider's error, at the same level", async () => {
    setPushProviders([new FakeProvider(() => ({ ok: false, invalidToken: false, reason: "HTTP 503 UNAVAILABLE" }))]);
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-1", pushToken: "live", platform: "android" });
    const info = vi.spyOn(console, "info").mockImplementation(() => undefined);
    await notifyDeviceWake("dev-1", "cmd-9");
    const lines = info.mock.calls.map((c) => String(c[0]));
    info.mockRestore();

    expect(lines).toHaveLength(1);
    expect(lines[0]).toContain("command=cmd-9");
    expect(lines[0]).toContain("reason=HTTP 503 UNAVAILABLE");
    expect(lines[0]).toContain("priority=high");
    expect(lines[0]).not.toContain("messageId=");
  });

  /**
   * The half of #673 that needs no phone: a wake that was never sent says so, in one line. Without it
   * "no line in the log" still has two meanings — no wake attempted, or a wake attempted and lost.
   */
  it("logs a wake that was never sent, so a missing push cannot be mistaken for a late one", async () => {
    setPushProviders([new FakeProvider()]);
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-1", pushToken: null, platform: "android" });
    const info = vi.spyOn(console, "info").mockImplementation(() => undefined);
    const outcome = await notifyDeviceWake("dev-1", "cmd-9");
    const lines = info.mock.calls.map((c) => String(c[0]));
    info.mockRestore();

    expect(outcome.skipped).toBe("no_token");
    expect(lines).toHaveLength(1);
    expect(lines[0]).toContain("command=cmd-9");
    expect(lines[0]).toContain("skip=no_token");
  });

  /**
   * The command id has to reach the wake, or every line above says `command=none`. Mutant: drop the id
   * from either `wakeDeviceDetached` call and the row fails on that path.
   */
  it("hands the command row's id to the wake, so the log line names the command", async () => {
    const wakes: Array<[string, string | undefined]> = [];
    setDeviceWakeSender(async (id, commandId) => {
      wakes.push([id, commandId]);
      return { delivered: 1, clearedToken: false, skipped: null };
    });
    prismaMock.deviceCommand.create.mockImplementation(async ({ data }: { data: Record<string, unknown> }) => ({
      id: "cmd-7", createdAt: new Date(), status: "pending", attempts: 0, ...data,
    }));

    const message = await enqueueDeviceCommand("dev-1", "resume_internet", {}, { requestedBy: "parent-1" });
    expect(wakes).toEqual([["dev-1", message.id]]);
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

  it("wakes the device again when a rules change coalesces onto a pending row", async () => {
    // Flip4, 29 Oct: a rules_updated row created while push was off (or whose wake FCM delayed) stayed
    // pending, and the next rules PATCH coalesced onto it without a wake, so the phone waited for the
    // 15-minute poll. Every enqueue must wake, coalesced or not.
    const wakes: Array<[string, string | undefined]> = [];
    setDeviceWakeSender(async (id, commandId) => {
      wakes.push([id, commandId]);
      return { delivered: 1, clearedToken: false, skipped: null };
    });
    const pending = {
      id: "c-old", deviceId: "dev-1", type: "rules_updated", payload: {}, status: "pending",
      createdAt: new Date(), expiresAt: new Date(Date.now() + 60_000), attempts: 0,
    };
    prismaMock.deviceCommand.findFirst.mockResolvedValue(pending);

    const first = await enqueueDeviceCommand("dev-1", "rules_updated", { reason: "a" });
    const second = await enqueueDeviceCommand("dev-1", "rules_updated", { reason: "b" });

    expect([first.id, second.id]).toEqual(["c-old", "c-old"]);
    expect(prismaMock.deviceCommand.create).not.toHaveBeenCalled();
    // #673: the coalesced wake names the row it is waking for, not an empty id.
    expect(wakes).toEqual([["dev-1", "c-old"], ["dev-1", "c-old"]]);
  });
});

/**
 * #673, Antigravity's review at `a56f73d3`: the wake writes a line for every attempt, and the lines are the
 * evidence that a push was sent at all — but nothing asserted that a line never carries the **device token**. A log
 * is a place a secret leaks from quietly: it is copied into bug reports, CI output and support tickets, and the token
 * is the whole credential a provider needs.
 *
 * Claude's `a4` / Fable's `B1` asked for one row across every outcome; Fable's `B2` asked for the two lines that say
 * *why* nothing was sent. Both live here.
 */
describe("the wake log (#673, Claude a4 / Fable B1-B2)", () => {
  // A phrase rather than a token-shaped literal, on purpose: a high-entropy `token = "..."` here trips the
  // repository's own gitleaks gate (it did, on the first push), and the row only needs a distinctive string that
  // must never appear in a log line.
  const token = "device-token-value-that-must-never-be-logged";

  /** Every line any console method received during [body], joined — what a reader of the log would see. */
  async function captureLog(body: () => Promise<void>): Promise<{ lines: string }> {
    const lines: string[] = [];
    const spies = (["info", "warn", "error"] as const).map((level) =>
      vi.spyOn(console, level).mockImplementation((...args: unknown[]) => {
        lines.push(args.map((a) => (typeof a === "string" ? a : JSON.stringify(a))).join(" "));
      }),
    );
    try {
      await body();
    } finally {
      spies.forEach((s) => s.mockRestore());
    }
    return { lines: lines.join("\n"), outcome: undefined };
  }

  beforeEach(() => {
    resetPrismaMock();
    setPushProviders(null);
    setDeviceWakeSender(null);
  });

  it("never writes the device token to a log, whatever the wake did", async () => {
    // Five outcomes in one test on purpose: the row is about the *absence* of the token everywhere, and a per-outcome
    // test can be deleted one at a time without anyone noticing the coverage shrank.
    const sent: Array<[string, () => Promise<void>]> = [
      ["sent", async () => {
        setPushProviders([new FakeProvider(() => ({ ok: true, messageId: "projects/osra-test/messages/1" }))]);
        prismaMock.device.findUnique.mockResolvedValue({ id: "dev-1", pushToken: token, platform: "android" });
        expect(await notifyDeviceWake("dev-1", "cmd-1")).toEqual({ delivered: 1, clearedToken: false, skipped: null });
      }],
      ["retained failure", async () => {
        setPushProviders([new FakeProvider(() => ({ ok: false, reason: "HTTP 500" }))]);
        prismaMock.device.findUnique.mockResolvedValue({ id: "dev-2", pushToken: token, platform: "android" });
        expect(await notifyDeviceWake("dev-2", "cmd-2")).toEqual({ delivered: 0, clearedToken: false, skipped: null });
      }],
      ["dead token cleared", async () => {
        setPushProviders([new FakeProvider(() => ({ ok: false, invalidToken: true, reason: "UNREGISTERED" }))]);
        prismaMock.device.findUnique.mockResolvedValue({ id: "dev-3", pushToken: token, platform: "android" });
        prismaMock.device.updateMany.mockResolvedValue({ count: 1 });
        expect(await notifyDeviceWake("dev-3", "cmd-3")).toEqual({ delivered: 0, clearedToken: true, skipped: null });
      }],
      ["unsupported platform", async () => {
        // `deviceWakeProviderFor` falls back to FCM for every non-iOS platform, so the only unsupported case is an
        // iPhone's raw APNs token with no APNs provider configured (the comment at notify.ts:105-110 explains why an
        // iPhone must never be sent through FCM — FCM answers INVALID_ARGUMENT and the token would be cleared).
        setPushProviders([new FakeProvider(() => ({ ok: true }))]);
        prismaMock.device.findUnique.mockResolvedValue({ id: "dev-4", pushToken: token, platform: "ios" });
        expect(await notifyDeviceWake("dev-4", "cmd-4")).toEqual({ delivered: 0, clearedToken: false, skipped: "unsupported_platform" });
      }],
      // The catch echoes the provider's own error text, so a provider that puts a token in its message would put it
      // in our log. That is outside this file's control; what it can pin is that *our* lines never add one, which is
      // why the error here is a realistic transport failure rather than a string carrying the token.
      ["provider threw", async () => {
        setPushProviders([new FakeProvider(() => { throw new Error("socket hang up"); })]);
        prismaMock.device.findUnique.mockResolvedValue({ id: "dev-5", pushToken: token, platform: "android" });
        expect(await notifyDeviceWake("dev-5", "cmd-5")).toEqual({ delivered: 0, clearedToken: false, skipped: null });
      }],
    ];

    for (const [label, run] of sent) {
      const { lines } = await captureLog(run);
      expect(lines, `${label}: the wake wrote no line at all, so "no line" still means two things`).not.toBe("");
      expect(lines, `${label}: a log line carried the device token`).not.toContain(token);
      // The positive control: the line names the device and the command, or it cannot answer "did it go out".
      expect(lines, `${label}: no line named the device`).toContain("device=");
    }
  });

  it("says why nothing was sent when the platform has no provider", async () => {
    // An iPhone's token with no APNs provider: the one route that reports \`unsupported_platform\`.
    setPushProviders([new FakeProvider(() => ({ ok: true }))]);
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-9", pushToken: token, platform: "ios" });

    const { lines } = await captureLog(async () => {
      expect(await notifyDeviceWake("dev-9", "cmd-9")).toEqual({ delivered: 0, clearedToken: false, skipped: "unsupported_platform" });
    });

    expect(lines).toContain("skipped skip=unsupported_platform");
    expect(lines).toContain("device=dev-9");
    expect(lines).toContain("command=cmd-9");
  });

  it("says the token was cleared when the provider reports it dead", async () => {
    setPushProviders([new FakeProvider(() => ({ ok: false, invalidToken: true, reason: "UNREGISTERED" }))]);
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-8", pushToken: token, platform: "android" });
    prismaMock.device.updateMany.mockResolvedValue({ count: 1 });

    const { lines } = await captureLog(async () => {
      expect(await notifyDeviceWake("dev-8", "cmd-8")).toEqual({ delivered: 0, clearedToken: true, skipped: null });
    });

    expect(lines).toContain("failed");
    expect(lines).toContain("reason=UNREGISTERED");
    expect(lines).toContain("tokenCleared=true");
  });
});

describe("parent alert push outcome logging (#1028)", () => {
  beforeEach(() => {
    resetPrismaMock();
    setPushProviders(null);
    delete process.env.PUSH_MIN_SEVERITY;
  });

  // Mutant: collapse THIRD_PARTY_AUTH_ERROR into generic provider_error -> the third_party_auth row fails.
  it("classifies provider errors into operator-scannable classes including third_party_auth", () => {
    expect(classifyPushError({ invalidToken: true, reason: "HTTP 404 UNREGISTERED" })).toBe("unregistered");
    expect(classifyPushError({ invalidToken: true, reason: "HTTP 410 Unregistered" })).toBe("unregistered");
    expect(classifyPushError({ invalidToken: true, reason: "HTTP 400 DeviceTokenNotForTopic" })).toBe("topic_mismatch");
    expect(classifyPushError({ invalidToken: true, reason: "HTTP 400 INVALID_ARGUMENT" })).toBe("invalid_token");
    expect(classifyPushError({ invalidToken: false, reason: "HTTP 401 THIRD_PARTY_AUTH_ERROR" })).toBe("third_party_auth");
    expect(classifyPushError({ invalidToken: false, reason: "HTTP 403 SENDER_ID_MISMATCH" })).toBe("auth_error");
    expect(classifyPushError({ invalidToken: false, reason: "FCM oauth token exchange failed: HTTP 401" })).toBe("auth_error");
    expect(classifyPushError({ invalidToken: false, reason: "HTTP 429 QUOTA_EXCEEDED" })).toBe("rate_limited");
    expect(classifyPushError({ invalidToken: false, reason: "HTTP 400 INVALID_ARGUMENT" })).toBe("invalid_request");
    expect(classifyPushError({ invalidToken: false, reason: "HTTP 503 UNAVAILABLE" })).toBe("provider_unavailable");
    expect(classifyPushError({ invalidToken: false, reason: "fetch failed (ECONNRESET)" })).toBe("network_error");
    expect(classifyPushError({ invalidToken: false, reason: "unexpected" })).toBe("provider_error");
  });

  // Mutant: emit raw messageId, raw provider reason, or raw exception objects, or include any push token /
  // family/parent/child/alert id -> the marker assertions below fail immediately.
  it("logs closed classifications and counts only, never leaking provider messageIds, raw reasons, exceptions, tokens, or ids", async () => {
    const provider: PushProvider = {
      platform: "android",
      async send(tok) {
        if (tok === "tok-secret-android") return { ok: true, messageId: "SYNTH_MSG_ID_MARKER_101" };
        if (tok === "tok-secret-ios") {
          return { ok: false, invalidToken: false, reason: "HTTP 401 THIRD_PARTY_AUTH_ERROR SYNTH_REASON_MARKER_202" };
        }
        if (tok === "tok-secret-web") {
          return { ok: false, invalidToken: true, reason: "HTTP 404 UNREGISTERED SYNTH_STALE_MARKER_303" };
        }
        throw new Error("ECONNRESET SYNTH_THROW_MARKER_404");
      },
    };
    setPushProviders([provider]);
    prismaMock.digestPrefs.findUnique.mockResolvedValue(null);
    prismaMock.parent.findMany.mockResolvedValue([{ id: "parent-secret-1" }, { id: "parent-secret-2" }]);
    prismaMock.parentPushToken.findMany.mockResolvedValue([
      { id: "row-secret-1", parentId: "parent-secret-1", token: "tok-secret-android", platform: "android" },
      { id: "row-secret-2", parentId: "parent-secret-1", token: "tok-secret-ios", platform: "ios" },
      { id: "row-secret-3", parentId: "parent-secret-2", token: "tok-secret-web", platform: "web" },
      { id: "row-secret-4", parentId: "parent-secret-2", token: "tok-secret-throw", platform: "ios" },
    ]);
    prismaMock.parentPushToken.deleteMany.mockResolvedValue({ count: 1 });

    const info = vi.spyOn(console, "info").mockImplementation(() => undefined);
    const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);
    const err = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const outcome = await notifyParentsOfAlert(
      "fam-secret-9",
      { id: "alert-secret-9", childId: "child-secret-9", severity: "critical", category: "sos", title: "SOSCanary", body: "BodyCanary" },
      "AlexCanary",
    );
    const infoLines = info.mock.calls.map((c) => c.map(String).join(" "));
    const warnLines = warn.mock.calls.map((c) => c.map(String).join(" "));
    const errLines = err.mock.calls.map((c) => c.map(String).join(" "));
    info.mockRestore();
    warn.mockRestore();
    err.mockRestore();

    expect(outcome).toEqual({ recipients: 4, delivered: 1, pruned: 1, skipped: null });
    expect(infoLines.some((l) => l === "[push] parent alert send outcome=sent platform=android provider=android")).toBe(true);
    expect(infoLines.some((l) => l === "[push] parent alert send outcome=stale platform=web provider=android errorClass=unregistered")).toBe(true);
    expect(warnLines.some((l) => l === "[push] delivery failed platform=ios provider=android errorClass=third_party_auth")).toBe(true);
    expect(warnLines.some((l) => l === "[push] delivery failed platform=ios provider=android errorClass=network_error")).toBe(true);
    expect(
      infoLines.filter((l) => l.startsWith("[push] parent alert outcome ")),
    ).toEqual([
      "[push] parent alert outcome recipients=4 delivered=1 stale=1 pruned=1 failed=2 cleanup=ok skipped=none category=sos severity=critical platforms=android:1,ios:2,web:1",
    ]);
    expect(errLines).toEqual([]);

    const allLogs = [...infoLines, ...warnLines, ...errLines].join("\n");
    for (const canary of [
      "SYNTH_MSG_ID_MARKER_101",
      "SYNTH_REASON_MARKER_202",
      "SYNTH_STALE_MARKER_303",
      "SYNTH_THROW_MARKER_404",
      "tok-secret-android",
      "tok-secret-ios",
      "tok-secret-web",
      "tok-secret-throw",
      "fam-secret-9",
      "parent-secret-1",
      "parent-secret-2",
      "row-secret-1",
      "alert-secret-9",
      "child-secret-9",
      "AlexCanary",
      "SOSCanary",
      "BodyCanary",
    ]) {
      expect(allLogs).not.toContain(canary);
    }
  });

  // Mutant (Codex #1040 review 7118885073): setting outcome.pruned = dead.length instead of deleted.count
  // reports pruned=1 when another worker already removed the stale row; skipping the aggregate on deleteMany
  // rejection leaves zero summary lines for an alert that already delivered pushes.
  it("reports affected-row pruned count on concurrent cleanup and still emits one summary on interrupted cleanup", async () => {
    const provider = new FakeProvider((tok) =>
      tok === "stale-tok" ? { ok: false, invalidToken: true, reason: "HTTP 404 UNREGISTERED" } : { ok: true },
    );
    setPushProviders([provider]);
    prismaMock.digestPrefs.findUnique.mockResolvedValue(null);
    prismaMock.parent.findMany.mockResolvedValue([{ id: "parent-1" }]);
    prismaMock.parentPushToken.findMany.mockResolvedValue([
      { id: "t1", parentId: "parent-1", token: "live-tok", platform: "android" },
      { id: "t2", parentId: "parent-1", token: "stale-tok", platform: "ios" },
    ]);

    // Case 1: Concurrent worker already deleted t2 -> deleteMany returns { count: 0 }.
    prismaMock.parentPushToken.deleteMany.mockResolvedValueOnce({ count: 0 });
    const info1 = vi.spyOn(console, "info").mockImplementation(() => undefined);
    const out1 = await notifyParentsOfAlert("fam-1", alert);
    const summaries1 = info1.mock.calls.map((c) => String(c[0])).filter((l) => l.startsWith("[push] parent alert outcome "));
    info1.mockRestore();

    expect(out1).toEqual({ recipients: 2, delivered: 1, pruned: 0, skipped: null });
    expect(summaries1).toEqual([
      "[push] parent alert outcome recipients=2 delivered=1 stale=1 pruned=0 failed=0 cleanup=ok skipped=none category=sos severity=critical platforms=android:1,ios:1",
    ]);

    // Case 2: Interrupted cleanup -> deleteMany rejects with an error carrying a synthetic marker.
    prismaMock.parentPushToken.deleteMany.mockRejectedValueOnce(new Error("DB_CLEANUP_MARKER_505"));
    const info2 = vi.spyOn(console, "info").mockImplementation(() => undefined);
    const err2 = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const out2 = await notifyParentsOfAlert("fam-1", alert);
    const summaries2 = info2.mock.calls.map((c) => String(c[0])).filter((l) => l.startsWith("[push] parent alert outcome "));
    const errLines2 = err2.mock.calls.map((c) => c.map(String).join(" "));
    info2.mockRestore();
    err2.mockRestore();

    expect(out2).toEqual({ recipients: 2, delivered: 1, pruned: 0, skipped: null });
    expect(summaries2).toEqual([
      "[push] parent alert outcome recipients=2 delivered=1 stale=1 pruned=0 failed=0 cleanup=failed skipped=none category=sos severity=critical platforms=android:1,ios:1",
    ]);
    expect(errLines2).toEqual(["[push] parent alert cleanup failed errorClass=cleanup_failed"]);
    expect([...summaries2, ...errLines2].join("\n")).not.toContain("DB_CLEANUP_MARKER_505");

    // Case 3: Unexpected outer DB failure -> logs closed errorClass + one summary, never serializing the exception.
    prismaMock.digestPrefs.findUnique.mockRejectedValueOnce(new Error("OUTER_DB_MARKER_606"));
    const info3 = vi.spyOn(console, "info").mockImplementation(() => undefined);
    const err3 = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const out3 = await notifyParentsOfAlert("fam-1", alert);
    const summaries3 = info3.mock.calls.map((c) => String(c[0])).filter((l) => l.startsWith("[push] parent alert outcome "));
    const errLines3 = err3.mock.calls.map((c) => c.map(String).join(" "));
    info3.mockRestore();
    err3.mockRestore();

    expect(out3).toEqual({ recipients: 0, delivered: 0, pruned: 0, skipped: null });
    expect(summaries3).toEqual([
      "[push] parent alert outcome recipients=0 delivered=0 stale=0 pruned=0 failed=0 cleanup=none skipped=error category=sos severity=critical",
    ]);
    expect(errLines3).toEqual(["[push] notifyParentsOfAlert failed errorClass=provider_error"]);
    expect([...summaries3, ...errLines3].join("\n")).not.toContain("OUTER_DB_MARKER_606");
  });

  // Mutant: omit logParentAlertOutcome on any skip branch or omit the no_provider branch -> fails below.
  it("logs aggregate NotifyOutcome on every skip reason (severity, no_providers, prefs, no_tokens) and missing provider", async () => {
    const info = vi.spyOn(console, "info").mockImplementation(() => undefined);
    const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);

    await notifyParentsOfAlert("fam-1", { ...alert, severity: "info", category: "device_restarted" });
    setPushProviders([]);
    await notifyParentsOfAlert("fam-1", alert);
    setPushProviders([new FakeProvider()]);
    prismaMock.digestPrefs.findUnique.mockResolvedValue({ familyId: "fam-1", pushEnabled: false, dailyEmail: true, weeklyEmail: true, emails: [] });
    await notifyParentsOfAlert("fam-1", alert);
    prismaMock.digestPrefs.findUnique.mockResolvedValue(null);
    prismaMock.parent.findMany.mockResolvedValue([{ id: "parent-1" }]);
    prismaMock.parentPushToken.findMany.mockResolvedValue([]);
    await notifyParentsOfAlert("fam-1", alert);
    const apnsOnly: PushProvider = { platform: "ios", async send() { return { ok: true }; } };
    setPushProviders([apnsOnly]);
    prismaMock.parentPushToken.findMany.mockResolvedValue([{ id: "t1", parentId: "parent-1", token: "fcm-ios-tok", platform: "ios" }]);
    const noProvOut = await notifyParentsOfAlert("fam-1", alert);

    const infoLines = info.mock.calls.map((c) => String(c[0]));
    const warnLines = warn.mock.calls.map((c) => String(c[0]));
    info.mockRestore();
    warn.mockRestore();

    expect(noProvOut).toEqual({ recipients: 1, delivered: 0, pruned: 0, skipped: null });
    expect(infoLines.some((l) => l.includes("[push] parent alert outcome") && l.includes("skipped=severity"))).toBe(true);
    expect(infoLines.some((l) => l.includes("[push] parent alert outcome") && l.includes("skipped=no_providers"))).toBe(true);
    expect(infoLines.some((l) => l.includes("[push] parent alert outcome") && l.includes("skipped=prefs"))).toBe(true);
    expect(infoLines.some((l) => l.includes("[push] parent alert outcome") && l.includes("skipped=no_tokens"))).toBe(true);
    expect(warnLines.some((l) => l === "[push] parent alert send outcome=skipped platform=ios errorClass=no_provider")).toBe(true);
    expect(
      infoLines.some(
        (l) => l.includes("recipients=1 delivered=0 stale=0 pruned=0 failed=1 cleanup=none skipped=none") && l.includes("platforms=ios:1"),
      ),
    ).toBe(true);
  });
});
