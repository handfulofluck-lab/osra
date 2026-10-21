# `eval/` — the labelled evaluation set and its harness

Plan 4.2 (a labelled set with documented provenance) and plan 4.3 (precision/recall published per
category, runnable in CI). Read `EVAL.md` at the service root for the current numbers, and
`schema.md` here for the row format.

## Run it

```bash
cd services/ai-engine

python -m eval.banks                    # validate every bank (the node CI job runs this)
python -m eval.generate                 # write eval/dataset.jsonl from the banks
python -m eval.generate --check         # fail if the committed set is stale
python -m eval.run_eval                 # score with the rules layer, print the table
python -m eval.run_eval --split test    # score the held-out side of the template split
python -m eval.run_eval --json out.json # same, machine-readable
python -m eval.run_eval --write-md EVAL.md   # refresh the table inside EVAL.md
python -m eval.run_eval --fail-under-recall 0.85 --fail-under-precision 0.6
```

`--scorer model` uses whatever `MODEL_PATH` points at (DistilBERT when the checkpoint exists, the
rules layer otherwise). `--scorer deepseek` is plan 4.1 and refuses to run without
`DEEPSEEK_API_KEY`; it is a named placeholder rather than a silently missing option.

Windows consoles default to cp1252 and raise `UnicodeEncodeError` on Arabic output; prefix any
command you want to *read* with `PYTHONIOENCODING=utf-8`. The banks, the generator and the tests are
unaffected.

## Where the text comes from

**Synthetic, from template banks.** Each of the seven categories is one module under `banks/`,
written by hand: 17–26 positive templates per language, a slot dictionary that expands them to 65
distinct messages, 12–14 hard negatives per language, and 7–8 generic safe messages. Everything is
committed, so a reviewer reads the pattern instead of 2,000 lines, and a row traces back to
`(bank, template_index, pattern, seed)`.

**The cap is five rows per template.** `--per-category` above `templates × 5` raises rather than
filling: one template filled 65 times is one item, not 65, and a recall interval computed from it is a
fiction. The set grows through **new templates or new sources**, which is why plan 4.2's 2,000 +
2,000 is an authoring target rather than a configuration value (Claude's ruling on #262).

**The split is per pattern, never per row.** A pattern is a template, its translation in the other
language, its gender twin and a retelling of it in another person under one id (`PATTERN_EN`/`PATTERN_AR`
and `LANGUAGE_ONLY` in each bank); `split_of(bank, pattern)` in `split.py` hashes that identity to `dev` or
`test`, and every row it generates carries both in `provenance`. `run_eval --split test` is the estimate
held out from tuning — not from the prompt's author, who wrote every template, so it measures this corpus
under a prompt written with its themes in view. A per-row draw would leave paraphrases of a test row in
dev, so the five rows that share a pattern always stay together — and cutting on the template's *position*
rather than its pattern put 8 of 14 gender twins, and translations like `self_harm` EN 5 ↔ AR 6, on
opposite sides.

**A positive must be labelable from the message alone.** Naming the substance or the act is required;
naming the *method* is forbidden. "We're vaping in the toilets at break, watch the door" is a
`substance_use` positive; "delete this chat before your mum sees it" is not a positive in any bank,
because no reader — human or model — could tell which category it belongs to. Where a message truly
belongs to two categories, the bank declares the overlap in `ALSO_LABELS_EN` / `ALSO_LABELS_AR`.

**Slots that agree with a verb are gendered.** `{target_m}` and `{target_f}` exist because Arabic
marks gender on the verb, the pronoun and the possessive; a mixed slot produces "هنا بكى" with a
girl's name. English needs the pair only where a pronoun appears.

**No real children's data.** Nothing in this set came from a device, a family, a school or a
conversation. There is no scraping step and no uploaded corpus. If a public corpus or a
parent-reported miss is added later, it goes in its own file with `provenance.kind` set to `public`
or `reported` and is scored separately — `schema.md` §"Adding a source" is the rule.

**Hard negatives are half the value.** They are benign messages that reuse the category's vocabulary
("the wifi is pathetic today", "my knife skills in cooking class", "this homework is killing me"),
so a scorer that keys on a single word shows its precision cost immediately. A set without them
rewards exactly the failure mode that makes a parental-control product unusable — everything flagged,
nothing trusted.

## The content rule

Banks describe the **social pattern** a detector must catch — secrecy, coercion, isolation, threat,
group targeting, pressure — in the register a school-age child actually types, and they **name the
thing** the message is about (the vape, the photo, the beating at the gate). They contain no method,
means, dosage, price, sourcing route, weapon construction, injury detail or graphic sexual
description, in either language. The rule lives at the top of `banks/__init__.py` as well as here,
because it is the one rule a future contributor is most likely to break in good faith: a set that
teaches harm is not a safer set, and a detector that only fires on method text misses grooming
entirely. The two halves are not in tension: naming the act keeps the row labelable, refusing the
method keeps the repository safe.

## Adding or changing a bank

1. Copy `banks/cyberbullying.py` — the reference. Same exports, no imports, no functions.
2. Arabic must be real Arabic script in a natural register, not transliteration; the validator
   rejects an Arabic array with no Arabic characters and an English array containing Arabic. State
   which register you used in the module docstring — the native review (TR-54) judges against that.
3. **A positive must be labelable from the message alone**; if a careful reader cannot name the
   category, it is not a positive. Where a message genuinely belongs to two categories, declare it in
   `ALSO_LABELS_EN` / `ALSO_LABELS_AR`.
4. **Gender:** a slot that a verb, pronoun or possessive agrees with is split into `{name_m}` /
   `{name_f}` (or `{target_m}` / `{target_f}`), with a template for each side. Arabic needs the pair
   almost everywhere a target is named; English only where a pronoun appears.
5. Every `{slot}` must be declared in the matching `SLOTS_<LANG>`, with enough templates that
   `templates × 5` covers 65 — the generator raises rather than filling one template beyond the cap.
6. `python -m eval.banks` must print `OK` with no errors, then `python -m eval.generate` and commit
   the regenerated `dataset.jsonl` in the same change.
7. If the numbers move, regenerate the table: `python -m eval.run_eval --write-md EVAL.md`. A
   hand-edited number is a number nobody can reproduce.

## Why the harness looks like this

- **Two languages scored separately.** Arabic recall is the number plan 4.1 exists to fix; a blended
  figure would hide it. See `EVAL.md` §"The headline".
- **Per category, not one accuracy.** A scorer that is 80 % right overall and blind to grooming is
  worse than useless in this product.
- **Deterministic.** Same seed, same banks, byte-identical dataset. `--check` in CI keeps the
  committed file honest.
- **No new dependencies.** Stdlib + `model.py`, so the job runs in seconds beside the existing pytest
  suite and can never be the reason CI needs torch.
