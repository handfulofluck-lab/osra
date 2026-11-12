import { beforeEach, describe, expect, it, vi } from "vitest";
import { FEATURE_KEYS } from "@familyshield/shared-types";
import { parseCapabilities, setupFor } from "../src/lib/capabilities.js";
import { deviceRoutes } from "../src/routes/devices.js";
import { buildApp, deviceHeader, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

/**
 * ADR-0041 D5.5, added to ADR-0034's vocabulary by its 2026-11-13 amendment: `child_account_admin`.
 *
 * The key says whether the child's own Windows or Mac account is an administrator, and it is a **state**,
 * not a boolean: `degraded` is what the parent app warns on, and an absent key is "not reported", which is
 * every phone. So the rows below are two questions: does a computer's report land (and keep its warning
 * state), and does a phone's report stop at the door.
 *
 * Mutants: drop the `COMPUTER_APPS` rule in `parseCapabilities` → every refusal row goes red while the
 * accept rows stay green; add `child-android`/`child-ios` to `COMPUTER_APPS` → the two refusal rows name
 * the phone and go red; drop `child_account_admin` from `FEATURE_KEYS` → every accept row is refused as an
 * unknown key; widen the state enum → [a state outside the four is refused] goes red.
 */

const NOW = Date.UTC(2026, 10, 13, 9, 0, 0);
const DEVICE = { id: "dev-1", childId: "child-1", child: { familyId: "fam-1" } };

function computerReport(platform: "windows" | "macos", state = "ready", overrides: Record<string, unknown> = {}) {
  return {
    client: {
      app: platform === "windows" ? "agent-desktop" : "agent-macos",
      version: "0.1.0",
      build: 1,
      flavour: "dev",
    },
    grants: {},
    features: { web_filter: "ready", child_account_admin: state },
    ...overrides,
  };
}

function phoneReport(app: "child-android" | "child-ios", overrides: Record<string, unknown> = {}) {
  return {
    client: { app, version: "0.2.0", build: 2, flavour: app === "child-android" ? "full" : "testflight" },
    grants: {},
    features: { lock_screen: "ready", location: "ready" },
    ...overrides,
  };
}

describe("child_account_admin — the vocabulary", () => {
  it("is one of the shared feature keys", () => {
    expect(FEATURE_KEYS).toContain("child_account_admin");
  });
});

describe("child_account_admin — a computer's report is accepted", () => {
  it("from a Windows device whose report says agent-desktop, in both warning states", () => {
    for (const state of ["ready", "degraded"]) {
      const parsed = parseCapabilities(computerReport("windows", state), "windows");
      expect(parsed.ok, `windows/${state}`).toBe(true);
      expect(parsed.ok ? parsed.value.features.child_account_admin : null).toBe(state);
    }
  });

  it("from a Mac whose report says agent-macos", () => {
    const parsed = parseCapabilities(computerReport("macos", "degraded"), "macos");
    expect(parsed.ok).toBe(true);
    expect(parsed.ok ? parsed.value.client.app : null).toBe("agent-macos");
  });

  it("`degraded` reaches the parent's setup screen as degraded — the state the pairing warning reads", () => {
    const setup = setupFor({ capabilities: computerReport("windows", "degraded"), capabilitiesReportedAt: new Date(NOW) }, NOW);
    expect(setup.features.child_account_admin).toBe("degraded");
  });

  it("claim 8 still holds for it: a computer claiming not_supported is shown as unavailable, not greyed", () => {
    // No desktop build is named in the table yet, so the claim is outside any row a build could back. Grey
    // would let a modified agent hide an administrator account behind "not in this version".
    const setup = setupFor({ capabilities: computerReport("windows", "not_supported"), capabilitiesReportedAt: new Date(NOW) }, NOW);
    expect(setup.features.child_account_admin).toBe("unavailable");
  });

  it("a state outside the four is refused, `banana` included", () => {
    const parsed = parseCapabilities(computerReport("windows", "banana"), "windows");
    expect(parsed.ok).toBe(false);
    // The existing enum refuses it, with the key's own path in the message.
    expect(parsed.ok ? "" : parsed.issue).toContain("features.child_account_admin");
  });
});

describe("child_account_admin — a phone's report is refused", () => {
  it("an Android device whose report carries the key is refused, naming the app that sent it", () => {
    // The honest mismatch: the app is the one this device is, and the key is still not its to send.
    const parsed = parseCapabilities(phoneReport("child-android", { features: { lock_screen: "ready", child_account_admin: "ready" } }), "android");
    expect(parsed.ok).toBe(false);
    expect(parsed.ok ? "" : parsed.issue).toBe(
      "features.child_account_admin: child-android cannot report it; only agent-desktop and agent-macos have a Windows or Mac account",
    );
  });

  it("an iPhone whose report carries the key is refused, naming child-ios", () => {
    const parsed = parseCapabilities(phoneReport("child-ios", { features: { location: "ready", child_account_admin: "degraded" } }), "ios");
    expect(parsed.ok).toBe(false);
    expect(parsed.ok ? "" : parsed.issue).toContain("features.child_account_admin: child-ios cannot report it");
  });

  it("an Android device claiming agent-desktop is refused before the key is even read", () => {
    // A1's rule, unchanged: the app must be the one this device is. A phone cannot get the key in by
    // wearing the desktop app's name, which is why the row above exists for the honest case.
    const parsed = parseCapabilities(computerReport("windows", "degraded"), "android");
    expect(parsed.ok).toBe(false);
    expect(parsed.ok ? "" : parsed.issue).toBe("client.app: agent-desktop does not match this device (android)");
  });

  it("an Android report without the key is unaffected, and shows no administrator row", () => {
    const parsed = parseCapabilities(phoneReport("child-android"), "android");
    expect(parsed.ok).toBe(true);
    const setup = setupFor({ capabilities: phoneReport("child-android"), capabilitiesReportedAt: new Date(NOW) }, NOW);
    expect(setup.features.child_account_admin).toBeUndefined();
    // The "what to fix" list is grants only, so a feature key can never reach it.
    expect(setup.missing).toEqual([]);
  });

  it("an iPhone report without the key is unaffected", () => {
    expect(parseCapabilities(phoneReport("child-ios"), "ios").ok).toBe(true);
  });
});

describe("child_account_admin — at the telemetry route", () => {
  beforeEach(() => resetPrismaMock());

  function device(platform: string) {
    prismaMock.device.findUnique.mockResolvedValue({ ...DEVICE, platform });
    prismaMock.device.update.mockResolvedValue(DEVICE);
  }

  async function post(capabilities: unknown) {
    const app = await buildApp(deviceRoutes, "/v1/devices");
    const res = await app.inject({
      method: "POST",
      url: "/v1/devices/dev-1/telemetry",
      headers: deviceHeader(app),
      payload: { batteryPct: 31, capabilities },
    });
    const written = prismaMock.device.update.mock.calls.at(-1)?.[0]?.data ?? {};
    return { res, written };
  }

  it("a Windows device's report is stored, warning state and all", async () => {
    device("windows");
    const { res, written } = await post(computerReport("windows", "degraded"));
    expect(res.statusCode).toBe(202);
    expect(written.capabilities).toMatchObject({ features: { child_account_admin: "degraded" } });
    expect(written.capabilitiesReportedAt).toBeInstanceOf(Date);
  });

  it("an Android device's report carrying the key costs the field, not the upload", async () => {
    device("android");
    const { res, written } = await post(
      phoneReport("child-android", { features: { lock_screen: "ready", child_account_admin: "ready" } }),
    );
    expect(res.statusCode).toBe(400);
    expect(res.json().error).toBe("invalid_capabilities");
    expect(res.json().fieldErrors.capabilities).toContain("child-android cannot report it");
    // The rest of the upload is stored and no report is written: a refused report leaves no chip behind.
    expect(written.batteryPct).toBe(31);
    expect(written.capabilities).toBeUndefined();
  });
});
