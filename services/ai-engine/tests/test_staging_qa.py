import hashlib
import json
from datetime import datetime, timedelta, timezone
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

import staging_qa
from app import app
from eval.prompt import CATEGORIES

APPROVED_TEXT = "Synthetic staging fixture"
STUB_POLICY = "Classifier policy for unit testing"
PATH = "/analyze/staging-qa"


def model_reply(answer, stop_reason="end_turn"):
    return {
        "ResponseMetadata": {"HTTPStatusCode": 200},
        "stopReason": stop_reason,
        "output": {"message": {"role": "assistant", "content": [{"text": answer}]}},
    }


class StubBedrock:
    def __init__(self):
        self.calls = []
        self.probabilities = {category: 0.0 for category in CATEGORIES}
        self.probabilities["cyberbullying"] = 0.91437
        self.answer = model_reply(json.dumps({"categories": self.probabilities}))

    def converse(self, **request):
        self.calls.append(request)
        if isinstance(self.answer, Exception):
            raise self.answer
        return self.answer


@pytest.fixture
def setup_qa(monkeypatch):
    bedrock = StubBedrock()
    monkeypatch.setattr(staging_qa, "_bedrock_client", lambda: bedrock)
    monkeypatch.setenv("OSRA_DEPLOYMENT_SCOPE", "staging")
    monkeypatch.setenv("OSRA_STAGING_QA_ANALYZER_ENABLED", "1")
    monkeypatch.setenv("OSRA_STAGING_QA_FIXTURE_SHA256", hashlib.sha256(APPROVED_TEXT.encode()).hexdigest())
    monkeypatch.setenv("OSRA_STAGING_QA_EXPIRES_AT", (datetime.now(timezone.utc) + timedelta(minutes=5)).isoformat())
    monkeypatch.setenv("OSRA_STAGING_QA_SYSTEM_PROMPT", STUB_POLICY)
    monkeypatch.setattr(staging_qa, "APPROVED_PROMPT_SHA256", hashlib.sha256(STUB_POLICY.encode()).hexdigest())
    return bedrock


def payload(**overrides):
    return {"text": APPROVED_TEXT, "trace_id": str(uuid4()), **overrides}


@pytest.mark.parametrize("name,value", [
    ("OSRA_DEPLOYMENT_SCOPE", "production"),
    ("OSRA_STAGING_QA_ANALYZER_ENABLED", ""),
    ("OSRA_STAGING_QA_FIXTURE_SHA256", "*"),
    ("OSRA_STAGING_QA_ALLOW_SYNTHETIC_PAIR_TEXT", "yes"),
    ("OSRA_STAGING_QA_EXPIRES_AT", "2030-01-01T00:00:00Z"),
    ("OSRA_STAGING_QA_EXPIRES_AT", "2020-01-01T00:00:00Z"),
])
def test_disabled_or_expired_gate_never_calls_bedrock(setup_qa, monkeypatch, name, value):
    # Dropping any of these gate conditions would call Bedrock for an otherwise valid fixture.
    monkeypatch.setenv(name, value)
    response = TestClient(app).post(PATH, json=payload())
    assert response.status_code == 404
    assert setup_qa.calls == []


def test_new_wording_is_scored_in_enabled_synthetic_pair_mode(setup_qa, monkeypatch):
    monkeypatch.setenv("OSRA_STAGING_QA_ALLOW_SYNTHETIC_PAIR_TEXT", "1")
    sample = "A sentence chosen during the test."
    response = TestClient(app).post(PATH, json=payload(text=sample))
    assert response.status_code == 200
    assert response.json()["categories"] == setup_qa.probabilities
    call, = setup_qa.calls
    assert call["messages"] == [{"role": "user", "content": [{"text": sample}]}]


@pytest.mark.parametrize("name,value,status", [
    ("OSRA_STAGING_QA_EXPIRES_AT", "2020-01-01T00:00:00Z", 404),
    ("OSRA_DEPLOYMENT_SCOPE", "production", 404),
    ("OSRA_STAGING_QA_SYSTEM_PROMPT", "Unapproved prompt", 404),
    ("", "", 422),
])
def test_synthetic_pair_mode_keeps_other_boundaries(setup_qa, monkeypatch, name, value, status):
    monkeypatch.setenv("OSRA_STAGING_QA_ALLOW_SYNTHETIC_PAIR_TEXT", "1")
    if name:
        monkeypatch.setenv(name, value)
    response = TestClient(app).post(PATH, json=payload(text="🎈" * 257 if status == 422 else APPROVED_TEXT))
    assert response.status_code == status
    assert not setup_qa.calls


