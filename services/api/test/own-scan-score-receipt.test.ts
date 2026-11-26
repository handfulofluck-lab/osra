import { describe, expect, it } from "vitest";
import { readOwnScanScoreReceipt } from "../src/lib/stagingProviderOutcomes.js";

const quiet = {
  status: "scored", model: "v9", flagged: false, severity: "info", flagged_categories: [],
  categories: { cyberbullying: 0.41234, self_harm: 0, grooming: 0.02, violence: 0.38, sexual_content: 0, substance_use: 0, hate_speech: 0.1 },
  language: "en", cutoff: 0.6, text: "never copied",
};

describe("own-model score receipt for every staging scan (Ahmed, 26 Nov)", () => {
  it("keeps the top harm score, language and cut-off of a scan that did not flag", () => {
    expect(readOwnScanScoreReceipt({ outcomes: { own: quiet } })).toEqual({
      modelVersion: "v9", lang: "en", topCategory: "cyberbullying", topScore: 0.4123, cutoff: 0.6,
    });
  });

  it("never carries the text or unknown fields", () => {
    const receipt = readOwnScanScoreReceipt({ outcomes: { own: quiet } });
    expect(JSON.stringify(receipt)).not.toContain("never copied");
    expect(Object.keys(receipt ?? {}).sort()).toEqual(["cutoff", "lang", "modelVersion", "topCategory", "topScore"]);
  });

  it("drops an unknown model, language or out-of-range score instead of trusting it", () => {
    const odd = { ...quiet, model: "v99", language: "xx", cutoff: "high", categories: { ...quiet.categories, cyberbullying: 7 } };
    expect(readOwnScanScoreReceipt({ outcomes: { own: odd } })).toEqual({
      modelVersion: null, lang: null, topCategory: "violence", topScore: 0.38, cutoff: null,
    });
  });

  it("answers nothing for an unavailable or missing own outcome", () => {
    expect(readOwnScanScoreReceipt({ outcomes: { own: { status: "unavailable", reason: "timeout" } } })).toBeUndefined();
    expect(readOwnScanScoreReceipt({ outcomes: {} })).toBeUndefined();
    expect(readOwnScanScoreReceipt(null)).toBeUndefined();
  });
});
