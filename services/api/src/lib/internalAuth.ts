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
export interface InternalAuthResult {
  valid: boolean;
  device?: {
    id: string;
    childId: string;
    internalSecret?: string | null;
    revokedAt?: Date | null;
  } | null;
  isGlobalSecret?: boolean;
}

function checkHmac(secret: string, rawBody: string | Buffer, sig: string): boolean {
  const expected = createHmac("sha256", secret).update(rawBody).digest("hex");
  const a = Buffer.from(sig, "utf8");
  const b = Buffer.from(expected, "utf8");
  return a.length === b.length && timingSafeEqual(a, b);
}

/**
 * Authenticate an internal request via HMAC signature against per-device secret or global secret.
 * Resolves candidate device by deviceId, x-device-id header, or childId candidates (e.g. iOS payload).
 */
export async function authenticateInternalRequest(
  rawBody: string | Buffer | undefined,
  signature: string | string[] | undefined,
  headers?: Record<string, string | string[] | undefined>,
): Promise<InternalAuthResult> {
  if (!signature || rawBody === undefined) return { valid: false };
  const sig = Array.isArray(signature) ? signature[0] : signature;

  try {
    const parsed = JSON.parse(rawBody.toString()) as { deviceId?: string; childId?: string };
    const deviceId = parsed.deviceId ?? (headers?.["x-device-id"] as string | undefined);

    if (deviceId) {
      const device = await prisma.device.findUnique({ where: { id: deviceId } });
      if (device?.internalSecret) {
        if (checkHmac(device.internalSecret, rawBody, sig)) {
          return { valid: true, device };
        }
        return { valid: false };
      }
    }

    if (parsed.childId) {
      const childDevices = await prisma.device.findMany({ where: { childId: parsed.childId } });
      for (const dev of childDevices) {
        if (dev.internalSecret && checkHmac(dev.internalSecret, rawBody, sig)) {
          return { valid: true, device: dev };
        }
      }
    }
  } catch {
    // Unparseable body: proceed to check global secret
  }

  const globalSecret = process.env.INTERNAL_HMAC_SECRET;
  if (globalSecret && checkHmac(globalSecret, rawBody, sig)) {
    return { valid: true, isGlobalSecret: true };
  }

  return { valid: false };
}

export async function verifyInternalSignature(
  rawBody: string | Buffer | undefined,
  signature: string | string[] | undefined,
  headers?: Record<string, string | string[] | undefined>,
): Promise<boolean> {
  const result = await authenticateInternalRequest(rawBody, signature, headers);
  return result.valid;
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
