"""Offline v9b adapter: the smallest contract that makes the trained model's own output the answer.

Why this module exists at all: `model.py` in this service is an eight-category, **positional** DistilBERT
path that merges rule scores into the model's numbers (`_merge_model_and_rules`) and silently degrades to
rules when the checkpoint is unreadable (`model.py:174`, `_fallback_probabilities`). A v9b row scored through
that path is not the v9b model's verdict. This adapter is deliberately separate and deliberately narrow: it
loads one checkpoint, verifies what it actually is, and scores text. It does not import the rules, does not
merge anything, and has no HTTP surface yet.

Contract (K31, 22 Nov 2026, sketched on #50):

  * the label set is the seven names the parity receipt verified, in that order, and the checkpoint's own
    `id2label` must agree element for element or the load fails;
  * one threshold per label, from a file whose digest is checked before it is applied;
  * no fallback: missing weights, a wrong config, a bad tokenizer or an unreadable text raise
    `AdapterUnavailable` — never a rules score, never a low-probability "safe";
  * the digests that produced a result travel with it.

The heavy imports (torch, transformers) are inside `load`, so the pure decision helpers and their tests run
on a machine with neither, which is what keeps the offline test suite fast.
"""
from __future__ import annotations

import hashlib
import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Mapping, Sequence

#: The seven categories, in the order the frozen predictions use. This tuple is the contract: every other
#: module reads it instead of spelling the names again, so a reordered checkpoint is caught here and nowhere
#: else has to care.
LABELS: tuple[str, ...] = (
    "cyberbullying",
    "self_harm",
    "grooming",
    "violence",
    "sexual_content",
    "substance_use",
    "hate_speech",
)


class AdapterUnavailable(RuntimeError):
    """The adapter cannot answer honestly: bad or missing artefacts, or no text to score.

    Raising this is the whole "no fallback" rule. A caller may serve nothing, retry, or fail loudly; it may
    not invent a verdict, and this module gives it nothing to invent one from.
    """


@dataclass(frozen=True)
class Scored:
    """One scored text. `probs` has exactly :data:`LABELS` as its keys, in that order."""

    probs: dict[str, float]
    flagged_categories: tuple[str, ...]
    verdict: str
    model_sha256: str
    thresholds_sha256: str

    def to_dict(self) -> dict:
        return {
            "probs": dict(self.probs),
            "flagged_categories": list(self.flagged_categories),
            "verdict": self.verdict,
            "model_sha256": self.model_sha256,
            "thresholds_sha256": self.thresholds_sha256,
        }


