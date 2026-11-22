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


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


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


def load_thresholds(path: Path, expected_sha256: str) -> dict[str, float]:
    """Read `{label: threshold}` and refuse it unless the bytes are the ones we were told about."""
    actual = sha256_file(path)
    if actual != expected_sha256:
        raise AdapterUnavailable(
            f"thresholds digest mismatch for {path.name}: expected {expected_sha256}, found {actual}"
        )
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise AdapterUnavailable(f"thresholds file is not readable JSON: {exc}") from exc
    missing = [label for label in LABELS if label not in raw]
    extra = [label for label in raw if label not in LABELS]
    if missing or extra:
        raise AdapterUnavailable(f"thresholds must name exactly {list(LABELS)}; missing={missing} extra={extra}")
    thresholds: dict[str, float] = {}
    for label in LABELS:
        value = raw[label]
        if not isinstance(value, (int, float)) or isinstance(value, bool) or not 0.0 <= float(value) <= 1.0:
            raise AdapterUnavailable(f"threshold for {label} is not a probability: {value!r}")
        thresholds[label] = float(value)
    return thresholds


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

    def __init__(self, pipeline, model_sha256: str, thresholds: dict[str, float], thresholds_sha256: str):
        self._pipeline = pipeline
        self._model_sha256 = model_sha256
        self._thresholds = thresholds
        self._thresholds_sha256 = thresholds_sha256

    @classmethod
    def load(cls, model_dir: Path, thresholds_path: Path, expected_thresholds_sha256: str) -> "V9bAdapter":
        model_dir = Path(model_dir)
        config_path = model_dir / "config.json"
        weights_path = model_dir / "model.safetensors"
        if not config_path.is_file():
            raise AdapterUnavailable(f"no config.json in {model_dir}")
        if not weights_path.is_file():
            raise AdapterUnavailable(f"no model.safetensors in {model_dir}")
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

    def score(self, text: str) -> Scored:
        if not isinstance(text, str) or not text.strip():
            raise AdapterUnavailable("no text to score")
        try:
            raw = self._pipeline(text, truncation=True, max_length=128)[0]
        except Exception as exc:  # noqa: BLE001
            raise AdapterUnavailable(f"scoring failed: {exc}") from exc
        by_label = {item["label"]: float(item["score"]) for item in raw}
        if set(by_label) != set(LABELS):
            raise AdapterUnavailable(f"model returned labels {sorted(by_label)}, not the verified seven")
        probs = {label: by_label[label] for label in LABELS}
        flagged = apply_thresholds(probs, self._thresholds)
        return Scored(
            probs=probs,
            flagged_categories=flagged,
            verdict=verdict_of(flagged),
            model_sha256=self._model_sha256,
            thresholds_sha256=self._thresholds_sha256,
        )

    def score_batch(self, texts: Iterable[str]) -> list[Scored]:
        return [self.score(text) for text in texts]
