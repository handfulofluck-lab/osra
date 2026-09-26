import { createHmac, timingSafeEqual } from "node:crypto";
import type { FastifyInstance } from "fastify";
import { prisma } from "../db.js";

/**
 * Verify the X-FamilyShield-Signature header: hex HMAC-SHA256 of the raw request body.
 *
 * Handoff item 5: when the parsed body identifies a device (`deviceId`), the signature is
 * verified against that device's per-device secret (minted at pair/claim, stored on
 * Device.internalSecret). Only callers without a device context (the ai-engine) fall back
 * to the global INTERNAL_HMAC_SECRET.
 */
export async function verifyInternalSignature(
  rawBody: string | Buffer | undefined,
  signature: string | string[] | undefined,
): Promise<boolean> {
  if (!signature || rawBody === undefined) return false;
  const sig = Array.isArray(signature) ? signature[0] : signature;

  let deviceSecret: string | null = null;
  try {
    const parsed = JSON.parse(rawBody.toString()) as { deviceId?: string };
    if (parsed.deviceId) {
      const device = await prisma.device.findUnique({ where: { id: parsed.deviceId } });
      deviceSecret = device?.internalSecret ?? null;
    }
  } catch {
    // Unparseable body: fall through to the global-secret check.
  }
  const secret = deviceSecret ?? process.env.INTERNAL_HMAC_SECRET;
  if (!secret) return false;
  const expected = createHmac("sha256", secret).update(rawBody).digest("hex");
  const a = Buffer.from(sig, "utf8");
  const b = Buffer.from(expected, "utf8");
  return a.length === b.length && timingSafeEqual(a, b);
}

/** Register a JSON parser that keeps the raw body string for HMAC verification. */
export function registerRawBodyParser(app: FastifyInstance): void {
  app.addContentTypeParser("application/json", { parseAs: "string" }, (req, body, done) => {
    (req as { rawBody?: string }).rawBody = body as string;
    try {
      done(null, JSON.parse(body as string));
    } catch (err) {
      done(err as Error);
    }
  });
}
