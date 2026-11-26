// P-23 Privacy and data: the retention numbers the parent app shows come from the server's own settings.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { privacySummary } from "../src/lib/privacySummary.js";
import { familyRoutes } from "../src/routes/family.js";
import { authHeader, buildApp, deviceHeader, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

const read = (relative: string) => readFileSync(fileURLToPath(new URL(relative, import.meta.url)), "utf8");

describe("P-23 privacy summary", () => {
  it("matches the published privacy policy §11 with no overrides", () => {
    expect(privacySummary({ AWS_REGION: "eu-central-1" })).toEqual({
      retention: {
        locationDays: 30,
        activityDays: 90,
        messageExcerptDays: 90,
        dailyTotalsDays: 365,
        alertDays: 365,
        serverLogDays: 90,
        backupDays: 14,
      },
      storage: { area: "eu", location: "frankfurt" },
      deletionCancelDays: null,
      policyUrls: { en: "https://osratech.com/privacy", ar: "https://osratech.com/ar/privacy" },
    });
  });

  it("follows the cleanup job's own settings, so the screen can't promise a period the job doesn't apply", () => {
    const s = privacySummary({ RETENTION_DAYS: "60", LOCATION_RETENTION_DAYS: "14", ALERT_RETENTION_DAYS: "180" });
    expect(s.retention.activityDays).toBe(60);
    expect(s.retention.messageExcerptDays).toBe(60);
    expect(s.retention.locationDays).toBe(14);
    expect(s.retention.alertDays).toBe(180);
  });

  it("reads log and backup windows from env and ignores unusable values", () => {
    expect(privacySummary({ PRIVACY_LOG_RETENTION_DAYS: "30", PRIVACY_BACKUP_RETENTION_DAYS: "7" }).retention)
      .toMatchObject({ serverLogDays: 30, backupDays: 7 });
    expect(privacySummary({ PRIVACY_LOG_RETENTION_DAYS: "abc", PRIVACY_BACKUP_RETENTION_DAYS: "0" }).retention)
      .toMatchObject({ serverLogDays: 90, backupDays: 14 });
  });

  it("names the real storage location, and hides it when the region is unknown", () => {
    expect(privacySummary({ AWS_REGION: "eu-north-1" }).storage).toEqual({ area: "eu", location: "stockholm" });
    expect(privacySummary({}).storage).toBeNull();
    expect(privacySummary({ AWS_REGION: "me-central-1" }).storage).toBeNull();
  });

  it("keeps the production Terraform log and backup windows equal to the policy defaults", () => {
    const base = read("../../../infra/terraform/base/production.tfvars.example");
    const env = read("../../../infra/terraform/env/production.tfvars.example");
    expect(Number(base.match(/^log_retention_days\s*=\s*(\d+)/m)?.[1])).toBe(privacySummary({}).retention.serverLogDays);
    expect(Number(env.match(/^db_backup_retention_days\s*=\s*(\d+)/m)?.[1])).toBe(privacySummary({}).retention.backupDays);
  });
});

describe("GET /v1/family/privacy", () => {
  beforeEach(() => resetPrismaMock());

  it("returns the summary to a parent", async () => {
    const app = await buildApp(familyRoutes, "/v1/family");
    const res = await app.inject({ method: "GET", url: "/v1/family/privacy", headers: authHeader(app) });
    expect(res.statusCode).toBe(200);
    expect(res.json().retention.locationDays).toBeGreaterThan(0);
    expect(res.json().deletionCancelDays).toBeNull();
    await app.close();
  });

  it("refuses a child device and an unauthenticated caller", async () => {
    const app = await buildApp(familyRoutes, "/v1/family");
    expect((await app.inject({ method: "GET", url: "/v1/family/privacy", headers: deviceHeader(app) })).statusCode).toBe(403);
    expect((await app.inject({ method: "GET", url: "/v1/family/privacy" })).statusCode).toBe(401);
    await app.close();
  });
});
