import { STAGING_QA_MODEL, STAGING_QA_REGION } from "./stagingQaModel.js";

export type ProviderMode = "bedrock" | "own" | "both";
type Provider = "bedrock" | "own";
type Severity = "info" | "warning" | "critical";
type Reason = "timeout" | "unavailable";
type Receipt = { status: "unavailable"; reason: Reason } | {
  status: "scored";
  model: string;
  flagged: boolean;
  flagged_categories: string[];
  categories: Record<string, number>;
};
export type ProviderReceipts = Partial<Record<Provider, Receipt>>;
export type ProviderAnalysis = {
  providers: ProviderReceipts;
  verdict: { flagged: boolean; severity: Severity; concernTypes: string[] } | null;
};

const harmful = ["cyberbullying", "self_harm", "grooming", "violence", "sexual_content", "substance_use", "hate_speech"];
const ownModels = new Set(["v9", "v9b", "v9+v9b"]);
const selected = (mode: ProviderMode): Provider[] => mode === "both" ? ["bedrock", "own"] : [mode];
const unavailable = (reason: Reason = "unavailable"): Receipt => ({ status: "unavailable", reason });

function record(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function failedProviders(mode: ProviderMode, reason: Reason): ProviderAnalysis {
  return { providers: Object.fromEntries(selected(mode).map((name) => [name, unavailable(reason)])), verdict: null };
}

function readOutcome(name: Provider, value: unknown): { receipt: Receipt; severity: Severity } {
  const failed = { receipt: unavailable(), severity: "info" as const };
  if (!record(value)) return failed;
  if (value.status === "unavailable") {
    return { receipt: unavailable(value.reason === "timeout" ? "timeout" : "unavailable"), severity: "info" };
  }
  const { status, model, flagged, severity, categories, flagged_categories: flags } = value;
  if (status !== "scored" || typeof model !== "string" ||
      (name === "bedrock" ? model !== STAGING_QA_MODEL : !ownModels.has(model)) ||
      typeof flagged !== "boolean" || (severity !== "info" && severity !== "warning" && severity !== "critical") ||
      flagged !== (severity !== "info") || !record(categories) || !Array.isArray(flags)) return failed;

  const labels = name === "bedrock" ? [...harmful, "safe"] : harmful;
  if (Object.keys(categories).length !== labels.length || !labels.every((label) => {
    const score = categories[label];
    return typeof score === "number" && Number.isFinite(score) && score >= 0 && score <= 1;
  })) return failed;
  if (!flags.every((flag): flag is string => typeof flag === "string" && harmful.includes(flag)) ||
      new Set(flags).size !== flags.length || flagged !== (flags.length > 0)) return failed;

  // A provider owns its thresholds. A calibrated positive can have a score below 0.5.
  const scores = Object.fromEntries(flags.map((label) => [label, categories[label] as number]));
  return { receipt: { status: "scored", model, flagged, flagged_categories: flags, categories: scores }, severity };
}

/** Validate the trace, region and selected engines before accepting a single provider's result. */
export function readProviderAnalysis(data: unknown, mode: ProviderMode, traceId: string): ProviderAnalysis {
  const names = selected(mode);
  if (!record(data) || data.trace_id !== traceId || data.region !== STAGING_QA_REGION || data.mode !== mode ||
      !record(data.outcomes)) return failedProviders(mode, "unavailable");
  const outcomes = data.outcomes;
  if (Object.keys(outcomes).length !== names.length || !names.every((name) => Object.hasOwn(outcomes, name))) {
    return failedProviders(mode, "unavailable");
  }
  const providers: ProviderReceipts = {};
  const concerns = new Set<string>();
  let anyScored = false;
  let severity: Severity = "info";
  for (const name of names) {
    const outcome = readOutcome(name, outcomes[name]);
    providers[name] = outcome.receipt;
    if (outcome.receipt.status !== "scored") continue;
    anyScored = true;
    if (outcome.severity === "critical" || severity === "info") severity = outcome.severity;
    for (const category of outcome.receipt.flagged_categories) concerns.add(category);
  }
  return { providers, verdict: anyScored ? { flagged: concerns.size > 0, severity, concernTypes: [...concerns] } : null };
}

export function flaggedProviders(receipts: ProviderReceipts): ProviderReceipts {
  return Object.fromEntries(Object.entries(receipts).filter(([, receipt]) => receipt.status === "scored" && receipt.flagged));
}
