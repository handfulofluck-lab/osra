import { describe, expect, it } from "vitest";
import { flaggedProviders, readProviderAnalysis } from "../src/lib/stagingProviderOutcomes.js";

const trace = "fixture-trace";
const scores = { cyberbullying: 0, self_harm: 0.36, grooming: 0, violence: 0, sexual_content: 0, substance_use: 0, hate_speech: 0 };
const own = { status: "scored", model: "v9", flagged: true, severity: "warning",
  categories: scores, flagged_categories: ["self_harm"], language: "en" };
const bedrock = { ...own, model: "openai.gpt-oss-20b-1:0", categories: { ...scores, safe: 0.1 } };
const both = { trace_id: trace, region: "eu-central-1", mode: "both", outcomes: { bedrock, own } };
const unavailable = { status: "unavailable", reason: "unavailable" };

describe("private provider receipts", () => {
  it("retains Stockholm on the staged own-model outcome and parent alert attribution", () => {
    const outcome = readProviderAnalysis({ ...both, region: "eu-north-1", mode: "own", outcomes: { own } }, "own", trace);
    expect(outcome.providers.own).toMatchObject({ status: "scored", region: "eu-north-1" });
    expect(outcome.providers.own).not.toHaveProperty("language");
    expect(flaggedProviders(outcome.providers).own).toEqual(outcome.providers.own);
  });

  it.each(["bedrock", "both"] as const)("rejects a Stockholm receipt for %s", (mode) => {
    const outcomes = mode === "both" ? { own, bedrock } : { bedrock };
    const result = readProviderAnalysis({ ...both, region: "eu-north-1", mode, outcomes }, mode, trace);
    expect(result.verdict).toBeNull();
    expect(result.providers.bedrock).toEqual(unavailable);
  });

  it.each(["bedrock", "own"] as const)("accepts exactly the selected %s provider", (mode) => {
    const result = readProviderAnalysis({ ...both, mode, outcomes: { [mode]: mode === "bedrock" ? bedrock : own } }, mode, trace);
    expect(Object.keys(result.providers)).toEqual([mode]);
    expect(result.verdict).toEqual({ flagged: true, severity: "warning", concernTypes: ["self_harm"] });
  });

  it.each([{ trace_id: "different-trace" }, { region: "us-east-1" }, { mode: "own" },
    { outcomes: { own } }, { outcomes: { own, bedrock, unexpected: own } }])("rejects an uncorrelated envelope %j", (change) => {
    // Mutant: accepting a response from a different scan or a different invocation mode.
    expect(readProviderAnalysis({ ...both, ...change }, "both", trace)).toEqual({
      providers: { bedrock: unavailable, own: unavailable }, verdict: null,
    });
  });

  it.each([{ model: "untrusted display text" }, { flagged_categories: ["unknown"] },
    { flagged_categories: ["self_harm", "self_harm"] }, { flagged: false }, { severity: "info" },
    { categories: { ...scores, self_harm: Infinity } }, { categories: { ...scores, self_harm: -0.1 } },
    { categories: { ...scores, self_harm: 1.1 } }, { categories: { ...scores, unexpected: 0.5 } }])(
    "discards a malformed peer without losing the other provider", (change) => {
      // Mutant: trusting provider-supplied keys or discarding the healthy peer.
      const result = readProviderAnalysis({ ...both, outcomes: { bedrock, own: { ...own, ...change } } }, "both", trace);
      expect(result.providers.own).toEqual(unavailable);
      expect(result.providers.bedrock).toMatchObject({ status: "scored", categories: { self_harm: 0.36 } });
      expect(result.verdict?.flagged).toBe(true);
    },
  );

  it("only persists known display identifiers and the explicitly flagged category scores", () => {
    const data = { ...own, model: "v9+v9b", language: "uncertain", text: "opaque synthetic input", endpoint: "private" };
    expect(readProviderAnalysis({ ...both, mode: "own", outcomes: { own: data } }, "own", trace).providers).toEqual({
      own: { status: "scored", model: "v9+v9b", flagged: true, flagged_categories: ["self_harm"], categories: { self_harm: 0.36 } },
    });
  });
});