def test_only_exact_fixture_text_is_allowed(setup_qa):
    # Trimming before hashing would allow this unapproved variant.
    response = TestClient(app).post(PATH, json=payload(text=APPROVED_TEXT + " "))
    assert response.status_code == 403
    assert setup_qa.calls == []


@pytest.mark.parametrize("prompt", [None, STUB_POLICY + "\n"])
def test_unapproved_prompt_never_initializes_the_sdk(setup_qa, monkeypatch, prompt):
    if prompt is None:
        monkeypatch.delenv("OSRA_STAGING_QA_SYSTEM_PROMPT")
    else:
        monkeypatch.setenv("OSRA_STAGING_QA_SYSTEM_PROMPT", prompt)

    def unexpected_client():
        pytest.fail("an unapproved configuration initialized the Bedrock client")

    monkeypatch.setattr(staging_qa, "_bedrock_client", unexpected_client)
    response = TestClient(app).post(PATH, json=payload())
    assert response.status_code == 404
    assert response.json() == {"detail": "not_found"}
    assert setup_qa.calls == []


@pytest.mark.parametrize("overrides", [{"trace_id": "not-an-opaque-id"}, {"contact": "unexpected-data"}])
def test_bad_input_is_rejected_without_echoing_it(setup_qa, overrides):
    response = TestClient(app).post(PATH, json=payload(**overrides))
    assert response.status_code == 422
    assert response.json() == {"detail": "invalid_request"}
    assert setup_qa.calls == []


def test_inference_receipt_echoes_only_model_probabilities_and_trace(setup_qa):
    request = payload()
    response = TestClient(app).post(PATH, json=request)
    assert response.status_code == 200
    assert response.json() == {
        "flagged": True,
        "severity": "critical",
        "categories": setup_qa.probabilities,
        "model": "openai.gpt-oss-20b-1:0",
        "region": "eu-central-1",
        "trace_id": request["trace_id"],
    }
    call, = setup_qa.calls
    assert call["modelId"] == "openai.gpt-oss-20b-1:0"
    assert call["requestMetadata"] == {"osraQaTraceId": request["trace_id"]}
    assert call["messages"] == [{"role": "user", "content": [{"text": APPROVED_TEXT}]}]
    assert call["system"] == [{"text": STUB_POLICY}]
    assert call["inferenceConfig"] == {"maxTokens": 1000, "temperature": 0}


def test_reply_after_two_seconds_cannot_be_reported_as_inference(setup_qa, monkeypatch):
    # A longer deadline would accept this otherwise valid reply.
    times = iter((100.0, 100.1, 102.01, 102.02))
    monkeypatch.setattr(staging_qa, "monotonic", lambda: next(times))
    response = TestClient(app).post(PATH, json=payload())
    assert response.status_code == 502
    assert response.json() == {"detail": "model_unavailable"}
    assert len(setup_qa.calls) == 1


@pytest.mark.parametrize("answer", [
    RuntimeError("provider-private-detail"),
    model_reply("provider-private-detail"),
    model_reply('{"categories": {"safe": 0.8}}'),
    model_reply('{"categories": {"safe": 0.8, "safe": 0.9}}'),
    model_reply(json.dumps({"categories": {category: -0.01 for category in CATEGORIES}})),
    model_reply(json.dumps({"categories": {category: float("nan") for category in CATEGORIES}})),
    model_reply(json.dumps({"categories": {category: True for category in CATEGORIES}})),
    model_reply(json.dumps({"categories": {category: 0.0 for category in CATEGORIES}}), "max_tokens"),
    model_reply(json.dumps({"categories": {category: 0.0 for category in CATEGORIES}}), "content_filtered"),
])
def test_unusable_provider_answer_cannot_be_reported_as_inference(setup_qa, caplog, answer):
    # Lenient evaluation parsing or a fabricated refusal verdict would return a false success.
    setup_qa.answer = answer
    response = TestClient(app).post(PATH, json=payload())
    assert response.status_code == 502
    assert response.json() == {"detail": "model_unavailable"}
    assert len(setup_qa.calls) == 1
    assert "provider-private-detail" not in caplog.text
    assert APPROVED_TEXT not in caplog.text
