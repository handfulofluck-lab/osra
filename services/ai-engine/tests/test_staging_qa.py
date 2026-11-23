import hashlib
import json
from datetime import datetime, timedelta, timezone
from unittest.mock import Mock
from uuid import uuid4

import boto3
import pytest
from fastapi.testclient import TestClient

import staging_qa
from app import app
from eval.prompt import CATEGORIES

APPROVED_TEXT = "Synthetic staging fixture"
STUB_POLICY = "Classifier policy for unit testing"
PATH = "/analyze/staging-qa"
BEDROCK_ENDPOINT = "https://vpce-0123456789abcdef0-osratest.bedrock-runtime.eu-central-1.vpce.amazonaws.com"


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
def sdk_session(monkeypatch):
    session = Mock()
    staging_qa._bedrock_client.cache_clear()
    monkeypatch.setattr(boto3, "Session", session)
    yield session
    staging_qa._bedrock_client.cache_clear()


@pytest.mark.parametrize("endpoint", [BEDROCK_ENDPOINT, BEDROCK_ENDPOINT.replace("-osratest.", ".")])
def test_client_signs_the_exact_private_endpoint_and_verifies_tls(sdk_session, monkeypatch, endpoint):
    # Reusing the default regional URL or relaxing TLS, signing, or proxies breaks this check.
    monkeypatch.setenv("OSRA_STAGING_QA_BEDROCK_ENDPOINT_URL", endpoint)

    assert staging_qa._bedrock_client() is sdk_session.return_value.client.return_value
    sdk_session.assert_called_once_with()
    client = sdk_session.return_value.client
    client.assert_called_once()
    args, kwargs = client.call_args
    assert args == ("bedrock-runtime",)
    assert kwargs["endpoint_url"] == endpoint
    assert kwargs["region_name"] == "eu-central-1"
    assert kwargs["verify"] is True
    assert kwargs["config"].signature_version == "v4"
    assert kwargs["config"].proxies == {}
    assert kwargs["config"].retries == {"total_max_attempts": 1, "mode": "standard"}


@pytest.mark.parametrize("endpoint", [
    None,
    "",
    "https://bedrock-runtime.eu-central-1.amazonaws.com",
    BEDROCK_ENDPOINT.replace("eu-central-1", "eu-north-1"),
    BEDROCK_ENDPOINT.replace("https://", "http://"),
    BEDROCK_ENDPOINT.replace("bedrock-runtime.", "bedrock."),
    BEDROCK_ENDPOINT.replace("-osratest.", "-osratest-eu-central-1a."),
    BEDROCK_ENDPOINT + ".example.test",
    BEDROCK_ENDPOINT + "/unexpected",
    BEDROCK_ENDPOINT + "?unexpected=value",
    BEDROCK_ENDPOINT + ":443",
    BEDROCK_ENDPOINT + "\n",
])
def test_bad_private_endpoint_fails_before_sdk_session(sdk_session, monkeypatch, endpoint):
    # A public or permissive fallback would construct the SDK before the configuration is rejected.
    if endpoint is None:
        monkeypatch.delenv("OSRA_STAGING_QA_BEDROCK_ENDPOINT_URL", raising=False)
    else:
        monkeypatch.setenv("OSRA_STAGING_QA_BEDROCK_ENDPOINT_URL", endpoint)

    with pytest.raises(ValueError, match="Frankfurt Bedrock endpoint is invalid"):
        staging_qa._bedrock_client()
    sdk_session.assert_not_called()


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


