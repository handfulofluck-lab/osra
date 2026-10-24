"""ADR-0033: the Bedrock scorer, tested without AWS, boto3 or a network.

A fake client stands in for boto3's `bedrock-runtime`, so every case runs offline in CI: the EU-only
route check, the refusal rule, the request each model family gets, the token meter, and the error that
names the missing terms. Whether a model is *good* is the eval run, and that costs money.
"""

import json

import pytest

from eval import run_eval
from eval.banks import HARMFUL_CATEGORIES
from eval.bedrock_scorer import BedrockScorer, BedrockUnavailable, check_route
from eval.prompt import REFUSED_KEY, SYSTEM_PROMPT


class FakeClient:
    """Answers `converse` from a function, and records every request it was sent."""

    def __init__(self, answer):
        self.answer = answer
        self.requests = []

    def converse(self, **request):
        self.requests.append(request)
        return self.answer(request)


def _reply(categories=None, text=None, stop="end_turn", tokens=(300, 60)):
    content = text if text is not None else json.dumps({"categories": categories or {}})
    return {
        "output": {"message": {"role": "assistant", "content": [{"text": content}]}},
        "stopReason": stop,
        "usage": {"inputTokens": tokens[0], "outputTokens": tokens[1]},
    }


def _scorer(answer, tmp_path, model_id="eu.amazon.nova-micro-v1:0", **kwargs):
    client = FakeClient(answer)
    scorer = BedrockScorer(
        model_id=model_id,
        region=kwargs.pop("region", "eu-central-1"),
        client=client,
        cache_path=str(tmp_path / "cache.json"),
        extra_fields=kwargs.pop("extra_fields", {}),
        log=lambda _m: None,
        **kwargs,
    )
    return scorer, client


# ── the route: EU only, checked before any request ──────────────────────────────────────────────


@pytest.mark.parametrize("model_id", [
    "eu.amazon.nova-micro-v1:0",          # the EU profile
    "amazon.nova-micro-v1:0",             # in-region
    "mistral.ministral-3-8b-instruct",    # in-region, another provider
    "eu.anthropic.claude-haiku-5-5",
])
def test_eu_routes_are_allowed(model_id):
    check_route(model_id, "eu-central-1")


@pytest.mark.parametrize("model_id", [
    "global.anthropic.claude-haiku-5-5",  # may leave the EU: the 10 % saving ADR-0033 declines
    "us.amazon.nova-micro-v1:0",
    "apac.amazon.nova-micro-v1:0",
    "arn:aws:bedrock:eu-central-1::foundation-model/amazon.nova-micro-v1:0",
    "",
])
def test_non_eu_routes_are_refused(model_id):
    with pytest.raises(BedrockUnavailable):
        check_route(model_id, "eu-central-1")


@pytest.mark.parametrize("region", ["us-east-1", "eu-west-2", "eu-central-2", "me-central-1"])
def test_regions_outside_the_eu_are_refused(region):
    # London and Zurich are in Europe but not in the EU; ADR-0033 means the EU.
    with pytest.raises(BedrockUnavailable):
        check_route("amazon.nova-micro-v1:0", region)


def test_a_refused_route_sends_nothing(tmp_path):
    client = FakeClient(lambda _r: pytest.fail("a request was sent on a refused route"))
    with pytest.raises(BedrockUnavailable):
        BedrockScorer(model_id="global.amazon.nova-micro-v1:0", region="eu-central-1",
                      client=client, cache_path=None, log=None)
    assert client.requests == []


# ── the answer ──────────────────────────────────────────────────────────────────────────────────


def test_a_well_formed_reply_becomes_probabilities(tmp_path):
    scorer, client = _scorer(lambda _r: _reply({"self_harm": 0.93, "grooming": 0.01}), tmp_path)
    probs = scorer("i won't be a problem for anyone much longer")

    assert probs["self_harm"] == 0.93
    assert probs["hate_speech"] == 0.0
    assert REFUSED_KEY not in probs
    request = client.requests[0]
    assert request["system"] == [{"text": SYSTEM_PROMPT}]  # the same prompt DeepSeek was measured with
    assert request["messages"][0]["content"] == [{"text": "i won't be a problem for anyone much longer"}]


@pytest.mark.parametrize("reply", [
    _reply({"self_harm": 0.9}, stop="content_filtered"),
    _reply({"self_harm": 0.9}, stop="guardrail_intervened"),
    _reply(text="I can't help with that."),
    _reply(text='{"categories": {"self_harm": "high"}}'),
])
def test_a_refusal_or_unreadable_answer_is_flagged_never_safe(tmp_path, reply):
    scorer, _client = _scorer(lambda _r: reply, tmp_path)
    probs = scorer("a message the model would rather not read")

    assert all(probs[c] == 1.0 for c in HARMFUL_CATEGORIES)
    assert probs["safe"] == 0.0
    assert probs[REFUSED_KEY] == 1.0
    assert scorer.usage()["refused_or_unreadable"] == 1


