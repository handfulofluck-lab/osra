"""Plan 4.1: the hosted scorer, tested without a network or a key.

`httpx.MockTransport` means every case here runs offline in CI: the JSON contract, the retry rule, the
cache, and the refusal when the key is missing or wrong. The one thing a unit test cannot tell us is
whether the model is *good* — that is `EVAL.md`, and it costs money per run.
"""

import json

import httpx
import pytest

from eval.deepseek_scorer import (
    CATEGORIES,
    DeepSeekScorer,
    DeepSeekUnavailable,
    _cache_key,
    parse_categories,
)


def _reply(categories: dict) -> dict:
    """An OpenAI-compatible chat-completion body whose message content is the JSON we want back."""
    return {
        "choices": [{"message": {"role": "assistant", "content": json.dumps({"categories": categories})}}],
        "usage": {"prompt_tokens": 410, "completion_tokens": 38},
    }


def _scorer(handler, tmp_path, **kwargs) -> DeepSeekScorer:
    client = httpx.Client(transport=httpx.MockTransport(handler))
    return DeepSeekScorer(
        api_key="test-key",
        client=client,
        cache_path=str(tmp_path / "cache.json"),
        sleep=lambda _s: None,
        log=lambda _m: None,
        **kwargs,
    )


def test_a_well_formed_reply_becomes_probabilities(tmp_path):
    calls = []

    def handler(request):
        calls.append(json.loads(request.content))
        return httpx.Response(200, json=_reply({"self_harm": 0.91, "grooming": 0.02}))

    scorer = _scorer(handler, tmp_path)
    probs = scorer("i don't want to be here anymore")

    assert probs["self_harm"] == 0.91
    assert probs["grooming"] == 0.02
    # Categories the model omitted are 0.0, not an error: a run of 1,000 rows should not die on one.
    assert probs["hate_speech"] == 0.0
    # `safe` is derived when the model leaves it out, so the harness still gets the full shape.
    assert probs["safe"] == pytest.approx(0.09)
    assert sorted(probs) == sorted(CATEGORIES)
    # And the request was the documented shape, not something improvised.
    assert calls[0]["response_format"] == {"type": "json_object"}
    assert calls[0]["temperature"] == 0
    assert calls[0]["messages"][0]["role"] == "system"


def test_values_are_clamped_and_a_non_number_is_an_error(tmp_path):
    assert parse_categories('{"categories": {"self_harm": 1.7, "grooming": -2}}')["self_harm"] == 1.0
    with pytest.raises(ValueError, match="not a number"):
        parse_categories('{"categories": {"self_harm": "high"}}')


def test_code_fences_are_stripped(tmp_path):
    fenced = "```json\n" + json.dumps({"categories": {"violence": 0.8, "safe": 0.2}}) + "\n```"
    assert parse_categories(fenced)["violence"] == 0.8


def test_a_missing_key_is_a_clear_refusal_not_a_traceback(monkeypatch):
    monkeypatch.delenv("DEEPSEEK_API_KEY", raising=False)
    with pytest.raises(DeepSeekUnavailable, match="DEEPSEEK_API_KEY is not set"):
        DeepSeekScorer(cache_path=None)


def test_a_refused_key_does_not_retry(tmp_path):
    calls = []

    def handler(request):
        calls.append(request)
        return httpx.Response(401, json={"error": "invalid key"})

    scorer = _scorer(handler, tmp_path)
    with pytest.raises(DeepSeekUnavailable, match="refused"):
        scorer("hello")
    assert len(calls) == 1, "401 is not worth retrying; only 429 and 5xx are"


def test_a_rate_limit_is_retried_and_then_succeeds(tmp_path):
    attempts = {"n": 0}

    def handler(request):
        attempts["n"] += 1
        if attempts["n"] == 1:
            return httpx.Response(429, json={"error": "slow down"})
        return httpx.Response(200, json=_reply({"cyberbullying": 0.7}))

    scorer = _scorer(handler, tmp_path)
    assert scorer("you're a loser")["cyberbullying"] == 0.7
    assert attempts["n"] == 2


