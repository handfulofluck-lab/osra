"""Manifest and gate checks for an own-model language pool (issue #617 units, e.g. tr / id / ms).

The pool itself never leaves the machine: this module reads local JSONL shards under ``catsets/`` and
prints counts and digests. The 17-field shape is the one the delivered `ar` pool uses, so a row here can
join the judge output on ``text_sha256`` without a translation step:

    id, lang, script, variety, text, label, category, pair_id, kind,
    age_band, platform, tone, writer_model, source_batch, source_file,
    source_sha256, text_sha256

Two gates are checked here because they are cheap and local:

* **shape** — every row has the 17 fields, the right ``lang``, a non-empty ``text``, and a
  ``text_sha256`` that actually matches the text.
* **exact duplicates** — two rows with the same ``text_sha256`` are a duplicate, full stop, and that
  holds across shards: the pool is the set of shards, not one file at a time.

The *near*-duplicate gate (the pinned ``k31_dupclasses.py``) is deliberately **not** re-implemented: a
second copy of a pinned validator is how two runs come to disagree. Pass ``--dupclasses`` a path to the
pinned script and this module will invoke it and fold its verdict into the manifest.

Usage::

    python services/ai-engine/pool_manifest.py --input ../catsets/tr --lang tr \\
        --dupclasses ../catsets/k31_dupclasses.pinned-v1.py --out /tmp/manifest-tr.json

The manifest carries counts, per-file sha256 and one set digest. It never carries a row.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

FIELDS: tuple[str, ...] = (
    "id",
    "lang",
    "script",
    "variety",
    "text",
    "label",
    "category",
    "pair_id",
    "kind",
    "age_band",
    "platform",
    "tone",
    "writer_model",
    "source_batch",
    "source_file",
    "source_sha256",
    "text_sha256",
)

# Brief v3 harm categories, plus "none" for an unpaired safe sentence (pair_id null, kind lookalike/plain).
CATEGORIES: frozenset[str] = frozenset(
    {
        "cyberbullying",
        "hate_speech",
        "violence",
        "self_harm",
        "grooming",
        "sexual_content",
        "substance_use",
        "scam",
        "extremism",
        "dangerous_challenges",
        "none",
    }
)
LABELS = frozenset({"harmful", "safe"})
# Observed on the delivered `ar` pool (200-row sample): a harmful row carries kind "harmful", a paired safe
# row carries "lookalike", and an unpaired safe carries "plain" (Antigravity, #50 21:15). Encoded from the
# data rather than from a guess: my first version assumed plain/lookalike only and refused half the pool.
KINDS = frozenset({"harmful", "lookalike", "plain"})


def text_sha256(text: str) -> str:
    """The join key the judge output uses; plain SHA-256 over the UTF-8 text, no normalisation."""
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


@dataclass
class ShardReport:
    path: str
    sha256: str
    lines: int = 0
    valid: int = 0
    duplicates: int = 0
    failures: list[str] = field(default_factory=list)

    def as_json(self) -> dict:
        return {
            "path": self.path,
            "sha256": self.sha256,
            "lines": self.lines,
            "valid": self.valid,
            "duplicates": self.duplicates,
            "failures": len(self.failures),
        }


def check_row(row: dict, lang: str) -> str | None:
    """Return a short reason the row is unusable, or None. Never includes row text: line numbers only."""
    missing = [f for f in FIELDS if f not in row]
    if missing:
        return f"missing fields: {','.join(missing)}"
    if row["lang"] != lang:
        return f"lang is {row['lang']!r}, expected {lang!r}"
    if not isinstance(row["text"], str) or not row["text"].strip():
        return "text is empty"
    # A JSON row can carry a list or an object where a string belongs, and `x in frozenset` raises
    # TypeError for it: the scanner would die and lose every later line of the shard (Neon, #1093).
    for name in ("label", "category", "kind", "text_sha256"):
        if not isinstance(row[name], str):
            return f"{name} is not a string"
    if row["pair_id"] is not None and not isinstance(row["pair_id"], str):
        return "pair_id must be a string or null"
    if row["label"] not in LABELS:
        return f"label {row['label']!r} is not one of {sorted(LABELS)}"
    if row["category"] not in CATEGORIES:
        return f"category {row['category']!r} is not a Brief v3 category"
    if row["kind"] not in KINDS:
        return f"kind {row['kind']!r} is not one of {sorted(KINDS)}"
    if row["label"] == "harmful" and row["kind"] != "harmful":
        return f"a harmful row must carry kind 'harmful', not {row['kind']!r}"
    if row["label"] == "harmful" and row["category"] == "none":
        return "a harmful row needs a Brief v3 harm category, not 'none'"
    if row["label"] == "safe" and row["kind"] not in {"lookalike", "plain"}:
        return f"a safe row must be kind 'lookalike' or 'plain', not {row['kind']!r}"
    unpaired = row["kind"] == "plain"
    if unpaired and row["pair_id"] is not None:
        return "kind 'plain' means unpaired, so pair_id must be null"
    if not unpaired and row["pair_id"] is None:
        return "kind harmful/lookalike is paired, so pair_id must be set"
    if not unpaired and not row["pair_id"].strip():
        return "kind harmful/lookalike is paired, so pair_id must be non-empty"
    if unpaired and row["category"] != "none":
        return "an unpaired safe row must carry category 'none'"
    if row["text_sha256"] != text_sha256(row["text"]):
        return "text_sha256 does not match the text"
    return None


def scan_shard(path: Path, lang: str, seen: set[str] | None = None) -> ShardReport:
    """Scan one shard. [seen] is shared by every shard of a run, so a duplicate that lands in two files
    is still a duplicate; a per-shard set reported `duplicates: 0` for a pool that was half copies.

    On its own (no [seen] passed) it keeps a private set, which is what a single-file caller wants.
    """
    raw = path.read_bytes()
    report = ShardReport(path=str(path), sha256=hashlib.sha256(raw).hexdigest())
    if seen is None:
        seen = set()
    for number, line in enumerate(raw.decode("utf-8").splitlines(), start=1):
        if not line.strip():
            continue
        report.lines += 1
        try:
            row = json.loads(line)
        except json.JSONDecodeError as exc:
            report.failures.append(f"line {number}: not JSON ({exc.msg})")
            continue
        if not isinstance(row, dict):
            report.failures.append(f"line {number}: not an object")
            continue
        reason = check_row(row, lang)
        if reason:
            report.failures.append(f"line {number}: {reason}")
            continue
        report.valid += 1
        digest = row["text_sha256"]
        if digest in seen:
            report.duplicates += 1
        else:
            seen.add(digest)
    return report


def run_dupclasses(script: Path, shards: list[Path]) -> dict:
    """Invoke the pinned validator rather than re-implementing it.

    A missing script, a non-zero exit or unparsable output is reported as ``status`` instead of being
    swallowed: a gate that silently did not run is worse than a gate that failed.
    """
    cmd = [sys.executable, str(script), *[str(s) for s in shards]]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=1800, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {"status": "error", "detail": str(exc)}
    out = proc.stdout.strip()
    try:
        parsed = json.loads(out.splitlines()[-1]) if out else {}
    except json.JSONDecodeError:
        parsed = {"raw_tail": out.splitlines()[-3:] if out else []}
    # `parsed` may be a list, and a script that prints `{"status": "ok"}` and exits 1 must not be able to
    # overwrite the exit code it actually returned (Neon, #1093).
    result = dict(parsed) if isinstance(parsed, dict) else {"output": parsed}
    result["status"] = "ok" if proc.returncode == 0 else f"exit {proc.returncode}"
    return result


def build_manifest(inputs: list[Path], lang: str, dupclasses: Path | None = None) -> dict:
    shards: list[Path] = []
    for item in inputs:
        if item.is_dir():
            shards.extend(sorted(p for p in item.rglob("*.jsonl")))
        elif item.suffix == ".jsonl":
            shards.append(item)
    seen: set[str] = set()
    reports = [scan_shard(p, lang, seen) for p in shards]
    valid = sum(r.valid for r in reports)
    duplicates = sum(r.duplicates for r in reports)
    totals = {
        "lines": sum(r.lines for r in reports),
        "valid": valid,
        "unique": valid - duplicates,
        "duplicates": duplicates,
        "failures": sum(len(r.failures) for r in reports),
    }
    set_digest = hashlib.sha256("\n".join(f"{r.path}:{r.sha256}" for r in reports).encode()).hexdigest()
    manifest = {
        "lang": lang,
        "units": {lang: totals["valid"]},
        "shards": [r.as_json() for r in reports],
        "totals": totals,
        "set_digest": set_digest,
        "failures": [f"{r.path} {f}" for r in reports for f in r.failures[:20]],
    }
    if dupclasses is not None:
        manifest["dupclasses"] = {"script": str(dupclasses), **run_dupclasses(dupclasses, shards)}
    return manifest


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Manifest and gates for an own-model language pool.")
    parser.add_argument("--input", action="append", required=True, help="directory or .jsonl shard (repeatable)")
    parser.add_argument("--lang", required=True, help="expected lang value, e.g. tr")
    parser.add_argument("--dupclasses", help="path to the pinned k31_dupclasses.py")
    parser.add_argument("--out", help="write the manifest here instead of stdout")
    args = parser.parse_args(argv)

    manifest = build_manifest(
        [Path(p) for p in args.input],
        args.lang,
        Path(args.dupclasses) if args.dupclasses else None,
    )
    if not manifest["shards"]:
        # An empty run is not a pass: a typo in --input used to print 0/0 valid and exit 0.
        print("no .jsonl shard matched --input; refusing to report an empty run as a pass", file=sys.stderr)
        return 1
    text = json.dumps(manifest, indent=2, ensure_ascii=False)
    if args.out:
        Path(args.out).write_text(text + "\n", encoding="utf-8")
        print(
            f"{args.out}: {manifest['totals']['valid']}/{manifest['totals']['lines']} valid, "
            f"{manifest['totals']['duplicates']} duplicates, set {manifest['set_digest'][:16]}"
        )
    else:
        print(text)
    if manifest["totals"]["failures"]:
        return 1
    dupclasses = manifest.get("dupclasses")
    if dupclasses is not None and dupclasses.get("status") != "ok":
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
