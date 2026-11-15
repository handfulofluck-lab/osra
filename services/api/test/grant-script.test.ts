import { createHash } from "node:crypto";
import { describe, expect, it, vi } from "vitest";
// @ts-expect-error the maintainer script is JavaScript, outside the TypeScript build.
import { runGrant } from "../scripts/billing/grant.mjs";

const input = {
  familyId: "2f4af9a1-2b59-4c61-bb0c-5e875a224ba3",
  expiresAt: "2027-01-31T23:59:59.000Z",
  reason: "closed-beta",
  secretName: "test/database/connection",
  profile: "maintainer-test-profile",
  region: "eu-central-1",
  productId: "beta.family",
};

function fakes() {
  return {
    awsCli: vi.fn(async () => JSON.stringify({ DATABASE_URL: "postgresql://test-user:synthetic-not-a-real-password@db.invalid:5432/osra" })),
    executeSql: vi.fn(async () => undefined),
    log: vi.fn(),
    newStoreRef: () => "synthetic-internal-grant-reference",
  };
}

describe("maintainer finite grant script", () => {
  it("refuses null, missing and invalid expiry before any AWS call", async () => {
    for (const expiresAt of [null, undefined, "", "not-a-date"]) {
      const deps = fakes();
      await expect(runGrant({ ...input, expiresAt }, deps)).rejects.toThrow("expires_at");
      expect(deps.awsCli).not.toHaveBeenCalled();
      expect(deps.executeSql).not.toHaveBeenCalled();
    }
  });

  it("passes the AWS profile and region without logging secret-bearing output", async () => {
    const deps = fakes();
    await runGrant(input, deps);
    expect(deps.awsCli).toHaveBeenCalledWith([
      "secretsmanager", "get-secret-value",
      "--secret-id", input.secretName,
      "--query", "SecretString", "--output", "text",
      "--profile", input.profile, "--region", input.region,
    ]);
    const [secret, sql, params] = deps.executeSql.mock.calls[0];
    expect(secret).toContain("synthetic-not-a-real-password");
    expect(sql).toContain('"family_purchases"');
    expect(params).toMatchObject({
      family_id: input.familyId,
      product_id: input.productId,
      expires_at: input.expiresAt,
      cause: input.reason,
      store_ref: createHash("sha256").update("synthetic-internal-grant-reference").digest("hex"),
    });
    expect(JSON.stringify({ sql, params, logs: deps.log.mock.calls })).not.toContain("synthetic-not-a-real-password");
    expect(JSON.stringify({ sql, params })).not.toContain("synthetic-internal-grant-reference");
    expect(deps.log).toHaveBeenCalledWith("grant_recorded");
  });
});
