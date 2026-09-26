import { createHmac } from "node:crypto";
import { describe, expect, it } from "vitest";
import {
  decryptForFamily,
  deriveDeviceKey,
  encryptForFamily,
  generateFamilyKey,
  hmacSign,
} from "../src/index.js";

describe("generateFamilyKey", () => {
  it("returns a 44-char base64 string encoding 32 random bytes", () => {
    const key = generateFamilyKey();
    expect(key).toHaveLength(44);
    expect(Buffer.from(key, "base64")).toHaveLength(32);
  });

  it("returns a distinct key on every call", () => {
    expect(generateFamilyKey()).not.toBe(generateFamilyKey());
  });
});

describe("AES-256-GCM family encryption", () => {
  it("round-trips plaintext", () => {
    const key = generateFamilyKey();
    const payload = encryptForFamily("hello family 👋", key);
    expect(Buffer.from(payload.iv, "base64")).toHaveLength(12);
    expect(Buffer.from(payload.tag, "base64")).toHaveLength(16);
    expect(decryptForFamily(payload, key)).toBe("hello family 👋");
  });

  it("fails with the wrong key", () => {
    const payload = encryptForFamily("secret data", generateFamilyKey());
    expect(() => decryptForFamily(payload, generateFamilyKey())).toThrow();
  });

  it("fails on tampered ciphertext", () => {
    const key = generateFamilyKey();
    const payload = encryptForFamily("secret data", key);
    const bytes = Buffer.from(payload.ciphertext, "base64");
    bytes[0] = bytes[0] ^ 0xff;
    expect(() =>
      decryptForFamily({ ...payload, ciphertext: bytes.toString("base64") }, key),
    ).toThrow();
  });

  it("fails on tampered tag", () => {
    const key = generateFamilyKey();
    const payload = encryptForFamily("secret data", key);
    const tag = Buffer.from(payload.tag, "base64");
    tag[0] = tag[0] ^ 0xff;
    expect(() => decryptForFamily({ ...payload, tag: tag.toString("base64") }, key)).toThrow();
  });
});

describe("hmacSign", () => {
  it("matches a known node:crypto computed vector", () => {
    // Vector: HMAC-SHA256("hello familyshield", key="familyshield-test-secret")
    expect(hmacSign("hello familyshield", "familyshield-test-secret")).toBe(
      "f9bf9abe11f92019b250e87917a3781c9a78ee44b07cfb8d31e02d82f2c4e936",
    );
  });

  it("agrees with createHmac and differs across secrets", () => {
    const expected = createHmac("sha256", "s1").update("body").digest("hex");
    expect(hmacSign("body", "s1")).toBe(expected);
    expect(hmacSign("body", "s1")).not.toBe(hmacSign("body", "s2"));
  });

  it("accepts Buffer bodies", () => {
    expect(hmacSign(Buffer.from("body"), "s")).toBe(hmacSign("body", "s"));
  });
});

describe("deriveDeviceKey", () => {
  it("is deterministic for the same master key and deviceId", () => {
    const master = generateFamilyKey();
    expect(deriveDeviceKey(master, "device-1")).toBe(deriveDeviceKey(master, "device-1"));
  });

  it("produces distinct keys per deviceId", () => {
    const master = generateFamilyKey();
    expect(deriveDeviceKey(master, "device-1")).not.toBe(deriveDeviceKey(master, "device-2"));
  });

  it("returns a 32-byte base64 key", () => {
    const derived = deriveDeviceKey(generateFamilyKey(), "device-1");
    expect(derived).toHaveLength(44);
    expect(Buffer.from(derived, "base64")).toHaveLength(32);
  });
});
