import { beforeEach, describe, expect, it, vi } from "vitest";
import { prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", () => ({ prisma: prismaMock }));
vi.mock("../src/redis.js", () => ({ publishJson: vi.fn(async () => undefined) }));
vi.mock("../src/lib/deviceCommands.js", () => ({ enqueueDeviceCommand: vi.fn(async () => undefined) }));

import { publishJson } from "../src/redis.js";
import { publishChildRules } from "../src/lib/ruleSync.js";
import { PREMIUM_FEATURES } from "../src/lib/planGate.js";

beforeEach(() => resetPrismaMock());

describe("agent rule sync with no enforceable plan", () => {
  it("omits only configured premium fields without deleting the stored rules", async () => {
    PREMIUM_FEATURES.socialMonitoring = true;
    try {
      const stored = { id: "rs-1", childId: "child-1", socialMonitoring: { enabled: true }, appRules: [{ packageId: "keep" }] };
      prismaMock.ruleSet.findUnique.mockResolvedValue(stored);
      prismaMock.child.findUnique.mockResolvedValue({ id: "child-1", familyId: "fam-1" });
      prismaMock.familyPurchase.findMany.mockResolvedValue([]);
      prismaMock.family.findUnique.mockResolvedValue({ id: "fam-1", timezone: "UTC" });
      prismaMock.device.findMany.mockResolvedValue([]);
      await publishChildRules("child-1");
      const [channel, json] = vi.mocked(publishJson).mock.calls[0];
      expect(channel).toBe("child:child-1:rules");
      const projected = json as Record<string, unknown>;
      expect(projected.socialMonitoring).toBeUndefined();
      expect(projected.appRules).toEqual([{ packageId: "keep" }]);
      expect(stored.socialMonitoring).toEqual({ enabled: true });
    } finally {
      delete PREMIUM_FEATURES.socialMonitoring;
    }
  });
});
