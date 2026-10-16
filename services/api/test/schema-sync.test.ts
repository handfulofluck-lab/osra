import { describe, expect, it } from "vitest";
import { checkSchemaSync, assertPrismaClientInSync } from "../src/lib/schemaSync.js";

describe("Prisma client vs Database schema sync check (#47)", () => {
  const fakeDmmf = {
    datamodel: {
      models: [
        {
          name: "RuleSet",
          dbName: null,
          fields: [
            { name: "id", kind: "scalar" },
            { name: "childId", kind: "scalar" },
            { name: "youtubeRestrictedMode", kind: "scalar" },
            { name: "child", kind: "object" }, // non-scalar relation field ignored
          ],
        },
      ],
      enums: [],
      types: [],
    },
  } as any;

  it("returns inSync: true when all scalar columns match", async () => {
    const mockClient = {
      $queryRawUnsafe: async () => [
        { table_name: "RuleSet", column_name: "id" },
        { table_name: "RuleSet", column_name: "childId" },
        { table_name: "RuleSet", column_name: "youtubeRestrictedMode" },
      ],
    } as any;

    const res = await checkSchemaSync(mockClient, fakeDmmf);
    expect(res.inSync).toBe(true);
    expect(res.missingInClient).toHaveLength(0);
    expect(res.missingInDb).toHaveLength(0);
  });

  it("detects drift when DB has a column not present in the generated client (#47 repro)", async () => {
    // DMMF is old (missing youtubeRestrictedMode)
    const oldDmmf = {
      datamodel: {
        models: [
          {
            name: "RuleSet",
            dbName: null,
            fields: [
              { name: "id", kind: "scalar" },
              { name: "childId", kind: "scalar" },
            ],
          },
        ],
        enums: [],
        types: [],
      },
    } as any;

    const mockClient = {
      $queryRawUnsafe: async () => [
        { table_name: "RuleSet", column_name: "id" },
        { table_name: "RuleSet", column_name: "childId" },
        { table_name: "RuleSet", column_name: "youtubeRestrictedMode" },
      ],
    } as any;

    const res = await checkSchemaSync(mockClient, oldDmmf);
    expect(res.inSync).toBe(false);
    expect(res.missingInClient).toContain("RuleSet.youtubeRestrictedMode");

    await expect(assertPrismaClientInSync(mockClient, oldDmmf)).rejects.toThrow(
      /pnpm exec prisma generate/
    );
  });

  it("detects drift when DB is missing a column present in client", async () => {
    const mockClient = {
      $queryRawUnsafe: async () => [
        { table_name: "RuleSet", column_name: "id" },
        { table_name: "RuleSet", column_name: "childId" },
      ],
    } as any;

    const res = await checkSchemaSync(mockClient, fakeDmmf);
    expect(res.inSync).toBe(false);
    expect(res.missingInDb).toContain("RuleSet.youtubeRestrictedMode");

    await expect(assertPrismaClientInSync(mockClient, fakeDmmf)).rejects.toThrow(
      /pnpm exec prisma migrate deploy/
    );
  });

  it("skips check when SKIP_PRISMA_SYNC_CHECK=1", async () => {
    process.env.SKIP_PRISMA_SYNC_CHECK = "1";
    try {
      const mockClient = {
        $queryRawUnsafe: async () => {
          throw new Error("Should not be called");
        },
      } as any;
      await expect(assertPrismaClientInSync(mockClient, fakeDmmf)).resolves.toBeUndefined();
    } finally {
      delete process.env.SKIP_PRISMA_SYNC_CHECK;
    }
  });
});