def test_opt_in_bedrock_receipt_distinguishes_benign_from_provider_failure(setup_qa):
    # Mutant: return an empty benign verdict when Bedrock fails.
    body = payload(include_provider_outcomes=True)
    setup_qa.probabilities = dict.fromkeys(CATEGORIES, 0.0)
    setup_qa.probabilities["safe"] = 1.0
    setup_qa.answer = model_reply(json.dumps({"categories": setup_qa.probabilities}))
    response = TestClient(app).post(PATH, json=body)
    assert response.status_code == 200
    result = response.json()
    assert result["trace_id"] == body["trace_id"] and result["mode"] == "bedrock"
    outcome = result["outcomes"]["bedrock"]
    assert set(result["outcomes"]) == {"bedrock"}
    assert outcome["status"] == "scored" and outcome["flagged"] is False
    assert outcome["severity"] == "info" and outcome["flagged_categories"] == []

    setup_qa.answer = RuntimeError("private marker not for evidence")
    failed = TestClient(app).post(PATH, json=body)
    assert failed.status_code == 200
    assert failed.json()["outcomes"] == {"bedrock": {"status": "unavailable", "reason": "unavailable"}}
    assert "private marker" not in failed.text


def test_receipt_requires_valid_selection_and_approved_fixture(setup_qa, monkeypatch):
    body = payload(include_provider_outcomes=True)
    client = TestClient(app)
    monkeypatch.setenv("OSRA_STAGING_QA_ENGINE", "unapproved")
    assert client.post(PATH, json=body).status_code == 404
    monkeypatch.setenv("OSRA_STAGING_QA_ENGINE", "both")
    assert client.post(PATH, json={**body, "text": "different synthetic sample"}).status_code == 403
    assert client.post(PATH, json=payload()).status_code == 422
    assert setup_qa.calls == []


@pytest.mark.parametrize("mode", ["own", "both"])
def test_receipt_honors_native_calibrated_labels_in_each_mode(setup_qa, monkeypatch, mode):
    # Mutants: turn a calibrated 0.41 flag benign, or hide a successful provider when its peer fails.
    monkeypatch.setenv("OSRA_STAGING_QA_ENGINE", mode)
    probs = {category: 0.0 for category in CATEGORIES if category != "safe"}
    probs["grooming"] = 0.41
    own = Mock(return_value={"model": "v9b", "language": "fr", "categories": probs, "flagged_categories": ["grooming"]})
    monkeypatch.setattr(staging_qa, "score_own", own)
    setup_qa.answer = RuntimeError("discard private reason")
    result = TestClient(app).post(PATH, json=payload(include_provider_outcomes=True)).json()
    own.assert_called_once()
    assert len(setup_qa.calls) == (1 if mode == "both" else 0)
    assert result["outcomes"]["own"] == {
        "status": "scored", "model": "v9b", "language": "fr", "flagged": True, "severity": "warning",
        "categories": probs, "flagged_categories": ["grooming"],
    }
    if mode == "both":
        assert result["outcomes"]["bedrock"] == {"status": "unavailable", "reason": "unavailable"}
    else:
        assert set(result["outcomes"]) == {"own"}


def test_bedrock_positive_survives_missing_own_checkpoint(setup_qa, monkeypatch):
    monkeypatch.setenv("OSRA_STAGING_QA_ENGINE", "both")
    monkeypatch.setattr(staging_qa, "score_own", Mock(side_effect=TimeoutError))
    result = TestClient(app).post(PATH, json=payload(include_provider_outcomes=True)).json()
    assert result["outcomes"]["own"] == {"status": "unavailable", "reason": "timeout"}
    bedrock = result["outcomes"]["bedrock"]
    assert bedrock["model"] == staging_qa.MODEL_ID and bedrock["flagged"] is True
    assert bedrock["flagged_categories"] == ["cyberbullying"] and bedrock["severity"] == "critical"
    assert "language" not in bedrock


