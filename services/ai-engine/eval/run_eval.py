"""Score the evaluation dataset and print precision/recall per category and language.

    python -m eval.run_eval                      # regex rules layer, 0.50 threshold
    python -m eval.run_eval --scorer model       # DistilBERT, if MODEL_PATH is set
    python -m eval.run_eval --split test         # the held-out half of the template split
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
from eval.prompt import REFUSED_KEY
from eval.split import SPLITS

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
    """The hosted scorer from plan 4.1, evaluation only (`eval/deepseek_scorer.py`).

    Imported lazily so the rules layer and the rest of the harness keep working without `httpx`, a key,
    or a network — and so `--scorer regex` can never accidentally reach a paid API. A missing key is a
    `DeepSeekUnavailable`, which `main` turns into a one-line refusal rather than a traceback.
    """
    from eval.deepseek_scorer import default_scorer

    return default_scorer()(text)


def score_bedrock(text: str) -> Dict[str, float]:
    """A candidate production model on Amazon Bedrock inside the EU (ADR-0033, `eval/bedrock_scorer.py`).

    Lazy for the same reason as DeepSeek: boto3, AWS credentials and a network are needed only here.
    """
    from eval.bedrock_scorer import default_scorer

    return default_scorer()(text)


SCORERS: Dict[str, Callable[[str], Dict[str, float]]] = {
    "regex": score_regex,
    "model": score_model,
    "deepseek": score_deepseek,
    "bedrock": score_bedrock,
}


def filter_rows(rows: List[dict], split: str = "all") -> List[dict]:
    """Rows on one side of the template split; `all` is the whole set, unchanged.

    The side is read from provenance, where `eval.generate` recorded it at build time, rather than
    recomputed here: one implementation of the rule, and a stale dataset that disagrees with it is the
    failing test, not a second opinion. Filtering before `--limit-per-category` means the limit counts
    the rows that will actually be scored.
    """
    if split == "all":
        return rows
    if split not in SPLITS:
        raise SystemExit(f"unknown split {split!r}; expected all, {', '.join(SPLITS)}")
    missing = [row["id"] for row in rows if row.get("provenance", {}).get("split") not in SPLITS]
    if missing:
        raise SystemExit(
            f"{len(missing)} row(s) carry no dev/test split (first: {missing[0]}); "
            f"run python -m eval.generate to regenerate the dataset"
        )
    return [row for row in rows if row["provenance"]["split"] == split]


def load_dataset(path: str = DATASET, limit_per_category: int = 0,
                 split: str = "all") -> List[dict]:
    if not os.path.exists(path):
        raise SystemExit(f"{path} missing; run python -m eval.generate first")
    rows = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            rows.append(json.loads(line))
    rows = filter_rows(rows, split)
    if limit_per_category:
        counts: Dict[tuple, int] = {}
        limited = []
        for row in rows:
            key = (row["lang"], row["category"], row["labels"][0])
            if counts.get(key, 0) >= limit_per_category:
                continue
            counts[key] = counts.get(key, 0) + 1
            limited.append(row)
        rows = limited
    return rows


def _ratio(num: int, den: int):
    """A rate, or None when the denominator is zero.

    None rather than 0.0: "Arabic precision 0.00" reads as "every flag was wrong", when the scorer in
    fact flagged nothing at all and precision is undefined. The table prints `n/a` for None (#262 review).
    """
    return (num / den) if den else None


def _fmt(value) -> str:
    return "n/a" if value is None else f"{value:.2f}"


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
            f1 = (2 * precision * recall / (precision + recall)
                  if precision is not None and recall is not None and (precision + recall) else None)
            per_category[category] = {
                "support": support, "tp": tp, "fp": fp, "fn": fn,
                "precision": precision, "recall": recall, "f1": f1,
            }

        def flagged(probs: Dict[str, float]) -> bool:
            return max(probs.get(c, 0.0) for c in HARMFUL_CATEGORIES) >= threshold

        unsafe = [(r, p) for r, p in lang_rows if r["labels"] != ["safe"]]
        safe = [(r, p) for r, p in lang_rows if r["labels"] == ["safe"]]
        hard = [(r, p) for r, p in safe if r.get("hard_negative_of")]
        flagged_unsafe = sum(1 for _r, p in unsafe if flagged(p))
        flagged_safe = sum(1 for _r, p in safe if flagged(p))
        flagged_hard = sum(1 for _r, p in hard if flagged(p))
        # A hosted scorer marks the rows it scored as flagged because the model refused or answered
        # unreadably (ADR-0033): they count as flags above, and here, so a reader can see how many.
        refused = sum(1 for _r, p in lang_rows if p.get(REFUSED_KEY))

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
                "refused_or_unreadable": refused,
            },
        }
    return result


def render(result: dict, scorer: str, items: int) -> str:
    lines = [
        f"scorer: {scorer}  split: {result.get('split', 'all')}  items: {items}  "
        f"threshold: {result['threshold']:.2f}",
        "",
    ]
    for lang in LANGS:
        block = result["langs"][lang]
        lines.append(f"[{lang.upper()}]  {block['items']} items")
        lines.append(f"{'category':18}{'support':>8}{'precision':>11}{'recall':>9}{'f1':>8}")
        for category in HARMFUL_CATEGORIES:
            row = block["per_category"][category]
            lines.append(f"{category:18}{row['support']:8d}{_fmt(row['precision']):>11}"
                         f"{_fmt(row['recall']):>9}{_fmt(row['f1']):>8}")
        flag = block["flag"]
        lines.append(
            f"{'flagged (any)':18}{flag['unsafe_support']:8d}"
            f"{'-':>11}{_fmt(flag['unsafe_recall']):>9}"
            f"    safe FP {_fmt(flag['safe_false_positive_rate'])}"
            f" (hard-negative FP {_fmt(flag['hard_false_positive_rate'])})"
        )
        lines.append("")
    return "\n".join(lines)


def render_markdown(result: dict, scorer: str, items: int, dataset_note: str) -> str:
    lines = [
        f"_Generated by `python -m eval.run_eval --scorer {scorer} --write-md EVAL.md` "
        f"on {datetime.date.today().isoformat()}. {items} items, split "
        f"`{result.get('split', 'all')}`, threshold "
        f"{result['threshold']:.2f}, {dataset_note}._",
        "",
        "| lang | category | support | precision | recall | f1 |",
        "|---|---|---|---|---|---|",
    ]
    for lang in LANGS:
        block = result["langs"][lang]
        for category in HARMFUL_CATEGORIES:
            row = block["per_category"][category]
            lines.append(f"| {lang} | {category} | {row['support']} | {_fmt(row['precision'])} "
                         f"| {_fmt(row['recall'])} | {_fmt(row['f1'])} |")
        flag = block["flag"]
        lines.append(f"| {lang} | **flagged (any category)** | {flag['unsafe_support']} | - "
                     f"| {_fmt(flag['unsafe_recall'])} | - |")
        lines.append(f"| {lang} | _safe rows false-positive rate_ | {flag['safe_support']} | - "
                     f"| - | {_fmt(flag['safe_false_positive_rate'])} |")
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
    parser.add_argument("--split", choices=("all",) + SPLITS, default="all",
                        help="score every row (all, the default) or one side of the template split")
    parser.add_argument("--json", dest="json_out", default="")
    parser.add_argument("--write-md", dest="md_out", default="")
    parser.add_argument("--fail-under-recall", type=float, default=None)
    parser.add_argument("--fail-under-precision", type=float, default=None)
    parser.add_argument("--gate-categories", default="self_harm,grooming",
                        help="categories the --fail-under-* thresholds apply to")
    parser.add_argument("--fail-over-hard-fp", type=float, default=None,
                        help="fail when either language flags more than this share of hard negatives "
                             "(ADR-0033 uses 0.05)")
    args = parser.parse_args(argv)

    score_fn = SCORERS[args.scorer]
    rows = load_dataset(args.dataset, args.limit_per_category, args.split)
    try:
        result = evaluate(rows, score_fn, args.threshold)
    except Exception as exc:  # *Unavailable, or a transport error that survived the retries
        if args.scorer == "deepseek":
            from eval.deepseek_scorer import DeepSeekUnavailable

            if isinstance(exc, DeepSeekUnavailable):
                # One line, no traceback: a missing key or a refused key is an operator problem, and the
                # message says which. The rows already scored are in the cache and were paid for.
                raise SystemExit(f"deepseek scorer unavailable: {exc}") from None
        if args.scorer == "bedrock":
            from eval.bedrock_scorer import BedrockUnavailable

            if isinstance(exc, BedrockUnavailable):
                raise SystemExit(f"bedrock scorer unavailable: {exc}") from None
        raise
    result["split"] = args.split
    if args.scorer == "bedrock":
        from eval.bedrock_scorer import default_scorer

        result["usage"] = default_scorer().usage()
    print(render(result, args.scorer, len(rows)))
    if "usage" in result:
        print("usage: " + json.dumps(result["usage"], sort_keys=True))

    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(result, handle, indent=2, sort_keys=True)
            handle.write("\n")
        print(f"wrote {args.json_out}")

    if args.md_out:
        note = f"dataset `{os.path.relpath(args.dataset).replace(os.sep, '/')}`"
        write_markdown(args.md_out, render_markdown(result, args.scorer, len(rows), note))
        print(f"updated the table in {args.md_out}")

    gating = (args.fail_under_recall is not None or args.fail_under_precision is not None
              or args.fail_over_hard_fp is not None)
    if gating:
        gate = [c.strip() for c in args.gate_categories.split(",") if c.strip()]
        failures = []
        if args.fail_over_hard_fp is not None:
            for lang in LANGS:
                rate = result["langs"][lang]["flag"]["hard_false_positive_rate"]
                if rate is not None and rate > args.fail_over_hard_fp:
                    failures.append(f"{lang}: hard-negative false-positive rate {rate:.2f} "
                                    f"> {args.fail_over_hard_fp:.2f}")
        for lang in LANGS:
            for category in gate:
                row = result["langs"][lang]["per_category"][category]
                if args.fail_under_recall is not None:
                    if row["recall"] is None:
                        failures.append(f"{lang}/{category}: recall undefined (nothing flagged)")
                    elif row["recall"] < args.fail_under_recall:
                        failures.append(f"{lang}/{category}: recall {row['recall']:.2f} "
                                        f"< {args.fail_under_recall:.2f}")
                if args.fail_under_precision is not None:
                    if row["precision"] is None:
                        failures.append(f"{lang}/{category}: precision undefined (nothing flagged)")
                    elif row["precision"] < args.fail_under_precision:
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
