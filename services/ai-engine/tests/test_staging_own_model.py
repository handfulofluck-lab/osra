"""Offline tests for the private OSRA checkpoint transport used by staging QA."""

import io
import json
from datetime import datetime, timedelta, timezone
from time import monotonic
from unittest.mock import Mock
from uuid import uuid4

import pytest

import staging_own_model as own

PRIVATE = "https://vpce-0123456789abcdef0-qatest.runtime.sagemaker.eu-central-1.vpce.amazonaws.com"


def reply(trace, version="v9", language="en", flagged=(), **updates):
    scores = {label: 0.1 for label in own.LABELS}
    scores.update({key: 0.41 for key in flagged})
    return {
        "trace_id": trace, "model": version, "language": language, "probs": scores,
        "flagged_categories": list(flagged), "verdict": "flagged" if flagged else "safe",
        "model_sha256": ("1" if version == "v9" else "3") * 64,
        "thresholds_sha256": ("2" if version == "v9" else "4") * 64, **updates,
    }


@pytest.fixture
def sdk(monkeypatch):
    own._client.cache_clear()
    session = Mock()
    monkeypatch.setattr(own.boto3, "Session", session)
    monkeypatch.setenv("OSRA_STAGING_QA_SAGEMAKER_ENDPOINT_URL", PRIVATE)
    for version, model, thresh in [("V9", "1", "2"), ("V9B", "3", "4")]:
        monkeypatch.setenv(f"OSRA_STAGING_QA_{version}_MODEL_SHA256", model * 64)
        monkeypatch.setenv(f"OSRA_STAGING_QA_{version}_THRESHOLDS_SHA256", thresh * 64)
    yield session
    own._client.cache_clear()


def install(sdk, *replies):
    stream = sdk.return_value.client.return_value.invoke_endpoint
    responses = []
    for result in replies:
        raw = result if isinstance(result, bytes) else json.dumps(result).encode()
        responses.append({"ResponseMetadata": {"HTTPStatusCode": 200}, "ContentType": "application/json",
                          "Body": io.BytesIO(raw)})
    stream.side_effect = responses
    return stream, [r["Body"] for r in responses]


def score(trace, budget=1):
    return own.score_own("synthetic fixture", trace, datetime.now(timezone.utc) + timedelta(minutes=2), monotonic() + budget)


@pytest.mark.parametrize("url", [
    "https://runtime.sagemaker.eu-central-1.amazonaws.com", PRIVATE + ".other.test",
    PRIVATE.replace("eu-central-1", "eu-west-1"), PRIVATE.replace("https://", "http://"),
    PRIVATE + "/forward", PRIVATE + "?target=x", "https://proxy@" + PRIVATE[8:],
])
def test_only_private_frankfurt_endpoint_is_eligible(sdk, monkeypatch, url):
    # Mutant: let the AWS SDK use its ordinary public service URL when private config is invalid.
    monkeypatch.setenv("OSRA_STAGING_QA_SAGEMAKER_ENDPOINT_URL", url)
    with pytest.raises(ValueError):
        score(str(uuid4()))
    sdk.assert_not_called()


def test_benign_reply_and_pinned_sdk_configuration(sdk):
    trace = str(uuid4())
    invoke, bodies = install(sdk, reply(trace))
    result = score(trace)
    assert result["flagged_categories"] == [] and result["language"] == "en" and result["model"] == "v9"
    assert all(body.closed for body in bodies)
    client = sdk.return_value.client.call_args
    assert client.args == ("sagemaker-runtime",)
    assert client.kwargs["endpoint_url"] == PRIVATE and client.kwargs["verify"] is True
    config = client.kwargs["config"]
    assert config.signature_version == "v4" and config.proxies == {} and config.retries["total_max_attempts"] == 1
    invoke.assert_called_once()
    assert invoke.call_args.kwargs["EndpointName"] == "osra-staging-own-v9"
    assert json.loads(invoke.call_args.kwargs["Body"]) == {"text": "synthetic fixture", "trace_id": trace}


