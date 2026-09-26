"""Fallback-path tests for analyze_text (must pass without torch/fastapi)."""

import pytest

from model import CATEGORIES, analyze_text


def _top_category(result):
    """Return the category with the highest probability in a result."""
    return max(result["categories"], key=result["categories"].get)


def _response_shape_ok(result):
    """Assert the response has the app.py AnalyzeResponse shape."""
    assert set(result) == {"categories", "severity", "flagged", "explanation"}
    assert set(result["categories"]) == set(CATEGORIES)
    assert all(0.0 <= p <= 1.0 for p in result["categories"].values())
    assert result["severity"] in ("info", "warning", "critical")
    assert result["flagged"] == (result["severity"] in ("warning", "critical"))


@pytest.mark.parametrize(
    "text",
    [
        "math homework",
        "soccer practice at 6 pm",
        "can you pick up milk on the way home?",
        "what time is dinner tonight?",
    ],
)
def test_innocent_text_not_flagged(text):
    result = analyze_text(text, "message", 10)
    _response_shape_ok(result)
    assert result["flagged"] is False
    assert result["severity"] == "info"
    assert result["categories"]["safe"] >= 0.9


@pytest.mark.parametrize(
    "text",
    [
        "seriously just kill yourself",
        "kys no one loves you",
        "I want to die, there is no reason to live",
    ],
)
def test_self_harm_phrases_flagged_critical(text):
    result = analyze_text(text, "message", 14)
    _response_shape_ok(result)
    assert result["flagged"] is True
    assert result["severity"] == "critical"
    assert _top_category(result) == "self_harm"


def test_grooming_phrase_with_phone_number_flagged():
    text = "meet me alone after school, call me at 555-123-4567 but don't tell your mom"
    result = analyze_text(text, "chatbot", 11)
    _response_shape_ok(result)
    assert result["flagged"] is True
    assert result["categories"]["grooming"] >= 0.6


@pytest.mark.parametrize(
    "text",
    [
        "this is our secret, don't tell your parents",
        "send me a pic, just between us",
        "meet me at the park behind the mall",
    ],
)
def test_grooming_phrases_flagged(text):
    result = analyze_text(text, "chat", 12)
    _response_shape_ok(result)
    assert result["flagged"] is True
    assert result["categories"]["grooming"] >= 0.6


def test_substance_use_flagged():
    result = analyze_text("wanna buy some weed and get high after class", "message", 15)
    _response_shape_ok(result)
    assert result["flagged"] is True
    assert result["categories"]["substance_use"] >= 0.6


def test_hate_speech_flagged():
    result = analyze_text("you're such a faggot, everyone hates you", "message", 13)
    _response_shape_ok(result)
    assert result["flagged"] is True
    assert result["categories"]["hate_speech"] >= 0.6


def test_explanation_names_top_two_categories():
    result = analyze_text("kill yourself you loser", "message", 14)
    top2 = sorted(result["categories"], key=lambda c: (-result["categories"][c], c))[:2]
    assert len(top2) == 2
    for category in top2:
        assert category in result["explanation"]


def test_explanation_names_two_categories_for_safe_text():
    result = analyze_text("math homework", "message", 9)
    top2 = sorted(result["categories"], key=lambda c: (-result["categories"][c], c))[:2]
    for category in top2:
        assert category in result["explanation"]


def test_severity_ordering_sanity():
    info = analyze_text("math homework", "message", 10)
    warning = analyze_text("do you have any weed", "message", 15)
    critical = analyze_text("kill yourself now", "message", 14)
    assert info["severity"] == "info"
    assert warning["severity"] == "warning"
    assert critical["severity"] == "critical"
    info_top = max(info["categories"][c] for c in CATEGORIES if c != "safe")
    warning_top = max(warning["categories"][c] for c in CATEGORIES if c != "safe")
    critical_top = max(critical["categories"][c] for c in CATEGORIES if c != "safe")
    assert info_top < warning_top < critical_top
    assert info_top < 0.6 <= warning_top < 0.85 <= critical_top


def test_fallback_is_deterministic():
    text = "meet me alone, don't tell your mom"
    first = analyze_text(text, "chat", 12)
    second = analyze_text(text, "chat", 12)
    assert first == second


def test_never_raises_on_empty_or_very_long_input():
    empty = analyze_text("", "message", None)
    _response_shape_ok(empty)
    assert empty["severity"] == "info"
    long_text = "hello friend, how are you today? " * 100000
    long_result = analyze_text(long_text, "web", 9)
    _response_shape_ok(long_result)
    assert long_result["severity"] == "info"
