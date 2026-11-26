import { describe, expect, it } from "vitest";
import { readOwnScanScoreReceipt, readProviderAnalysis } from "../src/lib/stagingProviderOutcomes.js";

const quiet = {
  status: "scored", model: "v9", flagged: false, severity: "info", flagged_categories: [],
  categories: { cyberbullying: 0.41234, self_harm: 0, grooming: 0.02, violence: 0.38, sexual_content: 0, substance_use: 0, hate_speech: 0.1 },
  language: "en", cutoff: 0.6, text: "never copied",
};

/** The receipt the route passes in: what the provider parser validated for this exact response. */
function receiptFor(own: Record<string, unknown>, trace = "t-1") {
  return readProviderAnalysis({ trace_id: trace, region: "eu-north-1", mode: "own", outcomes: { own } }, "own", "t-1").providers.own;
}
const read = (own: Record<string, unknown>) => readOwnScanScoreReceipt({ outcomes: { own } }, receiptFor(own));

describe("own-model score receipt for every staging scan (Ahmed, 26 Nov)", () => {
  it("keeps the top harm score, language and cut-off of a scan that did not flag", () => {
    expect(read(quiet)).toEqual({
      modelVersion: "v9", lang: "en", topCategory: "cyberbullying", topScore: 0.4123, cutoff: 0.6,
    });
  });

  it("never carries the text or unknown fields", () => {
    const receipt = read(quiet);
    expect(JSON.stringify(receipt)).not.toContain("never copied");
    expect(Object.keys(receipt ?? {}).sort()).toEqual(["cutoff", "lang", "modelVersion", "topCategory", "topScore"]);
  });

  it("drops an unknown language or cut-off instead of trusting it", () => {
    const odd = { ...quiet, language: "xx", cutoff: "high" };
    expect(read(odd)).toEqual({ modelVersion: "v9", lang: null, topCategory: "cyberbullying", topScore: 0.4123, cutoff: null });
  });

  it("logs nothing when the parser rejects the outcome (unknown model, out-of-range score)", () => {
    expect(read({ ...quiet, model: "v99" })).toBeUndefined();
    expect(read({ ...quiet, categories: { ...quiet.categories, cyberbullying: 7 } })).toBeUndefined();
  });

  it("answers nothing for an unavailable or missing own outcome", () => {
    expect(read({ status: "unavailable", reason: "timeout" })).toBeUndefined();
    expect(readOwnScanScoreReceipt({ outcomes: {} }, undefined)).toBeUndefined();
    expect(readOwnScanScoreReceipt(null, receiptFor(quiet))).toBeUndefined();
  });

  it("answers nothing when the parser rejected the response (mismatched trace)", () => {
    expect(readOwnScanScoreReceipt({ outcomes: { own: quiet } }, receiptFor(quiet, "other-trace"))).toBeUndefined();
  });
});
