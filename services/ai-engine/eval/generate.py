"""Expand the template banks into a labelled evaluation dataset.

Deterministic: the same seed and banks produce a byte-identical file, so a
number in EVAL.md can be traced back to an exact dataset. Regenerate with:

    python -m eval.generate                 # writes eval/dataset.jsonl
    python -m eval.generate --seed 7        # a different draw of the same banks
"""

import argparse
import json
import os
import random
from typing import Dict, List

from eval.banks import HARMFUL_CATEGORIES, SLOT_RE, Bank, load_banks
from eval.split import split_of

DEFAULT_OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dataset.jsonl")

# Claude's architecture decision on #262: the floor stays at 2,000 + 2,000, and the count grows only
# through new templates or new sources, never by filling one template more times. Five rows per
# template is the cap: beyond that the rows are the same sentence with a different name, and a set like
# that makes a recall interval look tighter than it is.
MAX_ROWS_PER_TEMPLATE = 5

DEFAULT_PER_CATEGORY = 65
DEFAULT_HARD_NEGATIVES = 12
DEFAULT_GENERIC_SAFE = 20


def fill(template: str, slots: Dict[str, List[str]], rng: random.Random) -> str:
    """Substitute every {slot} in a template, choosing each slot name **once**.

    A slot that appears twice must get the same fill: `re.sub` with a per-match `rng.choice` produced
    "we kicked Bilal out because Layla is stupid" on a template that names the target twice (#262
    review). The pronoun-free rewrites made that common, so the rule is explicit here and pinned by a
    test rather than left to each bank author's memory.
    """
    chosen: Dict[str, str] = {}

    def pick(match: "re.Match[str]") -> str:
        name = match.group(1)
        if name not in chosen:
            chosen[name] = rng.choice(slots[name])
        return chosen[name]

    return SLOT_RE.sub(pick, template)


def expand(templates: List[str], slots: Dict[str, List[str]], count: int,
           rng: random.Random, category: str, lang: str, seed: int,
           also_labels: Dict[int, List[str]] = None,
           patterns: List[int] = None) -> List[dict]:
    """Fill `count` unique snippets, cycling the templates so each is used.

    At most [MAX_ROWS_PER_TEMPLATE] rows come from one template. Beyond that the set is the same
    sentence with a different slot fill, which inflates the sample without adding an independent item —
    and the plan's gate is a recall interval, so independent items are the point.

    `patterns` is the pattern id of each template, aligned with `templates`; without it a template is
    its own pattern. `template_index` stays in provenance because it is the reproduction key, and the
    split is cut on the pattern, which also covers the translation and the gender twin.
    """
    if not templates:
        raise ValueError(f"{category}/{lang}: no positive templates")
    if patterns is None:
        patterns = list(range(len(templates)))
    if count > len(templates) * MAX_ROWS_PER_TEMPLATE:
        raise ValueError(
            f"{category}/{lang}: {count} rows requested from {len(templates)} templates, but the cap is "
            f"{MAX_ROWS_PER_TEMPLATE} rows per template ({len(templates) * MAX_ROWS_PER_TEMPLATE} max). "
            f"Add templates — do not raise the count."
        )

    also_labels = also_labels or {}
    per_template: Dict[int, int] = {}
    seen = set()
    rows = []
    cursor = 0
    attempts = 0
    budget = count * 60 + 100
    while len(rows) < count:
        attempts += 1
        if attempts > budget:
            raise ValueError(
                f"{category}/{lang}: only {len(rows)} unique snippets after {attempts} attempts; "
                f"add slots to SLOTS_{lang.upper()} or more templates"
            )
        template_index = cursor % len(templates)
        cursor += 1
        if per_template.get(template_index, 0) >= MAX_ROWS_PER_TEMPLATE:
            continue
        text = fill(templates[template_index], slots, rng).strip()
        if text in seen:
            continue
        seen.add(text)
        per_template[template_index] = per_template.get(template_index, 0) + 1
        pattern = patterns[template_index]
        rows.append({
            "id": f"{category}-{lang}-{len(rows) + 1:04d}",
            "lang": lang,
            "category": category,
            "text": text,
            # A true overlap (an adult asking a child for a photo is grooming *and* sexual content) is
            # labelled with both; `run_eval` counts `category in row["labels"]`, so no metric changes.
            "labels": [category] + list(also_labels.get(template_index, [])),
            "hard_negative_of": None,
            "provenance": {
                "kind": "synthetic",
                "bank": category,
                "template_index": template_index,
                "pattern": pattern,
                "split": split_of(category, pattern),
                "seed": seed,
            },
        })
    return rows


