import { beforeEach, describe, expect, it, vi } from "vitest";
import { authenticateInternalRequest, signV2 } from "../src/lib/internalAuth.js";
import { encryptSecret } from "../src/lib/secretVault.js";
import { prismaMock, resetPrismaMock } from "./helpers.js";

vi.mock("../src/db.js", async () => {
  const { prismaMock } = await import("./helpers.js");
  return { prisma: prismaMock };
});
vi.mock("ioredis", async () => {
  const { MockRedis } = await import("./helpers.js");
  return { Redis: MockRedis };
});

// osra-security#14: the per-device HMAC key is stored under VAULT_KEY. Verification uses the decrypted key;
// a row from before the change (plain hex) still verifies and is then re-stored encrypted.
const RAW = "a".repeat(64);
const env = { INTERNAL_HMAC_SECRET: "global-service-secret" } as NodeJS.ProcessEnv;
const NOW = 1_800_000_000;
let n = 0;
const sign = (key: string, body: string) => signV2(key, body, { timestamp: NOW, nonce: `nonce-key-at-rest-${String(++n).padStart(4, "0")}` });

describe("device HMAC key at rest (osra-security#14)", () => {
  beforeEach(() => {
    resetPrismaMock();
    (prismaMock.device as unknown as Record<string, unknown>).updateMany = vi.fn().mockResolvedValue({ count: 1 });
  });

  const byDevice = JSON.stringify({ deviceId: "dev-1", title: "x" });
  const byChild = JSON.stringify({ childId: "child-1", title: "x" });

  it("K1 an encrypted key verifies a request signed with the raw key, by device and by child", async () => {
    const dev = { id: "dev-1", childId: "child-1", internalSecret: encryptSecret(RAW) };
    prismaMock.device.findUnique.mockResolvedValue(dev);
    prismaMock.device.findMany.mockResolvedValue([dev]);
    let h = sign(RAW, byDevice);
    expect(await authenticateInternalRequest(byDevice, h["x-familyshield-signature"], h, NOW, env)).toMatchObject({ valid: true, device: { id: "dev-1" } });
    h = sign(RAW, byChild);
    expect(await authenticateInternalRequest(byChild, h["x-familyshield-signature"], h, NOW, env)).toMatchObject({ valid: true, device: { id: "dev-1" } });
    // Already sealed: nothing is re-written.
    expect((prismaMock.device as unknown as { updateMany: ReturnType<typeof vi.fn> }).updateMany).not.toHaveBeenCalled();
  });

  it("K2 the stored ciphertext itself is not a key (mutant: verify with the column as stored)", async () => {
    const stored = encryptSecret(RAW);
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-1", childId: "child-1", internalSecret: stored });
    const h = sign(stored, byDevice);
    expect(await authenticateInternalRequest(byDevice, h["x-familyshield-signature"], h, NOW, env)).toEqual({ valid: false, reason: "invalid_signature" });
  });

  it("K3 an undecryptable stored key counts as no key (mutant: verify with the empty string)", async () => {
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-1", childId: "child-1", internalSecret: "enc1:not-json" });
    const h = sign("", byDevice);
    expect(await authenticateInternalRequest(byDevice, h["x-familyshield-signature"], h, NOW, env)).toEqual({ valid: false, reason: "device_has_no_secret" });
  });

  it("K4 a legacy plaintext key still verifies, then is re-stored encrypted only if unchanged", async () => {
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-1", childId: "child-1", internalSecret: RAW });
    const h = sign(RAW, byDevice);
    expect((await authenticateInternalRequest(byDevice, h["x-familyshield-signature"], h, NOW, env)).valid).toBe(true);
    const updateMany = (prismaMock.device as unknown as { updateMany: ReturnType<typeof vi.fn> }).updateMany;
    expect(updateMany).toHaveBeenCalledTimes(1);
    const arg = updateMany.mock.calls[0][0];
    expect(arg.where).toEqual({ id: "dev-1", internalSecret: RAW });
    expect(arg.data.internalSecret.startsWith("enc1:")).toBe(true);
  });

  it("K5 a legacy key that fails to verify is not re-written (mutant: seal before verify)", async () => {
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-1", childId: "child-1", internalSecret: RAW });
    const h = sign("b".repeat(64), byDevice);
    expect((await authenticateInternalRequest(byDevice, h["x-familyshield-signature"], h, NOW, env)).valid).toBe(false);
    expect((prismaMock.device as unknown as { updateMany: ReturnType<typeof vi.fn> }).updateMany).not.toHaveBeenCalled();
  });

  it("K6 a failing re-write does not fail the request", async () => {
    prismaMock.device.findUnique.mockResolvedValue({ id: "dev-1", childId: "child-1", internalSecret: RAW });
    (prismaMock.device as unknown as { updateMany: ReturnType<typeof vi.fn> }).updateMany.mockRejectedValue(new Error("db down"));
    const h = sign(RAW, byDevice);
    expect((await authenticateInternalRequest(byDevice, h["x-familyshield-signature"], h, NOW, env)).valid).toBe(true);
  });
});
