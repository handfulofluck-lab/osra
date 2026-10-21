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

DEFAULT_OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dataset.jsonl")

# 65 positives per category per language is 455; with the minimum 8 hard
# negatives per bank (56) and 20 generic safe rows that is 531 per language,
# which clears plan 4.2's ">= 500 EN + 500 AR" with room for a thin bank.
DEFAULT_PER_CATEGORY = 65
DEFAULT_HARD_NEGATIVES = 12
DEFAULT_GENERIC_SAFE = 20


def fill(template: str, slots: Dict[str, List[str]], rng: random.Random) -> str:
    """Substitute every {slot} in a template with a random fill."""
    return SLOT_RE.sub(lambda m: rng.choice(slots[m.group(1)]), template)


def expand(templates: List[str], slots: Dict[str, List[str]], count: int,
           rng: random.Random, category: str, lang: str, seed: int) -> List[dict]:
    """Fill `count` unique snippets, cycling the templates so each is used.

    A template that cannot produce a new snippet is skipped; if the bank cannot
    reach `count` even after the retry budget, this raises -- a bank with too
    few slots is a bank whose author needs to know, not a silently short set.
    """
    if not templates:
        raise ValueError(f"{category}/{lang}: no positive templates")

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
        text = fill(templates[template_index], slots, rng).strip()
        if text in seen:
            continue
        seen.add(text)
        rows.append({
            "id": f"{category}-{lang}-{len(rows) + 1:04d}",
            "lang": lang,
            "category": category,
            "text": text,
            "labels": [category],
            "hard_negative_of": None,
            "provenance": {
                "kind": "synthetic",
                "bank": category,
                "template_index": template_index,
                "seed": seed,
            },
        })
    return rows


def _rows(category: str, lang: str, texts: List[str], labels: List[str],
          hard_negative_of, bank: str, seed: int) -> List[dict]:
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
                "template_index": index,
                "seed": seed,
            },
        })
    return rows


def build_dataset(per_category: int = DEFAULT_PER_CATEGORY,
                  hard_negatives: int = DEFAULT_HARD_NEGATIVES,
                  generic_safe: int = DEFAULT_GENERIC_SAFE,
                  seed: int = 1234,
                  banks: Dict[str, Bank] = None) -> List[dict]:
    """Build the full dataset: positives, hard negatives and generic safe rows."""
    banks = banks if banks is not None else load_banks()
    rng = random.Random(seed)
    rows: List[dict] = []

    for category in HARMFUL_CATEGORIES:
        bank = banks[category]
        for lang, templates, slots in (
            ("en", bank.positives_en, bank.slots_en),
            ("ar", bank.positives_ar, bank.slots_ar),
        ):
            positives = expand(templates, slots, per_category, rng, category, lang, seed)
            rows += positives

        for lang, hard, generic in (
            ("en", bank.hard_negatives_en, bank.generic_safe_en),
            ("ar", bank.hard_negatives_ar, bank.generic_safe_ar),
        ):
            # Sample without replacement, then top up with random repeats only
            # if the bank is smaller than the ask -- no invented text.
            sample = hard[:]
            rng.shuffle(sample)
            taken = sample[:hard_negatives]
            rows += _rows(category, lang, taken, ["safe"], category, bank.module_name, seed)

            safe_sample = generic[:]
            rng.shuffle(safe_sample)
            taken_safe = safe_sample[:generic_safe]
            rows += _rows(category, lang, taken_safe, ["safe"], None, bank.module_name, seed)

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