def _rows(category: str, lang: str, texts: List[str], labels: List[str],
          hard_negative_of, bank: str, seed: int, patterns: List[int]) -> List[dict]:
    rows = []
    for index, text in enumerate(texts):
        rows.append({
            "id": f"{category}-{lang}-{labels[0]}-{index + 1:03d}",
            "lang": lang,
            "category": hard_negative_of or category,
            "text": text,
            "labels": labels,
            "hard_negative_of": hard_negative_of,
            "provenance": {
                "kind": "synthetic",
                "bank": bank,
                # The draw position, as this field has always been for a sampled list; `pattern`
                # below is the index of the source template, which is what the split is cut on.
                "template_index": index,
                "pattern": patterns[index],
                "split": split_of(bank, patterns[index]),
                "seed": seed,
            },
        })
    return rows


def _sample_indices(texts: List[str], count: int, rng: random.Random) -> List[int]:
    """`count` source indices in a shuffled order — a draw without replacement, so a bank smaller
    than the ask contributes all of its entries rather than a repeat of one."""
    order = list(range(len(texts)))
    rng.shuffle(order)
    return order[:count]


def build_dataset(per_category: int = DEFAULT_PER_CATEGORY,
                  hard_negatives: int = DEFAULT_HARD_NEGATIVES,
                  generic_safe: int = DEFAULT_GENERIC_SAFE,
                  seed: int = 1234,
                  banks: Dict[str, Bank] = None) -> List[dict]:
    """Build the full dataset: positives, hard negatives and generic safe rows.

    Text is unique within a language across *all* banks: each bank used to carry its own copy of the
    same safe sentences, so the safe false-positive rate was computed over duplicates (#262 review).
    """
    banks = banks if banks is not None else load_banks()
    rng = random.Random(seed)
    rows: List[dict] = []
    seen_text: Dict[str, set] = {"en": set(), "ar": set()}

    def keep(row: dict) -> bool:
        if row["text"] in seen_text[row["lang"]]:
            return False
        seen_text[row["lang"]].add(row["text"])
        return True

    for category in HARMFUL_CATEGORIES:
        bank = banks[category]
        for lang, templates, slots, also in (
            ("en", bank.positives_en, bank.slots_en, bank.also_labels_en),
            ("ar", bank.positives_ar, bank.slots_ar, bank.also_labels_ar),
        ):
            positives = expand(templates, slots, per_category, rng, category, lang, seed, also,
                               bank.patterns("positives", lang))
            rows += [row for row in positives if keep(row)]

        for lang, hard, generic in (
            ("en", bank.hard_negatives_en, bank.generic_safe_en),
            ("ar", bank.hard_negatives_ar, bank.generic_safe_ar),
        ):
            # Sample by source index: the pattern belongs to the bank's template, not to the drawn
            # position. Shuffling the index list draws the same order as shuffling the texts did.
            for texts, patterns, count, hard_of in (
                (hard, bank.patterns("hard_negatives", lang), hard_negatives, category),
                (generic, bank.patterns("generic_safe", lang), generic_safe, None),
            ):
                taken = _sample_indices(texts, count, rng)
                rows += [row for row in _rows(category, lang, [texts[i] for i in taken], ["safe"],
                                              hard_of, bank.module_name, seed,
                                              [patterns[i] for i in taken]) if keep(row)]

    rows.sort(key=lambda r: (r["lang"], r["category"], r["labels"][0], r["id"]))
    return rows


def summarise(rows: List[dict]) -> str:
    by_key: Dict[tuple, int] = {}
    for row in rows:
        key = (row["lang"], row["category"], row["labels"][0])
        by_key[key] = by_key.get(key, 0) + 1
    lines = [f"{len(rows)} items"]
    for lang in ("en", "ar"):
        total = sum(v for (l, _c, _lab), v in by_key.items() if l == lang)
        lines.append(f"  {lang}: {total}")
    return "\n".join(lines)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Generate the evaluation dataset.")
    parser.add_argument("--per-category", type=int, default=DEFAULT_PER_CATEGORY)
    parser.add_argument("--hard-negatives", type=int, default=DEFAULT_HARD_NEGATIVES)
    parser.add_argument("--generic-safe", type=int, default=DEFAULT_GENERIC_SAFE)
    parser.add_argument("--seed", type=int, default=1234)
    parser.add_argument("--out", default=DEFAULT_OUT)
    parser.add_argument("--check", action="store_true",
                        help="do not write; fail if the committed file differs from a fresh draw")
    args = parser.parse_args(argv)

    rows = build_dataset(args.per_category, args.hard_negatives, args.generic_safe, args.seed)
    payload = "".join(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n" for row in rows)

    if args.check:
        if not os.path.exists(args.out):
            print(f"{args.out} missing; run python -m eval.generate")
            return 1
        with open(args.out, encoding="utf-8") as handle:
            if handle.read() != payload:
                print(f"{args.out} is stale; run python -m eval.generate")
                return 1
        print(f"{args.out} matches the banks ({len(rows)} items)")
        return 0

    with open(args.out, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(payload)
    print(f"wrote {args.out}")
    print(summarise(rows))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