def test_reasoning_blocks_are_ignored_and_only_the_text_is_read(tmp_path):
    def answer(_r):
        reply = _reply({"violence": 0.8})
        reply["output"]["message"]["content"].insert(0, {"reasoningContent": {"reasoningText": {"text": "…"}}})
        return reply

    scorer, _client = _scorer(answer, tmp_path)
    assert scorer("meet me after school, bring your friends")["violence"] == 0.8


# ── the request each family gets ────────────────────────────────────────────────────────────────


def test_claude_gets_thinking_off_and_no_sampling_parameters(tmp_path):
    scorer, client = _scorer(lambda _r: _reply({}), tmp_path, model_id="eu.anthropic.claude-haiku-5-5")
    scorer("hello")
    request = client.requests[0]
    assert request["additionalModelRequestFields"]["thinking"] == {"type": "disabled"}
    assert "temperature" not in request["inferenceConfig"]


def test_other_models_get_temperature_zero_and_extra_fields_pass_through(tmp_path):
    scorer, client = _scorer(lambda _r: _reply({}), tmp_path, model_id="qwen.qwen3-32b-v1:0",
                             extra_fields={"enable_thinking": False})
    scorer("hello")
    request = client.requests[0]
    assert request["inferenceConfig"]["temperature"] == 0
    assert request["additionalModelRequestFields"] == {"enable_thinking": False}


# ── the meter and the cache ─────────────────────────────────────────────────────────────────────


def test_tokens_are_metered_and_priced_per_1000_scans(tmp_path):
    scorer, _client = _scorer(lambda _r: _reply({}, tokens=(280, 60)), tmp_path,
                              price_in=0.046, price_out=0.184)
    scorer("one")
    scorer("two")
    usage = scorer.usage()
    assert usage["calls"] == 2
    assert usage["input_tokens"] == 560 and usage["output_tokens"] == 120
    # (280 × 0.046 + 60 × 0.184) / 1M per scan, × 1,000 — the ADR's Nova Micro arithmetic.
    assert usage["usd_per_1000_scans"] == pytest.approx(0.02392, abs=1e-4)


def test_a_cached_row_bills_nothing_and_a_new_model_misses(tmp_path):
    scorer, client = _scorer(lambda _r: _reply({"grooming": 0.7}), tmp_path)
    scorer("our secret, don't tell your mum")
    scorer.save_cache()
    again, again_client = _scorer(lambda _r: _reply({"grooming": 0.7}), tmp_path)
    assert again("our secret, don't tell your mum")["grooming"] == 0.7
    assert again_client.requests == [] and again.usage()["calls"] == 0
    other, other_client = _scorer(lambda _r: _reply({"grooming": 0.7}), tmp_path,
                                  model_id="mistral.ministral-3-8b-instruct")
    other("our secret, don't tell your mum")
    assert len(other_client.requests) == 1


def test_no_cache_makes_a_second_run_independent(tmp_path, monkeypatch):
    scorer, _client = _scorer(lambda _r: _reply({}), tmp_path)
    scorer("hello")
    scorer.save_cache()
    monkeypatch.setenv("BEDROCK_NO_CACHE", "1")
    second, second_client = _scorer(lambda _r: _reply({}), tmp_path)
    second("hello")
    assert len(second_client.requests) == 1


# ── errors that say what to do ──────────────────────────────────────────────────────────────────


class _ClientError(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.response = {"Error": {"Code": code, "Message": code}}


def test_access_denied_names_the_terms_and_the_role(tmp_path):
    def answer(_r):
        raise _ClientError("AccessDeniedException")

    scorer, _client = _scorer(answer, tmp_path)
    with pytest.raises(BedrockUnavailable, match="terms"):
        scorer("hello")


def test_a_missing_model_id_is_refused(monkeypatch):
    monkeypatch.delenv("BEDROCK_MODEL_ID", raising=False)
    with pytest.raises(BedrockUnavailable, match="BEDROCK_MODEL_ID"):
        BedrockScorer(client=FakeClient(lambda _r: _reply({})), cache_path=None, log=None)


# ── the harness ─────────────────────────────────────────────────────────────────────────────────


def test_the_harness_counts_refusals_and_gates_on_hard_negative_false_alarms(tmp_path, monkeypatch):
    # Every row refused: recall looks perfect and every hard negative is a false alarm, which is exactly
    # why ADR-0033 adds the false-alarm limit to the gate.
    monkeypatch.setitem(run_eval.SCORERS, "regex", lambda _t: dict(
        {c: 1.0 for c in HARMFUL_CATEGORIES}, safe=0.0, **{REFUSED_KEY: 1.0}))
    out = tmp_path / "r.json"
    code = run_eval.main(["--limit-per-category", "2", "--json", str(out), "--fail-over-hard-fp", "0.05"])
    result = json.loads(out.read_text())
    assert code == 1
    for lang in ("en", "ar"):
        flag = result["langs"][lang]["flag"]
        assert flag["refused_or_unreadable"] == result["langs"][lang]["items"]
        assert flag["hard_false_positive_rate"] == 1.0
