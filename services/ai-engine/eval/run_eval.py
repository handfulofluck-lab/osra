"""Score the evaluation dataset and print precision/recall per category and language.

    python -m eval.run_eval                      # regex rules layer, 0.50 threshold
    python -m eval.run_eval --scorer model       # DistilBERT, if MODEL_PATH is set
    python -m eval.run_eval --write-md EVAL.md   # refresh the table in EVAL.md
    python -m eval.run_eval --fail-under-recall 0.85 --fail-under-precision 0.6

Why per language and per category, and not one accuracy number: plan 4.1 exists
because Arabic text scored "safe" by default -- a rule set written in English
cannot match Arabic strings, so the Arabic recall is the number that says
whether the problem is fixed. One blended number would hide it.
"""

import argparse
import datetime
import json
import os
from typing import Callable, Dict, List

import model

from eval.banks import HARMFUL_CATEGORIES

DATASET = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dataset.jsonl")
LANGS = ("en", "ar")
TABLE_BEGIN = "<!-- BEGIN EVAL TABLE -->"
TABLE_END = "<!-- END EVAL TABLE -->"


def score_regex(text: str) -> Dict[str, float]:
    """The deterministic rules layer alone (what runs when no model is shipped).

    Deliberately calls the same helpers `analyze_text` uses in dev mode rather
    than flipping MODEL_PATH: the measurement names one scorer, and this is it.
    """
    rule_scores, _matched = model._rules_scores(text)  # noqa: SLF001 - same package
    return model._fallback_probabilities(rule_scores)  # noqa: SLF001


def score_model(text: str) -> Dict[str, float]:
    """The configured scorer (DistilBERT when MODEL_PATH is a checkpoint, else the rules layer)."""
    return model.analyze_text(text)["categories"]


def score_deepseek(text: str) -> Dict[str, float]:
    """Placeholder for plan 4.1 -- a hosted scorer cannot run without the key."""
    raise SystemExit(
        "scorer 'deepseek' is plan 4.1 and needs DEEPSEEK_API_KEY as a repository secret; "
        "the rules layer and any shipped checkpoint are what run today"
    )


SCORERS: Dict[str, Callable[[str], Dict[str, float]]] = {
    "regex": score_regex,
    "model": score_model,
    "deepseek": score_deepseek,
}


def load_dataset(path: str = DATASET, limit_per_category: int = 0) -> List[dict]:
    if not os.path.exists(path):
        raise SystemExit(f"{path} missing; run python -m eval.generate first")
    rows = []
    counts: Dict[tuple, int] = {}
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            if limit_per_category:
                key = (row["lang"], row["category"], row["labels"][0])
                if counts.get(key, 0) >= limit_per_category:
                    continue
                counts[key] = counts.get(key, 0) + 1
            rows.append(row)
    return rows


def _ratio(num: int, den: int) -> float:
    return (num / den) if den else 0.0


def evaluate(rows: List[dict], score_fn: Callable[[str], Dict[str, float]],
             threshold: float) -> dict:
    """Per (language, category) precision/recall plus the flag-level rates.

    Each row is scored once and the probabilities reused: a hosted scorer costs
    money per call, and scoring per category would have been seven times the
    bill for the same number.
    """
    scored = [(row, score_fn(row["text"])) for row in rows]
    result = {"threshold": threshold, "langs": {}}
    for lang in LANGS:
        lang_rows = [(row, probs) for row, probs in scored if row["lang"] == lang]
        per_category = {}
        for category in HARMFUL_CATEGORIES:
            tp = fp = fn = support = 0
            for row, probs in lang_rows:
                predicted = probs.get(category, 0.0) >= threshold
                truth = category in row["labels"]
                if truth:
                    support += 1
                if truth and predicted:
                    tp += 1
                elif truth and not predicted:
                    fn += 1
                elif predicted and not truth:
                    fp += 1
            precision = _ratio(tp, tp + fp)
            recall = _ratio(tp, tp + fn)
            per_category[category] = {
                "support": support, "tp": tp, "fp": fp, "fn": fn,
                "precision": precision, "recall": recall,
                "f1": _ratio(2 * precision * recall, precision + recall),
            }

        def flagged(probs: Dict[str, float]) -> bool:
            return max(probs.get(c, 0.0) for c in HARMFUL_CATEGORIES) >= threshold

        unsafe = [(r, p) for r, p in lang_rows if r["labels"] != ["safe"]]
        safe = [(r, p) for r, p in lang_rows if r["labels"] == ["safe"]]
        hard = [(r, p) for r, p in safe if r.get("hard_negative_of")]
        flagged_unsafe = sum(1 for _r, p in unsafe if flagged(p))
        flagged_safe = sum(1 for _r, p in safe if flagged(p))
        flagged_hard = sum(1 for _r, p in hard if flagged(p))

        result["langs"][lang] = {
            "items": len(lang_rows),
            "per_category": per_category,
            "flag": {
                "unsafe_support": len(unsafe),
                "unsafe_flagged": flagged_unsafe,
                "unsafe_recall": _ratio(flagged_unsafe, len(unsafe)),
                "safe_support": len(safe),
                "safe_flagged": flagged_safe,
                "safe_false_positive_rate": _ratio(flagged_safe, len(safe)),
                "hard_support": len(hard),
                "hard_flagged": flagged_hard,
                "hard_false_positive_rate": _ratio(flagged_hard, len(hard)),
            },
        }
    return result


