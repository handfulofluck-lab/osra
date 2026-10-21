### AI engine — the evaluation set is split into dev and test per pattern (plan 4.2)
- `eval/dataset.jsonl` rows carry `provenance.split` (`dev` or `test`) and `provenance.pattern`: **694
  dev / 485 test** of the 1,179 committed rows, with both sides non-empty in every bank and in both
  languages. The rule lives in `eval/split.py` as a pure `sha256("bank:pattern")` bit, so a pattern's side
  follows its identity and not its position — inserting a pattern into a bank cannot silently move every
  later one between the sides, which is what an alternating rule would do.
- **The split is per pattern, never per row, and not per template position either.** A pattern is a
  template, its translation in the other language, its gender twin and a retelling of it in another person
  under one id (`PATTERN_EN` / `PATTERN_AR`, the hard-negative and generic-safe companions, and
  `LANGUAGE_ONLY` in each bank). Five rows share one pattern's wording, so a per-row draw would put a
  paraphrase of a test row in dev and contaminate the held-out number.
- **Correction, made before this merged: the first head of this PR hashed the template's position, and
  that leaked.** The Arabic banks translate the English ones with gender twins inserted, so from the first
  twin onward EN *i* and AR *i* are different sentences and a template's translation sits at another index
  with an independent coin flip. 8 of 14 adjacent twin pairs landed on opposite sides, as did translation
  pairs such as `self_harm` EN 5 ↔ AR 6 and EN 7 ↔ AR 10 — one prompt scores both languages, so a dev
  sentence whose translation or twin was in test is a paraphrase in the tuning set. The split is now cut
  on the pattern, and the review of the first re-cut closed the two gaps it left: the twin test compares
  every pair rather than neighbours — 76 pairs, so `violence`, which lists its six masculine templates and
  then its six feminine ones, is covered — and five retellings in another person now share their source's
  id (grooming 16/17, 25/26, 28/29; `self_harm` EN 40 and AR 25; `violence` EN 5).
- Hard-negative and generic-safe rows now point at the bank template (`provenance.pattern`) instead of
  their position in the generator's shuffled draw, which is what `template_index` records for those
  lists; 117 of them changed side as a result. Freezing the old sides would only have postponed the
  re-cut, because the old rule hashed a shuffle result rather than an identity.
- Regenerating changed no row's content: all 1,179 rows compare equal to `d778997` once
  `provenance.pattern` and `provenance.split` are dropped.
- `run_eval.py` gains `--split {all,dev,test}` (default `all`), applied before `--limit-per-category`, and
  records `split` in the `--json` summary and the printed header. `--split all` scores the same rows with
  the same numbers as before. `ai-eval-deepseek.yml` exposes it as a `workflow_dispatch` choice.
- **The published numbers are unchanged and are still not held out.** `EVAL.md`'s tables are `all` rows;
  `--split test` **has not been run**, and when it is it will be held out from tuning rather than from the
  prompt's author, who wrote every template. `docs/ROADMAP.md` 4.2 stays partial — acceptance is 2,000 EN
  + 2,000 AR and the set is at 588 EN / 591 AR.
- Pattern ids, with the definitions the docs use so the three cannot be confused: **304 distinct
  `(bank, list, pattern)` ids**, **156 distinct `(bank, pattern)` keys** (what the committed dataset
  carries; none on both sides), and **155 positive patterns** (the number to quote for independent
  items).
- Tests: five `(bank, pattern)` values are pinned so a change to the hash input fails rather than
  re-cutting the split silently; every pattern list has the same length as its template list; both
  languages use the same patterns outside `LANGUAGE_ONLY`; all 76 gender twins share a pattern and a side;
  20 pinned translation pairs and 9 pinned retellings share their source's pattern; the committed dataset
  is checked against the rule row by row; every bank and language has both sides; rows sharing a pattern
  share one side; the filter returns only the requested side and refuses a dataset with no split. Every
  review mutation fails at least one of these — a neighbour-only twin scan, a `violence` twin moved to a
  third pattern, the `self_harm` AR 7/8 swap, an Arabic translation moved to a `LANGUAGE_ONLY` id, and
  each retelling undone.
