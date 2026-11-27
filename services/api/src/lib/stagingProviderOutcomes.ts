import { STAGING_QA_MODEL, STAGING_QA_REGION } from "./stagingQaModel.js";

export type ProviderMode = "bedrock" | "own" | "both";
type Provider = "bedrock" | "own";
type Severity = "info" | "warning" | "critical";
type Reason = "timeout" | "unavailable";
type Receipt = { status: "unavailable"; reason: Reason } | {
  status: "scored";
  region?: "eu-north-1";
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
export type ProviderModelSnapshot = {
  modelVersion: string;
  lang: string | null;
  topCategory: string | null;
  topScore: number | null;
  cutoff: number | null;
  path: "own" | "hybrid_second_look";
};

const harmful = ["cyberbullying", "self_harm", "grooming", "violence", "sexual_content", "substance_use", "hate_speech"];
const languages = new Set(["en", "id", "ms", "tr", "ur", "ar", "fr", "uncertain"]);
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
  if (!record(data) || data.trace_id !== traceId || data.mode !== mode ||
      !record(data.outcomes)) return failedProviders(mode, "unavailable");
  // The caller supplies the mode from the validated, unexpired staging window.
  const stockholmOwn = mode === "own" && data.region === "eu-north-1";
  if (data.region !== STAGING_QA_REGION && !stockholmOwn) return failedProviders(mode, "unavailable");
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
    if (stockholmOwn) outcome.receipt.region = "eu-north-1";
    anyScored = true;
    if (outcome.severity === "critical" || severity === "info") severity = outcome.severity;
    for (const category of outcome.receipt.flagged_categories) concerns.add(category);
  }
  return { providers, verdict: anyScored ? { flagged: concerns.size > 0, severity, concernTypes: [...concerns] } : null };
}

export function readProviderModelSnapshot(data: unknown, receipt: ProviderReceipts["own"]): ProviderModelSnapshot | undefined {
  if (receipt?.status !== "scored" || !record(data) || !record(data.outcomes) || !record(data.outcomes.own)) return undefined;
  const raw = data.outcomes.own;
  const top = Object.entries(receipt.categories).sort((a, b) => b[1] - a[1])[0];
  return {
    modelVersion: receipt.model,
    lang: typeof raw.language === "string" && languages.has(raw.language) ? raw.language : null,
    topCategory: top?.[0] ?? null,
    topScore: top?.[1] ?? null,
    cutoff: typeof raw.cutoff === "number" && Number.isFinite(raw.cutoff) ? raw.cutoff : null,
    path: receipt.model === "v9+v9b" ? "hybrid_second_look" : "own",
  };
}

export function flaggedProviders(receipts: ProviderReceipts): ProviderReceipts {
  return Object.fromEntries(Object.entries(receipts).filter(([, receipt]) => receipt.status === "scored" && receipt.flagged));
}

/** What the own model said about one scan, flagged or not, with no text (Ahmed's 26 Nov WhatsApp test). */
export type OwnScanScoreReceipt = {
  modelVersion: string | null;
  lang: string | null;
  topCategory: string | null;
  topScore: number | null;
};

/**
 * The flagged-only receipt keeps scores for flagged categories alone, so a scan that stayed quiet left no
 * way to tell a cut-off miss from text that never reached the model. This reads the validated own receipt:
 * the highest of the seven harm scores and the language. Never the text. The cut-off is not in the provider's
 * response contract (ai-engine ScoredOutcome); it stays in the serving config and alarm-levels notes, and
 * exposing it from the engine is after Saturday (Claude, #1227 7204404478).
 */
export function readOwnScanScoreReceipt(data: unknown, receipt: ProviderReceipts["own"]): OwnScanScoreReceipt | undefined {
  // Codex (#1227): only a receipt the provider parser validated and scored (trace, mode, region, model and all
  // seven scores in range) may be logged. The receipt keeps flagged scores only, so the quiet top score comes
  // from the same raw outcome the parser just validated, plus its language.
  if (receipt?.status !== "scored") return undefined;
  if (!record(data) || !record(data.outcomes) || !record(data.outcomes.own)) return undefined;
  const raw = data.outcomes.own;
  let topCategory: string | null = null;
  let topScore: number | null = null;
  if (record(raw.categories)) {
    for (const label of harmful) {
      const score = raw.categories[label];
      if (typeof score === "number" && Number.isFinite(score) && score >= 0 && score <= 1 &&
          (topScore === null || score > topScore)) {
        topCategory = label;
        topScore = score;
      }
    }
  }
  return {
    modelVersion: typeof receipt.model === "string" && ownModels.has(receipt.model) ? receipt.model : null,
    lang: typeof raw.language === "string" && languages.has(raw.language) ? raw.language : null,
    topCategory,
    topScore: topScore === null ? null : Math.round(topScore * 10_000) / 10_000,
  };
}
