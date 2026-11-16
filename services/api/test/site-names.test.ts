import { beforeEach, describe, expect, it, vi } from "vitest";
import { deviceRoutes } from "../src/routes/devices.js";
import { reportsRoutes } from "../src/routes/reports.js";
import { toApiRuleSet } from "../src/lib/ruleSync.js";
import { isExcludedSiteHost, siteNamesEnabled, siteVisitRetentionDays } from "../src/lib/siteNames.js";
import { authHeader, buildApp, deviceHeader, prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

const DEVICE_ROW = { id: "dev-1", childId: "child-1", child: { familyId: "fam-1" } };

async function postActivity(payload: unknown) {
  const app = await buildApp(deviceRoutes, "/v1/devices");
  prismaMock.device.findUnique.mockResolvedValue(DEVICE_ROW);
  prismaMock.activityEvent.createMany.mockResolvedValue({ count: 1 });
  prismaMock.appUsageDaily.upsert.mockResolvedValue({});
  prismaMock.webVisit.createMany.mockResolvedValue({ count: 1 });
  const res = await app.inject({
    method: "POST",
    url: "/v1/devices/dev-1/activity",
    headers: deviceHeader(app),
    payload: payload as Record<string, unknown>,
  });
  await app.close();
  return res;
}

beforeEach(() => {
  resetPrismaMock();
  delete process.env.SITE_NAMES_ENABLED;
});

describe("#830 site names — the flag", () => {
  it("is off by default and only the literal true turns it on", () => {
    expect(siteNamesEnabled({} as NodeJS.ProcessEnv)).toBe(false);
    expect(siteNamesEnabled({ SITE_NAMES_ENABLED: "" } as NodeJS.ProcessEnv)).toBe(false);
    expect(siteNamesEnabled({ SITE_NAMES_ENABLED: "1" } as NodeJS.ProcessEnv)).toBe(false);
    expect(siteNamesEnabled({ SITE_NAMES_ENABLED: "no" } as NodeJS.ProcessEnv)).toBe(false);
    expect(siteNamesEnabled({ SITE_NAMES_ENABLED: "true" } as NodeJS.ProcessEnv)).toBe(true);
    expect(siteNamesEnabled({ SITE_NAMES_ENABLED: " TRUE " } as NodeJS.ProcessEnv)).toBe(true);
  });

  it("travels with the rule projection so the agent can honour it", () => {
    const row = { id: "rs-1", childId: "child-1" };
    expect((toApiRuleSet(row) as { siteNames: boolean }).siteNames).toBe(false);
    process.env.SITE_NAMES_ENABLED = "true";
    expect((toApiRuleSet(row) as { siteNames: boolean }).siteNames).toBe(true);
  });

  it("keeps site names to 90 days even when the raw window is longer", () => {
    expect(siteVisitRetentionDays(365)).toBe(90);
    expect(siteVisitRetentionDays(90)).toBe(90);
    expect(siteVisitRetentionDays(30)).toBe(30);
  });
});

describe("#830 site names — host exclusions", () => {
  it("excludes our API and any of its subdomains", () => {
    expect(isExcludedSiteHost("api.osratech.com")).toBe(true);
    expect(isExcludedSiteHost("osratech.com")).toBe(true);
    expect(isExcludedSiteHost("staging.osratech.com")).toBe(true);
    expect(isExcludedSiteHost("notosratech.com")).toBe(false);
  });

  it("excludes a name that arrives with its DNS trailing dot (#841 CI)", () => {
    expect(isExcludedSiteHost("api.osratech.com.")).toBe(true);
    expect(isExcludedSiteHost("CONNECTIVITYCHECK.GSTATIC.COM.")).toBe(true);
    expect(isExcludedSiteHost("example.com.")).toBe(false);
  });

  it("excludes the enforcement hosts the filter forces and the OS connectivity checks", () => {
    for (const host of [
      "forcesafesearch.google.com",
      "strict.bing.com",
      "safe.duckduckgo.com",
      "restrict.youtube.com",
      "connectivitycheck.gstatic.com",
      "connectivitycheck.android.com",
      "time.android.com",
      "clients3.google.com",
    ]) {
      expect(isExcludedSiteHost(host)).toBe(true);
    }
    expect(isExcludedSiteHost("example.com")).toBe(false);
    expect(isExcludedSiteHost("")).toBe(true);
  });
});

describe("#830 site names — the activity route while the flag is off", () => {
  it("stores no visit for a name that was not blocked, and still stores a blocked one", async () => {
    const res = await postActivity({
      events: [
        { ts: "2026-10-15T10:00:00Z", type: "url", payload: { url: "https://example.com/page?a=1", blocked: false } },
        { ts: "2026-10-15T10:01:00Z", type: "url", payload: { url: "bad.example", blocked: true } },
      ],
    });
    expect(res.statusCode).toBe(202);
    expect(prismaMock.webVisit.createMany).toHaveBeenCalledWith({
      data: [
        expect.objectContaining({ childId: "child-1", deviceId: "dev-1", domain: "bad.example", url: "bad.example", blocked: true }),
      ],
    });
    // The raw log is a second table the same rule must cover (#841, Fable B1): only the blocked row is
    // stored, and it carries the host, never the path the phone sent.
    expect(prismaMock.activityEvent.createMany).toHaveBeenCalledTimes(1);
    const raw = prismaMock.activityEvent.createMany.mock.calls[0][0].data as Array<{ type: string; payload: Record<string, unknown> }>;
    expect(raw).toHaveLength(1);
    expect(raw[0].type).toBe("url");
    expect(raw[0].payload).toEqual({ url: "bad.example", domain: "bad.example", blocked: true });
  });

  it("writes no row at all when every name in the batch was unblocked", async () => {
    const res = await postActivity({
      events: [{ ts: "2026-10-15T10:00:00Z", type: "url", payload: { url: "example.com", blocked: false } }],
    });
    expect(res.statusCode).toBe(202);
    expect(prismaMock.webVisit.createMany).not.toHaveBeenCalled();
    expect(prismaMock.activityEvent.createMany).not.toHaveBeenCalled();
  });

  it("reduces a blocked event's full address to its host before the raw insert", async () => {
    const res = await postActivity({
      events: [
        { ts: "2026-10-15T10:00:00Z", type: "url", payload: { url: "https://Bad.example/secret?a=1", blocked: true, category: "gambling" } },
      ],
    });
    expect(res.statusCode).toBe(202);
    const raw = prismaMock.activityEvent.createMany.mock.calls[0][0].data as Array<{ payload: Record<string, unknown> }>;
    expect(raw[0].payload).toEqual({ url: "bad.example", domain: "bad.example", blocked: true, category: "gambling" });
  });

  it("stores an app_usage event untouched, so the gate only covers url events", async () => {
    const res = await postActivity({
      events: [{ ts: "2026-10-15T10:00:00Z", type: "app_usage", payload: { app: "YouTube", minutes: 3 } }],
    });
    expect(res.statusCode).toBe(202);
    const raw = prismaMock.activityEvent.createMany.mock.calls[0][0].data as Array<{ payload: Record<string, unknown> }>;
    expect(raw[0].payload).toEqual({ app: "YouTube", minutes: 3 });
  });
});

describe("#830 site names — the activity route with the flag on", () => {
  beforeEach(() => {
    process.env.SITE_NAMES_ENABLED = "true";
  });

  it("stores an unblocked name as its host only, never the path", async () => {
    const res = await postActivity({
      events: [{ ts: "2026-10-15T10:00:00Z", type: "url", payload: { url: "https://Example.com/secret/page?token=1", blocked: false } }],
    });
    expect(res.statusCode).toBe(202);
    expect(prismaMock.webVisit.createMany).toHaveBeenCalledWith({
      data: [expect.objectContaining({ domain: "example.com", url: "example.com", blocked: false })],
    });
  });

  it("still drops an excluded host, from both tables", async () => {
    const res = await postActivity({
      events: [
        { ts: "2026-10-15T10:00:00Z", type: "url", payload: { url: "api.osratech.com", blocked: false } },
        { ts: "2026-10-15T10:00:01Z", type: "url", payload: { url: "connectivitycheck.gstatic.com", blocked: false } },
        { ts: "2026-10-15T10:00:02Z", type: "url", payload: { url: "example.com", blocked: false } },
      ],
    });
    expect(res.statusCode).toBe(202);
    const data = prismaMock.webVisit.createMany.mock.calls[0][0].data as Array<{ domain: string }>;
    expect(data.map((row) => row.domain)).toEqual(["example.com"]);
    const raw = prismaMock.activityEvent.createMany.mock.calls[0][0].data as Array<{ payload: Record<string, unknown> }>;
    expect(raw.map((row) => row.payload.domain)).toEqual(["example.com"]);
  });
});

describe("#830 site names — the read side", () => {
  it("the web report shows blocked attempts only while the flag is off", async () => {
    const app = await buildApp(reportsRoutes, "/v1/reports");
    prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-1", displayName: "Laila", birthYear: 2012 });
    prismaMock.webVisit.findMany.mockResolvedValue([]);
    const res = await app.inject({
      method: "GET",
      url: "/v1/reports/web?childId=child-1",
      headers: authHeader(app),
    });
    expect(res.statusCode).toBe(200);
    expect(prismaMock.webVisit.findMany.mock.calls[0][0].where).toMatchObject({ childId: "child-1", blocked: true });
    await app.close();
  });

  it("the activity report excludes unblocked url rows while the flag is off", async () => {
    const app = await buildApp(reportsRoutes, "/v1/reports");
    prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-1", displayName: "Laila", birthYear: 2012 });
    prismaMock.activityEvent.findMany.mockResolvedValue([]);
    const res = await app.inject({
      method: "GET",
      url: "/v1/reports/activity?childId=child-1&type=url",
      headers: authHeader(app),
    });
    expect(res.statusCode).toBe(200);
    const where = prismaMock.activityEvent.findMany.mock.calls[0][0].where as Record<string, unknown>;
    expect(where.OR).toEqual([
      { type: { not: "url" } },
      { payload: { path: ["blocked"], equals: true } },
    ]);
    await app.close();
  });
});