def test_the_same_text_is_never_paid_for_twice(tmp_path):
    calls = []

    def handler(request):
        calls.append(1)
        return httpx.Response(200, json=_reply({"substance_use": 0.6}))

    scorer = _scorer(handler, tmp_path)
    scorer("want a hit of the vape")
    scorer("want a hit of the vape")

    assert len(calls) == 1
    assert (scorer.calls, scorer.hits) == (1, 1)

    # And the cache survives a new process, which is what makes a re-run free. The explicit save is the
    # contract: the scorer flushes every 25 calls and at process exit, and a test is neither.
    scorer.save_cache()
    reopened = DeepSeekScorer(
        api_key="test-key",
        client=httpx.Client(transport=httpx.MockTransport(handler)),
        cache_path=str(tmp_path / "cache.json"),
        sleep=lambda _s: None,
        log=lambda _m: None,
    )
    assert reopened("want a hit of the vape")["substance_use"] == 0.6
    assert len(calls) == 1


def test_a_corrupt_cache_is_a_miss_not_a_failure(tmp_path):
    path = tmp_path / "cache.json"
    path.write_text("{not json", encoding="utf-8")

    def handler(request):
        return httpx.Response(200, json=_reply({"violence": 0.5}))

    scorer = _scorer(handler, tmp_path)
    assert scorer("i'll beat him up")["violence"] == 0.5


def test_a_transport_error_is_retried_and_then_reported(tmp_path):
    def handler(request):
        raise httpx.ConnectError("no route to host", request=request)

    scorer = _scorer(handler, tmp_path)
    with pytest.raises(DeepSeekUnavailable, match="gave up after 3 attempts"):
        scorer("anything")


# ── the cache key covers the prompt ──────────────────────────────────────────────────────────────
# Before this, the key was `(model, text)`, so a prompt edit changed what every row should score while
# leaving every key valid: the next run served the old prompt's answers as cache hits and the numbers in
# `EVAL.md` described a prompt that no longer existed. A hit looks exactly like a cheap success, which is
# why the bug would have been found by comparing numbers and not by watching the run.


def test_a_changed_prompt_is_a_miss_not_a_reused_score(tmp_path):
    calls = []

    def handler(request):
        calls.append(json.loads(request.content)["messages"][0]["content"])
        return httpx.Response(200, json=_reply({"grooming": 0.11 * len(calls)}))

    first = _scorer(handler, tmp_path)
    assert first("do you have snapchat")["grooming"] == pytest.approx(0.11)
    first.save_cache()

    # Same text, same model, same cache file — a reworded prompt, which is the whole point.
    second = _scorer(handler, tmp_path, prompt="A different instruction, same contract.")
    assert second("do you have snapchat")["grooming"] == pytest.approx(0.22)

    assert len(calls) == 2, "a prompt change must re-ask; serving the old answer is a silent wrong number"
    assert calls[1] == "A different instruction, same contract.", "the request must carry the prompt that was keyed"
    assert second.hits == 0


def test_the_same_prompt_still_hits_across_processes(tmp_path):
    calls = []

    def handler(request):
        calls.append(1)
        return httpx.Response(200, json=_reply({"self_harm": 0.4}))

    scorer = _scorer(handler, tmp_path)
    scorer("nobody would notice")
    scorer.save_cache()

    reopened = _scorer(handler, tmp_path)  # default prompt both times
    assert reopened("nobody would notice")["self_harm"] == 0.4
    assert len(calls) == 1, "the fix must add misses for a changed prompt, not turn every run into a paid one"


def test_the_cache_key_separates_prompt_from_text(tmp_path):
    # A key built by concatenating the two would let these collide; the prompt digest is what prevents it.
    assert _cache_key("m", "z", prompt="x") != _cache_key("m", "z", prompt="x\x00y")
    assert _cache_key("m", "y\x00z", prompt="x") != _cache_key("m", "z", prompt="x\x00y")
    # And each of the three inputs alone changes the key, so none of them is silently ignored.
    base = _cache_key("deepseek-chat", "text", prompt="prompt")
    assert base != _cache_key("other-model", "text", prompt="prompt")
    assert base != _cache_key("deepseek-chat", "other text", prompt="prompt")
    assert base != _cache_key("deepseek-chat", "text", prompt="other prompt")
    assert base == _cache_key("deepseek-chat", "text", prompt="prompt")
