import type { ProviderMode } from "./stagingProviderOutcomes.js";
import { createHash, randomUUID } from "node:crypto";

export const STAGING_QA_MODEL = "openai.gpt-oss-20b-1:0";
export const STAGING_QA_REGION = "eu-central-1";

export type StagingQaModel = { endpoint: URL; expiresAt: number; traceId: string; fixtureNumber: number | null; providerMode?: ProviderMode; allChildren?: true };

// App keys emitted by Android MonitoredApps.appKeyFor.
const ANDROID_MONITORED_APPS = new Set([
  "whatsapp", "instagram", "tiktok", "snapchat", "twitter", "discord",
  "roblox", "line", "youtube", "telegram", "reddit", "messenger",
]);

type Capture = {
  device: { id: string; childId: string } | null | undefined;
  deviceId: string | undefined;
  childId: string;
  app: string;
  source: string | undefined;
  text: string;
  socialMonitoring?: unknown;
};

export function stagingQaModelEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  return env.OSRA_DEPLOYMENT_SCOPE === "staging" && env.OSRA_STAGING_QA_ANALYZER_ENABLED === "1";
}

export function stagingAiAllChildrenEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  return env.OSRA_STAGING_AI_ALL_CHILDREN === "1" && stagingQaModelEnabled(env) &&
    env.OSRA_STAGING_QA_ENGINE === "own" && env.OSRA_OWN_MODEL_REGION === "eu-north-1" &&
    (env.AWS_REGION ?? "eu-north-1") === "eu-north-1";
}

export function assertStagingAiScope(env: NodeJS.ProcessEnv = process.env): void {
  if (env.OSRA_STAGING_AI_ALL_CHILDREN === "1" && env.OSRA_DEPLOYMENT_SCOPE !== "staging") {
    throw new Error("OSRA_STAGING_AI_ALL_CHILDREN requires staging deployment scope");
  }
}

function eligibleCaptureSource(capture: Capture, androidSources: string | undefined): boolean {
  if (androidSources === undefined || androidSources === "0") {
    return capture.app === "whatsapp" && capture.source === "notification";
  }
  if (androidSources !== "1" || !ANDROID_MONITORED_APPS.has(capture.app) ||
      (capture.source !== "screen" && capture.source !== "notification")) return false;
  const rules = capture.socialMonitoring;
  return typeof rules === "object" && rules !== null && Object.hasOwn(rules, capture.app) &&
    (rules as Record<string, unknown>)[capture.app] === true;
}

function privateAnalyzerUrl(env: NodeJS.ProcessEnv, allChildren: boolean): URL | null {
  let endpoint: URL;
  try {
    endpoint = new URL(env.OSRA_STAGING_QA_ANALYZER_URL ?? "");
  } catch {
    return null;
  }
  const privateHost = allChildren ? /\.internal$/ : /\.(?:internal|local)$/;
  if (!["https:", "http:"].includes(endpoint.protocol) || !privateHost.test(endpoint.hostname) ||
      endpoint.username || endpoint.password || endpoint.search || endpoint.hash || endpoint.pathname !== "/") return null;
  endpoint.pathname = "/analyze/staging-qa";
  return endpoint;
}

/** Select the private analyzer for a paired capture under the enabled staging mode. */
export function stagingQaModel(capture: Capture, env: NodeJS.ProcessEnv = process.env, now = Date.now()): StagingQaModel | null {
  if (!stagingQaModelEnabled(env) || !capture.device || !capture.deviceId || !capture.childId ||
      capture.device.id !== capture.deviceId || capture.device.childId !== capture.childId ||
      !capture.text || Buffer.byteLength(capture.text, "utf8") > 1024) return null;

  if (env.OSRA_STAGING_AI_ALL_CHILDREN === "1") {
    if (!stagingAiAllChildrenEnabled(env) || !capture.text.trim() || !eligibleCaptureSource(capture, "1")) return null;
    const endpoint = privateAnalyzerUrl(env, true);
    if (!endpoint) return null;
    return { endpoint, expiresAt: Infinity, traceId: randomUUID(), fixtureNumber: null, providerMode: "own", allChildren: true };
  }

  if (capture.deviceId !== env.OSRA_STAGING_QA_DEVICE_ID ||
      capture.childId !== env.OSRA_STAGING_QA_CHILD_ID ||
      !eligibleCaptureSource(capture, env.OSRA_STAGING_QA_ANDROID_SOURCES)) return null;

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

  const endpoint = privateAnalyzerUrl(env, false);
  if (!endpoint) return null;
  const providerMode = env.OSRA_STAGING_QA_ENGINE;
  if (providerMode !== undefined && providerMode !== "own" && providerMode !== "bedrock" && providerMode !== "both") return null;
  return { endpoint, expiresAt, traceId: randomUUID(), fixtureNumber, providerMode };
}

/** Absolute cutoff for an already validated staging capture. */
export function stagingQaDeadline(qa: StagingQaModel, batchDeadline: number, now: number): number {
  if (qa.providerMode === "own") return Math.min(qa.expiresAt, now + 10000, batchDeadline);
  return Math.min(qa.expiresAt, now + 2600);
}