def render(result: dict, scorer: str, items: int) -> str:
    lines = [
        f"scorer: {scorer}  items: {items}  threshold: {result['threshold']:.2f}",
        "",
    ]
    for lang in LANGS:
        block = result["langs"][lang]
        lines.append(f"[{lang.upper()}]  {block['items']} items")
        lines.append(f"{'category':18}{'support':>8}{'precision':>11}{'recall':>9}{'f1':>8}")
        for category in HARMFUL_CATEGORIES:
            row = block["per_category"][category]
            lines.append(f"{category:18}{row['support']:8d}{row['precision']:11.2f}"
                         f"{row['recall']:9.2f}{row['f1']:8.2f}")
        flag = block["flag"]
        lines.append(
            f"{'flagged (any)':18}{flag['unsafe_support']:8d}"
            f"{'-':>11}{flag['unsafe_recall']:9.2f}"
            f"    safe FP {flag['safe_false_positive_rate']:.2f}"
            f" (hard-negative FP {flag['hard_false_positive_rate']:.2f})"
        )
        lines.append("")
    return "\n".join(lines)


def render_markdown(result: dict, scorer: str, items: int, dataset_note: str) -> str:
    lines = [
        f"_Generated by `python -m eval.run_eval --scorer {scorer} --write-md EVAL.md` "
        f"on {datetime.date.today().isoformat()}. {items} items, threshold "
        f"{result['threshold']:.2f}, {dataset_note}._",
        "",
        "| lang | category | support | precision | recall | f1 |",
        "|---|---|---|---|---|---|",
    ]
    for lang in LANGS:
        block = result["langs"][lang]
        for category in HARMFUL_CATEGORIES:
            row = block["per_category"][category]
            lines.append(f"| {lang} | {category} | {row['support']} | {row['precision']:.2f} "
                         f"| {row['recall']:.2f} | {row['f1']:.2f} |")
        flag = block["flag"]
        lines.append(f"| {lang} | **flagged (any category)** | {flag['unsafe_support']} | - "
                     f"| {flag['unsafe_recall']:.2f} | - |")
        lines.append(f"| {lang} | _safe rows false-positive rate_ | {flag['safe_support']} | - "
                     f"| - | {flag['safe_false_positive_rate']:.2f} |")
    return "\n".join(lines)


def write_markdown(path: str, table: str) -> None:
    """Replace the table between the markers, creating the file if absent."""
    block = f"{TABLE_BEGIN}\n{table}\n{TABLE_END}"
    if os.path.exists(path):
        with open(path, encoding="utf-8") as handle:
            existing = handle.read()
        if TABLE_BEGIN in existing and TABLE_END in existing:
            head, _, rest = existing.partition(TABLE_BEGIN)
            _, _, tail = rest.partition(TABLE_END)
            existing = f"{head}{block}{tail}"
        else:
            existing = existing.rstrip("\n") + "\n\n" + block + "\n"
    else:
        existing = f"# Evaluation results\n\n{block}\n"
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(existing)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Score the evaluation dataset.")
    parser.add_argument("--scorer", choices=sorted(SCORERS), default="regex")
    parser.add_argument("--dataset", default=DATASET)
    parser.add_argument("--threshold", type=float, default=0.5)
    parser.add_argument("--limit-per-category", type=int, default=0)
    parser.add_argument("--json", dest="json_out", default="")
    parser.add_argument("--write-md", dest="md_out", default="")
    parser.add_argument("--fail-under-recall", type=float, default=None)
    parser.add_argument("--fail-under-precision", type=float, default=None)
    parser.add_argument("--gate-categories", default="self_harm,grooming",
                        help="categories the --fail-under-* thresholds apply to")
    args = parser.parse_args(argv)

    score_fn = SCORERS[args.scorer]
    rows = load_dataset(args.dataset, args.limit_per_category)
    result = evaluate(rows, score_fn, args.threshold)
    print(render(result, args.scorer, len(rows)))

    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(result, handle, indent=2, sort_keys=True)
            handle.write("\n")
        print(f"wrote {args.json_out}")

    if args.md_out:
        note = f"dataset `{os.path.relpath(args.dataset).replace(os.sep, '/')}`"
        write_markdown(args.md_out, render_markdown(result, args.scorer, len(rows), note))
        print(f"updated the table in {args.md_out}")

    if args.fail_under_recall is not None or args.fail_under_precision is not None:
        gate = [c.strip() for c in args.gate_categories.split(",") if c.strip()]
        failures = []
        for lang in LANGS:
            for category in gate:
                row = result["langs"][lang]["per_category"][category]
                if args.fail_under_recall is not None and row["recall"] < args.fail_under_recall:
                    failures.append(f"{lang}/{category}: recall {row['recall']:.2f} "
                                    f"< {args.fail_under_recall:.2f}")
                if args.fail_under_precision is not None and row["precision"] < args.fail_under_precision:
                    failures.append(f"{lang}/{category}: precision {row['precision']:.2f} "
                                    f"< {args.fail_under_precision:.2f}")
        if failures:
            print("GATE FAILED")
            for failure in failures:
                print(f"  - {failure}")
            return 1
        print("gate passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
