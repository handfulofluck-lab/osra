import { createHash, randomUUID } from "node:crypto";

export const STAGING_QA_MODEL = "openai.gpt-oss-20b-1:0";
export const STAGING_QA_REGION = "eu-central-1";

export type StagingQaModel = { endpoint: URL; traceId: string; fixtureNumber: number | null };

type Capture = {
  device: { id: string; childId: string } | null | undefined;
  deviceId: string | undefined;
  childId: string;
  app: string;
  source: string | undefined;
  text: string;
};

export function stagingQaModelEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  return env.OSRA_DEPLOYMENT_SCOPE === "staging" && env.OSRA_STAGING_QA_ANALYZER_ENABLED === "1";
}

/** Select the analyzer for a scoped synthetic WhatsApp notification. */
export function stagingQaModel(capture: Capture, env: NodeJS.ProcessEnv = process.env, now = Date.now()): StagingQaModel | null {
  if (!stagingQaModelEnabled(env)) return null;
  if (!capture.device || !capture.deviceId || !capture.childId || capture.device.id !== capture.deviceId ||
      capture.device.childId !== capture.childId || capture.deviceId !== env.OSRA_STAGING_QA_DEVICE_ID ||
      capture.childId !== env.OSRA_STAGING_QA_CHILD_ID || capture.app !== "whatsapp" ||
      capture.source !== "notification" || !capture.text || Buffer.byteLength(capture.text, "utf8") > 1024) return null;

  const expiration = env.OSRA_STAGING_QA_EXPIRES_AT ?? "";
  const expiresAt = Date.parse(expiration);
  if (!expiration.endsWith("Z") || !(now < expiresAt && expiresAt <= now + 60 * 60 * 1000)) return null;

  const allowPairText = env.OSRA_STAGING_QA_ALLOW_SYNTHETIC_PAIR_TEXT ?? "0";
  if (allowPairText !== "0" && allowPairText !== "1") return null;
  let fixtureNumber: number | null = null;
  if (allowPairText === "0") {
    const digests = (env.OSRA_STAGING_QA_FIXTURE_SHA256 ?? "").split(",").map((digest) => digest.trim());
    if (digests.length > 8 || !digests.every((digest) => /^[a-f0-9]{64}$/.test(digest))) return null;
    const fixture = digests.indexOf(createHash("sha256").update(capture.text, "utf8").digest("hex"));
    if (fixture === -1) return null;
    fixtureNumber = fixture + 1;
  }

  let endpoint: URL;
  try {
    endpoint = new URL(env.OSRA_STAGING_QA_ANALYZER_URL ?? "");
  } catch {
    return null;
  }
  if (!["https:", "http:"].includes(endpoint.protocol) || !/\.(?:internal|local)$/.test(endpoint.hostname) ||
      endpoint.username || endpoint.password || endpoint.search || endpoint.hash || endpoint.pathname !== "/") return null;
  endpoint.pathname = "/analyze/staging-qa";
  return { endpoint, traceId: randomUUID(), fixtureNumber };
}