#: The files a v9b checkpoint is made of. A manifest pins all of them, not just the weights: a tokenizer swap
#: changes every score while the weights are untouched, and a config edit can reorder `id2label`.
MANIFEST_FILES: tuple[str, ...] = (
    "model.safetensors",
    "config.json",
    "tokenizer.json",
    "tokenizer_config.json",
    "sentencepiece.bpe.model",
    "special_tokens_map.json",
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def manifest_of(model_dir: Path) -> dict[str, str]:
    """The digests of every file a v9b checkpoint is made of, for pinning in a receipt or a test."""
    model_dir = Path(model_dir)
    missing = [name for name in MANIFEST_FILES if not (model_dir / name).is_file()]
    if missing:
        raise AdapterUnavailable(f"checkpoint is missing {missing}")
    return {name: sha256_file(model_dir / name) for name in MANIFEST_FILES}


def verify_manifest(model_dir: Path, expected: Mapping[str, str]) -> dict[str, str]:
    """Require every named file to match its pinned digest, and require the pin to cover the whole set.

    A partial pin is not a pin: pinning only the weights leaves the tokenizer and the config free to change
    under a receipt that still says the same thing.
    """
    missing_pins = [name for name in MANIFEST_FILES if name not in expected]
    if missing_pins:
        raise AdapterUnavailable(f"manifest does not pin {missing_pins}")
    actual = manifest_of(model_dir)
    mismatched = [name for name in MANIFEST_FILES if actual[name] != expected[name]]
    if mismatched:
        raise AdapterUnavailable(
            "checkpoint digests do not match the pin: "
            + ", ".join(f"{name} {actual[name]} != {expected[name]}" for name in mismatched)
        )
    return actual


def verify_labels(id2label: Mapping[str | int, str]) -> None:
    """Require the checkpoint's own label map to equal :data:`LABELS`, in order.

    A positional read of seven probabilities is only correct if the positions are the ones we think they are.
    A checkpoint whose `id2label` is reordered, short, or carries an eighth category is a different model, and
    scoring through it would produce confidently wrong categories rather than an error.
    """
    ordered = [id2label[key] for key in sorted(id2label, key=lambda k: int(k))]
    if tuple(ordered) != LABELS:
        raise AdapterUnavailable(
            "checkpoint labels do not match the verified seven: "
            f"expected {list(LABELS)}, found {ordered}"
        )


def load_thresholds(path: Path, expected_sha256: str) -> dict[str, dict[str, float]]:
    """Read the frozen per-language thresholds and refuse them unless the bytes are the ones we were told about.

    The real file (`compare-v9b.json`) is `{"thresholds": {lang: {label: value}}}`, because a category's cutoff
    is calibrated per language: `grooming` at 0.50 in Arabic and at another value in Turkish. A single flat map
    would silently apply one language's calibration to another, which is why the language is an input to
    :meth:`V9bAdapter.score` and not a detail of the tokenizer.
    """
    actual = sha256_file(path)
    if actual != expected_sha256:
        raise AdapterUnavailable(
            f"thresholds digest mismatch for {path.name}: expected {expected_sha256}, found {actual}"
        )
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise AdapterUnavailable(f"thresholds file is not readable JSON: {exc}") from exc
    per_language = raw.get("thresholds", raw) if isinstance(raw, dict) else None
    if not isinstance(per_language, dict) or not per_language:
        raise AdapterUnavailable("thresholds must be {language: {label: value}} or carry a 'thresholds' map")
    result: dict[str, dict[str, float]] = {}
    for language, mapping in per_language.items():
        if not isinstance(mapping, dict):
            raise AdapterUnavailable(f"thresholds for {language!r} are not a map of labels")
        missing = [label for label in LABELS if label not in mapping]
        extra = [label for label in mapping if label not in LABELS]
        if missing or extra:
            raise AdapterUnavailable(
                f"thresholds for {language!r} must name exactly {list(LABELS)}; missing={missing} extra={extra}"
            )
        resolved: dict[str, float] = {}
        for label in LABELS:
            value = mapping[label]
            if not isinstance(value, (int, float)) or isinstance(value, bool) or not 0.0 <= float(value) <= 1.0:
                raise AdapterUnavailable(f"threshold for {language}/{label} is not a probability: {value!r}")
            resolved[label] = float(value)
        result[str(language)] = resolved
    return result


def apply_thresholds(probs: Mapping[str, float], thresholds: Mapping[str, float]) -> tuple[str, ...]:
    """The labels whose own probability reaches their own threshold, in :data:`LABELS` order.

    One threshold for all seven is not a smaller version of this: the categories do not share a base rate, and
    a single cutoff would change which rows flag. That is why this function takes the per-label map and why a
    test drives it with synthetic vectors rather than with real rows — the three parity rows are all
    hate_speech-dominant and none of them straddles a cutoff.
    """
    if set(probs) != set(LABELS):
        raise AdapterUnavailable(f"probabilities must cover exactly {list(LABELS)}; got {sorted(probs)}")
    missing = [label for label in LABELS if label not in thresholds]
    if missing:
        raise AdapterUnavailable(f"no threshold for {missing}")
    return tuple(
        label
        for label in LABELS
        if float(probs[label]) >= float(thresholds[label])
    )


def verdict_of(flagged: Sequence[str]) -> str:
    return "flagged" if flagged else "safe"


class V9bAdapter:
    """A loaded v9b checkpoint. Built by :meth:`load`; every reason it could be wrong is checked there."""

    def __init__(self, pipeline, model_sha256: str, thresholds: dict[str, dict[str, float]], thresholds_sha256: str):
        self._pipeline = pipeline
        self._model_sha256 = model_sha256
        self._thresholds = thresholds
        self._thresholds_sha256 = thresholds_sha256

    @classmethod
    def load(
        cls,
        model_dir: Path,
        thresholds_path: Path,
        expected_thresholds_sha256: str,
        expected_manifest: Mapping[str, str],
    ) -> "V9bAdapter":
        model_dir = Path(model_dir)
        config_path = model_dir / "config.json"
        weights_path = model_dir / "model.safetensors"
        if not config_path.is_file():
            raise AdapterUnavailable(f"no config.json in {model_dir}")
        if not weights_path.is_file():
            raise AdapterUnavailable(f"no model.safetensors in {model_dir}")
        # Required, not optional: a score that is not tied to a pinned checkpoint is a score nobody can
        # attribute, which is the one thing #996 exists to prevent. The check runs before any runtime import.
        verify_manifest(model_dir, expected_manifest)
        thresholds = load_thresholds(Path(thresholds_path), expected_thresholds_sha256)
        try:
            config = json.loads(config_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise AdapterUnavailable(f"config.json is not readable JSON: {exc}") from exc
        id2label = config.get("id2label")
        if not isinstance(id2label, dict) or not id2label:
            raise AdapterUnavailable("config.json carries no id2label map; label positions cannot be verified")
        verify_labels(id2label)
        try:
            from transformers import pipeline  # imported here so the pure helpers stay dependency-free
        except ImportError as exc:  # pragma: no cover - only on a host without the runtime
            raise AdapterUnavailable(f"transformers is not installed: {exc}") from exc
        try:
            pipe = pipeline(
                "text-classification",
                model=str(model_dir),
                tokenizer=str(model_dir),
                top_k=None,
                function_to_apply="sigmoid",  # multi-label: softmax would normalise across the seven
                local_files_only=True,
            )
        except Exception as exc:  # noqa: BLE001 - every load failure means the same thing to a caller
            raise AdapterUnavailable(f"checkpoint did not load: {exc}") from exc
        return cls(pipe, sha256_file(weights_path), thresholds, expected_thresholds_sha256)

    def score(self, text: str, lang: str) -> Scored:
        if not isinstance(text, str) or not text.strip():
            raise AdapterUnavailable("no text to score")
        if lang not in self._thresholds:
            raise AdapterUnavailable(
                f"no calibrated thresholds for language {lang!r}; have {sorted(self._thresholds)}"
            )
        try:
            raw = self._pipeline(text, truncation=True, max_length=128)[0]
        except Exception as exc:  # noqa: BLE001
            raise AdapterUnavailable(f"scoring failed: {exc}") from exc
        if not isinstance(raw, list):
            raise AdapterUnavailable(f"scorer returned {type(raw).__name__}, not a list of label/score items")
        by_label: dict[str, float] = {}
        for item in raw:
            # Nothing the scorer produced reaches a message until it is validated. A field name, a label or a
            # score is attacker-influenced text as far as this module is concerned: the same call also serves
            # rows of a child's messages, so an echoed field could quote one into a log. Diagnostics use fixed
            # text plus safe structure (types, counts, and labels already known to be in LABELS).
            if not isinstance(item, dict) or "label" not in item or "score" not in item:
                shape = (
                    f"has label={isinstance(item, dict) and 'label' in item}, "
                    f"score={isinstance(item, dict) and 'score' in item}"
                    if isinstance(item, dict)
                    else f"is a {type(item).__name__}"
                )
                raise AdapterUnavailable(f"scorer item is not a label/score pair ({shape})")
            label, value = item["label"], item["score"]
            if not isinstance(label, str):
                raise AdapterUnavailable(f"scorer label is not a string (type: {type(label).__name__})")
            if label not in LABELS:
                raise AdapterUnavailable("scorer returned a label outside the verified seven")
            if label in by_label:
                raise AdapterUnavailable(f"scorer returned {label} more than once; one score per label")
            if isinstance(value, bool) or not isinstance(value, (int, float)):
                raise AdapterUnavailable(f"score for {label} is not a number (type: {type(value).__name__})")
            score = float(value)
            if not math.isfinite(score) or not 0.0 <= score <= 1.0:
                raise AdapterUnavailable(f"score for {label} is not a probability in [0, 1]")
            by_label[label] = score
        missing = [label for label in LABELS if label not in by_label]
        if missing:
            # Only names from our own LABELS appear here, never anything the scorer chose.
            raise AdapterUnavailable(f"scorer did not return {missing}")
        probs = {label: by_label[label] for label in LABELS}
        flagged = apply_thresholds(probs, self._thresholds[lang])
        return Scored(
            probs=probs,
            flagged_categories=flagged,
            verdict=verdict_of(flagged),
            model_sha256=self._model_sha256,
            thresholds_sha256=self._thresholds_sha256,
        )

    def score_batch(self, texts: Iterable[tuple[str, str]]) -> list[Scored]:
        return [self.score(text, lang) for text, lang in texts]