@pytest.mark.parametrize("bedrock_flag,own_flag", [(False, False), (True, False), (False, True), (True, True)])
def test_both_returns_independent_verdicts_for_one_scan(setup_qa, monkeypatch, bedrock_flag, own_flag):
    # Mutants: use one provider as fallback, duplicate its result, or overwrite the first positive.
    monkeypatch.setenv("OSRA_STAGING_QA_ENGINE", "both")
    scores = {category: 0.0 for category in CATEGORIES}
    scores["violence" if bedrock_flag else "safe"] = 0.93
    setup_qa.answer = model_reply(json.dumps({"categories": scores}))
    native = {key: 0.1 for key in CATEGORIES if key != "safe"}
    native["grooming"] = 0.41
    own = Mock(return_value={"model": "v9", "language": "en", "categories": native,
                             "flagged_categories": ["grooming"] if own_flag else []})
    monkeypatch.setattr(staging_qa, "score_own", own)
    body = payload(include_provider_outcomes=True)
    response = TestClient(app).post(PATH, json=body)
    assert response.status_code == 200
    receipt = response.json()
    assert receipt["trace_id"] == body["trace_id"] and receipt["mode"] == "both"
    bedrock, local = receipt["outcomes"]["bedrock"], receipt["outcomes"]["own"]
    assert bedrock["flagged"] is bedrock_flag and local["flagged"] is own_flag
    assert bedrock["flagged_categories"] == (["violence"] if bedrock_flag else [])
    assert local["flagged_categories"] == (["grooming"] if own_flag else [])
    assert len(setup_qa.calls) == own.call_count == 1
    assert own.call_args.args[1] == setup_qa.calls[0]["requestMetadata"]["osraQaTraceId"] == body["trace_id"]


def test_actual_route_deadline_keeps_already_completed_bedrock_result(setup_qa, monkeypatch):
    # Mutant: a timeout around gather() discards the completed positive.
    import time

    def delayed(*_):
        time.sleep(0.12)
        return {"model": "v9", "language": "en", "categories": {}, "flagged_categories": []}

    monkeypatch.setenv("OSRA_STAGING_QA_ENGINE", "both")
    monkeypatch.setattr(staging_qa, "MAX_INFERENCE_SECONDS", 0.05)
    monkeypatch.setattr(staging_qa, "score_own", delayed)
    with TestClient(app) as client:
        result = client.post(PATH, json=payload(include_provider_outcomes=True)).json()
    assert result["outcomes"]["bedrock"]["flagged"] is True
    assert result["outcomes"]["own"] == {"status": "unavailable", "reason": "timeout"}


def test_provider_exception_and_input_stay_out_of_logs_and_receipt(setup_qa, monkeypatch, caplog):
    # Mutants: log the model exception or echo the request when neither provider can score it.
    monkeypatch.setenv("OSRA_STAGING_QA_ENGINE", "both")
    monkeypatch.setenv("OSRA_STAGING_QA_ALLOW_SYNTHETIC_PAIR_TEXT", "1")
    sample = "private synthetic free-wording marker"
    failure = "private synthetic provider response marker"
    setup_qa.answer = RuntimeError(failure)
    monkeypatch.setattr(staging_qa, "score_own", Mock(side_effect=RuntimeError(sample)))
    with caplog.at_level("INFO", logger=staging_qa.__name__):
        response = TestClient(app).post(PATH, json=payload(text=sample, include_provider_outcomes=True))
    assert response.status_code == 200
    assert response.json()["outcomes"] == {
        "bedrock": {"status": "unavailable", "reason": "unavailable"},
        "own": {"status": "unavailable", "reason": "unavailable"},
    }
    assert caplog.text.count("staging QA provider unavailable") == 2
    assert sample not in response.text + caplog.text and failure not in response.text + caplog.text


@pytest.mark.parametrize("kind", ["ConnectTimeoutError", "ReadTimeoutError"])
def test_bedrock_sdk_socket_timeout_receives_timeout_class(setup_qa, kind):
    # Mutant: classify a socket timeout as a generic unavailable model.
    from botocore import exceptions

    setup_qa.answer = getattr(exceptions, kind)(endpoint_url="synthetic")
    response = TestClient(app).post(PATH, json=payload(include_provider_outcomes=True))
    assert response.json()["outcomes"] == {"bedrock": {"status": "unavailable", "reason": "timeout"}}