def test_routed_reply_uses_serving_language_and_its_calibrated_category(sdk):
    trace = str(uuid4())
    invoke, bodies = install(sdk, {"trace_id": trace, "language": "ar", "route": "v9b"},
                             reply(trace, "v9b", "ar", ("grooming",)))
    result = score(trace)
    assert result["model"] == "v9b" and result["language"] == "ar"
    assert result["flagged_categories"] == ["grooming"] and result["categories"]["grooming"] == 0.41
    assert [c.kwargs["EndpointName"] for c in invoke.call_args_list] == ["osra-staging-own-v9", "osra-staging-own-v9b"]
    assert json.loads(invoke.call_args_list[1].kwargs["Body"]) == {
        "text": "synthetic fixture", "trace_id": trace, "lang": "ar",
    }
    assert all(body.closed for body in bodies)


def test_uncertain_requires_two_verified_checkpoints(sdk):
    trace = str(uuid4())
    first = reply(trace, language="uncertain", flagged=("violence",))
    second = reply(trace, "v9b", "uncertain", ("cyberbullying",))
    install(sdk, first, second)
    result = score(trace)
    assert result["model"] == "v9+v9b" and result["language"] == "uncertain"
    assert result["flagged_categories"] == ["cyberbullying", "violence"]
    assert result["categories"]["violence"] == result["categories"]["cyberbullying"] == 0.41
    install(sdk, first, {**second, "model_sha256": "0" * 64})
    with pytest.raises(ValueError):
        score(trace)


@pytest.mark.parametrize("corruption", [
    {"trace_id": "wrong"}, {"language": "fr"}, {"model": "v9b"}, {"model_sha256": "f" * 64},
    {"thresholds_sha256": ""}, {"flagged_categories": ["unreviewed"]}, {"verdict": "flagged"},
    {"flagged_categories": ["violence", "violence"]}, {"probs": {"safe": 1}}, {"message": "surplus"},
])
def test_corrupt_or_unverified_reply_cannot_be_safe(sdk, corruption):
    trace = str(uuid4())
    install(sdk, {**reply(trace), **corruption})
    with pytest.raises(ValueError):
        score(trace)


@pytest.mark.parametrize("value", [True, float("nan"), float("inf"), "0.8", -0.1, 1.1])
def test_reject_invalid_probability(sdk, value):
    trace = str(uuid4())
    data = reply(trace)
    data["probs"]["grooming"] = value
    install(sdk, data)
    with pytest.raises(ValueError):
        score(trace)


def test_reject_oversize_duplicate_json_and_unauthorized_route(sdk):
    trace = str(uuid4())
    for data in [b" " * (own.MAX_REPLY_BYTES + 1), b'{"trace_id":"a","trace_id":"a"}',
                 {"trace_id": trace, "route": "arbitrary-endpoint", "language": "ar"}]:
        invoke, streams = install(sdk, data)
        before = invoke.call_count
        with pytest.raises(ValueError):
            score(trace)
        assert invoke.call_count == before + 1 and all(stream.closed for stream in streams)


def test_expired_budget_or_missing_pins_never_sends_text(sdk, monkeypatch):
    trace = str(uuid4())
    with pytest.raises(TimeoutError):
        score(trace, budget=-1)
    sdk.return_value.client.return_value.invoke_endpoint.assert_not_called()
    monkeypatch.delenv("OSRA_STAGING_QA_V9B_MODEL_SHA256")
    with pytest.raises(ValueError):
        score(trace)
    sdk.return_value.client.return_value.invoke_endpoint.assert_not_called()


@pytest.mark.parametrize("payload", ["bare_scorer", "legacy", "unavailable"])
def test_scorer_or_legacy_payload_without_native_provenance_has_no_verdict(sdk, payload):
    # Mutant: infer a safe/flagged category or detected language from incomplete serving output.
    trace = str(uuid4())
    receipt = reply(trace, flagged=("grooming",))
    native = {key: receipt[key] for key in ("probs", "flagged_categories", "verdict", "model_sha256", "thresholds_sha256")}
    legacy = {"trace_id": trace, "region": "eu-central-1", "model": "v9", "flagged": True,
              "severity": "warning", "categories": {**receipt["probs"], "safe": 0.0}}
    payloads = {"bare_scorer": native, "legacy": legacy, "unavailable": {"error": "adapter_unavailable"}}
    install(sdk, payloads[payload])
    with pytest.raises(ValueError):
        score(trace)
