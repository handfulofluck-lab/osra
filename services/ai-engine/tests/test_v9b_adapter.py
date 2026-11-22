"""Contract tests for `v9b_adapter`. Offline, no checkpoint, no network.

Each test names the mutant it kills (AGENTS.md §3): a check that cannot fail is worse than no check, and the
three real parity rows cannot test the per-label thresholds because all three are hate_speech-dominant and
none straddles a cutoff — so row 3 drives synthetic vectors instead.
"""
import json
import os
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from v9b_adapter import (  # noqa: E402
    LABELS,
    MANIFEST_FILES,
    AdapterUnavailable,
    Scored,
    apply_thresholds,
    load_thresholds,
    manifest_of,
    sha256_file,
    verify_labels,
    verify_manifest,
    verdict_of,
)


def id2label(**overrides):
    mapping = {str(index): label for index, label in enumerate(LABELS)}
    mapping.update(overrides)
    return mapping


def write_thresholds(tmp_path: Path, values=None) -> tuple[Path, str]:
    """One language's thresholds, in the frozen file's shape (`{"thresholds": {lang: {label: value}}}`)."""
    payload = values if values is not None else {"ar": {label: 0.5 for label in LABELS}}
    path = tmp_path / "compare-v9b.json"
    path.write_text(json.dumps({"thresholds": payload}), encoding="utf-8")
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
    assert load_thresholds(path, good)["ar"]["hate_speech"] == 0.5
    path.write_text(path.read_text(encoding="utf-8").replace("0.5", "0.6", 1), encoding="utf-8")
    # Mutant: drop the digest check -> the edited file loads and this row goes red.
    with pytest.raises(AdapterUnavailable):
        load_thresholds(path, good)


def test_load_thresholds_requires_every_label_in_every_language(tmp_path):
    path, digest = write_thresholds(tmp_path, {"ar": {label: 0.5 for label in LABELS if label != "violence"}})
    with pytest.raises(AdapterUnavailable):
        load_thresholds(path, digest)


def test_load_thresholds_rejects_a_value_that_is_not_a_probability(tmp_path):
    values = {label: 0.5 for label in LABELS}
    values["substance_use"] = 55
    path, digest = write_thresholds(tmp_path, {"ar": values})
    with pytest.raises(AdapterUnavailable):
        load_thresholds(path, digest)


def test_the_calibration_is_per_language_not_shared(tmp_path):
    # The real frozen file calibrates each language separately; a row that clears Arabic's grooming cutoff
    # must not clear Turkish's if Turkish is set higher.
    ar = {label: 0.50 for label in LABELS}
    tr = {label: 0.50 for label in LABELS}
    ar["grooming"] = 0.40
    tr["grooming"] = 0.90
    path, digest = write_thresholds(tmp_path, {"ar": ar, "tr": tr})
    loaded = load_thresholds(path, digest)
    probs = {label: 0.10 for label in LABELS}
    probs["grooming"] = 0.60
    assert apply_thresholds(probs, loaded["ar"]) == ("grooming",)
    assert apply_thresholds(probs, loaded["tr"]) == tuple()
    # Mutant: ignore the language and reuse the first calibrated map -> the Turkish assertion goes red.


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


# The one thing the offline cases above cannot show: that the adapter scores the real v9b checkpoint the way
# the frozen predictions say it does. It runs only where the checkpoint exists, and the receipt that matters is
# the parity run on the PC (archive 5bb6f82a..., weights 158ca1f0..., worst diff 4.9e-05 at tolerance 0.02,
# posted on #50). Set V9B_MODEL_DIR and V9B_THRESHOLDS to run it; without them the case is skipped, not passed.
@pytest.mark.skipif(
    not (os.environ.get("V9B_MODEL_DIR") and os.environ.get("V9B_THRESHOLDS")),
    reason="needs the trained checkpoint and its thresholds; the offline cases cover the contract",
)
def test_the_real_checkpoint_loads_and_scores_one_row_deterministically():
    from v9b_adapter import V9bAdapter

    model_dir = Path(os.environ["V9B_MODEL_DIR"])
    thresholds = Path(os.environ["V9B_THRESHOLDS"])
    adapter = V9bAdapter.load(model_dir, thresholds, sha256_file(thresholds), expected_manifest=manifest_of(model_dir))
    first = adapter.score("the teacher said the class will get a test next week", "en")
    second = adapter.score("the teacher said the class will get a test next week", "en")
    assert first.probs == second.probs, "the same text twice must give the same numbers"
    assert list(first.probs) == list(LABELS), "order is part of the contract"
    assert first.verdict in {"flagged", "safe"}
    assert len(first.model_sha256) == 64 and len(first.thresholds_sha256) == 64


