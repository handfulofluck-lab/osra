"""Score JSONL rows with DeepSeek and write the row log (#918).

    DEEPSEEK_API_KEY=... python -m eval.deepseek_rows --input rows.jsonl --output rows.scored.jsonl

Why this exists next to `run_eval.py`: `run_eval` answers "how good is the scorer" with recall per
category, and throws the individual answers away. #918 needs the opposite — one line per row, in a
shape the Bedrock runs can be diffed against row by row:

    {"id","text","probs":{8 categories},"refused","latency_ms","tokens_in","tokens_out"}

**Resume is the output file, not a cache.** Each line is written and flushed as soon as the row is
scored, and a re-run skips every id already in the output. That is the only resume that survives a
kill -9, and it keeps this tool's token counts honest: a cache hit would otherwise write zeros for a
row that was actually billed in an earlier run, and the totals would understate what was spent. The
scorer is therefore built with its disk cache off here.

**The policy guard is in code, not in a reviewer's head.** #918's data rules allow hate, bullying,
violence and safe rows and forbid grooming, sexual and self-harm rows outright. A row whose labels
fall outside the allowed set is skipped and counted — never sent — because "we only passed the right
files" is an assumption that one wrong path silently breaks.

**Cost is an upper bound.** DeepSeek bills input at a cache-miss rate and a cheaper cache-hit rate,
and both depend on whether the call lands in peak hours. A run cannot know how much of its prompt was
a cache hit, so this reports the all-cache-miss figure and says so. It is an over-estimate, never an
under-estimate.

Prices and the peak windows are from <https://api-docs.deepseek.com/quick_start/pricing>, read
18 November 2026, for `deepseek-flash` (DeepSeek-V4.1-Flash-1017).
"""

import argparse
import datetime
import json
import os
import sys
import time
from typing import Any, Dict, Iterable, List, Optional, Tuple

from eval.deepseek_scorer import DeepSeekScorer, DeepSeekUnavailable
from eval.prompt import REFUSED_KEY

CATEGORIES_FOR_LOG = (
    "cyberbullying",
    "self_harm",
    "grooming",
    "violence",
    "sexual_content",
    "substance_use",
    "hate_speech",
    "safe",
)

#: #918's data rules, as a filter. A label outside this set means the row may not be sent at all.
POLICY_ALLOWED = frozenset({"cyberbullying", "hate_speech", "violence", "safe"})

#: US$ per 1M tokens, `deepseek-flash`, from the pricing page (18 Nov 2026). Cache-miss input and
#: output only: a run cannot know its cache-hit share, so the cost it reports is an upper bound.
PRICE_IN = {"peak": 0.30, "off_peak": 0.15}
PRICE_OUT = {"peak": 1.20, "off_peak": 0.60}

#: Peak hours are 01:00-04:00 and 06:00-10:00 UTC, Monday-Friday. Chinese public holidays are also
#: off-peak upstream and are not modelled here, so a run on one of those days over-states its cost.
PEAK_HOURS = ((1, 4), (6, 10))


def is_peak(now: datetime.datetime) -> bool:
    """Whether `now` falls in a published peak window — weekdays 01:00-04:00 and 06:00-10:00 UTC."""
    if now.weekday() >= 5:  # Saturday, Sunday
        return False
    return any(start <= now.hour < end for start, end in PEAK_HOURS)


def price_period(now: datetime.datetime) -> str:
    return "peak" if is_peak(now) else "off_peak"


def load_scored_ids(path: str) -> set:
    """Ids already in the output. A half-written last line is ignored rather than fatal: a run that
    was killed mid-write must resume from the line before it, not refuse to start."""
    if not os.path.exists(path):
        return set()
    ids = set()
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if isinstance(row, dict) and isinstance(row.get("id"), str):
                ids.add(row["id"])
    return ids


