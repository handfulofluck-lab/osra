# Evaluation set schema

The set is one JSON object per line (`eval/dataset.jsonl`), generated from the template banks in
`eval/banks/`. Every field below is normative: a row that does not carry all of them is a row the
metrics cannot attribute, and `tests/test_eval_harness.py` fails on it.

## A row

```json
{
  "id": "self_harm-ar-0007",
  "lang": "ar",
  "category": "self_harm",
  "text": "أحس الكل أحسن بدوني",
  "labels": ["self_harm"],
  "hard_negative_of": null,
  "provenance": {"kind": "synthetic", "bank": "self_harm", "template_index": 3, "split": "test", "seed": 1234}
}
```

| Field | Type | Meaning |
|---|---|---|
| `id` | string | Stable, human-readable: `<category>-<lang>-<n>`, or `<category>-<lang>-safe-<n>` for a safe row. Never reused. |
| `lang` | `"en"` \| `"ar"` | The language the text is written in. Chosen by which bank array it came from, not detected. |
| `category` | one of the seven | The bank the row came from. For a safe row this is the bank whose vocabulary it tests. |
| `text` | string | The message as a child would type it. |
| `labels` | `[string]` | Exactly one label: the harmful category, or `"safe"`. |
| `hard_negative_of` | category \| `null` | Set when the text is benign but reuses that category's vocabulary. `null` for positives and for generic safe text. |
| `provenance` | object | Where it came from: `kind` (`synthetic`, later `public`/`reported`), `bank`, `template_index` (index into that bank's `POSITIVES_<LANG>`), `split` (`dev` or `test`, derived by `eval/split.py::split_of` from `bank` and `template_index` — never drawn per row), and the generator `seed`. |

## Labels

Seven harmful categories plus `safe`, matching `model.CATEGORIES` in `services/ai-engine/model.py`:

| Label | The pattern it names |
|---|---|
| `cyberbullying` | Targeted humiliation, exclusion, rumour, group mockery between peers. |
| `self_harm` | Hopelessness, goodbye-shaped messages, concealment of injury, being a burden. |
| `grooming` | Secrecy from parents, age-gap flattery, isolation from friends, gifts, requests to meet alone, image requests. |
| `violence` | Threats aimed at a person, retaliation, arranged fights, a weapon brought to school. |
| `sexual_content` | Pressure for images, age-inappropriate sexual talk, coercion after a breakup. |
| `substance_use` | Offers, group pressure, concealment of use, a dealer as a character. |
| `hate_speech` | Group-targeted slurs and dehumanising speech, extremist recruitment framing. |

`labels` is a list. The first element is always the bank's own category; further elements are declared
overlaps from `ALSO_LABELS_<LANG>`, where a message genuinely belongs to two categories — an adult
asking a child for a photo is `grooming` *and* `sexual_content`, and a scorer that answers either has
read it correctly. `run_eval` counts `category in row["labels"]`, so an overlap raises that category's
`support` without changing the metric.

Each row's text is unique within its language across all seven banks. The generator drops a duplicate
rather than counting the same sentence twice: the safe false-positive rate is computed over these rows,
and a repeated safe line would make a scorer look better than it is.

## Age context

`AGE_RANGE = (min, max)` is declared per bank — the ages the category typically concerns — and is
copied into no row, because the scorer does not use it yet (`analyze_text` accepts `child_age` and
ignores it). It is recorded so that (a) a reviewer can see the intended population, and (b) the day
the scorer becomes age-aware, the field is already there to condition on. Pretending the set is
age-conditioned today would be a documentation bug.

## What a row may never contain

- Method, means, dosage, price, sourcing route, weapon construction, injury detail, or graphic
  sexual description — in either language.
- A real person's name, school, or address. Slot fills are common first names only.
- Text with no provenance: a pasted real message is not admissible without consent and is not in the
  set today.

## Adding a source

The set is open to sources other than the template banks, and the schema is what keeps them
separable:

1. `provenance.kind` distinguishes `synthetic` (generated here), `public` (a published corpus, named
   in `provenance.source` and licence-checked), and `reported` (a parent-reported miss, with consent
   and no identifying data).
2. A non-synthetic row carries `provenance.source` (corpus name or "parent report, date") and does not
   carry `template_index`/`seed`/`split`: the split is a property of a template, so it belongs to the
   synthetic set, and a separate source file is scored whole with `--dataset` (the default `--split
   all`).
3. Rows from a new source go in a separate file (`eval/public/<corpus>.jsonl`), and
   `python -m eval.run_eval --dataset <file>` scores it alone, so the published numbers keep naming
   the dataset they came from.
4. Never edit a committed synthetic row to fix a label: regenerate from the bank (the seed makes it
   reproducible) and fix the *template*, so the mistake is fixed for every row it produced.
