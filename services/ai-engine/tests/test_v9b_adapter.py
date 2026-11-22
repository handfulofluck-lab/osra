"""Contract tests for `v9b_adapter`. Offline, no checkpoint, no network.

Each test names the mutant it kills (AGENTS.md §3): a check that cannot fail is worse than no check, and the
three real parity rows cannot test the per-label thresholds because all three are hate_speech-dominant and
none straddles a cutoff — so row 3 drives synthetic vectors instead.
"""
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from v9b_adapter import (  # noqa: E402
    LABELS,
    AdapterUnavailable,
    Scored,
    apply_thresholds,
    load_thresholds,
    sha256_file,
    verify_labels,
    verdict_of,
)


def id2label(**overrides):
    mapping = {str(index): label for index, label in enumerate(LABELS)}
    mapping.update(overrides)
    return mapping


def write_thresholds(tmp_path: Path, values=None) -> tuple[Path, str]:
    payload = values if values is not None else {label: 0.5 for label in LABELS}
    path = tmp_path / "thresholds.json"
    path.write_text(json.dumps(payload), encoding="utf-8")
    return path, sha256_file(path)


def test_the_seven_labels_are_the_verified_names_in_order():
    # Mutant: reordering LABELS here reds this and every test that names a position.
    assert LABELS == (
        "cyberbullying",
        "self_harm",
        "grooming",
        "violence",
        "sexual_content",
        "substance_use",
        "hate_speech",
    )


def test_verify_labels_accepts_the_verified_mapping():
    verify_labels(id2label())


@pytest.mark.parametrize(
    "mapping",
    [
        pytest.param({"0": LABELS[1], "1": LABELS[0], **{str(i): l for i, l in enumerate(LABELS) if i > 1}},
                     id="two-names-swapped"),
        pytest.param({str(i): l for i, l in enumerate(LABELS[:-1])}, id="one-label-missing"),
        pytest.param({str(i): l for i, l in enumerate(LABELS + ("profanity",))}, id="eighth-category"),
    ],
)
def test_verify_labels_rejects_a_checkpoint_that_is_not_the_verified_model(mapping):
    # Mutant: compare sorted name sets instead of order -> the swapped case passes and this row goes red.
    with pytest.raises(AdapterUnavailable):
        verify_labels(mapping)


def test_a_threshold_is_used_per_label_not_one_for_all():
    probs = {label: 0.10 for label in LABELS}
    probs["grooming"] = 0.42
    probs["violence"] = 0.62
    thresholds = {label: 0.50 for label in LABELS}
    thresholds["grooming"] = 0.40
    # grooming 0.42 clears its own 0.40; violence 0.62 clears 0.50; everything else stays under.
    assert apply_thresholds(probs, thresholds) == ("grooming", "violence")
    # Mutant: average the thresholds into one cutoff (0.4857) -> grooming drops out and this goes red.
    mean = sum(thresholds.values()) / len(thresholds)
    with pytest.raises(AssertionError):
        assert apply_thresholds(probs, thresholds) == tuple(
            label for label in LABELS if probs[label] >= mean
        )


def test_a_probability_exactly_on_its_threshold_flags():
    probs = {label: 0.0 for label in LABELS}
    probs["self_harm"] = 0.50
    assert apply_thresholds(probs, {label: 0.50 for label in LABELS}) == ("self_harm",)


def test_apply_thresholds_refuses_a_missing_label():
    probs = {label: 0.1 for label in LABELS if label != "grooming"}
    with pytest.raises(AdapterUnavailable):
        apply_thresholds(probs, {label: 0.5 for label in LABELS})


def test_load_thresholds_verifies_the_digest(tmp_path):
    path, good = write_thresholds(tmp_path)
    assert load_thresholds(path, good)["hate_speech"] == 0.5
    path.write_text(path.read_text(encoding="utf-8").replace("0.5", "0.6", 1), encoding="utf-8")
    # Mutant: drop the digest check -> the edited file loads and this row goes red.
    with pytest.raises(AdapterUnavailable):
        load_thresholds(path, good)


def test_load_thresholds_requires_every_label(tmp_path):
    path, digest = write_thresholds(tmp_path, {label: 0.5 for label in LABELS if label != "violence"})
    with pytest.raises(AdapterUnavailable):
        load_thresholds(path, digest)


def test_load_thresholds_rejects_a_value_that_is_not_a_probability(tmp_path):
    values = {label: 0.5 for label in LABELS}
    values["substance_use"] = 55
    path, digest = write_thresholds(tmp_path, values)
    with pytest.raises(AdapterUnavailable):
        load_thresholds(path, digest)


def test_load_refuses_a_missing_checkpoint_without_inventing_a_result(tmp_path):
    from v9b_adapter import V9bAdapter

    path, digest = write_thresholds(tmp_path)
    with pytest.raises(AdapterUnavailable):
        V9bAdapter.load(tmp_path / "no-such-model", path, digest)
    # Mutant: return a rules-derived Scored instead of raising -> this row goes red, and that is the rule
    # that keeps a v9b receipt honest.


def test_load_refuses_a_checkpoint_whose_labels_are_not_verified(tmp_path):
    from v9b_adapter import V9bAdapter

    model_dir = tmp_path / "model"
    model_dir.mkdir()
    (model_dir / "model.safetensors").write_bytes(b"not a real checkpoint")
    (model_dir / "config.json").write_text(
        json.dumps({"id2label": {"0": "hate_speech", "1": "grooming"}}), encoding="utf-8"
    )
    path, digest = write_thresholds(tmp_path)
    # The label check runs before any heavy import, so this needs no torch on the host.
    with pytest.raises(AdapterUnavailable) as raised:
        V9bAdapter.load(model_dir, path, digest)
    assert "verified seven" in str(raised.value)


def test_scored_carries_the_digests_and_round_trips():
    scored = Scored(
        probs={label: 0.1 for label in LABELS},
        flagged_categories=(),
        verdict=verdict_of(()),
        model_sha256="a" * 64,
        thresholds_sha256="b" * 64,
    )
    payload = scored.to_dict()
    assert payload["verdict"] == "safe"
    assert set(payload["probs"]) == set(LABELS)
    assert list(payload["probs"]) == list(LABELS), "order is part of the contract, not incidental"
    assert payload["model_sha256"] == "a" * 64 and payload["thresholds_sha256"] == "b" * 64


def test_the_result_is_deterministic_for_the_same_inputs():
    probs = {label: 0.5 for label in LABELS}
    thresholds = {label: 0.5 for label in LABELS}
    first = apply_thresholds(probs, thresholds)
    second = apply_thresholds(probs, thresholds)
    assert first == second == LABELS