@pytest.mark.skipif(
    not all(os.environ.get(v) for v in ("V9B_MODEL_DIR", "V9B_THRESHOLDS", "V9B_ROWS", "V9B_EXPECT")),
    reason="needs the checkpoint, its thresholds and the frozen reference rows",
)
def test_the_adapter_agrees_with_the_frozen_reference_predictions():
    """The cross-implementation check: this adapter vs the runner's own scoring path.

    Both read the same checkpoint through different code (a verified `pipeline` call here, a direct
    `AutoModelForSequenceClassification` there), so agreement on the verdicts and near-agreement on the
    numbers is what rules out a label-order or normalization mistake in either. It ran on this PC with the
    verified archive and produced the same verdicts, worst difference 4.937e-05.
    """
    from v9b_adapter import V9bAdapter

    model_dir = Path(os.environ["V9B_MODEL_DIR"])
    thresholds = Path(os.environ["V9B_THRESHOLDS"])
    adapter = V9bAdapter.load(model_dir, thresholds, sha256_file(thresholds), expected_manifest=manifest_of(model_dir))
    rows = [
        json.loads(line)
        for line in Path(os.environ["V9B_ROWS"]).read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    reference = {
        row["id"]: row
        for row in (
            json.loads(line)
            for line in Path(os.environ["V9B_EXPECT"]).read_text(encoding="utf-8").splitlines()
            if line.strip()
        )
    }
    assert rows, "the reference file must not be empty, or this row passes for the wrong reason"
    per_language = load_thresholds(thresholds, sha256_file(thresholds))
    for row in rows:
        lang = row.get("lang", "ar")
        scored = adapter.score(row["text"], lang)
        expected = reference[row["id"]]["probs"]
        if isinstance(expected, list):
            expected = dict(zip(LABELS, expected))
        # Written out rather than reused from the adapter: a comparison that calls the code under test twice
        # agrees with itself whatever it does. This independent expression of "past its own cutoff" is what
        # makes the row able to fail.
        expected_flagged = tuple(
            label for label in LABELS if float(expected[label]) >= per_language[lang][label]
        )
        assert scored.flagged_categories == expected_flagged, (
            f"{row['id']}: adapter flagged {scored.flagged_categories}, reference would flag {expected_flagged}"
        )
        assert scored.verdict == ("flagged" if expected_flagged else "safe")
        for label in LABELS:
            assert abs(scored.probs[label] - float(expected[label])) <= 2e-03, (
                f"{row['id']}/{label}: adapter {scored.probs[label]:.6f} vs reference {float(expected[label]):.6f}"
            )


def _make_checkpoint(root: Path, id2label_map=None) -> Path:
    root.mkdir(parents=True, exist_ok=True)
    for name in MANIFEST_FILES:
        (root / name).write_bytes(b"placeholder-" + name.encode())
    (root / "config.json").write_text(
        json.dumps({"id2label": id2label_map if id2label_map is not None else id2label()}), encoding="utf-8"
    )
    return root


def test_a_manifest_pins_every_file_not_only_the_weights(tmp_path):
    model = _make_checkpoint(tmp_path / "model")
    pinned = manifest_of(model)
    assert set(pinned) == set(MANIFEST_FILES)
    verify_manifest(model, pinned)
    # Change the tokenizer only: the weights are untouched and every score would move.
    (model / "tokenizer.json").write_bytes(b"different tokenizer")
    # Mutant: verify only model.safetensors -> the tokenizer swap passes and this row goes red.
    with pytest.raises(AdapterUnavailable) as raised:
        verify_manifest(model, pinned)
    assert "tokenizer.json" in str(raised.value)


def test_a_partial_manifest_is_refused(tmp_path):
    model = _make_checkpoint(tmp_path / "model")
    pinned = {name: digest for name, digest in manifest_of(model).items() if name != "config.json"}
    # A pin that names five of six files is not a pin, and the config can reorder id2label.
    with pytest.raises(AdapterUnavailable):
        verify_manifest(model, pinned)


def test_load_refuses_a_checkpoint_that_does_not_match_its_pin(tmp_path):
    from v9b_adapter import V9bAdapter

    model = _make_checkpoint(tmp_path / "model")
    pinned = manifest_of(model)
    path, digest = write_thresholds(tmp_path)
    (model / "config.json").write_text(json.dumps({"id2label": id2label()}) + " ", encoding="utf-8")
    with pytest.raises(AdapterUnavailable):
        V9bAdapter.load(model, path, digest, expected_manifest=pinned)
