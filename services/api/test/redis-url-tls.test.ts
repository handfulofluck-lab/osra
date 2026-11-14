import { describe, expect, it } from "vitest";
import { Redis } from "ioredis";

// Production's cache requires TLS in transit (infra/terraform/env/elasticache.tf, #714), and Terraform then
// hands the API REDIS_URL=rediss://…. Both clients (src/redis.ts, src/realtime/gateway.ts) pass the URL
// straight to `new Redis(url)`, so this pins the ioredis behaviour they rely on: the rediss scheme turns TLS
// on by itself, and plain redis:// (staging, local) stays plaintext. lazyConnect: nothing is dialled.
describe("REDIS_URL scheme selects TLS (#714)", () => {
  it("rediss:// enables TLS with Node's default trust store", () => {
    const client = new Redis("rediss://cache.example.internal:6379", { lazyConnect: true });
    try {
      expect(client.options.tls).toBeTruthy();
      expect(client.options.host).toBe("cache.example.internal");
      expect(client.options.port).toBe(6379);
    } finally {
      client.disconnect();
    }
  });

  it("redis:// stays plaintext", () => {
    const client = new Redis("redis://cache.example.internal:6379", { lazyConnect: true });
    try {
      expect(client.options.tls).toBeFalsy();
    } finally {
      client.disconnect();
    }
  });
});