def read_rows(path: str) -> List[dict]:
    """Every row in the JSONL, with the field this tool needs checked here rather than 30 rows in."""
    rows: List[dict] = []
    with open(path, encoding="utf-8") as handle:
        for number, line in enumerate(handle, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except ValueError as exc:
                raise SystemExit(f"{path}:{number}: not JSON ({exc})") from None
            if not isinstance(row, dict):
                raise SystemExit(f"{path}:{number}: a row must be a JSON object")
            if not isinstance(row.get("id"), str) or not row["id"]:
                raise SystemExit(f"{path}:{number}: missing a string `id`")
            if not isinstance(row.get("text"), str) or not row["text"].strip():
                raise SystemExit(f"{path}:{number}: row {row['id']!r} has no `text`")
            rows.append(row)
    return rows


def labels_of(row: dict) -> List[str]:
    """The row's labels, tolerant of the two shapes the banks use (`labels` list, `category` string)."""
    labels = row.get("labels")
    if isinstance(labels, list) and labels:
        return [str(label) for label in labels]
    category = row.get("category")
    return [str(category)] if category else []


def policy_refusal(row: dict) -> Optional[str]:
    """Why this row may not be sent, or None when it may. Empty labels are refused too: an unlabelled
    row cannot be shown to be inside the allowed set, and "probably fine" is not one of the rules."""
    labels = labels_of(row)
    if not labels:
        return "no labels"
    outside = sorted(set(labels) - POLICY_ALLOWED)
    if outside:
        return "labels outside the allowed set: " + ", ".join(outside)
    return None


def entry_for(
    row: dict,
    probs: Dict[str, float],
    latency_ms: int = 0,
    tokens_in: int = 0,
    tokens_out: int = 0,
) -> Dict[str, Any]:
    """One row-log line. `_refused` is the parser's marker, not a category, so it becomes a boolean and
    the probabilities keep exactly the eight categories a comparison needs."""
    return {
        "id": row["id"],
        "text": row["text"],
        "probs": {category: round(float(probs.get(category, 0.0)), 6) for category in CATEGORIES_FOR_LOG},
        "refused": bool(probs.get(REFUSED_KEY)),
        "latency_ms": latency_ms,
        "tokens_in": tokens_in,
        "tokens_out": tokens_out,
    }


def score_rows(
    rows: Iterable[dict],
    scorer: DeepSeekScorer,
    output_path: str,
    resume: bool = True,
    delay_seconds: float = 0.0,
    sleep=time.sleep,
    log=None,
) -> Dict[str, Any]:
    """Score every row that policy allows and the output file does not already have.

    Returns the run summary. The output is appended line by line and flushed, so an interrupted run
    loses at most the row that was in flight.
    """
    already = load_scored_ids(output_path) if resume else set()
    written = 0
    resumed = 0
    skipped = 0
    sendable = 0
    started = time.monotonic()
    with open(output_path, "a", encoding="utf-8", newline="\n") as out:
        for row in rows:
            if row["id"] in already:
                resumed += 1
                continue
            reason = policy_refusal(row)
            if reason is not None:
                skipped += 1
                if log:
                    log(f"[deepseek-rows] skipped {row['id']}: {reason}")
                continue
            if sendable and delay_seconds:
                sleep(delay_seconds)
            probs = scorer(row["text"])
            sendable += 1
            entry = entry_for(
                row,
                probs,
                latency_ms=scorer.last_latency_ms,
                tokens_in=scorer.last_tokens_in,
                tokens_out=scorer.last_tokens_out,
            )
            out.write(json.dumps(entry, ensure_ascii=False, sort_keys=True) + "\n")
            out.flush()
            written += 1
            if log and written % 50 == 0:
                log(f"[deepseek-rows] {written} written · {scorer.calls} calls")

    now = datetime.datetime.now(datetime.timezone.utc)
    period = price_period(now)
    usage = scorer.usage()
    usd = (usage["input_tokens"] * PRICE_IN[period] + usage["output_tokens"] * PRICE_OUT[period]) / 1e6
    return {
        "output": output_path,
        "rows_in_file": written + resumed + skipped,
        "written": written,
        "resumed": resumed,
        "skipped_by_policy": skipped,
        "wall_seconds": round(time.monotonic() - started, 1),
        "usage": usage,
        "cost": {
            "price_period_at_end": period,
            "usd_upper_bound": round(usd, 4),
            "note": "cache-miss input and output rates only: the cache-hit share is unknown to a run",
        },
    }


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Score JSONL rows with DeepSeek and write the row log (#918).")
    parser.add_argument("--input", required=True, help="JSONL rows: {id, lang, text, labels}")
    parser.add_argument("--output", required=True, help="row-log JSONL; also the resume record")
    parser.add_argument("--model", default=None, help="API id; defaults to deepseek-flash")
    parser.add_argument(
        "--thinking",
        action="store_true",
        help="leave the model's thinking mode on (the service then ignores --temperature; not the "
        "same comparison, so state it wherever the numbers are quoted)",
    )
    parser.add_argument("--delay-seconds", type=float, default=0.2, help="pause between calls")
    parser.add_argument("--limit", type=int, default=0, help="stop after N rows to score (0: all)")
    parser.add_argument("--no-resume", action="store_true", help="re-score ids already in the output")
    args = parser.parse_args(argv)

    rows = read_rows(args.input)
    if args.limit:
        rows = rows[: args.limit]
    try:
        scorer = DeepSeekScorer(
            model=args.model,
            thinking=args.thinking,
            cache_path=None,  # the output file is the resume; a cache would write zeros for billed rows
        )
    except DeepSeekUnavailable as exc:
        raise SystemExit(f"deepseek scorer unavailable: {exc}") from None

    try:
        summary = score_rows(
            rows,
            scorer,
            args.output,
            resume=not args.no_resume,
            delay_seconds=args.delay_seconds,
            log=lambda message: print(message, file=sys.stderr, flush=True),
        )
    except DeepSeekUnavailable as exc:
        raise SystemExit(f"stopped by the service: {exc}") from None
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":  # pragma: no cover - the module is what the tests call
    raise SystemExit(main())
