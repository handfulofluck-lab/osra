### AI engine — the evaluation set is split into dev and test per template (plan 4.2)
- `eval/dataset.jsonl` rows now carry `provenance.split` (`dev` or `test`): **665 dev / 514 test** of the
  1,179 committed rows, with both sides non-empty in every bank and in both languages. The rule lives in
  `eval/split.py` as a pure `sha256("bank:template_index")` bit, so a template's side follows its identity
  and not its position — inserting a template into a bank cannot silently move every later template
  between the sides, which is what an alternating rule would do. Regenerating changed nothing else: all
  1,179 rows compare equal once the new key is removed.
- **The split is per template, never per row.** Five rows share one template's wording, so a per-row draw
  would put a paraphrase of a test template in dev and contaminate the "held-out" number.
- `run_eval.py` gains `--split {all,dev,test}` (default `all`), applied before `--limit-per-category`, and
  records `split` in the `--json` summary and the printed header. `--split all` scores the same rows with
  the same numbers as before. `ai-eval-deepseek.yml` exposes it as a `workflow_dispatch` choice.
- **The published numbers are unchanged and are still not held out.** `EVAL.md`'s tables are `all` rows;
  the held-out estimate is `--split test`, which **has not been run**. `docs/ROADMAP.md` 4.2 stays partial
  — acceptance is 2,000 EN + 2,000 AR and the set is at 588 EN / 591 AR.
- Tests: three `(bank, index)` values are pinned so a change to the hash input fails rather than re-cutting
  the split silently, the committed dataset is checked against the rule row by row, every bank and
  language has both sides, rows sharing a template share one side, and the filter returns only the
  requested side.
