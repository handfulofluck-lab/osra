"""Tests for the evaluation harness (plan 4.2 / 4.3).

The harness is what turns "the scorer is good" into a number someone else can
reproduce, so its own failure modes matter: a bank that silently produces the
same sentence 65 times, a metric that reports 1.00 because the denominator was
zero, and an Arabic file that is English with Arabic quotation marks around it.
"""

import json
import os
import random
import re

import pytest

import model
from eval import generate, run_eval
from eval.banks import HARMFUL_CATEGORIES, SLOT_RE, load_banks, validate_module

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATASET = os.path.join(ROOT, "eval", "dataset.jsonl")
ARABIC = re.compile(r"[\u0600-\u06FF]")


@pytest.fixture(scope="module")
def banks():
    return load_banks()


def test_every_harmful_category_has_a_valid_bank(banks):
    assert sorted(banks) == sorted(HARMFUL_CATEGORIES)
    for category, bank in banks.items():
        assert bank.module_name == category


def test_banks_are_language_separated(banks):
    """An Arabic bank written in English is the failure this set exists to catch."""
    for category, bank in banks.items():
        for text in bank.positives_ar + bank.hard_negatives_ar + bank.generic_safe_ar:
            assert ARABIC.search(text), f"{category}/ar entry has no Arabic: {text!r}"
        for text in bank.positives_en + bank.hard_negatives_en + bank.generic_safe_en:
            assert not ARABIC.search(text), f"{category}/en entry contains Arabic: {text!r}"


def test_slots_are_declared(banks):
    for category, bank in banks.items():
        for lang, templates, slots in (("en", bank.positives_en, bank.slots_en),
                                       ("ar", bank.positives_ar, bank.slots_ar)):
            for template in templates:
                for slot in SLOT_RE.findall(template):
                    assert slot in slots, f"{category}/{lang}: undeclared slot {{{slot}}}"


def test_expansion_is_deterministic_and_unique():
    slot_map = {"name": ["a", "b", "c", "d", "e", "f"]}
    templates = ["hello {name} one", "hello {name} two"]
    first = generate.expand(templates, slot_map, 10, random.Random(7), "x", "en", 7)
    second = generate.expand(templates, slot_map, 10, random.Random(7), "x", "en", 7)
    assert [row["text"] for row in first] == [row["text"] for row in second]
    assert len({row["text"] for row in first}) == 10
    # Every template is used before any is repeated: a bank with one good
    # template and nine mediocre ones should not hide the nine.
    indices = {row["provenance"]["template_index"] for row in first[:2]}
    assert indices == {0, 1}


def test_expansion_refuses_a_bank_too_thin_to_reach_the_ask():
    with pytest.raises(ValueError, match="only .* unique snippets"):
        generate.expand(["only one {name}"], {"name": ["a", "b"]}, 5,
                        random.Random(1), "x", "en", 1)


def test_dataset_meets_the_plan_4_2_floor():
    with open(DATASET, encoding="utf-8") as handle:
        rows = [json.loads(line) for line in handle if line.strip()]
    by_lang = {"en": 0, "ar": 0}
    for row in rows:
        by_lang[row["lang"]] += 1
        assert row["labels"], row["id"]
        assert row["category"] in HARMFUL_CATEGORIES
        if row["hard_negative_of"] is not None:
            # A hard negative is a *safe* row that reuses the category's
            # vocabulary, so it is scored against that category's false positives.
            assert row["labels"] == ["safe"], row["id"]
            assert row["hard_negative_of"] in HARMFUL_CATEGORIES, row["id"]
        elif row["labels"] == ["safe"]:
            pass  # generic safe: no trigger at all
        else:
            assert row["labels"] == [row["category"]], row["id"]
        assert row["provenance"]["kind"] == "synthetic"
    assert by_lang["en"] >= 500, by_lang
    assert by_lang["ar"] >= 500, by_lang


def test_committed_dataset_matches_the_banks(tmp_path, capsys):
    """A stale dataset under a fresh bank is a number nobody can reproduce."""
    assert generate.main(["--check"]) == 0


def _toy_dataset():
    return [
        {"id": "self_harm-en-1", "lang": "en", "category": "self_harm", "text": "a",
         "labels": ["self_harm"], "hard_negative_of": None},
        {"id": "self_harm-en-2", "lang": "en", "category": "self_harm", "text": "b",
         "labels": ["self_harm"], "hard_negative_of": None},
        {"id": "self_harm-en-3", "lang": "en", "category": "self_harm", "text": "c",
         "labels": ["safe"], "hard_negative_of": "self_harm"},
    ]


def _toy_scorer(table):
    def score(text):
        probs = {category: 0.0 for category in model.CATEGORIES}
        probs.update(table.get(text, {}))
        return probs
    return score


def test_precision_recall_arithmetic():
    # One true positive, one false negative, one false positive: precision 0.5,
    # recall 0.5. Written out because a metric bug that reports 1.00 silently
    # makes every later gate meaningless.
    scorer = _toy_scorer({"a": {"self_harm": 0.9}, "c": {"self_harm": 0.9}})
    result = run_eval.evaluate(_toy_dataset(), scorer, 0.5)
    row = result["langs"]["en"]["per_category"]["self_harm"]
    assert (row["tp"], row["fp"], row["fn"], row["support"]) == (1, 1, 1, 2)
    assert row["precision"] == pytest.approx(0.5)
    assert row["recall"] == pytest.approx(0.5)
    flag = result["langs"]["en"]["flag"]
    assert flag["unsafe_flagged"] == 1
    assert flag["hard_flagged"] == 1
    assert flag["hard_false_positive_rate"] == pytest.approx(1.0)


def test_empty_support_does_not_divide_by_zero():
    rows = [row for row in _toy_dataset() if row["labels"] == ["safe"]]
    result = run_eval.evaluate(rows, _toy_scorer({}), 0.5)
    for category in HARMFUL_CATEGORIES:
        assert result["langs"]["en"]["per_category"][category]["precision"] == 0.0
        assert result["langs"]["en"]["per_category"][category]["recall"] == 0.0


def test_regex_scorer_returns_every_category():
    probs = run_eval.score_regex("you are a loser, nobody likes you")
    assert sorted(probs) == sorted(model.CATEGORIES)
    assert probs["cyberbullying"] > 0


def test_regex_floor_catches_its_own_vocabulary():
    """The rules layer is a floor, not nothing.

    This is the control that keeps the published numbers honest: the evaluation
    banks describe the social pattern and deliberately carry no method vocabulary,
    so a low recall there is paraphrase being missed -- not a broken scorer. The
    floor itself is what this asserts.
    """
    assert run_eval.score_regex("just kill yourself already")["self_harm"] >= 0.5
    assert run_eval.score_regex("don't tell your parents about this")["grooming"] >= 0.5


def test_regex_floor_is_blind_to_arabic():
    """Plan 4.1's premise, pinned so it cannot regress into an assumption.

    Every Arabic rule is missing, so this asserts the gap the hosted scorer must
    close. If someone adds Arabic rules, this test fails and the EVAL numbers
    should be regenerated -- that failure is the point, not an inconvenience.
    """
    score = run_eval.score_regex("اقتل نفسك، لا أحد يحبك")
    assert max(score[c] for c in HARMFUL_CATEGORIES) == 0.0
