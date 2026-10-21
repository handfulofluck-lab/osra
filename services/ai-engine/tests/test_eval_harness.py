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
from eval.split import SPLITS, split_of

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


def test_expansion_caps_rows_per_template():
    """Claude's decision on #262: the count grows through templates, never through more fills."""
    slot_map = {"name": ["a", "b", "c", "d", "e", "f", "g", "h"]}
    templates = ["one {name}", "two {name}"]
    assert len(generate.expand(templates, slot_map, 10, random.Random(1), "x", "en", 1)) == 10
    with pytest.raises(ValueError, match="do not raise the count"):
        generate.expand(templates, slot_map, 11, random.Random(1), "x", "en", 1)


def test_a_true_overlap_carries_both_labels():
    slot_map = {"name": ["a", "b"]}
    rows = generate.expand(["photo {name}"], slot_map, 2, random.Random(1), "grooming", "en", 1,
                           {0: ["sexual_content"]})
    assert rows[0]["labels"] == ["grooming", "sexual_content"]


def test_dataset_labels_start_with_the_banks_category():
    with open(DATASET, encoding="utf-8") as handle:
        for line in handle:
            row = json.loads(line)
            if row["hard_negative_of"] is not None or row["labels"] == ["safe"]:
                assert row["labels"] == ["safe"], row["id"]
                continue
            assert row["labels"][0] == row["category"], row["id"]
            for extra in row["labels"][1:]:
                assert extra in HARMFUL_CATEGORIES and extra != row["category"], row["id"]


def test_dataset_text_is_unique_within_a_language():
    """Each bank used to repeat the same safe sentences, which skewed the safe false-positive rate."""
    seen = {"en": {}, "ar": {}}
    with open(DATASET, encoding="utf-8") as handle:
        for line in handle:
            row = json.loads(line)
            bucket = seen[row["lang"]]
            assert row["text"] not in bucket, f"{row['id']} duplicates {bucket.get(row['text'])}"
            bucket[row["text"]] = row["id"]


def test_a_slot_used_twice_gets_one_fill():
    """`{n} and {n}` must name one child, not two (#262 review)."""
    rows = generate.expand(["{n} and {n} did it"], {"n": ["Sara", "Omar", "Layla"]}, 3,
                           random.Random(3), "x", "en", 3)
    for row in rows:
        left, right = row["text"].split(" and ")[0], row["text"].split(" and ")[1].split(" did")[0]
        assert left == right, row["text"]


def test_no_english_row_glues_two_articles_together():
    """"such a a joke", "the a loser one": an adjective slot used where a noun belongs.

    The check is the whole class, not the eleven rows Claude found, because the next bank author will
    repeat it with a different frame.
    """
    doubled = re.compile(r"\b(a|an|the) (a|an|the|so|such)\b", re.IGNORECASE)
    with open(DATASET, encoding="utf-8") as handle:
        for line in handle:
            row = json.loads(line)
            if row["lang"] == "en":
                assert not doubled.search(row["text"]), row["text"]


def test_dataset_meets_the_interim_language_floor():
    """500 per language is the interim floor; the plan's 2,000 + 2,000 is a template-count problem
    (#262 decision), so this test is named for what it actually holds."""
    with open(DATASET, encoding="utf-8") as handle:
        rows = [json.loads(line) for line in handle if line.strip()]
    by_lang = {"en": 0, "ar": 0}
    for row in rows:
        by_lang[row["lang"]] += 1
        assert row["labels"], row["id"]
        assert row["category"] in HARMFUL_CATEGORIES
        assert row["provenance"]["kind"] == "synthetic"
    assert by_lang["en"] >= 500, by_lang
    assert by_lang["ar"] >= 500, by_lang


def test_committed_dataset_matches_the_banks(tmp_path, capsys):
    """A stale dataset under a fresh bank is a number nobody can reproduce."""
    assert generate.main(["--check"]) == 0


def _dataset_rows():
    with open(DATASET, encoding="utf-8") as handle:
        return [json.loads(line) for line in handle if line.strip()]


def test_split_of_is_stable():
    """The hash input *is* the split's identity: change it and the set is re-cut, so fail here first."""
    assert split_of("self_harm", 0) == "test"
    assert split_of("cyberbullying", 3) == "dev"
    assert split_of("violence", 7) == "dev"


def test_split_is_carried_by_generated_rows():
    rows = generate.expand(["hi {n}", "bye {n}"], {"n": ["a", "b", "c"]}, 4, random.Random(2),
                           "x", "en", 2)
    for row in rows:
        assert row["provenance"]["split"] == split_of("x", row["provenance"]["template_index"])


def test_every_bank_and_language_has_both_sides():
    """A bank that is all dev would make its category unmeasurable on the held-out side."""
    by_bank, by_lang = {}, {}
    for row in _dataset_rows():
        prov = row["provenance"]
        by_bank.setdefault(prov["bank"], set()).add(prov["split"])
        by_lang.setdefault(row["lang"], set()).add(prov["split"])
    for bank, sides in by_bank.items():
        assert sides == set(SPLITS), f"{bank}: {sorted(sides)}"
    for lang, sides in by_lang.items():
        assert sides == set(SPLITS), f"{lang}: {sorted(sides)}"


def test_committed_dataset_agrees_with_the_split_rule():
    """The regression that matters: a dataset and a rule that drift apart make a held-out number a lie."""
    for row in _dataset_rows():
        prov = row["provenance"]
        assert prov["split"] == split_of(prov["bank"], prov["template_index"]), row["id"]


def test_rows_from_one_template_share_one_side():
    """The anti-leak invariant: a paraphrase of a test template must not sit in dev."""
    sides = {}
    for row in _dataset_rows():
        prov = row["provenance"]
        sides.setdefault((prov["bank"], prov["template_index"]), set()).add(prov["split"])
    leaked = {key: sorted(value) for key, value in sides.items() if len(value) > 1}
    assert not leaked, leaked


def test_split_filter_selects_only_that_side():
    rows = _dataset_rows()
    test_rows = run_eval.filter_rows(rows, "test")
    assert test_rows and all(row["provenance"]["split"] == "test" for row in test_rows)
    assert len(test_rows) < len(rows)
    assert run_eval.filter_rows(rows, "all") == rows


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
        # None, not 0.0: nothing was flagged, so precision and recall are undefined rather than bad.
        assert result["langs"]["en"]["per_category"][category]["precision"] is None
        assert result["langs"]["en"]["per_category"][category]["recall"] is None
        assert result["langs"]["en"]["per_category"][category]["f1"] is None


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
